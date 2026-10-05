// Prints the reason string the module would show, without prompting Touch ID.
// Invoke it with sudo-shaped arguments from different parents to exercise the
// command parser and the requester walk (see tests/check-reasons.sh).
#include "../src/pam_tid_context.m"

int main(void) {
    @autoreleasepool { printf("%s\n", build_reason().UTF8String); }
    return 0;
}
