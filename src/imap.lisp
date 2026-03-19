(in-package #:imap-cleaner)

(defvar *processed-uids-file* nil
  "Path to file tracking processed UIDs (fallback when custom flags unsupported).")

(defvar *use-custom-flags* nil
  "Whether the IMAP server supports custom keywords.")

(defvar *processed-uids* (make-hash-table :test 'equal)
  "Set of already-processed UIDs (for file-based tracking).")

(defun processed-uids-path ()
  (merge-pathnames ".imap-cleaner/processed-uids.dat" (user-homedir-pathname)))

(defun load-processed-uids ()
  "Load processed UIDs from disk."
  (let ((path (processed-uids-path)))
    (clrhash *processed-uids*)
    (when (probe-file path)
      (with-open-file (s path :direction :input)
        (loop for line = (read-line s nil nil)
              while line
              do (let ((uid (string-trim '(#\Space #\Newline #\Return) line)))
                   (when (plusp (length uid))
                     (setf (gethash uid *processed-uids*) t))))))
    *processed-uids*))

(defun save-processed-uid (uid-string)
  "Append a processed UID to the tracking file."
  (let ((path (processed-uids-path)))
    (ensure-directories-exist path)
    (with-open-file (s path :direction :output
                            :if-exists :append
                            :if-does-not-exist :create)
      (write-line uid-string s))))

(defun uid-processed-p (uid-string)
  "Check if UID has already been processed."
  (gethash uid-string *processed-uids*))

(defun connect-imap (config)
  "Connect to IMAP server. Returns the mailbox object."
  (let ((host (getf config :imap-host))
        (port (getf config :imap-port 993))
        (user (getf config :imap-user))
        (password (getf config :imap-password)))
    (log-message :info "Connecting to IMAP ~A:~A as ~A" host port user)
    (let ((mb (net.post-office:make-imap-connection
               host
               :user user
               :password password
               :port port
               :ssl t)))
      ;; Check for custom keyword support
      (net.post-office:select-mailbox mb (getf config :inbox "INBOX"))
      (let ((pflags (net.post-office:mailbox-permanent-flags mb)))
        (setf *use-custom-flags*
              (and pflags (or (member :\\* pflags)
                              (member :$spamchecked pflags :test #'string-equal)))))
      (if *use-custom-flags*
          (log-message :info "Server supports custom flags, using $SpamChecked")
          (progn
            (log-message :info "Using file-based UID tracking")
            (load-processed-uids)))
      mb)))

(defun fetch-unseen-uids (mb config)
  "Get UIDs of messages that haven't been spam-checked."
  (net.post-office:select-mailbox mb (getf config :inbox "INBOX"))
  (let ((all-uids (net.post-office:search-mailbox mb '(:not :deleted))))
    (if *use-custom-flags*
        ;; Search for messages without $SpamChecked flag
        (let ((checked (net.post-office:search-mailbox mb '(:keyword "$SpamChecked"))))
          (set-difference all-uids checked))
        ;; Filter using local UID tracking
        (remove-if (lambda (uid) (uid-processed-p (princ-to-string uid)))
                   all-uids))))

(defun fetch-headers (mb uid)
  "Fetch RFC822 headers for a message by UID."
  (let ((parts (net.post-office:fetch-parts mb uid '("RFC822.HEADER")
                                            :uid t)))
    (when parts
      ;; fetch-parts returns ((uid (part-name value) ...))
      (let ((msg-parts (cdr (assoc uid parts))))
        (if msg-parts
            (second (assoc "RFC822.HEADER" msg-parts :test #'string-equal))
            ;; Try alternate response format
            (loop for entry in parts
                  when (and (listp entry) (listp (cdr entry)))
                    do (loop for part in (cdr entry)
                             when (and (listp part)
                                       (string-equal (car part) "RFC822.HEADER"))
                               return (second part))))))))

(defun strip-html (text)
  "Remove HTML tags from text."
  (cl-ppcre:regex-replace-all "<[^>]+>" text ""))

(defun extract-text-body (raw-body max-chars)
  "Extract readable text from a raw email body, truncated to MAX-CHARS."
  ;; Simple approach: strip HTML tags, collapse whitespace
  (let* ((stripped (strip-html raw-body))
         (collapsed (cl-ppcre:regex-replace-all "\\s+" stripped " "))
         (trimmed (string-trim '(#\Space #\Newline #\Return #\Tab) collapsed)))
    (if (> (length trimmed) max-chars)
        (subseq trimmed 0 max-chars)
        trimmed)))

(defun fetch-body (mb uid config)
  "Fetch and extract text body for a message by UID."
  (let ((parts (net.post-office:fetch-parts mb uid '("RFC822")
                                            :uid t)))
    (when parts
      (let ((raw nil))
        ;; Navigate response structure to get raw body
        (loop for entry in parts
              when (listp entry)
                do (loop for part in (if (listp (cdr entry)) (cdr entry) (list entry))
                         when (and (listp part)
                                   (string-equal (car part) "RFC822"))
                           do (setf raw (second part))))
        (when raw
          (extract-text-body raw (getf config :body-max-chars 4000)))))))

(defun move-to-spam (mb uid spam-folder)
  "Move a message to the spam folder: COPY, flag deleted, expunge."
  (net.post-office:copy-msg mb uid spam-folder :uid t)
  (net.post-office:alter-flags mb uid :add-flags '(:deleted) :uid t)
  (net.post-office:expunge-mailbox mb))

(defun mark-processed (mb uid)
  "Mark a message as processed (spam-checked)."
  (if *use-custom-flags*
      (handler-case
          (net.post-office:alter-flags mb uid :add-flags '(:$spamchecked) :uid t)
        (error (e)
          (log-message :warn "Failed to set $SpamChecked flag: ~A, falling back to file" e)
          (save-processed-uid (princ-to-string uid))
          (setf (gethash (princ-to-string uid) *processed-uids*) t)))
      (progn
        (save-processed-uid (princ-to-string uid))
        (setf (gethash (princ-to-string uid) *processed-uids*) t))))

(defun ensure-spam-folder (mb folder)
  "Create the spam folder if it doesn't exist."
  (handler-case
      (progn
        (net.post-office:select-mailbox mb folder)
        (log-message :debug "Spam folder ~A exists" folder))
    (error ()
      (log-message :info "Creating spam folder: ~A" folder)
      (net.post-office:create-mailbox mb folder))))

(defun disconnect-imap (mb)
  "Disconnect from IMAP server."
  (handler-case
      (net.post-office:close-connection mb)
    (error (e)
      (log-message :warn "Error disconnecting: ~A" e))))

(defun extract-header (headers name)
  "Extract a specific header value from raw headers string."
  (let ((pattern (format nil "(?i)^~A:\\s*(.+?)\\s*$" (cl-ppcre:quote-meta-chars name))))
    (multiple-value-bind (match groups)
        (cl-ppcre:scan-to-strings pattern headers)
      (declare (ignore match))
      (when groups
        (aref groups 0)))))

(defun noop-keepalive (mb)
  "Send NOOP to keep connection alive."
  (handler-case
      (net.post-office:noop mb)
    (error (e)
      (log-message :warn "NOOP failed: ~A" e)
      (error e))))
