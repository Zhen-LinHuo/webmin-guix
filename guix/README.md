# webmin-guix

An **unofficial fork** of [Webmin](https://github.com/webmin/webmin), adapted
for [GNU Guix](https://guix.gnu.org) systems where `/etc` is declarative and
not meant to be mutated by running services.

This is not affiliated with or endorsed by the Webmin project.

## Why this fork exists

Upstream Webmin assumes a mutable, FHS-style distribution. On Guix System:

- service configuration lives in `config.scm` and is regenerated on reconfigure;
- writing `/etc/samba/smb.conf` (or any managed file) directly is at best
  overwritten at the next activation, at worst a divergence bug;
- there is no systemd, so anything that shells out to `systemctl` must be
  routed differently.

The fork therefore splits into two layers:

| Layer | Location | Policy |
|---|---|---|
| Upstream code | everything tracked on `master` | never edited here; synced from upstream as-is |
| Guix adaptation | `.guix-channel` + `guix/` | developed on the `guix` branch only |

## Repository layout

```
.guix-channel        channel meta-data: (channel (version 0) (directory "guix"))
guix/
  README.md          this file
  LICENSE            full text of GPL-3.0-or-later (applies to guix/**)
  webmin-guix/
    packages/
      webmin.scm     module (webmin-guix packages webmin) — package definition
    services/
      webmin.scm     module (webmin-guix services webmin) — shepherd service
    profiles/
      nas.scm        module (webmin-guix profiles nas)
      router.scm     module (webmin-guix profiles router)
      full.scm       module (webmin-guix profiles full)
    patches/
      README.md      patch-point table and numbering rules
LICENCE              upstream Webmin licence (BSD 3-Clause), untouched
```

Module paths match their namespaces with `guix/` as the load root, as
required by the Guix manual (§6.8, "Package Modules in a Sub-directory").
The sub-directory matters: the rest of this repository is Perl, not Guile
modules, and must stay outside the channel's load path or `guix pull`
would fail while trying to load it.

## Using the channel

Development, straight from a checkout:

```sh
guix build -L guix webmin-guix
```

As a channel (once published state is reached):

```scheme
;; ~/.config/guix/channels.scm
(list (channel
        (name 'webmin-guix)
        (url "https://github.com/Zhen-LinHuo/webmin-guix")
        (branch "guix")))
```

```sh
guix pull && guix build webmin-guix
```

## Licence layering

- **Upstream code is BSD 3-Clause**, as declared by upstream's `LICENCE`
  file (kept verbatim on `master`).
- **Everything under `guix/` is GPL-3.0-or-later** — full text in
  `guix/LICENSE`, SPDX headers on each `.scm` file.
- Patches under `guix/webmin-guix/patches/` are diffs against BSD-licensed
  sources; the patch files themselves are GPL-3.0-or-later.

## Profiles

A *profile* is a plain list of Webmin module directories to keep. Modules
not listed in a profile are excluded at build time — no upstream code is
deleted, the trim happens through the packaging arguments.

- `nas` — storage server (RAID, S.M.A.R.T., shares)
- `router` — edge appliance (networking, firewall fragments)
- `full` — parity with stock Webmin (the `all` sentinel, no trim)

## Status

- [x] Fork created; branch model: `master` = pure upstream sync,
      `guix` = development line (this branch).
- [x] Channel scaffolding per Guix manual: `.guix-channel`, namespace-matched
      module paths.
- [x] Packaging probe passed: unattended setup works, `miniserv` runs without
      an init system, session login works, the RAID module renders.
- [ ] `patches/` — four patch points identified by the probe (root check in
      setup, no-init service start, OS detection, uninstall guard).
- [ ] `profiles/` — lists are drafts; extend to match the acceptance
      checklist before first use.
- [ ] `guix build -L guix webmin-guix` green (placeholders in
      `packages/webmin.scm` still TODO).
- [ ] Channel authentication material before wider publication.

## Syncing with upstream

Add the upstream remote once:

```sh
git remote add upstream https://github.com/webmin/webmin.git
git fetch upstream
git checkout master && git merge --ff-only upstream/master && git push origin master
```

Rebase or merge `guix` against `master` when picking up a new release.
