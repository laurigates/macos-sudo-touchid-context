// Asks the system libpam whether a PAM policy would load, without installing it.
//
//   probe_load <module.so>      wraps the module in "auth sufficient <path>"
//   probe_load <policy-file>    parses the file as a pam.d policy (all facilities)
//
// Exit 0: every module in the policy loaded. Exit 1: libpam rejected it — the
// same failure that makes sudo print "unable to initialize PAM". Exit 2: the probe
// itself could not run (bad args, or this macOS no longer exports the parser).
//
// Uses openpam_read_chain_from_filehandle, an OpenPAM-internal function that
// Apple's libpam exports. Signature and enum values from Apple OpenPAM-35:
// openpam/lib/openpam_configure.c:128 and openpam/lib/openpam_impl.h:72,136.

#include <security/pam_appl.h>
#include <dlfcn.h>
#include <pwd.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum { PAM_FACILITY_ANY = -1, PAM_AUTH = 0 };
enum { pam_conf_style = 0, pam_d_style = 1 };

typedef int (*read_chain_fn)(pam_handle_t *, const char *, int, FILE *, const char *, int);

static int null_conv(int n, const struct pam_message **m, struct pam_response **r, void *d) {
    return PAM_CONV_ERR;
}

static int parse(read_chain_fn read_chain, pam_handle_t *h, FILE *f, const char *label, int facility) {
    return read_chain(h, "probe", facility, f, label, pam_d_style);
}

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: %s <module.so | policy-file>\n", argv[0]); return 2; }

    read_chain_fn read_chain = (read_chain_fn)dlsym(RTLD_DEFAULT, "openpam_read_chain_from_filehandle");
    if (!read_chain) { fprintf(stderr, "probe: libpam does not export the parser: %s\n", dlerror()); return 2; }

    struct pam_conv conv = {null_conv, NULL};
    pam_handle_t *h = NULL;
    if (pam_start("pam_tid_context_probe", getpwuid(getuid())->pw_name, &conv, &h) != PAM_SUCCESS) {
        fprintf(stderr, "probe: pam_start failed\n");
        return 2;
    }

    // Control: Apple's own module must load, or the probe is broken rather than the policy.
    const char *control = "auth sufficient pam_tid.so\n";
    int c = parse(read_chain, h, fmemopen((void *)control, strlen(control), "r"), "control", PAM_AUTH);
    if (c != 1) { fprintf(stderr, "probe: control (pam_tid.so) returned %d, expected 1\n", c); pam_end(h, 0); return 2; }

    FILE *f;
    char line[1100];
    size_t len = strlen(argv[1]);
    if (len > 3 && strcmp(argv[1] + len - 3, ".so") == 0) {
        // OpenPAM resolves a path without a leading '/' against its module
        // directory (openpam_dynamic.c:211), so make a file argument absolute.
        char abs[PATH_MAX];
        if (!realpath(argv[1], abs)) { perror(argv[1]); pam_end(h, 0); return 2; }
        snprintf(line, sizeof line, "auth sufficient %s\n", abs);
        f = fmemopen(line, strlen(line), "r");
    } else if (!(f = fopen(argv[1], "r"))) {
        perror(argv[1]);
        pam_end(h, 0);
        return 2;
    }

    int n = parse(read_chain, h, f, argv[1], PAM_FACILITY_ANY);  // parse closes f
    pam_end(h, 0);
    if (n < 0) { printf("REJECTED %s (libpam returned %d)\n", argv[1], n); return 1; }
    printf("OK %s (%d module line(s) loaded)\n", argv[1], n);
    return 0;
}
