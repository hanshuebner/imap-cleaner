#!/bin/sh
# Setup imap-cleaner on FreeBSD
# Run as root from the imap-cleaner source directory

set -e

SERVICE_USER="imap-cleaner"
CONFIG_DIR="/usr/local/etc/imap-cleaner"

echo "=== Installing build dependencies ==="
pkg install -y sbcl cl-quicklisp gmake

echo "=== Building ==="
gmake

echo "=== Installing ==="
gmake install

echo "=== Creating service user ==="
if ! pw user show "${SERVICE_USER}" >/dev/null 2>&1; then
    pw useradd "${SERVICE_USER}" -d /home/${SERVICE_USER} -m -s /usr/sbin/nologin -c "IMAP Cleaner"
fi

echo "=== Creating data directory ==="
mkdir -p /home/${SERVICE_USER}/.imap-cleaner
chown ${SERVICE_USER}:${SERVICE_USER} /home/${SERVICE_USER}/.imap-cleaner
chown ${SERVICE_USER}:${SERVICE_USER} ${CONFIG_DIR}/config.lisp

echo "=== Creating log file ==="
touch /var/log/imap-cleaner.log
chown ${SERVICE_USER}:${SERVICE_USER} /var/log/imap-cleaner.log

echo "=== Installing rc script ==="
gmake install-service-freebsd

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Edit ${CONFIG_DIR}/config.lisp"
echo "  2. Test:  su -m ${SERVICE_USER} -c 'imap-cleaner --config ${CONFIG_DIR}/config.lisp --scan 5'"
echo "  3. Enable: sysrc imap_cleaner_enable=YES"
echo "  4. Start:  service imap_cleaner start"
echo "  5. Logs:   tail -f /var/log/imap-cleaner.log"
