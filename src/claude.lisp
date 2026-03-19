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

(defun get-retry-after (response-headers)
  "Extract retry-after seconds from response headers, or NIL if absent."
  (let ((value (cdr (assoc "retry-after" response-headers :test #'string-equal))))
    (when value
      (handler-case (parse-integer (string-trim '(#\Space) value) :junk-allowed t)
        (error () nil)))))

(defun call-claude (config system-prompt user-content &key (timeout 120))
  "Call the Claude API with retries. Retries rate-limit and server errors
for up to TIMEOUT seconds (default 120). Returns response text or NIL."
  (let ((api-key (getf config :claude-api-key))
        (model (getf config :claude-model "claude-haiku-4-5-20251001")))
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
                     ("content-type" . "application/json")))
          (deadline (+ (get-universal-time) timeout))
          (attempt 0))
      (loop
        (incf attempt)
        (when (>= (get-universal-time) deadline)
          (log-message :error "Claude API: giving up after ~Ds" timeout)
          (return nil))
        (handler-case
            (multiple-value-bind (body-bytes status response-headers)
                (dex:post *claude-api-url*
                          :content body
                          :headers headers
                          :want-stream nil)
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
                 (let ((wait (or (get-retry-after response-headers)
                                 (min (* attempt 5) 30))))
                   (log-message :warn "Rate limited (429), waiting ~Ds (attempt ~D)"
                                wait attempt)
                   (sleep wait)))
                ((= status 529)
                 (let ((wait (min (* attempt 10) 60)))
                   (log-message :warn "API overloaded (529), waiting ~Ds (attempt ~D)"
                                wait attempt)
                   (sleep wait)))
                ((>= status 500)
                 (let ((wait (min (* attempt 5) 30)))
                   (log-message :warn "Server error (~D), waiting ~Ds (attempt ~D)"
                                status wait attempt)
                   (sleep wait)))
                (t
                 (log-message :error "Claude API unexpected status: ~D" status)
                 (return nil))))
          (error (e)
            (let ((wait (min (* attempt 3) 15)))
              (log-message :warn "Request error: ~A, waiting ~Ds (attempt ~D)"
                           e wait attempt)
              (when (>= (get-universal-time) deadline)
                (return nil))
              (sleep wait))))))))

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
