#!/usr/bin/env bash
set -euo pipefail

: "${VAULT_ADDR:=https://vault.secretchip.net:8200}"
: "${VAULT_CACERT:=/opt/vault/tls/vault-ca.pem}"
: "${VAULT_TOKEN:?Set VAULT_TOKEN}"

: "${OIDC_DISCOVERY_URL:?Set OIDC_DISCOVERY_URL}"
: "${OIDC_CLIENT_ID:?Set OIDC_CLIENT_ID}"
: "${OIDC_CLIENT_SECRET:?Set OIDC_CLIENT_SECRET}"

export VAULT_ADDR VAULT_CACERT VAULT_TOKEN

vault write auth/oidc/config \
  oidc_discovery_url="${OIDC_DISCOVERY_URL}" \
  oidc_client_id="${OIDC_CLIENT_ID}" \
  oidc_client_secret="${OIDC_CLIENT_SECRET}" \
  default_role="vault-admins"

vault write auth/oidc/role/vault-admins \
  user_claim="sub" \
  groups_claim="groups" \
  policies="admin" \
  ttl="1h" \
  allowed_redirect_uris="https://vault.secretchip.net:8200/ui/vault/auth/oidc/oidc/callback" \
  allowed_redirect_uris="http://localhost:8250/oidc/callback"