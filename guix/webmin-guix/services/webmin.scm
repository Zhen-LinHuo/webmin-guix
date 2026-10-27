;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; webmin-guix — shepherd service for Webmin's miniserv.
;;;
;;; Module: (webmin-guix services webmin)
;;;
;;; Design notes (all three probe-verified against webmin 2.670):
;;;   * `miniserv.pl --nofork <abs-config>` — --nofork must be argv[1],
;;;     exactly one further argument (the config file) or it exits.
;;;   * `setup.sh` consumes UNATTENDED input from the environment
;;;     (config_dir, var_dir, port, login, crypt, ssl, atboot,
;;;     nouninstall, noportcheck) and takes wadir as $1.
;;;   * Patch point #3 (interactive oschooser) is defeated WITHOUT any
;;;     pre-seed file: the "Get old os name" config reads (line ~184)
;;;     live inside the upgrading=1 branch (three-file check at 140/155),
;;;     so on a fresh install the os_*/real_os_* ENVIRONMENT variables
;;;     reach line 360 untouched and `if [ "$os_type" = "" ]` skips the
;;;     chooser — while the config dir stays empty (setup refuses a
;;;     non-empty dir at line ~236).
;;;
;;; First-run setup lives in the shepherd START WRAPPER (idempotent via
;;; the config-exists guard) rather than an activation hook: same root
;;; privilege at boot, one fewer API surface, and miniserv is handed off
;;; with execl so the shepherd tracks the same pid for stop/kill.

(define-module (webmin-guix services webmin)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:use-module (guix packages)                     ; package-version
  #:use-module ((webmin-guix packages webmin)
                #:select (webmin-guix-nas))
  #:use-module (gnu packages bash)                ; bash-minimal for shell helpers
  #:use-module (gnu packages linux)               ; psmisc lives here (pkill)
  #:use-module (webmin-guix packages perl-crypt)
  #:use-module (srfi srfi-1)                      ; filter-map
  #:use-module (srfi srfi-13)                     ; string-join
  #:export (webmin-configuration
            webmin-configuration?
            webmin-configuration-package
            webmin-configuration-port
            webmin-configuration-ssl?
            webmin-configuration-username
            webmin-configuration-password-crypt
            webmin-configuration-config-dir
            webmin-service-type))

(define-record-type* <webmin-configuration>
  webmin-configuration make-webmin-configuration
  webmin-configuration?
  (package       webmin-configuration-package
                 (default webmin-guix-nas))
  (port          webmin-configuration-port
                 (default 10000))
  (ssl?          webmin-configuration-ssl?
                 (default #f))
  (username      webmin-configuration-username
                 (default "admin"))
  ;; crypt(3) hash for the panel login — never a plaintext password in
  ;; config.scm.  Example: openssl passwd -6  (setup's `crypt` env var
  ;; consumes the hash directly; empty = refuse to start with a clear
  ;; error instead of letting setup.sh fall into an interactive prompt).
  (password-crypt webmin-configuration-password-crypt
                 (default ""))
  (config-dir    webmin-configuration-config-dir
                 (default "/var/lib/webmin"))
  ;; OS pre-seed (patch point #3).  *-linux suffix matters: setup.sh's
  ;; init-module filter matches /-linux$/; copyconfig finds no per-module
  ;; dir for guix-linux and falls back to default configs (verified in
  ;; the v4 VM pass — flip here if evidence says otherwise).
  (os-type       webmin-configuration-os-type
                 (default "guix-linux"))
  (real-os-type  webmin-configuration-real-os-type
                 (default "guix"))
  (os-version    webmin-configuration-os-version
                 (default "rolling"))
  (real-os-version webmin-configuration-real-os-version
                 (default "1.0")))

(define (webmin-start-wrapper config)
  "Gexp program: idempotent unattended setup, then hand off to miniserv
in the foreground (shepherd-tracked pid)."
  (let ((pkg     (webmin-configuration-package config))
        (conf    (webmin-configuration-config-dir config))
        (port    (number->string (webmin-configuration-port config)))
        (ssl     (if (webmin-configuration-ssl? config) "1" "0"))
        (user    (webmin-configuration-username config))
        (crypt   (webmin-configuration-password-crypt config))
        (os-t    (webmin-configuration-os-type config))
        (ros-t   (webmin-configuration-real-os-type config))
        (os-v    (webmin-configuration-os-version config))
        (ros-v   (webmin-configuration-real-os-version config)))
    (program-file
     "webmin-start"
     #~(begin
         ;; The shepherd user module is minimal: get-string-all is NOT bound
         ;; there, and a missing binding here aborts service startup entirely
         ;; (measured: "Unbound variable: get-string-all" on boot).
         (use-modules (ice-9 textual-ports))
         ;; A gexp program is evaluated in its own scope: the module's
         ;; #:use-module forms do NOT apply here.  Missing these two made the
         ;; start program die with "Unbound variable" on every attempt, which
         ;; looked like a broken service with no message.
         (use-modules (srfi srfi-1) (srfi srfi-13))
         ;; scandir lives in (ice-9 ftw) — not core, and not inherited
         ;; from the module's imports either.
         (use-modules (ice-9 ftw))
         (when (string-null? #$crypt)
           (error "webmin: password-crypt is empty — set a crypt(3) hash \
in webmin-configuration (e.g. output of `openssl passwd -6')"))
         ;; let* (NOT let): conf-file/cfg initializers reference `conf'
         ;; bound in the SAME form — parallel let would evaluate them
         ;; against the enclosing gexp scope, where `conf' is data, not
         ;; a variable -> runtime "Unbound variable: conf".
         (let* ((wadir     #$(file-append pkg "/share/webmin"))
               (conf      #$conf)
               (miniserv  #$(file-append pkg "/share/webmin/miniserv.pl"))
               ;; same perl the package's shebangs reference (closure
               ;; consistency); setup.sh line 290 skips its interactive
               ;; "Full path to perl:" prompt when $perl is set —
               ;; perldef only probes /usr/bin and /usr/local/bin,
               ;; which never exist on Guix (store paths).
               (perl-bin  #$(file-append perl-crypt "/bin/perl"))
               (conf-file (string-append conf "/miniserv.conf"))
               (cfg       (string-append conf "/config")))
           (unless (file-exists? cfg)
             ;; A setup attempt that died mid-way leaves files that
             ;; trip setup's "not empty" check (line ~236) on retry —
             ;; wipe the managed state dir and start clean.  config's
             ;; absence is the "install incomplete" marker.
             (when (file-exists? conf)
               (system* "rm" "-rf" conf))
             ;; NO pre-seed file: setup.sh refuses a non-empty config
             ;; dir, and its "Get old os name" reads (line ~184) sit
             ;; inside the upgrading=1 branch only (three-file check at
             ;; 140/155) — on a fresh install the os_* ENVIRONMENT
             ;; variables reach line 360 untouched and its
             ;; `if [ "$os_type" = "" ]` skips oschooser entirely.
             (setenv "config_dir" conf)
             (setenv "var_dir" (string-append conf "/var"))
             (setenv "perl" perl-bin)
             (setenv "os_type" #$os-t)
             (setenv "real_os_type" #$ros-t)
             (setenv "os_version" #$os-v)
             (setenv "real_os_version" #$ros-v)
             (setenv "port" #$port)
             (setenv "login" #$user)
             (setenv "crypt" #$crypt)
             (setenv "ssl" #$ssl)
             (setenv "atboot" "0")        ; shepherd owns start-at-boot
             (setenv "nouninstall" "1")   ; no sysv script management
             (setenv "noportcheck" "1")
             (unless (zero? (system* (string-append wadir "/setup.sh") wadir))
               (error "webmin: unattended setup.sh failed")))
           ;; setup.sh creates the panel user and its ACL only on the
           ;; interactive path; measured on the installed system, this
           ;; unattended flow left `miniserv.users' at zero bytes and wrote no
           ;; `webmin.acl' at all, so miniserv had nobody to authenticate and
           ;; every login failed while the service looked healthy.
           ;;
           ;; Both files are facts of this configuration (the user and its
           ;; crypt(3) hash come from webmin-configuration), so write them here
           ;; rather than hoping an upstream branch runs.  Idempotent: rewriting
           ;; the same bytes on every start keeps the panel user in step with a
           ;; reconfigure that changes the hash.
           (let* ((ufile (string-append conf "/miniserv.users"))
                  (afile (string-append conf "/webmin.acl"))
                  (mods  (filter-map (lambda (d)
                                       (and (file-exists?
                                             (string-append wadir "/" d "/module.info"))
                                            d))
                                     ;; scandir's 2nd argument is a selector and
                                     ;; the 3rd is the sort predicate; passing
                                     ;; string<? as the selector raises at
                                     ;; runtime and takes the whole service down.
                                     (scandir wadir (const #t) string<?))))
             ;; simple-format, not format: `format' lives in (ice-9 format)
             ;; and is NOT available in a gexp program.  Calling it creates the
             ;; file and then raises, so the service exits 1 with two empty
             ;; files behind it — which is exactly how this looked.
             (call-with-output-file ufile
               (lambda (p) (simple-format p "~a:~a:0~%" #$user #$crypt)))
             (call-with-output-file afile
               (lambda (p) (simple-format p "~a: ~a~%" #$user (string-join mods " ")))))

           ;; Two things `setup.sh' does only on its interactive path, both
           ;; missing here (measured on an installed system: `config' held just
           ;; `path=', no os_type, and no config-guix-linux anywhere under the
           ;; config dir).  Without them patches 0005/0006/0007 are inert at
           ;; runtime: modules never see guix-linux and useradmin keeps
           ;; upstream's base_uid=500, below Guix's uid floor.
           ;;
           ;; Seed key by key, never overwriting a value the panel has written
           ;; since — config.cgi saves into this same file.
           (let* ((kv-file (lambda (f)
                             (if (file-exists? f)
                                 (filter (lambda (l)
                                           (and (string-contains l "=")
                                                (not (string-prefix? "#" l))))
                                         (string-split
                                          (call-with-input-file f get-string-all)
                                          #\newline))
                                 '())))
                  (key-of (lambda (l) (car (string-split l #\=))))
                  (present? (lambda (ls k)
                              (any (lambda (l) (string=? (key-of l) k)) ls)))
                  (existing (kv-file cfg))
                  (wanted (append
                           (kv-file (string-append wadir "/config-guix-linux"))
                           (list (string-append "os_type=" #$os-t)
                                 (string-append "real_os_type=" #$ros-t)
                                 (string-append "os_version=" #$os-v)
                                 (string-append "real_os_version=" #$ros-v)
                                 (string-append "version=" #$(package-version pkg))
                                 (string-append
                                  "path=/run/current-system/profile/sbin:"
                                  "/run/current-system/profile/bin:"
                                  "/run/privileged/bin"))))
                  (missing (filter (lambda (l)
                                     (not (present? existing (key-of l))))
                                   wanted)))
             (unless (null? missing)
               (let ((p (open-file cfg "a")))
                 (for-each (lambda (l) (simple-format p "~a~%" l)) missing)
                 (close-port p))))
           ;; Module defaults: upstream copyconfig.pl copies
           ;; <module>/config-guix-linux to <config-dir>/<module>/config on
           ;; install.  Same copy, same order, only when the module has no
           ;; config yet.
           (for-each
            (lambda (d)
              (let ((seed   (string-append wadir "/" d "/config-guix-linux"))
                    (target (string-append conf "/" d "/config")))
                (when (and (file-exists? seed) (not (file-exists? target)))
                  (system* "mkdir" "-p" (string-append conf "/" d))
                  (copy-file seed target)
                  (chmod target #o644))))
            (scandir wadir (const #t) string<?))
           ;; Foreground hand-off: same pid -> shepherd stop/kill works.
           ;;
           ;; PATH is the only thing Webmin's has_command() consults (it walks
           ;; $ENV{PATH}, not any config key), and shepherd hands services a
           ;; bare "profile/bin".  Every storage and account tool lives in
           ;; profile/sbin — fdisk, sfdisk, mdadm, smartctl, useradd, chpasswd —
           ;; so without this the modules report "program not found" although
           ;; the binaries are present and world-executable.
           ;; setup.sh's post-install hook starts miniserv in the BACKGROUND
           ;; (.start-init).  That orphan holds :10000; this process then cannot
           ;; bind, exits 1, and shepherd respawns for ever while the orphan
           ;; serves (measured: `herd stop' left two miniserv alive on the port).
           ;; Reclaim the port before the hand-over, scoped to our config file.
           (system* #$(file-append psmisc "/bin/pkill")
                    "-f" (string-append "miniserv[.]pl .*" conf-file))
           (sleep 1)
           (setenv "PATH"
                   (string-append "/run/current-system/profile/sbin:"
                                  "/run/current-system/profile/bin:"
                                  "/run/privileged/bin"))
           (execl miniserv miniserv "--nofork" conf-file))))))

(define (webmin-shepherd-service config)
  (list
   (shepherd-service
    (provision '(webmin))
    (documentation "Webmin miniserv (webmin-guix), configured declaratively.")
    ;; make-forkexec-constructor wants a LIST of strings as `command'
    ;; (the ssh service passes a pre-built list gexp; a bare program-file
    ;; path is a plain string -> "wrong type ... list-of-strings?").
    ;; log to the console (not a guest file): during the bring-up loop
    ;; there is no console login yet, and wrapper/setup/miniserv stderr
    ;; must land in the captured serial log.  Move to /var/log/webmin.log
    ;; once the service is green.
    (start #~(make-forkexec-constructor
              (list #$(webmin-start-wrapper config))
              #:log-file "/dev/console"))
    (stop #~(make-kill-destructor))
    (respawn? #t))))

(define webmin-service-type
  (service-type
   (name 'webmin)
   (description
    "Run Webmin's miniserv with declarative configuration; first-run \
unattended setup happens at service start, guarded by config existence.")
   (extensions
    (list (service-extension
           shepherd-root-service-type
           webmin-shepherd-service)))
   (default-value (webmin-configuration))))
