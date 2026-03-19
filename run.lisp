;;; Run imap-cleaner
;;; Usage: sbcl --noinform --non-interactive --load run.lisp

(unless (find-package :quicklisp)
  (format *error-output* "Error: Quicklisp is not installed.~%~
                          See https://www.quicklisp.org/ for installation instructions.~%")
  (sb-ext:exit :code 1))

(let ((base (make-pathname :directory (pathname-directory *load-truename*))))
  (pushnew (merge-pathnames "mel-base/" base) asdf:*central-registry* :test #'equal)
  (pushnew base asdf:*central-registry* :test #'equal))

(ql:quickload "imap-cleaner" :silent t)
(imap-cleaner:main)
