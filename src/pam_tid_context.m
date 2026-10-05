// pam_tid_context: Touch ID PAM module whose dialog names the command being
// authorized and the process that asked. Mirrors Apple's pam_tid.c guards (GUI
// session, sudo -A askpass) but authenticates via LAContext so it can set
// localizedReason. See docs/how-it-works.md.

#import <Foundation/Foundation.h>
#import <LocalAuthentication/LocalAuthentication.h>
#include <security/pam_appl.h>
#include <security/pam_modules.h>
#include <sys/sysctl.h>
#include <pwd.h>
#include <unistd.h>
#include <SystemConfiguration/SystemConfiguration.h>
#include <os/log.h>
#include <errno.h>

#define MAX_REASON 160
#define LOG os_log_create("pam_tid_context", "auth")

// argv of a process via KERN_PROCARGS2 (layout: int argc, exec path, NULs, argv...).
static NSArray<NSString *> *process_argv(pid_t pid) {
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size < sizeof(int)) return @[];
    char *buf = malloc(size);
    if (!buf) return @[];
    if (sysctl(mib, 3, buf, &size, NULL, 0) != 0) { free(buf); return @[]; }

    int argc;
    memcpy(&argc, buf, sizeof(argc));
    char *p = buf + sizeof(argc), *end = buf + size;
    p += strnlen(p, end - p);                  // skip exec path
    while (p < end && *p == '\0') p++;         // skip padding

    NSMutableArray *args = [NSMutableArray array];
    for (int i = 0; i < argc && p < end; i++) {
        size_t len = strnlen(p, end - p);
        NSString *s = [[NSString alloc] initWithBytes:p length:len encoding:NSUTF8StringEncoding];
        [args addObject:s ?: @"?"];
        p += len + 1;
    }
    free(buf);
    return args;
}

static pid_t parent_of(pid_t pid) {
    struct kinfo_proc kp;
    size_t len = sizeof(kp);
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    if (sysctl(mib, 4, &kp, &len, NULL, 0) != 0 || len == 0) return 0;
    return kp.kp_eproc.e_ppid;
}

// sudo options that consume the following word.
static BOOL takes_value(NSString *opt) {
    static NSSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[@"-u", @"-g", @"-p", @"-C", @"-h", @"-r", @"-t", @"-U", @"-D", @"-R", @"-T"]];
    });
    return [set containsObject:opt];
}

// The command sudo will run: everything after "--", else after the leading options.
static NSArray<NSString *> *sudo_command(NSArray<NSString *> *argv) {
    NSUInteger dashdash = [argv indexOfObject:@"--"];
    if (dashdash != NSNotFound) return [argv subarrayWithRange:NSMakeRange(dashdash + 1, argv.count - dashdash - 1)];
    NSUInteger i = 1;
    while (i < argv.count && [argv[i] hasPrefix:@"-"]) i += takes_value(argv[i]) ? 2 : 1;
    return i < argv.count ? [argv subarrayWithRange:NSMakeRange(i, argv.count - i)] : @[];
}

static NSString *truncated(NSString *s, NSUInteger max) {
    return s.length <= max ? s : [[s substringToIndex:max - 1] stringByAppendingString:@"…"];
}

// Absolute paths shortened to their last component, e.g. the portable-ruby path brew runs under.
static NSArray<NSString *> *basenames(NSArray<NSString *> *words) {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:words.count];
    for (NSString *w in words) [out addObject:[w hasPrefix:@"/"] ? w.lastPathComponent : w];
    return out;
}

static NSString *shell_name(NSArray<NSString *> *argv) {
    if (!argv.count) return nil;
    NSString *name = [argv[0] hasPrefix:@"-"] ? [argv[0] substringFromIndex:1] : argv[0].lastPathComponent;
    return [@[@"sh", @"bash", @"zsh", @"dash", @"ksh", @"fish"] containsObject:name] ? name : nil;
}

// `sh -c '<inline script>'` says nothing about who asked; a script file or an interactive shell does.
static BOOL is_inline_shell(NSArray<NSString *> *argv) {
    return shell_name(argv) && argv.count > 1 && [argv[1] hasPrefix:@"-"] && [argv[1] containsString:@"c"];
}

// "ruby -W1 --disable=gems brew.rb upgrade" -> "brew.rb upgrade": the script names the requester.
static NSArray<NSString *> *without_interpreter(NSArray<NSString *> *argv) {
    static NSArray *interpreters;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ interpreters = @[@"ruby", @"python", @"python3", @"perl", @"node", @"bun", @"deno"]; });
    if (!argv.count || ![interpreters containsObject:argv[0].lastPathComponent]) return argv;
    NSUInteger i = 1;
    while (i < argv.count && [argv[i] hasPrefix:@"-"]) i++;
    return i < argv.count ? [argv subarrayWithRange:NSMakeRange(i, argv.count - i)] : argv;
}

// First ancestor that is not an inline `shell -c` wrapper, e.g. "claude (via zsh -c)".
static NSString *requester(void) {
    NSMutableArray *via = [NSMutableArray array];
    pid_t pid = parent_of(getpid());
    NSArray *argv = process_argv(pid);
    for (int hops = 0; hops < 8 && pid > 1 && is_inline_shell(argv); hops++) {
        [via addObject:[shell_name(argv) stringByAppendingString:@" -c"]];
        pid = parent_of(pid);
        argv = process_argv(pid);
    }
    if (!argv.count) return @"unknown";
    NSString *who = [basenames(without_interpreter(argv)) componentsJoinedByString:@" "];
    if ([who hasPrefix:@"-"]) who = [who substringFromIndex:1];  // login shell "-zsh"
    return via.count ? [NSString stringWithFormat:@"%@ (via %@)", truncated(who, 50),
                                  [[[via reverseObjectEnumerator] allObjects] componentsJoinedByString:@" → "]]
                     : who;
}

static NSString *build_reason(void) {
    NSArray *self_argv = process_argv(getpid());
    NSArray *cmd = sudo_command(self_argv);
    // No command (sudo -s, -v, -i): show sudo's own flags instead.
    NSArray *shown = cmd.count ? cmd : [@[@"sudo"] arrayByAddingObjectsFromArray:
                                        [self_argv subarrayWithRange:NSMakeRange(1, self_argv.count ? self_argv.count - 1 : 0)]];
    NSString *what = [shown componentsJoinedByString:@" "];

    NSString *from = requester();

    NSString *reason = [NSString stringWithFormat:@"run: %@ — requested by: %@",
                        truncated(what, 100), truncated(from, 80)];
    return truncated(reason, MAX_REASON);
}

static BOOL in_aqua_session(void) {
    // Same intent as pam_tid's VPROCMGR_SESSION_AQUA check: only prompt when a GUI is there.
    uid_t console_uid = (uid_t)-1;
    CFStringRef user = SCDynamicStoreCopyConsoleUser(NULL, &console_uid, NULL);
    if (user) CFRelease(user);
    return user != NULL && console_uid != (uid_t)-1;
}

// Only accept the fingerprint for the user sitting at the console, and only when
// that user is the one authenticating (LAContext's policy ignores the PAM user).
static BOOL target_is_console_user(const char *pam_user) {
    struct passwd *pw = getpwnam(pam_user);
    if (!pw) return NO;
    uid_t console_uid = (uid_t)-1;
    CFStringRef user = SCDynamicStoreCopyConsoleUser(NULL, &console_uid, NULL);
    if (user) CFRelease(user);
    return user != NULL && pw->pw_uid == console_uid && getuid() == console_uid;
}

static int evaluate(NSString *reason) {
    LAContext *ctx = [LAContext new];
    NSError *err = nil;
    if (![ctx canEvaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics error:&err]) {
        os_log(LOG, "Touch ID unavailable: %{public}@", err.localizedDescription);
        return PAM_AUTHINFO_UNAVAIL;
    }
    os_log(LOG, "prompting: %{public}@", reason);

    __block BOOL ok = NO;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [ctx evaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics
        localizedReason:reason
                  reply:^(BOOL success, NSError *e) {
                      ok = success;
                      if (!success) os_log(LOG, "declined: %{public}@", e.localizedDescription);
                      dispatch_semaphore_signal(done);
                  }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    return ok ? PAM_SUCCESS : PAM_AUTH_ERR;
}

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    @autoreleasepool {
        const char *user = NULL;
        if (pam_get_user(pamh, &user, NULL) != PAM_SUCCESS || !user) return PAM_AUTHINFO_UNAVAIL;
        if (!in_aqua_session()) { os_log(LOG, "skip: no GUI session"); return PAM_AUTHINFO_UNAVAIL; }

        const void *askpass = NULL;
        if (pam_get_data(pamh, "askpass-enabled", &askpass) == PAM_SUCCESS) {
            os_log(LOG, "skip: sudo -A askpass mode");
            return PAM_AUTHINFO_UNAVAIL;
        }

        if (!target_is_console_user(user)) {
            os_log(LOG, "skip: %{public}s is not the console user / invoking user", user);
            return PAM_AUTHINFO_UNAVAIL;
        }

        // coreauthd evaluates for the caller's effective uid; inside setuid sudo that is
        // root, who has no enrolled fingers ("No identities are enrolled"). Drop to the
        // invoking user for the evaluation only.
        uid_t saved_euid = geteuid();
        if (saved_euid != getuid() && seteuid(getuid()) != 0) {
            os_log_error(LOG, "seteuid(%d) failed: %{errno}d", getuid(), errno);
            return PAM_AUTHINFO_UNAVAIL;
        }
        int rc = evaluate(build_reason());
        if (geteuid() != saved_euid && seteuid(saved_euid) != 0) {
            os_log_fault(LOG, "cannot restore euid %d: %{errno}d", saved_euid, errno);
            abort();
        }
        return rc;
    }
}

PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    return PAM_SUCCESS;
}

PAM_EXTERN int pam_sm_acct_mgmt(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    return PAM_SUCCESS;
}
