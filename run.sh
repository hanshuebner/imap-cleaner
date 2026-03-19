#!/bin/bash
# Launch imap-cleaner
# Usage: ./run.sh [config-path]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_PATH="${1:-$HOME/.imap-cleaner/config.lisp}"

exec sbcl --noinform --non-interactive \
  --eval '(require :asdf)' \
  --eval "(push #p\"${SCRIPT_DIR}/\" asdf:*central-registry*)" \
  --eval '(asdf:load-system "imap-cleaner")' \
  --eval "(imap-cleaner:main \"${CONFIG_PATH}\")"
