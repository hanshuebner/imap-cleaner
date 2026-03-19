(in-package #:imap-cleaner)

(defmacro with-exit-on-interrupt (&body body)
  "Execute BODY, catching Ctrl-C to exit cleanly without a backtrace."
  `(handler-case (progn ,@body)
     (sb-sys:interactive-interrupt ()
       (log-message :info "Interrupted, shutting down")
       (fresh-line))))

(defun poll-cycle (config mb &key min-uid)
  "Run one poll cycle: check for new messages and process them.
When MIN-UID is given, only considers messages with UID > MIN-UID."
  ;; Keepalive
  (noop-keepalive mb)
  ;; Fetch unprocessed UIDs
  (let* ((uids (fetch-unseen-uids mb config :min-uid min-uid))
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
  "Process the last COUNT messages in the mailbox.
Returns (values total spam ham errors)."
  (let* ((all-uids (imap-search mb "not deleted"))
         (recent (last all-uids count))
         (total 0)
         (spam 0)
         (ham 0)
         (errors 0))
    (log-message :info "Scanning last ~D message~:P" (length recent))
    (dolist (uid recent)
      (incf total)
      (handler-case
          (let ((headers (fetch-headers mb uid)))
            (let ((from (or (extract-header headers "From") "unknown"))
                  (subject (or (extract-header headers "Subject") "(no subject)")))
              (multiple-value-bind (verdict stage)
                  (classify-message config mb uid)
                (log-message :info "UID ~A | From: ~A | Subject: ~A | ~A ~D% (~A) | Stage: ~A"
                             uid from subject
                             (spam-verdict-label verdict)
                             (spam-verdict-confidence verdict)
                             (spam-verdict-reason verdict)
                             stage)
                (cond
                  ((eq (spam-verdict-label verdict) :spam)
                   (incf spam)
                   (if (getf config :dry-run)
                       (progn
                         (imap-add-flags mb uid "\\Flagged")
                         (log-message :info "DRY RUN: Flagged UID ~A (would move to ~A)"
                                      uid (getf config :spam-folder)))
                       (progn
                         (move-to-spam mb uid (getf config :spam-folder))
                         (log-message :info "Moved UID ~A to ~A" uid (getf config :spam-folder)))))
                  (t (incf ham)))
                (mark-processed mb uid))))
        (error (e)
          (incf errors)
          (log-message :error "Error processing UID ~A: ~A" uid e)
          (handler-case (mark-processed mb uid)
            (error (e2)
              (log-message :error "Failed to mark UID ~A as processed: ~A" uid e2))))))
    (values total spam ham errors)))

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
  "Main polling loop with reconnection logic (single-connection mode).
Only processes messages that arrived after monitoring started."
  (let ((mb nil)
        (baseline-uid nil)
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
                (unless baseline-uid
                  (setf baseline-uid (get-max-uid mb))
                  (log-message :info "Monitoring messages after UID ~A" baseline-uid))
                (log-message :info "Connected and ready. Polling every ~Ds." poll-interval))
              ;; Poll
              (handler-case
                  (poll-cycle config mb :min-uid baseline-uid)
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
Monitor connection stays in IDLE; worker connection opens on-demand.
Only processes messages that arrived after monitoring started."
  (log-message :info "Using IDLE mode for instant mail notification")
  ;; Record highest UID before monitoring so we only process new arrivals
  (let ((baseline-uid (let ((mb (try-connect config)))
                        (when mb
                          (unwind-protect (get-max-uid mb)
                            (handler-case (disconnect-imap mb) (error () nil)))))))
    (log-message :info "Monitoring messages after UID ~A" baseline-uid)
    (run-idle-monitor config
      (lambda ()
        (let ((worker (try-connect config)))
          (when worker
            (unwind-protect
                 (let ((n (poll-cycle config worker :min-uid baseline-uid)))
                   (when (zerop n)
                     (log-message :info "No new messages to process")))
              (handler-case (disconnect-imap worker) (error () nil)))))))))

(defun check-idle-support (config)
  "Open a test connection to check IDLE capability. Returns T or NIL."
  (let ((mb nil))
    (unwind-protect
         (handler-case
             (progn
               (setf mb (connect-imap config))
               (let ((capable (mel.folders.imap:idle-capable-p mb)))
                 (log-message :info "IDLE capability: ~:[not supported~;supported~]" capable)
                 capable))
           (error (e)
             (log-message :warn "Could not check IDLE capability: ~A" e)
             nil))
      (when mb
        (handler-case (disconnect-imap mb) (error () nil))))))

(defun log-startup (config)
  "Log common startup information."
  (log-message :info "imap-cleaner starting")
  (log-message :info "Host: ~A, User: ~A, Inbox: ~A, Spam: ~A"
               (getf config :imap-host)
               (getf config :imap-user)
               (getf config :inbox "INBOX")
               (getf config :spam-folder "Junk"))
  (log-message :info "Using $SpamChecked flag for tracking")
  (when (getf config :dry-run)
    (log-message :info "DRY RUN mode enabled - spam will be flagged, not moved")))

(defun scan (count &optional config-path)
  "Scan the last COUNT messages, print statistics, and exit."
  (with-exit-on-interrupt
    (let ((config (load-config config-path)))
      (validate-config config)
      (setup-logging config)
      (log-startup config)
      (log-message :info "Scan mode: checking ~D messages" count)
      (let ((mb (try-connect config)))
        (unless mb
          (log-message :error "Could not connect to IMAP server")
          (return-from scan))
        (unwind-protect
             (multiple-value-bind (total spam ham errors)
                 (process-recent config mb :count count)
               (log-message :info "--- Scan complete ---")
               (log-message :info "Total: ~D | Spam: ~D | Ham: ~D | Errors: ~D"
                            total spam ham errors))
          (handler-case (disconnect-imap mb) (error () nil)))))))

(defun main (&optional config-path)
  "Entry point for imap-cleaner. Monitors for new mail via IDLE or polling."
  (with-exit-on-interrupt
    (let ((config (load-config config-path)))
      (validate-config config)
      (setup-logging config)
      (log-startup config)
      ;; Enter monitoring loop
      (if (and (getf config :use-idle t)
               (check-idle-support config))
          (run-idle-loop config)
          (progn
            (when (getf config :use-idle)
              (log-message :info "Falling back to polling mode"))
            (run-poll-loop config))))))
