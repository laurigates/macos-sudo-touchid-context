#!/bin/bash
# Regenerates the README screenshots, capturing only the dialog window (nothing
# else on screen). Do not touch the sensor until the capture message appears.
#
#   screenshot.sh          docs/images/dialog.png: this module's dialog, run through
#                          tests/harness.c (copied as "sudo" so the title matches real
#                          sudo) with brew's argv and a Perl script named brew.rb as
#                          the requester. No system changes needed.
#   screenshot.sh stock    docs/images/dialog-stock.png: Apple's pam_tid.so dialog from
#                          real /usr/bin/sudo. Only real sudo is entitled to that
#                          authorization right, so pam_tid.so must be the active
#                          sudo_local line; the script refuses otherwise.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$root/build/screenshot"
mode="${1:-module}"
mkdir -p "$work" "$root/docs/images"
cd "$work"

case "$mode" in
module)
    out="$root/docs/images/dialog.png"
    cp "$root/build/harness" "$work/sudo"
    cat > "$work/brew.rb" <<'EOF'
system("./sudo", "-E", "--", "/usr/sbin/installer", "-pkg",
       "/opt/homebrew/Caskroom/zoom/6.4.0/zoomusInstallerFull.pkg", "-target", "/");
EOF
    MODULE="$root/build/pam_tid_context.so" /usr/bin/perl -W brew.rb upgrade --cask zoom &
    ;;
stock)
    out="$root/docs/images/dialog-stock.png"
    if ! grep -v '^[[:space:]]*#' /etc/pam.d/sudo_local 2>/dev/null | grep -qE '[[:space:]]pam_tid\.so([[:space:]]|$)'; then
        echo "screenshot: pam_tid.so is not the active sudo_local line; see README for switching" >&2
        exit 1
    fi
    /usr/bin/sudo -k
    # Apple's dialog does not name the command, so a harmless one is used.
    /usr/bin/sudo /usr/bin/true &
    ;;
*)
    echo "usage: $0 [stock]" >&2
    exit 2
    ;;
esac

/bin/sleep 3
# Touch ID sheets are drawn by coreautha (LocalAuthentication) or SecurityAgent (Authorization).
"$root/build/windows" > windows.txt
id="$(awk -F'\t' '$2 == "coreautha" || $2 == "SecurityAgent" { print $1; exit }' windows.txt)"
if [[ -z "$id" ]]; then
    echo "screenshot: no coreautha/SecurityAgent window found; cancel the dialog" >&2
    wait || true
    exit 1
fi
screencapture -x -l "$id" "$out"
echo "screenshot: captured window $id -> ${out#"$root"/} (cancel or approve the dialog now)"
wait || true
