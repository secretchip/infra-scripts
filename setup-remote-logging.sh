#!/usr/bin/env bash
set -euo pipefail

REMOTE_HOST="aegis.logs.secretchip.net"
REMOTE_PORT="514"
RSYSLOG_CONF="/etc/rsyslog.d/90-remote-forward.conf"
BACKUP_DIR="/root/rsyslog-backups"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

if [[ "${EUID}" -ne 0 ]]; then
  echo "This script must be run as root."
  exit 1
fi

echo "[*] Updating package index..."
apt-get update -y

echo "[*] Installing rsyslog..."
DEBIAN_FRONTEND=noninteractive apt-get install -y rsyslog

echo "[*] Creating backup directory..."
mkdir -p "${BACKUP_DIR}"

if [[ -f "${RSYSLOG_CONF}" ]]; then
  echo "[*] Backing up existing remote forwarding config..."
  cp -a "${RSYSLOG_CONF}" "${BACKUP_DIR}/90-remote-forward.conf.${TIMESTAMP}.bak"
fi

echo "[*] Writing rsyslog remote forwarding configuration..."
cat > "${RSYSLOG_CONF}" <<EOF
# Remote log forwarding to ${REMOTE_HOST}:${REMOTE_PORT} over UDP
# Created by setup-remote-logging.sh on ${TIMESTAMP}

*.* action(
  type="omfwd"
  target="${REMOTE_HOST}"
  port="${REMOTE_PORT}"
  protocol="udp"
  action.resumeRetryCount="-1"
  queue.type="linkedList"
  queue.filename="fwdAllLogs"
  queue.maxdiskspace="1g"
  queue.saveonshutdown="on"
  queue.size="10000"
)
EOF

echo "[*] Validating rsyslog configuration..."
rsyslogd -N1

echo "[*] Enabling and restarting rsyslog..."
systemctl enable rsyslog
systemctl restart rsyslog

echo "[*] Sending test log entry..."
logger -p user.info "Remote syslog test from $(hostname -f) to ${REMOTE_HOST}:${REMOTE_PORT}"

echo
echo "[+] Done."
echo "[+] Logs are now configured to be forwarded to ${REMOTE_HOST}:${REMOTE_PORT}/udp"
echo "[+] Test message sent with logger."
echo
echo "[!] Note:"
echo "    Only logs handled by syslog/journald will be forwarded."
echo "    Applications writing only to their own files need separate forwarding."