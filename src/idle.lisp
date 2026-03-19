(in-package #:imap-cleaner)

(defun idle-wait (folder &key (timeout 1500))
  "Enter IDLE mode and wait for mailbox changes.
Returns :mailbox-change, :timeout, or :error.
TIMEOUT is in seconds (default 1500 = 25 minutes)."
  (let ((deadline (+ (get-universal-time) timeout))
        (result :timeout))
    (unwind-protect
         (progn
           ;; Enter IDLE mode
           (unless (mel.folders.imap:idle-start folder)
             (log-message :warn "IDLE not accepted by server")
             (setf result :error)
             (return-from idle-wait result))
           ;; Poll for server pushes using listen + sleep
           (loop
             (when (>= (get-universal-time) deadline)
               (setf result :timeout)
               (return))
             (let ((response (mel.folders.imap:idle-read-response folder)))
               (if response
                   ;; Data available — check for mailbox changes
                   ;; response format: (tag type &rest arguments)
                   ;; e.g. (#\* 3 :EXISTS) — untagged numeric notification
                   (destructuring-bind (tag number &rest arguments) response
                     (when (and (eql tag #\*)
                                (numberp number)
                                (member (first arguments) '(:exists :recent :expunge)))
                       (log-message :debug "IDLE: ~A ~A" (first arguments) number)
                       (setf result :mailbox-change)
                       (return)))
                   ;; No data yet — sleep briefly
                   (sleep 1)))))
      ;; Cleanup: terminate IDLE
      (when (member result '(:mailbox-change :timeout))
        (handler-case
            (mel.folders.imap:idle-done folder)
          (error (e)
            (log-message :warn "Error ending IDLE: ~A" e)))))
    result))

(defun connect-monitor (config)
  "Open a dedicated IMAP connection for IDLE monitoring."
  (log-message :info "Opening monitor connection for IDLE")
  (let ((folder (mel.folders.imap:make-imaps-folder
                 :host (getf config :imap-host)
                 :port (getf config :imap-port 993)
                 :username (getf config :imap-user)
                 :password (getf config :imap-password)
                 :mailbox (getf config :inbox "INBOX"))))
    ;; idle-start calls send-command which triggers ensure-connection,
    ;; so no explicit connection setup needed here.
    folder))

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
                    (setf monitor (connect-monitor config))
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
                   (log-message :info "IDLE: mailbox change detected")
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
