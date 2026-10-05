# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

A Touch ID PAM module for macOS sudo whose dialog names the command and the
requesting process. One Objective-C source file (`src/pam_tid_context.m`), test
tools in `tests/`, install/uninstall scripts in `scripts/`. Findings and evidence:
[docs/how-it-works.md](docs/how-it-works.md).

## Commands

`just test` builds and runs the non-interactive checks; `just lint` runs
shellcheck. Both must pass before committing. CI runs the same on a macOS runner.

## Safety rules

- **Never run `just install`, `just uninstall`, or edit `/etc/pam.d/*` without the
  user confirming a root shell is open.** A module that fails to load makes sudo
  refuse every login; see the "fails to load" section of docs/how-it-works.md.
- Any change to how `sudo_local` is rewritten must keep the libpam gate
  (`build/probe_load`) before and after the write, and the rollback.
- Uninstall order is fixed: remove the `sudo_local` line, verify, then delete the
  module file.
- Test rewrite logic against copies (extract the awk program from the script and
  run it on a copy of `sudo_local`), never against `/etc/pam.d` directly.

## Debugging

Use `/usr/bin/log`, not `log` (a zsh builtin). `just logs` has the predicate.
Inside sudo the module runs with euid 0 until it switches; LocalAuthentication
errors such as "No identities are enrolled" usually mean the evaluation ran as root.

## Conventions

Conventional commits (`feat`, `fix`, `docs`, `test`, `ci`, `chore`). PR titles are
checked by `.github/workflows/conventional-commits.yml`.
