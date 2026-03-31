#!/usr/bin/env bash
set -euo pipefail

#Run it as:[
#chmod +x vault-bootstrap-primary.sh
#export VAULT_ADDR="https://vault.secretchip.net:8200"
#export VAULT_CACERT="/opt/vault/tls/vault-ca.pem"
#export VAULT_TOKEN="YOUR_ROOT_OR_ADMIN_TOKEN"
#./vault-bootstrap-primary.sh
#]

: "${VAULT_ADDR:=https://vault.secretchip.net:8200}"
: "${VAULT_CACERT:=/opt/vault/tls/vault-ca.pem}"
: "${VAULT_TOKEN:?Set VAULT_TOKEN before running this script}"

PKI_CA_CN="${PKI_CA_CN:-SecretChip Internal Services CA}"
PKI_ALLOWED_DOMAIN="${PKI_ALLOWED_DOMAIN:-secretchip.net}"
AUDIT_FILE="${AUDIT_FILE:-/var/log/vault/audit.log}"
TRANSIT_KEY_NAME="${TRANSIT_KEY_NAME:-app-default}"

export VAULT_ADDR VAULT_CACERT VAULT_TOKEN

log() {
  printf '[+] %s\n' "$*"
}

fail() {
  printf '[!] %s\n' "$*" >&2
  exit 1
}

require_commands() {
  local missing=0
  for cmd in vault jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      printf '[!] Missing required command: %s\n' "$cmd" >&2
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || exit 1
}

preflight_checks() {
  log "Checking Vault status"
  if ! vault status >/tmp/vault-status.$$ 2>/dev/null; then
    rm -f /tmp/vault-status.$$
    fail "Cannot reach Vault at ${VAULT_ADDR}. Check VAULT_ADDR, TLS trust, DNS, and whether Vault is running."
  fi

  if grep -qi '^Sealed[[:space:]]*true' /tmp/vault-status.$$; then
    rm -f /tmp/vault-status.$$
    fail "Vault is sealed. Unseal it first with your Shamir keys."
  fi

  rm -f /tmp/vault-status.$$
}

enable_audit() {
  log "Ensuring file audit logging is enabled"
  if ! vault audit list -format=json | jq -e 'has("file/")' >/dev/null; then
    vault audit enable file file_path="${AUDIT_FILE}"
  else
    log "File audit device already enabled"
  fi
}

write_policies() {
  log "Writing policies"

  cat >/tmp/admin.hcl <<'EOF'
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
EOF

  cat >/tmp/app-read.hcl <<'EOF'
path "kv/data/apps/prod/*" {
  capabilities = ["read"]
}

path "kv/metadata/apps/prod/*" {
  capabilities = ["read", "list"]
}
EOF

  vault policy write admin /tmp/admin.hcl
  vault policy write app-read /tmp/app-read.hcl

  rm -f /tmp/admin.hcl /tmp/app-read.hcl
}

enable_auth_methods() {
  log "Ensuring required auth methods are enabled"
  vault auth list -format=json | jq -e 'has("approle/")' >/dev/null || vault auth enable approle
  vault auth list -format=json | jq -e 'has("oidc/")' >/dev/null || vault auth enable oidc
}

enable_secrets_engines() {
  log "Ensuring required secrets engines are enabled"
  vault secrets list -format=json | jq -e 'has("kv/")' >/dev/null || vault secrets enable -path=kv -version=2 kv
  vault secrets list -format=json | jq -e 'has("transit/")' >/dev/null || vault secrets enable transit
  vault secrets list -format=json | jq -e 'has("pki/")' >/dev/null || vault secrets enable pki

  vault secrets tune -max-lease-ttl=87600h pki
}

configure_pki() {
  log "Configuring PKI"

  if ! vault read pki/cert/ca >/dev/null 2>&1; then
    vault write -field=certificate pki/root/generate/internal \
      common_name="${PKI_CA_CN}" \
      ttl=87600h >/etc/vault.d/pki-ca.crt
    chown root:vault /etc/vault.d/pki-ca.crt
    chmod 0640 /etc/vault.d/pki-ca.crt
  else
    log "PKI root CA already exists"
  fi

  vault write pki/config/urls \
    issuing_certificates="${VAULT_ADDR}/v1/pki/ca" \
    crl_distribution_points="${VAULT_ADDR}/v1/pki/crl"

  vault write pki/roles/internal-services \
    allowed_domains="${PKI_ALLOWED_DOMAIN}" \
    allow_subdomains=true \
    max_ttl="720h"
}

configure_transit() {
  log "Configuring Transit"

  if ! vault read "transit/keys/${TRANSIT_KEY_NAME}" >/dev/null 2>&1; then
    vault write -f "transit/keys/${TRANSIT_KEY_NAME}"
  else
    log "Transit key ${TRANSIT_KEY_NAME} already exists"
  fi
}

configure_approle() {
  log "Configuring AppRole"

  vault write auth/approle/role/app-prod \
    token_policies="app-read" \
    token_ttl="1h" \
    token_max_ttl="4h" \
    secret_id_ttl="24h" \
    secret_id_num_uses=0
}

seed_example_secret() {
  log "Writing example KV secret"
  vault kv put kv/apps/prod/myapp username="svc_app" password="replace-me-now"
}

print_summary() {
  local role_id
  role_id="$(vault read -field=role_id auth/approle/role/app-prod/role-id)"

  cat <<EOF

Bootstrap complete.

What is now enabled:
  - audit: file -> ${AUDIT_FILE}
  - auth methods: approle, oidc
  - secrets engines: kv v2, transit, pki

Created objects:
  - policies: admin, app-read
  - AppRole: app-prod
  - Transit key: ${TRANSIT_KEY_NAME}
  - PKI role: internal-services
  - example secret: kv/apps/prod/myapp

AppRole Role ID:
  ${role_id}

Generate a Secret ID with:
  vault write -force -field=secret_id auth/approle/role/app-prod/secret-id

Read the example secret with:
  vault kv get kv/apps/prod/myapp

Issue a certificate with:
  vault write pki/issue/internal-services common_name="host.${PKI_ALLOWED_DOMAIN}" ttl="24h"

Next step for OIDC:
  Run your separate OIDC configuration script after you have the provider values.
EOF
}

main() {
  require_commands
  preflight_checks
  enable_audit
  write_policies
  enable_auth_methods
  enable_secrets_engines
  configure_pki
  configure_transit
  configure_approle
  seed_example_secret
  print_summary
}

main "$@"