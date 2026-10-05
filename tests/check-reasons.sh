#!/bin/bash
# Asserts the dialog reason for the argv/parent shapes sudo sees in practice.
# Needs build/reason_test (`just build`). No Touch ID prompt, no root.
set -euo pipefail

bin="$(cd "$(dirname "$0")/.." && pwd)/build/reason_test"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0

expect() {  # expect <label> <substring> <actual>
    if [[ "$3" == *"$2"* ]]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s\n     want substring: %s\n     got:            %s\n' "$1" "$2" "$3"
        fail=1
    fi
}

# brew's SystemCommand shape: /usr/bin/sudo [-A] -E -- <cmd>, parent is a script file.
printf '#!/bin/bash\n"%s" -E -- /usr/sbin/installer -pkg /opt/homebrew/Caskroom/zoom/6.4.0/zoom.pkg -target /\n' "$bin" > "$tmp/fake-brew"
chmod +x "$tmp/fake-brew"
out="$("$tmp/fake-brew" upgrade --cask zoom)"
expect "command after --"            "run: /usr/sbin/installer -pkg /opt/homebrew/Caskroom/zoom/6.4.0/zoom.pkg -target /" "$out"
expect "script parent named by file" "requested by: bash fake-brew upgrade --cask zoom" "$out"

# Interpreter parent (brew runs as `ruby -W1 --disable=gems,rubyopt …/brew.rb upgrade`):
# the script, not the interpreter, names the requester. perl ships with macOS.
# shellcheck disable=SC2016  # $ENV is Perl, not shell
printf 'system($ENV{BIN}, "-E", "--", "/usr/bin/true");\n' > "$tmp/brew.pl"
out="$(BIN="$bin" /usr/bin/perl -W -X "$tmp/brew.pl" upgrade --cask zoom)"
expect "interpreter and its flags dropped" "requested by: brew.pl upgrade --cask zoom" "$out"

# Leading options without --, including one that takes a value.
out="$("$bin" -u root -H /usr/bin/id -un)"
expect "options skipped, -u value skipped" "run: /usr/bin/id -un" "$out"

# No command: sudo's own flags are shown.
out="$("$bin" -s)"
expect "no command shows sudo flags" "run: sudo -s" "$out"

# Inline shells are skipped and listed as "via"; `; :` stops bash exec'ing its last command.
out="$(/bin/bash -c '"$0" -- /usr/bin/true; :' "$bin")"
expect "inline shell listed as via" "(via bash -c)" "$out"
out="$(/bin/sh -c '/bin/bash -c '"'"'"$0" -- /usr/bin/true; :'"'"' "$0"; :' "$bin")"
expect "nested inline shells, outermost first" "(via sh -c → bash -c)" "$out"

# Long commands are truncated with an ellipsis.
long="$(printf 'x%.0s' {1..300})"
out="$("$bin" -- /bin/echo "$long")"
expect "long command truncated" "…" "$out"

exit "$fail"
