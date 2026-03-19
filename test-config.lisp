;;; Test imap-cleaner configuration
;;; Usage: sbcl --noinform --non-interactive --load test-config.lisp
;;;
;;; Tests IMAP connection, IDLE capability, Claude API, and
;;; classifies the last message in the inbox.

(unless (find-package :quicklisp)
  (format *error-output* "Error: Quicklisp is not installed.~%~
                          See https://www.quicklisp.org/ for installation instructions.~%")
  (sb-ext:exit :code 1))

(let ((base (make-pathname :directory (pathname-directory *load-truename*))))
  (pushnew (merge-pathnames "mel-base/" base) asdf:*central-registry* :test #'equal)
  (pushnew base asdf:*central-registry* :test #'equal))

(ql:quickload "imap-cleaner" :silent t)

(defun test-config ()
  (let ((config (imap-cleaner::load-config)))
    (imap-cleaner::validate-config config)
    (imap-cleaner::setup-logging config)
    (format *error-output* "~%=== imap-cleaner configuration test ===~%~%")

    ;; Test IMAP connection
    (format *error-output* "1. Testing IMAP connection to ~A:~A...~%"
            (getf config :imap-host) (getf config :imap-port 993))
    (let ((mb (imap-cleaner::connect-imap config)))
      (unless mb (error "Connection failed"))
      (format *error-output* "   Connected as ~A~%" (getf config :imap-user))

      (unwind-protect
           (progn
             ;; Count messages
             (let ((uids (imap-cleaner::imap-search mb "not deleted")))
               (format *error-output* "   ~D messages in ~A~%~%" (length uids) (getf config :inbox "INBOX"))

               ;; Test IDLE capability
               (format *error-output* "2. Testing IDLE capability...~%")
               (setf imap-cleaner::*idle-supported* :unknown)
               (let ((idle-p (imap-cleaner::idle-capable-p mb)))
                 (format *error-output* "   IDLE ~:[not supported (will use polling)~;supported~]~%~%" idle-p))

               ;; Test header fetch
               (let* ((last-uid (car (last uids)))
                      (headers (imap-cleaner::fetch-headers mb last-uid)))
                 (format *error-output* "3. Fetching last message (UID ~A)...~%" last-uid)
                 (format *error-output* "   From: ~A~%" (imap-cleaner::extract-header headers "From"))
                 (format *error-output* "   Subject: ~A~%~%" (imap-cleaner::extract-header headers "Subject"))

                 ;; Test Claude API
                 (format *error-output* "4. Testing Claude API classification...~%")
                 (multiple-value-bind (verdict stage)
                     (imap-cleaner::classify-message config mb last-uid)
                   (format *error-output* "   Model: ~A~%" (getf config :claude-model))
                   (format *error-output* "   Verdict: ~A ~D%~%"
                           (imap-cleaner::spam-verdict-label verdict)
                           (imap-cleaner::spam-verdict-confidence verdict))
                   (format *error-output* "   Reason: ~A~%" (imap-cleaner::spam-verdict-reason verdict))
                   (format *error-output* "   Stage: ~A~%~%" stage)))))

        (imap-cleaner::disconnect-imap mb)))

    (format *error-output* "=== All tests passed ===~%")))

(handler-case (test-config)
  (error (e)
    (format *error-output* "~%ERROR: ~A~%" e)
    (sb-ext:exit :code 1)))

(sb-ext:exit :code 0)
