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
  #:use-module ((webmin-guix packages webmin)
                #:select (webmin-guix-nas))
  #:use-module (gnu packages bash)                ; bash-minimal for shell helpers
  #:use-module (gnu packages linux)               ; psmisc lives here (pkill)
  #:use-module (gnu packages perl)
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
               (perl-bin  #$(file-append perl "/bin/perl"))
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
           ;; Webmin rebuilds $ENV{PATH} in init_config() from the "path" key of
           ;; its managed config, and otherwise falls back to the Debian layout
           ;; (/usr/local/sbin:/usr/sbin:/sbin:/bin) — none of which exists on
           ;; Guix.  A module then reports "command not found" for a binary that
           ;; is world-executable in the profile.  Keep the key present so the
           ;; search path is the system profile, not a guess.  (Measured: with
           ;; this key absent, /fdisk/ fails; with it present, it lists disks.)
           (let* ((want     (string-append
                             "path=/run/current-system/profile/sbin:"
                             "/run/current-system/profile/bin:"
                             "/run/privileged/bin"))
                  ;; No srfi-1 here: shepherd's user module has no `any', and an
                  ;; unbound binding aborts startup (measured: exit 1, service
                  ;; respawn-looping instead of serving the panel).
                  (has-key? (lambda (key)
                              (lambda (txt)
                                (let loop ((ls (string-split txt #\newline)))
                                  (cond ((null? ls) #f)
                                        ((string-prefix? key (car ls)) #t)
                                        (else (loop (cdr ls))))))))
                  (has-path? (has-key? "path=")))
             (when (file-exists? cfg)
               (let ((txt (call-with-input-file cfg get-string-all)))
                 (unless (has-path? txt)
                   (let ((p (open-file cfg "a")))
                     (display want p)
                     (newline p)
                     (close-port p))))))
           ;; Module configs are seeded by Webmin's OWN copyconfig.pl, which
           ;; setup.sh invokes with os_type/real_os_type: it looks for
           ;; <module>/config-guix-linux, then config-ALL-linux, then config.
           ;; Patches 0006/0007 supply those files, so no local copying logic is
           ;; needed here — deliberately, so the lookup order stays upstream's.
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
