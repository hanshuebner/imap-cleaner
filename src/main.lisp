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

(defun process-recent (config mb &key (count 10))
  "Process the last COUNT messages in the mailbox."
  (let* ((all-uids (net.post-office:search-mailbox mb '(not :deleted) :uid t))
         (recent (last all-uids count)))
    (log-message :info "Checking last ~D message~:P on startup" (length recent))
    (dolist (uid recent)
      (process-message config mb uid))))

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
  "Main polling loop with reconnection logic (single-connection mode)."
  (let ((mb nil)
        (poll-interval (getf config :poll-interval-seconds 120))
        (reconnect-delay 30))
    (unwind-protect
         (tagbody
          next
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
              (sleep poll-interval)))
      ;; Cleanup
      (when mb
        (handler-case (disconnect-imap mb) (error () nil))))))

(defun run-idle-loop (config)
  "Main loop using IDLE for instant notification (two-connection mode).
Monitor connection stays in IDLE; worker connection opens on-demand."
  (log-message :info "Using IDLE mode for instant mail notification")
  (run-idle-monitor config
    (lambda ()
      (let ((worker (try-connect config)))
        (when worker
          (unwind-protect
               (poll-cycle config worker)
            (handler-case (disconnect-imap worker) (error () nil))))))))

(defun check-idle-support (config)
  "Open a test connection to check IDLE capability. Returns T or NIL."
  (let ((mb nil))
    (unwind-protect
         (handler-case
             (progn
               (setf mb (connect-imap config))
               (let ((capable (idle-capable-p mb)))
                 (log-message :info "IDLE capability: ~:[not supported~;supported~]" capable)
                 capable))
           (error (e)
             (log-message :warn "Could not check IDLE capability: ~A" e)
             nil))
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
      (log-message :info "DRY RUN mode enabled - spam will be flagged, not moved"))
    ;; Initial check of recent messages
    (let ((mb (try-connect config)))
      (when mb
        (unwind-protect
             (process-recent config mb)
          (handler-case (disconnect-imap mb) (error () nil)))))
    ;; Enter main loop
    (if (and (getf config :use-idle t)
             (check-idle-support config))
        (run-idle-loop config)
        (progn
          (when (getf config :use-idle)
            (log-message :info "Falling back to polling mode"))
          (run-poll-loop config)))))
