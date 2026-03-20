#!/bin/bash
# Launch imap-cleaner from source
# Usage: ./run.sh [--config PATH] [--scan N]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

exec sbcl --noinform --non-interactive \
  --load "${SCRIPT_DIR}/run.lisp" -- "$@"
