;;; Run imap-cleaner from source
;;; Usage: sbcl --noinform --non-interactive --load run.lisp [OPTIONS]
;;;
;;; Options:
;;;   --config PATH   Configuration file (default: ~/.imap-cleaner/config.lisp)
;;;   --scan N         Check the last N messages, print statistics, and exit
;;;
;;; Default: monitor for new mail via IDLE (or polling as fallback)

(unless (find-package :quicklisp)
  (format *error-output* "Error: Quicklisp is not installed.~%~
                          See https://www.quicklisp.org/ for installation instructions.~%")
  (sb-ext:exit :code 1))

(let ((base (make-pathname :directory (pathname-directory *load-truename*))))
  (pushnew (merge-pathnames "mel-base/" base) asdf:*central-registry* :test #'equal)
  (pushnew base asdf:*central-registry* :test #'equal))

(ql:quickload "imap-cleaner" :silent t)

(let* ((args (remove "--" (uiop:command-line-arguments) :test #'string=))
       (config-path nil)
       (scan-count nil))
  ;; Parse arguments
  (loop with rest = args
        while rest do
    (let ((arg (pop rest)))
      (cond
        ((string= arg "--config")
         (setf config-path (pop rest)))
        ((string= arg "--scan")
         (let ((val (pop rest)))
           (setf scan-count (and val (parse-integer val :junk-allowed t)))))
        (t
         (format *error-output* "Unknown option: ~A~%" arg)
         (sb-ext:exit :code 1)))))
  (cond
    ((and scan-count (plusp scan-count))
     (imap-cleaner:scan scan-count config-path))
    (scan-count
     (format *error-output* "Error: --scan requires a positive integer argument~%")
     (sb-ext:exit :code 1))
    (t
     (imap-cleaner:main config-path))))
