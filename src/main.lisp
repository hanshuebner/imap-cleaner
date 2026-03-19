(in-package #:imap-cleaner)

(defun poll-cycle (config mb)
  "Run one poll cycle: check for new messages and process them."
  ;; Keepalive
  (noop-keepalive mb)
  ;; Fetch unprocessed UIDs
  (let* ((uids (fetch-unseen-uids mb config))
         (max-msgs (getf config :max-messages-per-poll 50))
         (batch (if (> (length uids) max-msgs)
                    (subseq uids 0 max-msgs)
                    uids)))
    (when batch
      (log-message :info "Found ~D unprocessed message~:P (processing up to ~D)"
                   (length uids) max-msgs)
      (dolist (uid batch)
        (process-message config mb uid)))
    (length batch)))

(defun try-connect (config)
  "Attempt IMAP connection. Returns mailbox or NIL.
Signals an error for auth failures."
  (handler-case
      (let ((mb (connect-imap config)))
        (ensure-spam-folder mb (getf config :spam-folder "Junk"))
        mb)
    (error (e)
      (when (search "LOGIN" (princ-to-string e))
        (error e))
      (log-message :error "Connection failed: ~A" e)
      nil)))

(defun run-poll-loop (config)
  "Main polling loop with reconnection logic."
  (let ((mb nil)
        (poll-interval (getf config :poll-interval-seconds 120))
        (reconnect-delay 30))
    (unwind-protect
         (loop
           ;; Connect if needed
           (unless mb
             (setf mb (try-connect config))
             (unless mb
               (log-message :info "Retrying in ~Ds" reconnect-delay)
               (sleep reconnect-delay)
               (go next))
             (log-message :info "Connected and ready. Polling every ~Ds." poll-interval))
           ;; Poll
           (handler-case
               (poll-cycle config mb)
             (error (e)
               (log-message :error "Poll error: ~A" e)
               (log-message :info "Reconnecting in ~Ds" reconnect-delay)
               (handler-case (disconnect-imap mb) (error () nil))
               (setf mb nil)
               (sleep reconnect-delay)
               (go next)))
           ;; Sleep between polls
           (sleep poll-interval)
           next)
      ;; Cleanup
      (when mb
        (handler-case (disconnect-imap mb) (error () nil))))))

(defun main (&optional config-path)
  "Entry point for imap-cleaner."
  (let ((config (load-config config-path)))
    (validate-config config)
    (setup-logging config)
    (log-message :info "imap-cleaner starting")
    (log-message :info "Host: ~A, User: ~A, Inbox: ~A, Spam: ~A"
                 (getf config :imap-host)
                 (getf config :imap-user)
                 (getf config :inbox "INBOX")
                 (getf config :spam-folder "Junk"))
    (when (getf config :dry-run)
      (log-message :info "DRY RUN mode enabled - no messages will be moved"))
    (run-poll-loop config)))
