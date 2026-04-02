#!/usr/bin/env bash
set -euo pipefail

DEPLOY_LOG="/var/log/ufw-ddns-deploy.log"
exec > >(tee -a "$DEPLOY_LOG") 2>&1

CONFIG_FILE="/etc/ufw-ddns-refresh.conf"
REFRESH_SCRIPT="/usr/local/sbin/ufw-ddns-refresh.sh"
SERVICE_FILE="/etc/systemd/system/ufw-ddns-refresh.service"
TIMER_FILE="/etc/systemd/system/ufw-ddns-refresh.timer"

UFW_RESET="${UFW_RESET:-yes}"
INSTALL_UFW_IF_MISSING="${INSTALL_UFW_IF_MISSING:-yes}"
ALLOW_SSH_MISMATCH="${ALLOW_SSH_MISMATCH:-no}"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must run as root."
    exit 1
  fi
}

require_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemctl not found. This script requires systemd."
    exit 1
  fi
}

install_ufw_if_needed() {
  if command -v ufw >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$INSTALL_UFW_IF_MISSING" != "yes" ]]; then
    echo "ufw is not installed and INSTALL_UFW_IF_MISSING is not set to yes."
    exit 1
  fi

  echo "Installing ufw..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ufw
}

write_config() {
  echo "Writing config to $CONFIG_FILE ..."
  cat > "$CONFIG_FILE" <<'EOF'
#!/usr/bin/env bash

DDNS_HOSTS=(
  "hep09cctf5g.sn.mynetname.net"
  "cc4f0c432bf0.sn.mynetname.net"
  "hea08x8262e.sn.mynetname.net"
)

# Publicly allowed ports from anywhere
PUBLIC_TCP_PORTS=(443 853)
PUBLIC_UDP_PORTS=(443 853)

# Restricted management/admin ports allowed only from DDNS-resolved IPs
MGMT_TCP_PORTS=(22 53444)

STATE_DIR="/var/lib/ufw-ddns-refresh"
STATE_FILE="/var/lib/ufw-ddns-refresh/applied.rules"
LOCK_FILE="/run/ufw-ddns-refresh.lock"
LOG_FILE="/var/log/ufw-ddns-refresh.log"

TIMER_ON_BOOT_SEC="2min"
TIMER_ON_CALENDAR="*:0/5"
EOF

  chmod 644 "$CONFIG_FILE"
}

write_refresh_script() {
  echo "Writing refresh script to $REFRESH_SCRIPT ..."
  install -d -m 755 /usr/local/sbin

  cat > "$REFRESH_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/ufw-ddns-refresh.conf"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Missing config file: $CONFIG_FILE"
  exit 1
fi

# shellcheck disable=SC1091
source "$CONFIG_FILE"

mkdir -p "$STATE_DIR"
touch "$LOG_FILE"

exec >>"$LOG_FILE" 2>&1
echo "[$(date -Is)] starting refresh"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "[$(date -Is)] another refresh is already running, exiting"
  exit 0
fi

declare -A OLD_RULES=()
declare -A DESIRED_RULES=()

load_old_state() {
  [[ -f "$STATE_FILE" ]] || return 0
  while IFS='|' read -r host proto port ip; do
    [[ -n "${host:-}" && -n "${proto:-}" && -n "${port:-}" && -n "${ip:-}" ]] || continue
    OLD_RULES["$host|$proto|$port|$ip"]=1
  done < "$STATE_FILE"
}

resolve_ipv4() {
  local host="$1"
  getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | grep -E '^[0-9.]+$' | sort -u || true
}

resolve_ipv6() {
  local host="$1"
  getent ahostsv6 "$host" 2>/dev/null | awk '{print $1}' | grep ':' | grep -vi '^::ffff:' | sort -u || true
}

add_desired_for_host_from_old() {
  local host="$1"
  local key
  for key in "${!OLD_RULES[@]}"; do
    [[ "$key" == "$host|"* ]] && DESIRED_RULES["$key"]=1
  done
}

add_desired_for_host_from_dns() {
  local host="$1"
  local resolved_any=0
  local ip port

  while IFS= read -r ip; do
    [[ -n "$ip" ]] || continue
    resolved_any=1
    for port in "${MGMT_TCP_PORTS[@]}"; do
      DESIRED_RULES["$host|tcp|$port|$ip"]=1
    done
  done < <(resolve_ipv4 "$host")

  while IFS= read -r ip; do
    [[ -n "$ip" ]] || continue
    resolved_any=1
    for port in "${MGMT_TCP_PORTS[@]}"; do
      DESIRED_RULES["$host|tcp|$port|$ip"]=1
    done
  done < <(resolve_ipv6 "$host")

  if [[ "$resolved_any" -eq 1 ]]; then
    echo "[$(date -Is)] resolved $host successfully"
    return 0
  fi

  echo "[$(date -Is)] WARNING: could not resolve $host, keeping old rules if present"
  add_desired_for_host_from_old "$host"
  return 1
}

delete_rule() {
  local proto="$1"
  local port="$2"
  local ip="$3"
  ufw --force delete allow proto "$proto" from "$ip" to any port "$port" >/dev/null 2>&1 || true
}

add_rule() {
  local proto="$1"
  local port="$2"
  local ip="$3"
  ufw allow proto "$proto" from "$ip" to any port "$port" >/dev/null
}

write_state() {
  local tmp
  tmp="$(mktemp)"
  for key in "${!DESIRED_RULES[@]}"; do
    printf '%s\n' "$key"
  done | sort > "$tmp"
  install -m 600 "$tmp" "$STATE_FILE"
  rm -f "$tmp"
}

load_old_state

for host in "${DDNS_HOSTS[@]}"; do
  add_desired_for_host_from_dns "$host" || true
done

if [[ "${#DESIRED_RULES[@]}" -eq 0 ]]; then
  echo "[$(date -Is)] ERROR: no desired rules were built, refusing to touch firewall"
  exit 1
fi

for key in "${!OLD_RULES[@]}"; do
  if [[ -z "${DESIRED_RULES[$key]+x}" ]]; then
    IFS='|' read -r host proto port ip <<< "$key"
    delete_rule "$proto" "$port" "$ip"
    echo "[$(date -Is)] removed $proto/$port from $ip for $host"
  fi
done

for key in "${!DESIRED_RULES[@]}"; do
  if [[ -z "${OLD_RULES[$key]+x}" ]]; then
    IFS='|' read -r host proto port ip <<< "$key"
    add_rule "$proto" "$port" "$ip"
    echo "[$(date -Is)] added $proto/$port from $ip for $host"
  fi
done

write_state
echo "[$(date -Is)] refresh complete"
EOF

  chmod 750 "$REFRESH_SCRIPT"
}

write_service() {
  echo "Writing systemd service to $SERVICE_FILE ..."
  cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=Refresh UFW rules from DDNS hostnames
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ufw-ddns-refresh.sh
EOF
}

write_timer() {
  echo "Writing systemd timer to $TIMER_FILE ..."

  # shellcheck disable=SC1091
  source "$CONFIG_FILE"

  cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Run UFW DDNS refresh on schedule

[Timer]
OnBootSec=${TIMER_ON_BOOT_SEC}
OnCalendar=${TIMER_ON_CALENDAR}
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

resolve_host_ips() {
  local host="$1"
  {
    getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | grep -E '^[0-9.]+$' || true
    getent ahostsv6 "$host" 2>/dev/null | awk '{print $1}' | grep ':' | grep -vi '^::ffff:' || true
  } | sort -u
}

preflight_ssh_safety() {
  local current_ssh_ip host ip
  declare -A allowed_ips=()

  current_ssh_ip="${SSH_CLIENT%% *}"

  if [[ -z "${current_ssh_ip:-}" ]]; then
    echo "No SSH_CLIENT detected. Skipping SSH source safety check."
    return 0
  fi

  echo "Detected current SSH client IP: $current_ssh_ip"
  echo "Resolving DDNS names before applying firewall..."

  # shellcheck disable=SC1091
  source "$CONFIG_FILE"

  for host in "${DDNS_HOSTS[@]}"; do
    while IFS= read -r ip; do
      [[ -n "$ip" ]] || continue
      allowed_ips["$ip"]=1
      echo "  $host -> $ip"
    done < <(resolve_host_ips "$host")
  done

  if [[ -n "${allowed_ips[$current_ssh_ip]+x}" ]]; then
    echo "Current SSH client IP matches one of the allowed DDNS-resolved IPs."
    return 0
  fi

  echo "WARNING: current SSH client IP does not match any currently resolved DDNS IP."
  echo "You may lock yourself out if you continue from this session."
  echo "Set ALLOW_SSH_MISMATCH=yes if you want to force deployment anyway."

  if [[ "$ALLOW_SSH_MISMATCH" != "yes" ]]; then
    exit 1
  fi
}

reset_ufw_if_requested() {
  if [[ "$UFW_RESET" == "yes" ]]; then
    echo "Resetting UFW because UFW_RESET=yes ..."
    ufw --force reset
  else
    echo "Skipping UFW reset because UFW_RESET=$UFW_RESET"
    echo "Be aware: if old allow rules already exist, they may remain in place."
  fi
}

apply_base_policy() {
  echo "Applying UFW base policy..."
  ufw default allow outgoing
  ufw default deny incoming
}

apply_public_rules() {
  echo "Applying public allow rules..."

  # shellcheck disable=SC1091
  source "$CONFIG_FILE"

  for port in "${PUBLIC_TCP_PORTS[@]}"; do
    ufw allow "${port}/tcp"
  done

  for port in "${PUBLIC_UDP_PORTS[@]}"; do
    ufw allow "${port}/udp"
  done
}

run_initial_refresh_direct() {
  echo "Running initial DDNS refresh directly before enabling UFW..."
  "$REFRESH_SCRIPT"
}

enable_ufw() {
  echo "Enabling UFW..."
  ufw --force enable
}

reload_systemd_and_enable_timer() {
  echo "Reloading systemd and enabling timer..."
  systemctl daemon-reload
  systemctl enable --now ufw-ddns-refresh.timer
}

show_status() {
  echo
  echo "==== UFW STATUS ===="
  ufw status numbered || true
  echo
  echo "==== TIMER STATUS ===="
  systemctl status ufw-ddns-refresh.timer --no-pager || true
  echo
  echo "==== LAST REFRESH LOG ===="
  tail -n 50 /var/log/ufw-ddns-refresh.log || true
}

main() {
  require_root
  require_systemd
  install_ufw_if_needed
  write_config
  write_refresh_script
  write_service
  write_timer
  preflight_ssh_safety
  reset_ufw_if_requested
  apply_base_policy
  apply_public_rules
  run_initial_refresh_direct
  enable_ufw
  reload_systemd_and_enable_timer
  show_status
}

main "$@"