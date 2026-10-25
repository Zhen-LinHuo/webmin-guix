;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; NAS profile — Webmin modules to KEEP when building for a storage server.
;;;
;;; Module: (webmin-guix profiles nas)
;;; Modules not listed here are excluded at build time; upstream files are
;;; never deleted from the repository.
;;;
;;; Every name below was VERIFIED against webmin 2.670's top-level module
;;; directories (module.info presence + its desc= line) — the build's
;;; two-way assert fails hard on any stale name, so keep this list in
;;; lockstep with upstream renames on every version bump.

(define-module (webmin-guix profiles nas)
  #:export (profile-name modules))

(define profile-name "nas")

(define modules
  '(
    ;; --- storage / array management (core requirement) ---
    "raid"                 ; Linux RAID — reads /proc/mdstat, mdadm exec
    "fdisk"                ; desc: Partitions on Local Disks — the Linux module
                           ; ("format" is Solaris-only: os_support=solaris)
    "smart-status"         ; desc: SMART Drive Status (was "smart")
    "mount"                ; desc: Disk and Network Filesystems
    "quota"                ; desc: Disk Quotas

    ;; --- services typical for a storage server ---
    "samba"                ; rendered as fragments, NOT direct /etc writes
    "status"               ; desc: System and Server Status (disk-space
                           ; monitors — was "disk-usage", no such module)

    ;; --- base admin surface ---
    "system-status"        ; desc: System Status — dashboard/landing
                           ; (was "index" + "sysinfo"; neither exists)
    "useradmin"            ; desc: Users and Groups (was "users")
    "cron"
    "logviewer"            ; desc: System Logs (was "logs")

    ;; TODO: add from acceptance checklist (share CRUD, scheduled tasks,
    ;; S.M.A.R.T. alerts).  Keep the list minimal: every module here is
    ;; surface we commit to maintaining against Guix's declarative model.
    ))
