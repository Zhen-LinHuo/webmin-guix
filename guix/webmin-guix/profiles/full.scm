;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Full profile — parity with a stock Webmin install (no trimming).
;;;
;;; Module: (webmin-guix profiles full)
;;; Serves as the reference: profiles/nas.scm and profiles/router.scm are
;;; subsets of this list.  Build with this profile to compare behaviour
;;; against upstream Webmin.

(define-module (webmin-guix profiles full)
  #:export (profile-name modules))

(define profile-name "full")

(define modules
  '(
    ;; Empty list = keep everything (the packager treats 'all as the
    ;; sentinel for "no trim").  When explicit trimming is needed, list the
    ;; modules to keep here first, then derive nas/router as subsets.
    all))
