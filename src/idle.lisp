(in-package #:imap-cleaner)

(defvar *idle-supported* :unknown
  "Whether the IMAP server supports IDLE. :unknown, T, or NIL.")

(defun idle-capable-p (mb)
  "Check if the IMAP server supports the IDLE extension.
Caches result in *idle-supported*; reset to :unknown on reconnect."
  (when (eq *idle-supported* :unknown)
    (setf *idle-supported*
          (handler-case
              (let ((capabilities nil))
                (net.post-office::send-command-get-results
                 mb "CAPABILITY"
                 (lambda (mb cmd count extra comment)
                   (declare (ignore mb count extra))
                   (when (eq cmd :capability)
                     (setf capabilities comment)))
                 (lambda (mb cmd count extra comment)
                   (declare (ignore mb cmd count extra comment))))
                (and capabilities
                     (search "IDLE" (string-upcase capabilities))
                     t))
            (error (e)
              (log-message :warn "CAPABILITY check failed: ~A" e)
              nil))))
  *idle-supported*)

(defun send-idle-done (mb tag)
  "Send DONE to terminate IDLE, read responses until tagged OK.
TAG is the tag used for the original IDLE command."
  (let ((sock (net.post-office::post-office-socket mb)))
    (format sock "DONE~A" net.post-office::*crlf*)
    (force-output sock))
  ;; Read until we get the tagged response
  (loop repeat 10
        do (handler-case
               (multiple-value-bind (buf count)
                   (net.post-office::get-line-from-server mb)
                 (multiple-value-bind (resp-tag cmd rcount extra comment)
                     (net.post-office::parse-imap-response buf count)
                   (cond
                     ;; Tagged response — we're done
                     ((and resp-tag (string-equal resp-tag tag))
                      (return))
                     ;; Untagged — let the library handle it
                     ((eq resp-tag :untagged)
                      (net.post-office::handle-untagged-response
                       mb cmd rcount extra comment)))))
             (error () (return)))))

(defun idle-wait (mb &key (timeout 1500))
  "Enter IDLE mode and wait for mailbox changes.
Returns :mailbox-change, :timeout, or :error.
TIMEOUT is in seconds (default 1500 = 25 minutes)."
  (let* ((tag (net.post-office::get-next-tag))
         (sock (net.post-office::post-office-socket mb))
         (deadline (+ (get-universal-time) timeout))
         (result :timeout))
    (unwind-protect
         (progn
           ;; Send IDLE command
           (format sock "~A IDLE~A" tag net.post-office::*crlf*)
           (force-output sock)
           ;; Read continuation response (+)
           (multiple-value-bind (buf count)
               (net.post-office::get-line-from-server mb)
             (declare (ignore count))
             (unless (and buf (plusp (length buf)) (char= (char buf 0) #\+))
               (log-message :warn "IDLE not accepted by server: ~A" buf)
               (setf result :error)
               (return-from idle-wait result)))
           ;; Poll for server pushes using listen + sleep
           ;; We can't use get-line-from-server with short timeouts because
           ;; it closes the socket on timeout errors.
           (loop
             (when (>= (get-universal-time) deadline)
               (setf result :timeout)
               (return))
             (if (listen sock)
                 ;; Data available — read and parse the response
                 (handler-case
                     (multiple-value-bind (buf count)
                         (net.post-office::get-line-from-server mb)
                       (multiple-value-bind (resp-tag cmd rcount extra comment)
                           (net.post-office::parse-imap-response buf count)
                         (declare (ignore resp-tag))
                         (case cmd
                           ((:exists :recent :expunge)
                            (log-message :debug "IDLE: ~A ~A" cmd rcount)
                            (setf result :mailbox-change)
                            (return))
                           (t
                            (net.post-office::handle-untagged-response
                             mb cmd rcount extra comment)))))
                   (error (e)
                     (log-message :warn "IDLE read error: ~A" e)
                     (setf result :error)
                     (return)))
                 ;; No data yet — sleep briefly before checking again
                 (sleep 1))))
      ;; Cleanup: terminate IDLE and restore timeout
      (when (member result '(:mailbox-change :timeout))
        (handler-case (send-idle-done mb tag)
          (error (e)
            (log-message :warn "Error sending IDLE DONE: ~A" e)))))
    result))

(defun connect-monitor (config)
  "Open a dedicated IMAP connection for IDLE monitoring.
This connection should only be used for IDLE, not for FETCH/COPY/etc."
  (log-message :info "Opening monitor connection for IDLE")
  (let ((mb (make-ssl-imap-connection
             (getf config :imap-host)
             :user (getf config :imap-user)
             :password (getf config :imap-password)
             :port (getf config :imap-port 993))))
    (net.post-office:select-mailbox mb (getf config :inbox "INBOX"))
    mb))

(defun run-idle-monitor (config on-new-mail)
  "Main IDLE monitoring loop. Calls ON-NEW-MAIL (a function of no arguments)
when new mail is detected. Handles reconnection on errors."
  (let ((monitor nil)
        (idle-timeout (getf config :idle-timeout-seconds 1500))
        (reconnect-delay 30))
    (unwind-protect
         (tagbody
          next
            (loop
              ;; Connect monitor if needed
              (unless monitor
                (handler-case
                    (progn
                      (setf *idle-supported* :unknown)
                      (setf monitor (connect-monitor config)))
                  (error (e)
                    (log-message :error "Monitor connection failed: ~A" e)
                    (log-message :info "Retrying in ~Ds" reconnect-delay)
                    (sleep reconnect-delay)
                    (go next))))
              ;; Enter IDLE
              (let ((result (handler-case
                                (idle-wait monitor :timeout idle-timeout)
                              (error (e)
                                (log-message :error "IDLE failed: ~A" e)
                                :error))))
                (case result
                  (:mailbox-change
                   (log-message :info "IDLE: new mail detected")
                   (handler-case
                       (funcall on-new-mail)
                     (error (e)
                       (log-message :error "Error processing new mail: ~A" e))))
                  (:timeout
                   (log-message :debug "IDLE timeout, re-issuing"))
                  (:error
                   (log-message :warn "IDLE error, reconnecting")
                   (handler-case (disconnect-imap monitor) (error () nil))
                   (setf monitor nil)
                   (sleep reconnect-delay))))))
      ;; Cleanup
      (when monitor
        (handler-case (disconnect-imap monitor) (error () nil))))))
