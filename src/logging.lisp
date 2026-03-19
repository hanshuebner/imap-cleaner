(in-package #:imap-cleaner)

(defvar *log-stream* *error-output*
  "Stream for log output.")

(defvar *log-level* :info
  "Minimum log level to output.")

(defparameter *log-level-priority*
  '(:debug 0 :info 1 :warn 2 :error 3))

(defun log-level-priority (level)
  (or (getf *log-level-priority* level) 1))

(defun log-message (level fmt &rest args)
  "Write a timestamped log message."
  (when (>= (log-level-priority level) (log-level-priority *log-level*))
    (multiple-value-bind (sec min hour day month year)
        (decode-universal-time (get-universal-time))
      (format *log-stream* "~4,'0D-~2,'0D-~2,'0D ~2,'0D:~2,'0D:~2,'0D [~A] ~?~%"
              year month day hour min sec
              (string-upcase (symbol-name level))
              fmt args)
      (force-output *log-stream*))))

(defun setup-logging (config)
  "Configure logging based on config."
  (let ((log-file (getf config :log-file)))
    (when log-file
      (setf *log-stream*
            (open log-file
                  :direction :output
                  :if-exists :append
                  :if-does-not-exist :create))))
  (when (getf config :debug)
    (setf *log-level* :debug)))
