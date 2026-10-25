;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Router profile — Webmin modules to KEEP for an edge router / gateway.
;;;
;;; Module: (webmin-guix profiles router)
;;; Draft: shrink toward what an appliance-style router actually exposes.
;;; Nothing here writes /etc directly; firewall/NAT changes must be emitted
;;; as config.scm fragments (see guix/README.md).

(define-module (webmin-guix profiles router)
  #:export (profile-name modules))

(define profile-name "router")

(define modules
  '(
    ;; --- networking core ---
    "index"
    "sysinfo"
    "network"               ; interfaces, addresses (read + fragment emit)
    "iptables"              ; firewall rules — emit, never iptables-restore
                            ; onto a declarative host without activation hook
    "squid"                 ; proxy (if enabled on the host)

    ;; --- base admin surface ---
    "users"
    "cron"
    "logs"

    ;; TODO: narrow further per appliance threat model: drop anything that
    ;; only makes sense for a general-purpose server (disk modules, package
    ;; managers, bind zones unless actually used).
    ))
