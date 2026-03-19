(in-package #:imap-cleaner)

(defvar *idle-supported* :unknown
  "Whether the IMAP server supports IDLE. :unknown, T, or NIL.")

(defun idle-capable-p (folder)
  "Check if the IMAP server supports the IDLE extension.
Caches result in *idle-supported*; reset to :unknown on reconnect."
  (when (eq *idle-supported* :unknown)
    (setf *idle-supported*
          (handler-case
              (let ((caps (mel.folders.imap::capability folder)))
                (declare (ignore caps))
                (let ((cap-list (slot-value folder 'mel.folders.imap::capabilities)))
                  (and cap-list
                       (member :idle cap-list)
                       t)))
            (error (e)
              (log-message :warn "CAPABILITY check failed: ~A" e)
              nil))))
  *idle-supported*)

(defun idle-wait (folder &key (timeout 1500))
  "Enter IDLE mode and wait for mailbox changes.
Returns :mailbox-change, :timeout, or :error.
TIMEOUT is in seconds (default 1500 = 25 minutes)."
  (let ((stream (mel.folders.imap::connection folder))
        (deadline (+ (get-universal-time) timeout))
        (result :timeout))
    (unwind-protect
         (progn
           ;; Send IDLE command
           (mel.folders.imap::send-command folder "~A idle" "t01")
           ;; Read continuation response (+)
           ;; process-response handles + via on-continuation
           ;; But we need to NOT block waiting for tagged OK.
           ;; Read one line manually to get the + continuation.
           (let ((response (mel.folders.imap::read-response stream)))
             (unless (eq (first response) :+)
               (log-message :warn "IDLE not accepted by server: ~A" response)
               (setf result :error)
               (return-from idle-wait result)))
           ;; Poll for server pushes using listen + sleep
           (loop
             (when (>= (get-universal-time) deadline)
               (setf result :timeout)
               (return))
             (if (listen stream)
                 ;; Data available — read and check for mailbox changes
                 (handler-case
                     (let ((response (mel.folders.imap::read-response stream)))
                       (when (and (eql (first response) #\*)
                                  (numberp (second response)))
                         (let ((cmd (first (third response))))
                           (when (member cmd '(:exists :recent :expunge))
                             (log-message :debug "IDLE: ~A ~A" cmd (second response))
                             (setf result :mailbox-change)
                             (return)))))
                   (error (e)
                     (log-message :warn "IDLE read error: ~A" e)
                     (setf result :error)
                     (return)))
                 ;; No data yet — sleep briefly
                 (sleep 1))))
      ;; Cleanup: terminate IDLE
      (when (member result '(:mailbox-change :timeout))
        (handler-case
            (progn
              (mel.folders.imap::send-command folder "done")
              (mel.folders.imap::process-response folder))
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
    (mel.folders.imap::ensure-connection folder)
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
