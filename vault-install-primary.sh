#!/usr/bin/env bash
set -euo pipefail

#Run, Initialize and Unseal
# chmod +x install-vault-primary.sh
# sudo ./install-vault-primary.sh

# export VAULT_ADDR="https://vault.secretchip.net:8200"
# export VAULT_CACERT="/opt/vault/tls/vault-ca.pem"
# vault operator init -key-shares=5 -key-threshold=3
# vault operator unseal
# vault operator unseal
# vault operator unseal
# vault login
# vault status

# =========================
# Fixed primary Vault values
# =========================
VAULT_FQDN="${VAULT_FQDN:-vault.secretchip.net}"
VAULT_IP="${VAULT_IP:-10.10.10.7}"
VAULT_NODE_ID="${VAULT_NODE_ID:-vault1}"

TLS_DIR="/opt/vault/tls"
DATA_DIR="/opt/vault/data"
CONFIG_DIR="/etc/vault.d"
CONFIG_FILE="${CONFIG_DIR}/vault.hcl"
AUDIT_DIR="/var/log/vault"
SYSTEMD_OVERRIDE_DIR="/etc/systemd/system/vault.service.d"
SYSTEMD_OVERRIDE_FILE="${SYSTEMD_OVERRIDE_DIR}/override.conf"
LOGROTATE_FILE="/etc/logrotate.d/vault-audit"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root."
    exit 1
  fi
}

backup_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    cp -a "$file" "${file}.bak.$(date +%Y%m%d-%H%M%S)"
  fi
}

install_packages() {
  apt-get update
  apt-get install -y curl wget gpg jq unzip openssl ca-certificates lsb-release
}

install_hashicorp_repo() {
  if [[ ! -f /usr/share/keyrings/hashicorp-archive-keyring.gpg ]]; then
    wget -O- https://apt.releases.hashicorp.com/gpg \
      | gpg --dearmor \
      | tee /usr/share/keyrings/hashicorp-archive-keyring.gpg >/dev/null
  fi

  source /etc/os-release
  cat >/etc/apt/sources.list.d/hashicorp.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${VERSION_CODENAME} main
EOF

  apt-get update
  apt-get install -y vault
}

create_directories() {
  mkdir -p "$TLS_DIR" "$DATA_DIR" "$CONFIG_DIR" "$AUDIT_DIR" "$SYSTEMD_OVERRIDE_DIR"
  chown -R vault:vault "$DATA_DIR" "$AUDIT_DIR"
  chmod 0750 "$DATA_DIR" "$AUDIT_DIR"
  chmod 0755 "$TLS_DIR"
}

generate_internal_ca() {
  if [[ ! -f "${TLS_DIR}/ca.key" || ! -f "${TLS_DIR}/vault-ca.pem" ]]; then
    openssl genrsa -out "${TLS_DIR}/ca.key" 4096
    openssl req -x509 -new -nodes \
      -key "${TLS_DIR}/ca.key" \
      -sha256 -days 3650 \
      -out "${TLS_DIR}/vault-ca.pem" \
      -subj "/C=PL/O=SecretChip/CN=SecretChip-Vault-Internal-CA"
  fi
}

generate_server_cert() {
  if [[ ! -f "${TLS_DIR}/vault-key.pem" || ! -f "${TLS_DIR}/vault-cert.pem" ]]; then
    cat >"${TLS_DIR}/vault-server.cnf" <<EOF
[req]
default_bits = 4096
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[dn]
C = PL
O = SecretChip
CN = ${VAULT_FQDN}

[req_ext]
subjectAltName = @alt_names
extendedKeyUsage = serverAuth

[alt_names]
DNS.1 = ${VAULT_FQDN}
DNS.2 = localhost
IP.1 = ${VAULT_IP}
IP.2 = 127.0.0.1
EOF

    openssl genrsa -out "${TLS_DIR}/vault-key.pem" 4096
    openssl req -new \
      -key "${TLS_DIR}/vault-key.pem" \
      -out "${TLS_DIR}/vault.csr" \
      -config "${TLS_DIR}/vault-server.cnf"

    openssl x509 -req \
      -in "${TLS_DIR}/vault.csr" \
      -CA "${TLS_DIR}/vault-ca.pem" \
      -CAkey "${TLS_DIR}/ca.key" \
      -CAcreateserial \
      -out "${TLS_DIR}/vault-cert.pem" \
      -days 825 \
      -sha256 \
      -extensions req_ext \
      -extfile "${TLS_DIR}/vault-server.cnf"
  fi

  chown root:root "${TLS_DIR}/vault-cert.pem" "${TLS_DIR}/vault-ca.pem"
  chown root:vault "${TLS_DIR}/vault-key.pem"
  chmod 0644 "${TLS_DIR}/vault-cert.pem" "${TLS_DIR}/vault-ca.pem"
  chmod 0640 "${TLS_DIR}/vault-key.pem"
}

write_vault_config() {
  backup_file "$CONFIG_FILE"

  cat >"$CONFIG_FILE" <<EOF
ui = true

api_addr = "https://${VAULT_FQDN}:8200"
cluster_addr = "https://${VAULT_FQDN}:8201"
disable_mlock = true

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_cert_file   = "${TLS_DIR}/vault-cert.pem"
  tls_key_file    = "${TLS_DIR}/vault-key.pem"
}

storage "raft" {
  path    = "${DATA_DIR}"
  node_id = "${VAULT_NODE_ID}"
}
EOF

  chown root:vault "$CONFIG_FILE"
  chmod 0640 "$CONFIG_FILE"
}

write_systemd_override() {
  backup_file "$SYSTEMD_OVERRIDE_FILE"

  cat >"$SYSTEMD_OVERRIDE_FILE" <<'EOF'
[Service]
Environment="VAULT_ENABLE_FILE_PERMISSIONS_CHECK=true"
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=/etc/vault.d /opt/vault /var/log/vault
EOF
}

write_logrotate() {
  cat >"$LOGROTATE_FILE" <<'EOF'
/var/log/vault/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    create 0640 vault vault
}
EOF
}

start_vault() {
  systemctl daemon-reload
  systemctl enable vault
  systemctl restart vault
  systemctl --no-pager --full status vault || true
}

print_next_steps() {
  cat <<EOF

Primary Vault installation complete.

Client environment:
  export VAULT_ADDR="https://${VAULT_FQDN}:8200"
  export VAULT_CACERT="${TLS_DIR}/vault-ca.pem"

Health checks:
  curl --cacert "${TLS_DIR}/vault-ca.pem" "https://${VAULT_FQDN}:8200/v1/sys/health" | jq
  curl --cacert "${TLS_DIR}/vault-ca.pem" "https://127.0.0.1:8200/v1/sys/health" | jq
  curl --cacert "${TLS_DIR}/vault-ca.pem" "https://localhost:8200/v1/sys/health" | jq

IMPORTANT:
  This node uses manual unseal with Shamir keys.

Initialize it with:
  vault operator init -key-shares=5 -key-threshold=3

Then unseal it with any 3 unseal keys:
  vault operator unseal
  vault operator unseal
  vault operator unseal

After unseal:
  vault login
  ./vault-bootstrap-primary.sh

Files created:
  ${CONFIG_FILE}
  ${TLS_DIR}/vault-ca.pem
  ${TLS_DIR}/vault-cert.pem
  ${TLS_DIR}/vault-key.pem
EOF
}

main() {
  require_root
  install_packages
  install_hashicorp_repo
  create_directories
  generate_internal_ca
  generate_server_cert
  write_vault_config
  write_systemd_override
  write_logrotate
  start_vault
  print_next_steps
}

main "$@"