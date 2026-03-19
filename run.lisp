;;; Run imap-cleaner
;;; Usage: sbcl --noinform --non-interactive --load run.lisp [--scan N]
;;;
;;; Default: monitor for new mail via IDLE (or polling as fallback)
;;; --scan N: check the last N messages, print statistics, and exit

(unless (find-package :quicklisp)
  (format *error-output* "Error: Quicklisp is not installed.~%~
                          See https://www.quicklisp.org/ for installation instructions.~%")
  (sb-ext:exit :code 1))

(let ((base (make-pathname :directory (pathname-directory *load-truename*))))
  (pushnew (merge-pathnames "mel-base/" base) asdf:*central-registry* :test #'equal)
  (pushnew base asdf:*central-registry* :test #'equal))

(ql:quickload "imap-cleaner" :silent t)

(let* ((args (uiop:command-line-arguments))
       (scan-pos (position "--scan" args :test #'string=)))
  (if scan-pos
      (let ((count (and (< (1+ scan-pos) (length args))
                        (parse-integer (nth (1+ scan-pos) args) :junk-allowed t))))
        (unless (and count (plusp count))
          (format *error-output* "Error: --scan requires a positive integer argument~%")
          (sb-ext:exit :code 1))
        (imap-cleaner:scan count))
      (imap-cleaner:main)))
