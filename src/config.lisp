(in-package #:imap-cleaner)

(defvar *config* nil
  "Current configuration plist.")

(defvar *default-config*
  '(:inbox "INBOX"
    :spam-folder "Junk"
    :poll-interval-seconds 120
    :claude-model "claude-haiku-4-5-20251001"
    :header-confidence-threshold 80
    :max-messages-per-poll 50
    :body-max-chars 4000
    :dry-run nil
    :imap-port 993
    :use-idle t
    :idle-timeout-seconds 1500)
  "Default configuration values.")

(defun default-config-path ()
  (merge-pathnames ".imap-cleaner/config.lisp" (user-homedir-pathname)))

(defun resolve-secret (config key command-key)
  "Resolve a secret: use direct value KEY, or shell out via COMMAND-KEY."
  (let ((direct (getf config key))
        (command (getf config command-key)))
    (cond
      (direct direct)
      (command
       (string-trim '(#\Newline #\Return #\Space)
                    (uiop:run-program command :output '(:string :stripped t))))
      (t nil))))

(defun load-config (&optional path)
  "Load configuration from PATH (defaults to ~/.imap-cleaner/config.lisp)."
  (let* ((config-path (or path (default-config-path)))
         (config-path (etypecase config-path
                        (pathname config-path)
                        (string (pathname config-path)))))
    (unless (probe-file config-path)
      (error "Config file not found: ~A" config-path))
    (let ((user-config (with-open-file (s config-path :direction :input)
                         (read s))))
      ;; Merge with defaults (user values take precedence)
      (let ((merged (copy-list *default-config*)))
        (loop for (key val) on user-config by #'cddr
              do (setf (getf merged key) val))
        ;; Resolve secrets
        (let ((imap-pass (resolve-secret merged :imap-password :imap-password-command))
              (api-key (resolve-secret merged :claude-api-key :claude-api-key-command)))
          (when imap-pass (setf (getf merged :imap-password) imap-pass))
          (when api-key (setf (getf merged :claude-api-key) api-key)))
        ;; Resolve prompt file paths relative to config directory
        (let ((config-dir (uiop:pathname-directory-pathname config-path)))
          (flet ((resolve-prompt (key default-name)
                   (let ((val (getf merged key)))
                     (if val
                         (setf (getf merged key)
                               (if (uiop:absolute-pathname-p val)
                                   val
                                   (merge-pathnames val config-dir)))
                         ;; Default: look in ~/.imap-cleaner/ then project prompts/
                         (let ((home-prompt (merge-pathnames default-name config-dir)))
                           (if (probe-file home-prompt)
                               (setf (getf merged key) home-prompt)
                               ;; Try prompts/ directory relative to system
                               (let ((system-prompt (asdf:system-relative-pathname
                                                     "imap-cleaner"
                                                     (format nil "prompts/~A" default-name))))
                                 (when (probe-file system-prompt)
                                   (setf (getf merged key) system-prompt)))))))))
            (resolve-prompt :headers-prompt-file "headers-prompt.txt")
            (resolve-prompt :body-prompt-file "body-prompt.txt")))
        (setf *config* merged)
        merged))))

(defun validate-config (config)
  "Validate that required configuration keys are present."
  (let ((required '(:imap-host :imap-user :imap-password :claude-api-key)))
    (dolist (key required)
      (unless (getf config key)
        (error "Missing required config key: ~A" key))))
  config)

(defun config-value (key &optional (config *config*))
  "Get a configuration value."
  (getf config key))
