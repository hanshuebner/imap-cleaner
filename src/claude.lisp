(in-package #:imap-cleaner)

(defvar *claude-api-url* "https://api.anthropic.com/v1/messages")

(defun load-prompt-file (path)
  "Load a prompt template from a file."
  (unless (and path (probe-file path))
    (error "Prompt file not found: ~A" path))
  (uiop:read-file-string path))

(defun substitute-template (template substitutions)
  "Replace {KEY} placeholders in TEMPLATE with values from SUBSTITUTIONS alist."
  (let ((result template))
    (loop for (key . value) in substitutions
          do (setf result (cl-ppcre:regex-replace-all
                           (format nil "\\{~A\\}" key)
                           result
                           (or value ""))))
    result))

(defun call-claude (config system-prompt user-content &key (max-retries 3))
  "Call the Claude API. Returns the response text or NIL on failure."
  (let ((api-key (getf config :claude-api-key))
        (model (getf config :claude-model "claude-sonnet-4-20250514")))
    (unless api-key
      (error "Claude API key not configured"))
    (let ((body (with-output-to-string (s)
                  (yason:encode
                   (alexandria:plist-hash-table
                    (list "model" model
                          "max_tokens" 256
                          "system" system-prompt
                          "messages" (list (alexandria:plist-hash-table
                                           (list "role" "user"
                                                 "content" user-content))))
                    :test 'equal)
                   s)))
          (headers `(("x-api-key" . ,api-key)
                     ("anthropic-version" . "2023-06-01")
                     ("content-type" . "application/json"))))
      (loop for attempt from 1 to max-retries
            do (handler-case
                   (multiple-value-bind (body-bytes status response-headers)
                       (dex:post *claude-api-url*
                                 :content body
                                 :headers headers
                                 :want-stream nil)
                     (declare (ignore response-headers))
                     (cond
                       ((= status 200)
                        (let* ((response (yason:parse
                                          (if (stringp body-bytes)
                                              body-bytes
                                              (babel:octets-to-string body-bytes :encoding :utf-8))))
                               (content (gethash "content" response))
                               (first-block (first content)))
                          (when first-block
                            (return (gethash "text" first-block)))))
                       ((= status 401)
                        (log-message :error "Claude API authentication failed (401)")
                        (error "Claude API authentication failed"))
                       ((= status 429)
                        (log-message :warn "Claude API rate limited (429), attempt ~D/~D"
                                     attempt max-retries)
                        (sleep (* attempt 5)))
                       ((>= status 500)
                        (log-message :warn "Claude API server error (~D), attempt ~D/~D"
                                     status attempt max-retries)
                        (sleep (* attempt 3)))
                       (t
                        (log-message :error "Claude API unexpected status: ~D" status)
                        (return nil))))
                 (error (e)
                   (log-message :warn "Claude API request error: ~A, attempt ~D/~D"
                                e attempt max-retries)
                   (when (= attempt max-retries)
                     (return nil))
                   (sleep (* attempt 3))))))))

(defstruct spam-verdict
  (label :unknown :type keyword)   ; :spam or :ham
  (confidence 0 :type integer)     ; 0-100
  (reason "" :type string))

(defun parse-spam-verdict (text)
  "Parse Claude's response into a spam-verdict.
Expected format:
  SPAM (or HAM)
  85
  Reason text here"
  (when (and text (plusp (length text)))
    (let* ((lines (cl-ppcre:split "\\n" (string-trim '(#\Space #\Newline #\Return) text)))
           (first-line (string-trim '(#\Space) (or (first lines) "")))
           (label (cond
                    ((cl-ppcre:scan "(?i)^spam" first-line) :spam)
                    ((cl-ppcre:scan "(?i)^ham" first-line) :ham)
                    (t :unknown)))
           (confidence-line (string-trim '(#\Space) (or (second lines) "0")))
           (confidence (handler-case
                           (parse-integer confidence-line :junk-allowed t)
                         (error () 0)))
           (reason (string-trim '(#\Space #\Newline)
                                (format nil "~{~A~^ ~}" (cddr lines)))))
      (make-spam-verdict :label label
                         :confidence (or confidence 0)
                         :reason reason))))

(defun check-headers-for-spam (config headers-string)
  "Classify based on headers only. Returns a spam-verdict."
  (let* ((prompt-file (getf config :headers-prompt-file))
         (template (load-prompt-file prompt-file))
         (system-prompt (substitute-template template
                                             `(("HEADERS" . ,headers-string))))
         (response (call-claude config system-prompt headers-string)))
    (if response
        (or (parse-spam-verdict response)
            (make-spam-verdict :label :unknown :confidence 0
                               :reason "Failed to parse response"))
        (make-spam-verdict :label :unknown :confidence 0
                           :reason "API call failed"))))

(defun check-body-for-spam (config headers-string body-string)
  "Classify based on headers + body. Returns a spam-verdict."
  (let* ((prompt-file (getf config :body-prompt-file))
         (template (load-prompt-file prompt-file))
         (user-content (format nil "HEADERS:~%~A~%~%BODY:~%~A"
                               headers-string body-string))
         (system-prompt (substitute-template template
                                             `(("HEADERS" . ,headers-string)
                                               ("BODY" . ,body-string))))
         (response (call-claude config system-prompt user-content)))
    (if response
        (or (parse-spam-verdict response)
            (make-spam-verdict :label :unknown :confidence 0
                               :reason "Failed to parse response"))
        (make-spam-verdict :label :unknown :confidence 0
                           :reason "API call failed"))))
