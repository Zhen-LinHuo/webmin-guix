;;; perl-crypt.scm — Perl with a working crypt().
;;;
;;; Guix's glibc no longer carries crypt(): the symbol lives in libxcrypt, and
;;; Perl's Configure only finds it if that library directory is on its search
;;; path.  Without this, `crypt("xx", "yy")' raises "The crypt() function is
;;; unimplemented due to excessive paranoia" in *every* Guix Perl — which is
;;; fatal for Webmin, whose miniserv verifies user passwords by crypt()ing the
;;; supplied password against /etc/shadow and dies mid-request when it cannot.
;;;
;;; Everything else is inherited unchanged, so this stays a two-line delta over
;;; the stock package rather than a fork that drifts.

(define-module (webmin-guix packages perl-crypt)
  #:use-module (gnu packages)
  #:use-module (gnu packages base)
  #:use-module (gnu packages crypto)          ; libxcrypt
  #:use-module (gnu packages perl)
  #:use-module (guix packages)
  #:use-module (guix gexp)
  #:use-module (guix utils)
  #:export (perl-crypt))

(define-public perl-crypt
  (package
    (inherit perl)
    (name "perl-crypt")
    (synopsis "Perl built with a working crypt()")
    (description
     "Perl as packaged by Guix, with libxcrypt on the library search path so
that Configure enables the built-in crypt() function.  Needed by programs that
verify system passwords themselves, such as Webmin's miniserv.")
    (inputs
     (modify-inputs (package-inputs perl)
       (prepend libxcrypt glibc)))
    (arguments
     (substitute-keyword-arguments (package-arguments perl)
       ((#:configure-flags _)
        ;; The inherited flags, with libxcrypt's include and library
        ;; directories added: Configure probes for crypt(), finds it there,
        ;; links -lcrypt and defines d_crypt by itself.
        #~(list
           (string-append "-Dprefix=" #$output)
           (string-append "-Dman1dir=" #$output "/share/man/man1")
           (string-append "-Dman3dir=" #$output "/share/man/man3")
           "-de" "-Dcc=gcc"
           "-Uinstallusrbinperl"
           "-Dinstallstyle=lib/perl5"
           "-Duseshrplib"
           ;; libxcrypt FIRST: glibc ships a libcrypt.so.1 stub whose crypt()
           ;; returns "*0" (failure) for every salt.  If Configure links that
           ;; stub the build looks successful and crypt() still does not work.
           (string-append "-Dlocincpth="
                          #$(file-append libxcrypt "/include") " "
                          #$(file-append glibc "/include"))
           (string-append "-Dloclibpth="
                          #$(file-append libxcrypt "/lib") " "
                          #$(file-append glibc "/lib"))
           "-Dusethreads"))))))
