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

(defun make-ssl-imap-connection (host &key (port 993) user password (timeout 30))
  "Connect to an IMAP server over SSL/TLS.
Creates a plain socket, wraps it with cl+ssl, then performs IMAP login."
  (let* ((sock (acl-compat.socket:make-socket :remote-host host
                                               :remote-port port))
         (ssl-stream (cl+ssl:make-ssl-client-stream sock
                                                     :hostname host
                                                     :external-format :latin-1))
         (imap (make-instance 'net.post-office::imap-mailbox
                 :socket ssl-stream
                 :host host
                 :timeout timeout
                 :state :unauthorized)))
    ;; Read server greeting
    (multiple-value-bind (tag cmd count extra comment)
        (net.post-office::get-and-parse-from-imap-server imap)
      (declare (ignore cmd count extra))
      (unless (eq :untagged tag)
        (net.post-office:po-error :error-response
                                  :server-string comment)))
    ;; Login
    (net.post-office::send-command-get-results
     imap
     (format nil "login ~a ~a" user password)
     #'net.post-office::handle-untagged-response
     (lambda (mb command count extra comment)
       (net.post-office::check-for-success mb command count extra
                                           comment "login")))
    ;; Find separator character
    (let ((res (net.post-office:mailbox-list imap)))
      (let ((sep (cadr (car res))))
        (when sep
          (setf (net.post-office::mailbox-separator imap) sep))))
    imap))

(defun connect-imap (config)
  "Connect to IMAP server over SSL. Returns the mailbox object."
  (let ((host (getf config :imap-host))
        (port (getf config :imap-port 993))
        (user (getf config :imap-user))
        (password (getf config :imap-password)))
    (log-message :info "Connecting to IMAP ~A:~A as ~A" host port user)
    (let ((mb (make-ssl-imap-connection host
                                        :port port
                                        :user user
                                        :password password)))
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
  (let ((all-uids (net.post-office:search-mailbox mb '(not :deleted) :uid t)))
    (if *use-custom-flags*
        ;; Search for messages without $SpamChecked flag
        (let ((checked (net.post-office:search-mailbox mb '(keyword "$SpamChecked") :uid t)))
          (set-difference all-uids checked))
        ;; Filter using local UID tracking
        (remove-if (lambda (uid) (uid-processed-p (princ-to-string uid)))
                   all-uids))))

(defun fetch-headers (mb uid)
  "Fetch RFC822 headers for a message by UID."
  (let ((parts (net.post-office:fetch-parts mb uid '("RFC822.HEADER")
                                            :uid t)))
    (when parts
      (net.post-office:fetch-field uid "RFC822.HEADER" parts :uid t))))

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
      (let ((raw (net.post-office:fetch-field uid "RFC822" parts :uid t)))
        (when raw
          (extract-text-body raw (getf config :body-max-chars 4000)))))))

(defun move-to-spam (mb uid spam-folder)
  "Move a message to the spam folder: COPY, flag deleted, expunge."
  (net.post-office:copy-to-mailbox mb uid spam-folder :uid t)
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
  (let ((pattern (format nil "(?im)^~A:\\s*(.+?)\\s*$" (cl-ppcre:quote-meta-chars name))))
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
