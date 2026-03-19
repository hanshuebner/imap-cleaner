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

;;; mel-base IMAP helpers

(defun imap-cmd (folder fmt &rest args)
  "Send a raw IMAP command and process the response via mel-base."
  (apply #'mel.folders.imap::send-command folder fmt args)
  (mel.folders.imap::process-response folder))

(defun imap-add-flags (folder uid flags-string)
  "Add IMAP flags to a message by UID.
FLAGS-STRING is raw IMAP syntax, e.g. \"\\\\Flagged\" or \"$SpamChecked\"."
  (imap-cmd folder "~A uid store ~A +flags (~A)" "t01" uid flags-string))

(defun imap-remove-flags (folder uid flags-string)
  "Remove IMAP flags from a message by UID."
  (imap-cmd folder "~A uid store ~A -flags (~A)" "t01" uid flags-string))

(defun imap-search (folder query)
  "Search mailbox with raw IMAP search query. Returns list of UIDs (numbers)."
  (mel.folders.imap::send-command folder "~A uid search ~A" "t01" query)
  (let (uids)
    (mel.folders.imap::process-response
     folder :on-list (lambda (list) (setf uids list)))
    uids))

;;; Connection management

(defun connect-imap (config)
  "Connect to IMAP server over SSL. Returns a mel-base imaps-folder."
  (let ((host (getf config :imap-host))
        (port (getf config :imap-port 993))
        (user (getf config :imap-user))
        (password (getf config :imap-password))
        (inbox (getf config :inbox "INBOX")))
    (log-message :info "Connecting to IMAP ~A:~A as ~A" host port user)
    (let ((folder (mel.folders.imap:make-imaps-folder
                   :host host
                   :port port
                   :username user
                   :password password
                   :mailbox inbox)))
      ;; Force connection and mailbox selection
      (mel.folders.imap::ensure-connection folder)
      (setf *use-custom-flags* t)
      folder)))

(defun fetch-unseen-uids (folder config &key min-uid)
  "Get UIDs of messages that haven't been spam-checked.
When MIN-UID is given, only considers messages with UID > MIN-UID."
  (declare (ignore config))
  (let ((query (if min-uid
                   (format nil "not deleted uid ~A:*" (1+ min-uid))
                   "not deleted")))
    (let ((all-uids (imap-search folder query)))
      (if *use-custom-flags*
          (if min-uid
              ;; For new messages, just check if they have the flag
              (let ((checked (imap-search folder
                               (format nil "keyword $SpamChecked uid ~A:*" (1+ min-uid)))))
                (set-difference all-uids checked))
              (let ((checked (imap-search folder "keyword $SpamChecked")))
                (set-difference all-uids checked)))
          (remove-if (lambda (uid) (uid-processed-p (princ-to-string uid)))
                     all-uids)))))

(defun get-max-uid (folder)
  "Get the highest UID currently in the mailbox."
  (let ((uids (imap-search folder "not deleted")))
    (if uids
        (reduce #'max uids)
        0)))

(defun fetch-headers (folder uid)
  "Fetch RFC822 headers for a message by UID. Returns a string."
  (let ((header-bytes (mel.folders.imap::fetch-message-header folder uid)))
    (when header-bytes
      (babel:octets-to-string header-bytes :encoding :latin-1))))

(defun strip-html (text)
  "Remove HTML tags from text."
  (cl-ppcre:regex-replace-all "<[^>]+>" text ""))

(defun extract-text-body (raw-body max-chars)
  "Extract readable text from a raw email body, truncated to MAX-CHARS."
  (let* ((stripped (strip-html raw-body))
         (collapsed (cl-ppcre:regex-replace-all "\\s+" stripped " "))
         (trimmed (string-trim '(#\Space #\Newline #\Return #\Tab) collapsed)))
    (if (> (length trimmed) max-chars)
        (subseq trimmed 0 max-chars)
        trimmed)))

(defun fetch-body (folder uid config)
  "Fetch and extract text body for a message by UID."
  (let ((body-bytes (mel.folders.imap::fetch-message-body folder uid)))
    (when body-bytes
      (let ((raw (babel:octets-to-string body-bytes :encoding :latin-1)))
        (extract-text-body raw (getf config :body-max-chars 4000))))))

(defun move-to-spam (folder uid spam-folder)
  "Move a message to the spam folder: COPY, flag deleted, expunge."
  (imap-cmd folder "~A uid copy ~A ~A" "t01" uid spam-folder)
  (imap-add-flags folder uid "\\Deleted")
  (mel.folders.imap::expunge-mailbox folder))

(defun mark-processed (folder uid)
  "Mark a message as processed (spam-checked)."
  (if *use-custom-flags*
      (handler-case
          (imap-add-flags folder uid "$SpamChecked")
        (error (e)
          (log-message :warn "Failed to set $SpamChecked flag: ~A, falling back to file" e)
          (save-processed-uid (princ-to-string uid))
          (setf (gethash (princ-to-string uid) *processed-uids*) t)))
      (progn
        (save-processed-uid (princ-to-string uid))
        (setf (gethash (princ-to-string uid) *processed-uids*) t))))

(defun ensure-spam-folder (folder spam-folder-name)
  "Create the spam folder if it doesn't exist."
  (handler-case
      (progn
        (imap-cmd folder "~A select ~A" "t01" spam-folder-name)
        ;; Re-select original mailbox
        (mel.folders.imap::select-mailbox folder)
        (log-message :debug "Spam folder ~A exists" spam-folder-name))
    (error ()
      (log-message :info "Creating spam folder: ~A" spam-folder-name)
      (mel.folders.imap::create-mailbox folder spam-folder-name))))

(defun disconnect-imap (folder)
  "Disconnect from IMAP server."
  (handler-case
      (mel:close-folder folder)
    (error (e)
      (log-message :warn "Error disconnecting: ~A" e))))

(defun extract-header (headers name)
  "Extract a specific header value from raw headers string."
  (let ((pattern (format nil "(?im)^~A:\\s*(.+?)\\s*$" (cl-ppcre:quote-meta-chars name))))
    (multiple-value-bind (match groups)
        (cl-ppcre:scan-to-strings pattern headers)
      (declare (ignore match))
      (when groups
        (aref groups 0)))))

(defun noop-keepalive (folder)
  "Send NOOP to keep connection alive."
  (handler-case
      (mel.folders.imap::noop folder)
    (error (e)
      (log-message :warn "NOOP failed: ~A" e)
      (error e))))
