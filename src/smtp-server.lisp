(in-package #:imap-cleaner)

;;; SMTP filter server for Postfix before-queue content filtering.
;;;
;;; Receives mail via SMTP, classifies with Claude, and either:
;;; - Rejects spam with 550 (normal mode)
;;; - Re-injects accepted mail to a downstream SMTP server
;;; - In dry-run mode: always re-injects, logs verdict only
;;;
;;; Postfix configuration (main.cf):
;;;   smtpd_proxy_filter = 127.0.0.1:10025
;;;   smtpd_proxy_options = speed_adjust
;;;
;;; Postfix re-injection service (master.cf):
;;;   127.0.0.1:10026 inet n - n - 10 smtpd
;;;     -o content_filter=
;;;     -o receive_override_options=no_unknown_recipient_checks,no_header_body_checks,no_milters
;;;     -o smtpd_recipient_restrictions=permit_mynetworks,reject
;;;     -o mynetworks=127.0.0.0/8
;;;     -o smtpd_authorized_xforward_hosts=127.0.0.0/8

;;; --- Raw message classification ---

(defun split-headers-body (message-data)
  "Split raw message data into headers and body at the blank line.
MESSAGE-DATA uses CRLF line endings.
Returns (values headers-string body-string)."
  (let ((sep (search #.(format nil "~C~C~C~C" #\Return #\Linefeed #\Return #\Linefeed)
                     message-data)))
    (if sep
        (values (subseq message-data 0 sep)
                (subseq message-data (+ sep 4)))
        (values message-data ""))))

(defun classify-raw-message (config headers-string body-string)
  "Two-stage spam classification on raw message strings.
Returns (values verdict stage) like classify-message."
  (let ((threshold (getf config :header-confidence-threshold 80)))
    ;; Stage 1: Headers only
    (let ((verdict (check-headers-for-spam config headers-string)))
      (log-message :debug "Header verdict: ~A ~D% - ~A"
                   (spam-verdict-label verdict)
                   (spam-verdict-confidence verdict)
                   (spam-verdict-reason verdict))
      (when (and (member (spam-verdict-label verdict) '(:spam :ham))
                 (>= (spam-verdict-confidence verdict) threshold))
        (return-from classify-raw-message (values verdict :headers)))
      ;; Stage 2: Headers + Body
      (log-message :info "Ambiguous after headers (~A ~D%), checking body"
                   (spam-verdict-label verdict)
                   (spam-verdict-confidence verdict))
      (let ((extracted-body (when (and body-string (plusp (length body-string)))
                              (extract-text-body body-string
                                                 (getf config :body-max-chars 4000)))))
        (if (and extracted-body (plusp (length extracted-body)))
            (let ((body-verdict (check-body-for-spam config headers-string extracted-body)))
              (log-message :debug "Body verdict: ~A ~D% - ~A"
                           (spam-verdict-label body-verdict)
                           (spam-verdict-confidence body-verdict)
                           (spam-verdict-reason body-verdict))
              (values body-verdict :body))
            (progn
              (log-message :warn "No body available, using header verdict")
              (values verdict :headers)))))))

;;; --- SMTP line protocol ---

(defun smtp-read-line (stream)
  "Read a CRLF-terminated line, returning the line without CRLF.
Returns NIL on end-of-file."
  (handler-case
      (let ((buf (make-string-output-stream)))
        (loop for char = (read-char stream)
              do (cond
                   ((eql char #\Return)
                    (let ((next (read-char stream nil nil)))
                      (if (eql next #\Linefeed)
                          (return (get-output-stream-string buf))
                          (progn
                            (write-char char buf)
                            (when next (write-char next buf))))))
                   (t (write-char char buf)))))
    (end-of-file () nil)))

(defun smtp-write-line (stream fmt &rest args)
  "Write a CRLF-terminated line to STREAM."
  (apply #'format stream fmt args)
  (write-char #\Return stream)
  (write-char #\Linefeed stream)
  (force-output stream))

;;; --- SMTP client for re-injection ---

(defun smtp-read-response (stream)
  "Read a possibly multi-line SMTP response.
Returns (values numeric-code full-text)."
  (let ((lines nil))
    (loop for line = (smtp-read-line stream)
          while line
          do (push line lines)
          ;; Last line of response has space after code, not hyphen
          until (or (< (length line) 4)
                    (char= (char line 3) #\Space)))
    (let* ((all-lines (nreverse lines))
           (last-line (car (last all-lines)))
           (code (when (and last-line (>= (length last-line) 3))
                   (parse-integer last-line :end 3 :junk-allowed t))))
      (values code (format nil "~{~A~^~%~}" all-lines)))))

(defun reinject-message (config envelope-from recipients raw-message-data)
  "Re-inject a message to the downstream SMTP server.
RAW-MESSAGE-DATA is dot-stuffed with CRLF line endings.
Returns T on success, NIL on failure."
  (let ((host (getf config :smtp-downstream-host "127.0.0.1"))
        (port (getf config :smtp-downstream-port 10026)))
    (handler-case
        (let ((socket (usocket:socket-connect host port)))
          (unwind-protect
               (let ((stream (usocket:socket-stream socket)))
                 (flet ((expect (expected-code context)
                          (multiple-value-bind (code text)
                              (smtp-read-response stream)
                            (unless (eql code expected-code)
                              (log-message :error "Downstream ~A: expected ~D, got ~D (~A)"
                                           context expected-code code text)
                              (return-from reinject-message nil))
                            code)))
                   (expect 220 "greeting")
                   (smtp-write-line stream "EHLO localhost")
                   (expect 250 "EHLO")
                   (smtp-write-line stream "MAIL FROM:<~A>" (or envelope-from ""))
                   (expect 250 "MAIL FROM")
                   (dolist (rcpt recipients)
                     (smtp-write-line stream "RCPT TO:<~A>" rcpt)
                     (multiple-value-bind (code text)
                         (smtp-read-response stream)
                       (unless (member code '(250 251))
                         (log-message :error "Downstream RCPT TO <~A>: ~D (~A)" rcpt code text)
                         (return-from reinject-message nil))))
                   (smtp-write-line stream "DATA")
                   (expect 354 "DATA")
                   ;; Send raw message data (dot-stuffed, CRLF endings)
                   (write-string raw-message-data stream)
                   (smtp-write-line stream ".")
                   (expect 250 "end-of-data")
                   (smtp-write-line stream "QUIT")
                   (handler-case (smtp-read-response stream) (error () nil))
                   t))
            (handler-case (usocket:socket-close socket) (error () nil))))
      (error (e)
        (log-message :error "Re-injection to ~A:~D failed: ~A" host port e)
        nil))))

;;; --- SMTP server ---

(defun extract-smtp-address (param-string)
  "Extract email address from SMTP parameter like '<user@host>' or 'user@host'."
  (let ((start (position #\< param-string))
        (end (position #\> param-string)))
    (if (and start end (< start end))
        (subseq param-string (1+ start) end)
        (string-trim '(#\Space) param-string))))

(defun parse-smtp-params (line)
  "Extract the parameter portion after the first colon in an SMTP command."
  (let ((colon (position #\: line)))
    (if colon
        (string-trim '(#\Space) (subseq line (1+ colon)))
        (let ((space (position #\Space line)))
          (if space
              (string-trim '(#\Space) (subseq line (1+ space)))
              "")))))

(defun handle-smtp-connection (config client-stream)
  "Handle one SMTP filter session."
  (let ((envelope-from nil)
        (recipients nil)
        (client-name "[unknown]")
        (client-addr "[unknown]"))
    (labels
        ((respond (fmt &rest args)
           (let ((line (apply #'format nil fmt args)))
             (smtp-write-line client-stream "~A" line)
             (log-message :debug "SMTP > ~A" line)))
         (respond-ehlo (hostname)
           (smtp-write-line client-stream "250-~A" hostname)
           (smtp-write-line client-stream "250-XFORWARD NAME ADDR PROTO HELO")
           (smtp-write-line client-stream "250-ENHANCEDSTATUSCODES")
           (smtp-write-line client-stream "250 8BITMIME")
           (force-output client-stream))
         (receive-data ()
           "Read DATA content. Returns (values raw-data clean-data)."
           (let ((raw-buf (make-string-output-stream))
                 (clean-buf (make-string-output-stream)))
             (loop for line = (smtp-read-line client-stream)
                   until (or (null line) (string= line "."))
                   do (progn
                        ;; Raw: preserve dot-stuffing for re-injection
                        (write-string line raw-buf)
                        (write-char #\Return raw-buf)
                        (write-char #\Linefeed raw-buf)
                        ;; Clean: undo dot-stuffing for classification
                        (let ((clean (if (and (plusp (length line))
                                              (char= (char line 0) #\.))
                                         (subseq line 1)
                                         line)))
                          (write-string clean clean-buf)
                          (write-char #\Return clean-buf)
                          (write-char #\Linefeed clean-buf))))
             (values (get-output-stream-string raw-buf)
                     (get-output-stream-string clean-buf))))
         (handle-data ()
           (respond "354 End data with <CR><LF>.<CR><LF>")
           (multiple-value-bind (raw-data clean-data)
               (receive-data)
             (multiple-value-bind (headers-string body-string)
                 (split-headers-body clean-data)
               (let ((from (or (extract-header headers-string "From") envelope-from "unknown"))
                     (subject (or (extract-header headers-string "Subject") "(no subject)"))
                     (rcpts (reverse recipients)))
                 ;; Classify and act
                 (handler-case
                     (multiple-value-bind (verdict stage)
                         (classify-raw-message config headers-string body-string)
                       (log-message :info
                                    "From: ~A | To: ~{~A~^,~} | Subject: ~A | Client: ~A[~A] | ~A ~D% (~A) | Stage: ~A"
                                    from rcpts subject client-name client-addr
                                    (spam-verdict-label verdict)
                                    (spam-verdict-confidence verdict)
                                    (spam-verdict-reason verdict)
                                    stage)
                       (cond
                         ;; Spam, not dry-run: reject
                         ((and (eq (spam-verdict-label verdict) :spam)
                               (not (getf config :dry-run)))
                          (respond "550 5.7.1 Message rejected: ~A"
                                   (spam-verdict-reason verdict)))
                         ;; Ham or dry-run: deliver
                         (t
                          (when (and (eq (spam-verdict-label verdict) :spam)
                                     (getf config :dry-run))
                            (log-message :info "DRY RUN: Would reject From: ~A | Subject: ~A"
                                         from subject))
                          (if (reinject-message config envelope-from rcpts raw-data)
                              (respond "250 2.0.0 OK")
                              (respond "451 4.3.0 Temporary delivery failure")))))
                   (error (e)
                     ;; Fail open: accept on classification error
                     (log-message :error "Classification error for ~A: ~A" from e)
                     (if (reinject-message config envelope-from rcpts raw-data)
                         (respond "250 2.0.0 OK")
                         (respond "451 4.3.0 Temporary delivery failure")))))))))
      ;; Send greeting
      (respond "220 ~A ESMTP imap-cleaner spam filter"
               (getf config :smtp-banner-host "localhost"))
      ;; Command loop
      (loop
        (let ((line (smtp-read-line client-stream)))
          (unless line
            (log-message :debug "SMTP client disconnected")
            (return))
          (log-message :debug "SMTP < ~A" line)
          (let* ((space-pos (position #\Space line))
                 (cmd (string-upcase (subseq line 0 (or space-pos (length line))))))
            (cond
              ((or (string= cmd "EHLO") (string= cmd "HELO"))
               (respond-ehlo (getf config :smtp-banner-host "localhost")))

              ((string= cmd "XFORWARD")
               (let ((params (if space-pos (subseq line (1+ space-pos)) "")))
                 (cl-ppcre:do-register-groups (key value)
                     ("(NAME|ADDR)=([^\\s]+)" params)
                   (cond
                     ((string-equal key "NAME") (setf client-name value))
                     ((string-equal key "ADDR") (setf client-addr value)))))
               (respond "250 2.0.0 OK"))

              ((string= cmd "MAIL")
               (setf envelope-from (extract-smtp-address (parse-smtp-params line)))
               (setf recipients nil)
               (respond "250 2.1.0 OK"))

              ((string= cmd "RCPT")
               (push (extract-smtp-address (parse-smtp-params line)) recipients)
               (respond "250 2.1.5 OK"))

              ((string= cmd "DATA")
               (handle-data))

              ((string= cmd "RSET")
               (setf envelope-from nil recipients nil)
               (respond "250 2.0.0 OK"))

              ((string= cmd "NOOP")
               (respond "250 2.0.0 OK"))

              ((string= cmd "QUIT")
               (respond "221 2.0.0 Bye")
               (return))

              (t
               (respond "502 5.5.2 Command not recognized")))))))))

(defun run-smtp-server (config)
  "Run the SMTP filter server, accepting connections in a loop."
  (let ((address (getf config :smtp-listen-address "127.0.0.1"))
        (port (getf config :smtp-listen-port 10025)))
    (log-message :info "SMTP filter listening on ~A:~D" address port)
    (log-message :info "Downstream relay: ~A:~D"
                 (getf config :smtp-downstream-host "127.0.0.1")
                 (getf config :smtp-downstream-port 10026))
    (when (getf config :dry-run)
      (log-message :info "DRY RUN mode - spam will be accepted and logged, not rejected"))
    (let ((server (usocket:socket-listen address port
                                         :reuse-address t
                                         :backlog 5)))
      (unwind-protect
           (loop
             (handler-case
                 (let ((client (usocket:socket-accept server)))
                   (log-message :debug "SMTP connection accepted")
                   (sb-thread:make-thread
                    (lambda ()
                      (unwind-protect
                           (handler-case
                               (handle-smtp-connection config
                                                       (usocket:socket-stream client))
                             (error (e)
                               (log-message :error "SMTP session error: ~A" e)))
                        (handler-case (usocket:socket-close client) (error () nil))))
                    :name "smtp-handler"))
               (error (e)
                 (log-message :error "Accept error: ~A" e)
                 (sleep 1))))
        (usocket:socket-close server)))))

(defun smtp-main (&optional config-path)
  "Entry point for SMTP filter mode."
  (with-exit-on-interrupt
    (let ((config (load-config config-path)))
      (unless (getf config :claude-api-key)
        (error "Missing required config key: :claude-api-key"))
      (setup-logging config)
      (log-message :info "imap-cleaner SMTP filter starting")
      (run-smtp-server config))))
