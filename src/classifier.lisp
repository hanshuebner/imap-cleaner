(in-package #:imap-cleaner)

(defun classify-message (config mb uid)
  "Two-stage spam classification. Returns (values verdict stage).
STAGE is :headers or :body indicating which stage made the decision."
  (let* ((headers (fetch-headers mb uid))
         (threshold (getf config :header-confidence-threshold 80)))
    (unless headers
      (log-message :warn "Could not fetch headers for UID ~A" uid)
      (return-from classify-message
        (values (make-spam-verdict :label :ham :confidence 0
                                   :reason "No headers available")
                :headers)))
    ;; Stage 1: Headers only
    (let ((verdict (check-headers-for-spam config headers)))
      (log-message :debug "Header verdict for UID ~A: ~A ~D% - ~A"
                   uid (spam-verdict-label verdict)
                   (spam-verdict-confidence verdict)
                   (spam-verdict-reason verdict))
      (when (and (member (spam-verdict-label verdict) '(:spam :ham))
                 (>= (spam-verdict-confidence verdict) threshold))
        (return-from classify-message (values verdict :headers)))
      ;; Stage 2: Headers + Body
      (log-message :info "UID ~A ambiguous after headers (~A ~D%), checking body"
                   uid (spam-verdict-label verdict)
                   (spam-verdict-confidence verdict))
      (let ((body (fetch-body mb uid config)))
        (if (and body (plusp (length body)))
            (let ((body-verdict (check-body-for-spam config headers body)))
              (log-message :debug "Body verdict for UID ~A: ~A ~D% - ~A"
                           uid (spam-verdict-label body-verdict)
                           (spam-verdict-confidence body-verdict)
                           (spam-verdict-reason body-verdict))
              (values body-verdict :body))
            ;; No body available, use header verdict as-is
            (progn
              (log-message :warn "No body available for UID ~A, using header verdict" uid)
              (values verdict :headers)))))))

(defun process-message (config mb uid)
  "Process a single message: classify, log, and act."
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
               (if (getf config :dry-run)
                   (progn
                     (net.post-office:alter-flags mb uid :add-flags '(:\\flagged) :uid t)
                     (log-message :info "DRY RUN: Flagged UID ~A (would move to ~A)"
                                  uid (getf config :spam-folder)))
                   (progn
                     (move-to-spam mb uid (getf config :spam-folder))
                     (log-message :info "Moved UID ~A to ~A" uid (getf config :spam-folder)))))
              (t
               (log-message :debug "UID ~A classified as ~A, leaving in inbox"
                            uid (spam-verdict-label verdict))))
            ;; Mark as processed regardless of verdict
            (mark-processed mb uid))))
    (error (e)
      ;; Fail open: log error, mark processed, leave in inbox
      (log-message :error "Error processing UID ~A: ~A" uid e)
      (handler-case (mark-processed mb uid)
        (error (e2)
          (log-message :error "Failed to mark UID ~A as processed: ~A" uid e2))))))
