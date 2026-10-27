;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; webmin-guix — package definition for the Guix-adapted Webmin fork.
;;;
;;; Module: (webmin-guix packages webmin)   — path matches namespace per
;;; Guix manual §6.8 (channel directory = "guix", see /.guix-channel).
;;;
;;; Source strategy: the upstream RELEASE tarball (not a git-fetch of this
;;; fork).  All Guix adaptations are quilt patches from ../patches applied
;;; by the origin, so upstream files stay byte-pristine in git and the
;;; source hash stays stable across fork commits.  Patch point #2
;;; (miniserv --nofork) and #3 (OS detection pre-seed) are resolved at
;;; the service layer — see patches/README.md — not in source.
;;;
;;; Trimming: the build-time keep-list comes from (webmin-guix profiles
;;; <name>) — modules outside the list are deleted from the OUTPUT tree
;;; only (never from the repository).  Profile "full" carries the 'all
;;; sentinel and disables trimming.

(define-module (webmin-guix packages webmin)
  #:use-module (guix licenses)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module (guix build-system gnu)
  #:use-module (gnu packages perl)
  #:use-module (webmin-guix packages perl-crypt)
  #:export (webmin-guix* webmin-guix webmin-guix-nas))

(define (profile-modules name)
  "Return the keep-list of module directory names for profile NAME, or
#f meaning \"no trim\".  Resolution happens at evaluation time — the
channel's (webmin-guix profiles NAME) module must be on the load path.
Profile \"full\" exports the sentinel symbol 'all (or an empty list):
both mean keep everything."
  (let* ((m (resolve-module
             `(webmin-guix profiles ,(string->symbol name))
             #:ensure #t))
         (mods (module-ref m 'modules)))
    (if (or (null? mods)
            (and (= 1 (length mods)) (eq? (car mods) 'all)))
        #f
        mods)))

(define (webmin-guix* profile)
  "Package constructor: same upstream source and patches as `webmin-guix',
with the install phase trimming to PROFILE's keep-list.  PROFILE \"full\"
disables trimming."
  (let* ((keep (profile-modules profile))
         (keep-str (if keep (string-join keep " ") "")))
    (package
      (name "webmin-guix")
      (version "2.670")
      (source
       (origin
         (method url-fetch)
         (uri (string-append
               "https://github.com/webmin/webmin/releases/download/"
               version "/webmin-" version ".tar.gz"))
         (sha256
          (base32 "08fw90vi4ps7ycfqlv87ygax86nyd1qrsp6a7nl1ishbi5xg0yk1"))
         (patches
          ;; quilt order matters: 0001 first, 0002 second (both touch
          ;; setup.sh; sequential dry-run verified at generation time).
          (list (local-file "../patches/0001-setup-root-guard-warn.patch")
                (local-file "../patches/0002-setup-chown-tolerant.patch")
                ;; 0003 does not touch setup.sh: it appends a Guix entry to
                ;; os_list.txt, which edit_advanced.cgi renders as the
                ;; "Operating system" choices.  Without it the panel offers
                ;; every distro except the one it is running on.
                (local-file "../patches/0003-os-list-guix.patch")
                ;; 0005 adds guix-linux to os_support of a CURATED module set.
                ;; Deliberately not a blanket "guix == generic-linux" alias:
                ;; that would advertise modules that then write to FHS paths
                ;; (/etc/init.d, /etc/apache2) that do not exist here — worse
                ;; than an honest "not available".
                (local-file "../patches/0005-os-support-guix-linux.patch")
                ;; 0006 ships config-guix-linux, the OS profile Webmin reads for
                ;; a guix-linux host (search path, passwd file, index layout).
                (local-file "../patches/0006-config-guix-linux.patch")
                ;; 0007 ships <module>/config-guix-linux for the modules that
                ;; carry per-OS configs.  setup.sh already runs copyconfig.pl,
                ;; which looks for exactly this filename — without it the module
                ;; config falls back to /dev/null, leaving passwd_file unset.
                (local-file "../patches/0007-config-guix-linux-modules.patch")))))
      (build-system gnu-build-system)
      (arguments
       (list
        #:tests? #f                    ; TODO: miniserv smoke test (probe recipe)
        #:phases
        #~(modify-phases %standard-phases
            ;; No autotools here: gnu-build-system has NO #:configure or
            ;; #:build keyword (only configure-flags) — disabling steps is
            ;; done by deleting the phases.
            (delete 'configure)
            (delete 'build)
            (replace 'install
              (lambda* (#:key outputs #:allow-other-keys)
                ;; Unattended setup runs in the SERVICE, not at build time
                ;; (probe: config_dir/var_dir/port/login/password env vars
                ;; feed setup.sh at first activation; #3 pre-seeds os_type
                ;; into the managed config so the OS chooser is skipped).
                (let* ((out (assoc-ref outputs "out"))
                       (dest (string-append out "/share/webmin")))
                  (mkdir-p dest)
                  (invoke "cp" "-a" "." (string-append dest "/"))
                  #$(if keep
                        ;; Trim: keep-list embedded as a space-joined string
                        ;; (plain-string unquote = the boring, guaranteed
                        ;; gexp path).  Two-way assert: every kept module
                        ;; must still exist afterwards (catches stale
                        ;; profile lists at build time), kept != 0.
                        #~(let* ((keep-ls (string-split #$keep-str #\space))
                                 ;; Only TOP-LEVEL module roots count: a
                                 ;; nested module.info (e.g. under acl/)
                                 ;; made the old loop re-enter an already
                                 ;; deleted tree -> lstat ENOENT on parent.
                                 (mod-dirs
                                  (let loop ((ls (find-files dest
                                                             "module.info"))
                                             (acc '()))
                                    (if (null? ls)
                                        (reverse acc)
                                        (let ((d (dirname (car ls))))
                                          (loop (cdr ls)
                                                (if (and (equal? (dirname d)
                                                                 dest)
                                                         (not (member d acc)))
                                                    (cons d acc)
                                                    acc))))))
                                 (to-trim (filter (lambda (d)
                                                    (not (member (basename d)
                                                                 keep-ls)))
                                                  mod-dirs))
                                 (to-keep (filter (lambda (d)
                                                    (member (basename d)
                                                            keep-ls))
                                                  mod-dirs)))
                            (for-each delete-file-recursively to-trim)
                            (for-each
                             (lambda (mod)
                               (unless (file-exists?
                                        (string-append dest "/" mod
                                                       "/module.info"))
                                 (error "webmin-guix trim: kept module missing"
                                        mod)))
                             keep-ls)
                            (when (null? to-keep)
                              (error "webmin-guix trim: kept nothing"))
                            (format #t "TRIM profile=~a kept=~a trimmed=~a~%"
                                    #$profile (length to-keep)
                                    (length to-trim)))
                        #~#t)))))))
      ;; perl is the runtime interpreter: patch-shebangs rewrites the CGI
      ;; tree's #!/usr/local/bin/perl to this store path, which also pins
      ;; the closure.  Probe findings: raid/smart modules exec host mdadm/
      ;; smartmontools; Apache is optional (miniserv is the server).
      (inputs (list perl-crypt))
      (synopsis "Webmin, adapted for declarative Guix systems")
      (description
       "Unofficial Webmin fork whose Guix layer keeps configuration
declarative: services render config fragments for the system to activate,
rather than mutating /etc directly.")
      (home-page "https://github.com/Zhen-LinHuo/webmin-guix")
      ;; Upstream code is BSD-3-Clause (see /LICENCE); files under guix/ are
      ;; GPL-3.0-or-later (see guix/LICENSE).
      (license bsd-3))))

(define-public webmin-guix
  (webmin-guix* "full"))

(define-public webmin-guix-nas
  (webmin-guix* "nas"))