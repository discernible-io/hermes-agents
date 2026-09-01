#!/usr/bin/env bash
# Bootstrap Sofia Celeste Hermes ingress on meb01:
#   https://sofiaceleste.mundoenblanco.com:8443  (Telegram + webhooks + A2A)
#
# Run from deploy/ after passport mint:
#   ./scripts/bootstrap-sofiaceleste-ingress.sh
# Then open the firewall (requires sudo password):
#   sudo /home/meb01/infra/configure-host-firewall-oneoff.sh enable permanent
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

HOST="${SOFIACELESTE_HOST:-sofiaceleste.mundoenblanco.com}"
INGRESS_PORT="${HERMES_INGRESS_PORT:-8443}"
APP="$(hermes_app_dir)"
DEPLOY_USER="${SUDO_USER:-${USER:-meb01}}"

marker="# sofiaceleste ingress (managed by bootstrap-sofiaceleste-ingress.sh)"

echo "==> Stopping Hermes (if running) ..."
"$REPO_ROOT/hermes.sh" stop 2>/dev/null || true
"$REPO_ROOT/hermes.sh" own host 2>/dev/null || {
  if [[ "$(id -u)" -eq 0 ]]; then
    chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "$APP"
  else
    echo "Run: sudo chown -R ${DEPLOY_USER}:${DEPLOY_USER} ${APP}" >&2
    exit 1
  fi
}

ENV_LOCAL="$(hermes_env_file)"
ENV_SECRETS="$(hermes_gateway_env_file)"
touch "$ENV_LOCAL" "$ENV_SECRETS"
chmod 600 "$ENV_LOCAL" "$ENV_SECRETS"

if ! grep -qF "$marker" "$ENV_LOCAL" 2>/dev/null; then
  cat >>"$ENV_LOCAL" <<EOF

${marker}
HERMES_DEPLOY_MODE=pod
HERMES_PUBLIC_HOST=${HOST}
HERMES_INGRESS_PORT=${INGRESS_PORT}
HERMES_TELEGRAM_PORT=${INGRESS_PORT}
WEBHOOK_ENABLED=true
EOF
  echo "Appended pod-mode settings to ${ENV_LOCAL}"
else
  echo "env.local already has ${marker}"
fi

upsert_env() {
  local file="$1" key="$2" val="$3"
  if grep -qE "^${key}=" "$file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$file"
  else
    printf '%s=%s\n' "$key" "$val" >>"$file"
  fi
}

if ! grep -qE '^WEBHOOK_SECRET=.+' "$ENV_SECRETS" 2>/dev/null; then
  upsert_env "$ENV_SECRETS" WEBHOOK_SECRET "$(openssl rand -hex 32)"
  echo "Generated WEBHOOK_SECRET in ${ENV_SECRETS}"
fi

upsert_env "$ENV_SECRETS" TELEGRAM_WEBHOOK_URL "https://${HOST}:${INGRESS_PORT}/telegram"
if ! grep -qE '^TELEGRAM_WEBHOOK_SECRET=.+' "$ENV_SECRETS" 2>/dev/null; then
  upsert_env "$ENV_SECRETS" TELEGRAM_WEBHOOK_SECRET "$(openssl rand -hex 32)"
  echo "Generated TELEGRAM_WEBHOOK_SECRET in ${ENV_SECRETS}"
fi
upsert_env "$ENV_SECRETS" WEBHOOK_ENABLED "true"
upsert_env "$ENV_SECRETS" WEBHOOK_PORT "8644"

# A2A: bind loopback; nginx on :8443 is the public surface.
upsert_env "$ENV_SECRETS" A2A_PORT "9900"
upsert_env "$ENV_SECRETS" A2A_HOST "127.0.0.1"
upsert_env "$ENV_SECRETS" A2A_PUBLIC_URL "https://${HOST}:${INGRESS_PORT}"

echo "==> TLS certs + nginx sidecar ..."
export HERMES_PUBLIC_HOST="$HOST"
export HERMES_INGRESS_PORT="$INGRESS_PORT"
"$REPO_ROOT/hermes.sh" generate-certs
"$REPO_ROOT/hermes.sh" build-nginx

echo "==> Starting Hermes pod (gateway + nginx) ..."
"$REPO_ROOT/hermes.sh" start

echo ""
echo "Done. Verify locally:"
echo "  curl -k https://127.0.0.1:${INGRESS_PORT}/health"
echo ""
echo "Open host firewall (sudo):"
echo "  sudo /home/meb01/infra/configure-host-firewall-oneoff.sh enable permanent"
echo "  sudo /home/meb01/infra/configure-host-firewall-oneoff.sh status"
echo ""
echo "Ensure DNS A/AAAA for ${HOST} points at this host, then register Telegram webhook:"
echo "  ${DEPLOY_USER}@${HOST}: cd ~/mundoenblanco-agent/deploy && ./hermes.sh exec -- hermes gateway telegram webhook-info"
