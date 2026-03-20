#!/bin/bash
# Setup imap-cleaner on Debian/Ubuntu
# Run as root from the imap-cleaner source directory

set -e

SERVICE_USER="imap-cleaner"
CONFIG_DIR="/etc/imap-cleaner"

echo "=== Installing build dependencies ==="
apt-get update
apt-get install -y sbcl cl-quicklisp build-essential

echo "=== Building ==="
make SYSCONFDIR=/etc

echo "=== Installing ==="
make install SYSCONFDIR=/etc

echo "=== Creating service user ==="
if ! id "${SERVICE_USER}" >/dev/null 2>&1; then
    useradd --system --create-home --shell /usr/sbin/nologin "${SERVICE_USER}"
fi

echo "=== Creating data directory ==="
mkdir -p /home/${SERVICE_USER}/.imap-cleaner
chown ${SERVICE_USER}:${SERVICE_USER} /home/${SERVICE_USER}/.imap-cleaner
chown ${SERVICE_USER}:${SERVICE_USER} ${CONFIG_DIR}/config.lisp

echo "=== Installing systemd service ==="
make install-service-debian SYSCONFDIR=/etc

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Edit ${CONFIG_DIR}/config.lisp"
echo "  2. Test:  sudo -u ${SERVICE_USER} imap-cleaner --config ${CONFIG_DIR}/config.lisp --scan 5"
echo "  3. Enable: systemctl enable imap-cleaner"
echo "  4. Start:  systemctl start imap-cleaner"
echo "  5. Logs:   journalctl -u imap-cleaner -f"
