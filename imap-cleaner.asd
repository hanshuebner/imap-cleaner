(defsystem "imap-cleaner"
  :description "IMAP spam filter using Claude API for classification"
  :version "0.1.0"
  :depends-on ("post-office"
               "dexador"
               "yason"
               "alexandria"
               "cl-ppcre")
  :serial t
  :components ((:module "src"
                :serial t
                :components ((:file "packages")
                             (:file "config")
                             (:file "logging")
                             (:file "imap")
                             (:file "claude")
                             (:file "classifier")
                             (:file "main")))))
