# Patches directory

Quilt-style patches applied on top of the upstream sources by
`(webmin-guix packages webmin)` (`../packages/webmin.scm`) through the
origin's `patches` field.  One file per fix, named

    0001-short-description.patch

## Known patch points (from the packaging probe)

| # | File | Why | Where it lives |
|---|------|-----|----------------|
| 1 | `setup.sh` | hard `exit 1` when not run as root — unattended setup must survive a non-root activation user; downgraded to a warning | `0001-setup-root-guard-warn.patch` |
| 2 | miniserv start path | must run without an init system (no systemd): `miniserv.pl --nofork` foreground invocation | **service layer** — the Guix service invokes `--nofork` (probe-validated flag, no source edit needed) |
| 3 | OS detection | `os_type` empty → `oschooser.pl` (autoos=2) fails on Guix's `/etc/issue`/`os-release` and falls into an interactive STDIN prompt that EOFs under unattended runs | **service layer** — the service pre-seeds `os_type=`/`real_os_type=` into the managed config *before* running setup; `setup.sh` reads existing config first (line ~184) and skips the chooser entirely |
| 4 | uninstall / root guards | `chown`/`chgrp -R bin` in the permissions pass fail for non-root or a host without a `bin` group | `0002-setup-chown-tolerant.patch` |

None of these patches delete upstream functionality; they relax environment
assumptions so the same code runs on a declarative host.

## Rules

- Patches must apply cleanly to `master` at the release the package pins.
  Verify with `patch -p1 --dry-run` against the pristine tarball (in quilt
  order when patches touch the same file) before wiring into the origin.
- New patches get a new number; never rewrite a pushed one (rebase instead).
- Files here are GPL-3.0-or-later (see `../../LICENSE`).
