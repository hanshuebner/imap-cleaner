(defsystem "imap-cleaner"
  :description "IMAP spam filter using Claude API for classification"
  :version "0.1.0"
  :depends-on ("mel-base"
               "dexador"
               "yason"
               "alexandria"
               "cl-ppcre"
               "babel"
               "usocket")
  :serial t
  :components ((:module "src"
                :serial t
                :components ((:file "packages")
                             (:file "config")
                             (:file "logging")
                             (:file "imap")
                             (:file "idle")
                             (:file "claude")
                             (:file "classifier")
                             (:file "smtp-server")
                             (:file "main")))))
