#!/usr/bin/env bash
# Migrate OpenClaw agent-b (Olivia Tara) → Hermes profile "olivia".
# - Uses Hermes-native profiles/ (not OpenClaw agents/agent-*).
# - Never writes into the default (Lemuel) profile home secrets/.env.
# - Secrets: create-only / fill-empty.
# - Memory/persona: hermes claw migrate --preset user-data (no --migrate-secrets).
set -euo pipefail

HERMES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "${HERMES_ROOT}/scripts/lib.sh"

OPENCLAW_APP="${OPENCLAW_APP_DIR:-$HOME/openclaw-agents-app}"
OPENCLAW_SRC="${OPENCLAW_AGENT_B:-${OPENCLAW_APP}/agents/agent-b}"
OPENCLAW_CTR="${OPENCLAW_AGENT_B_CONTAINER:-openclaw-agent-b}"
PROFILE_ID=olivia
DRY_RUN=0
DO_CUTOVER=0

usage() {
  cat <<EOF
Usage: migrate-olivia-from-openclaw.sh [--dry-run] [--cutover]

  --dry-run   Print actions only
  --cutover   After seeding, stop OpenClaw agent-b and start Hermes olivia
              in hermes-agent-pod (Hermes :10443 / Telegram 80→10443; OpenClaw keeps :8443)
EOF
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --cutover) DO_CUTOVER=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $arg" >&2; usage; exit 1 ;;
  esac
done

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY: $*"
  else
    "$@"
  fi
}

echo "==> Olivia migration (OpenClaw agent-b → Hermes profile olivia)"
echo "    OpenClaw source: ${OPENCLAW_SRC} (container ${OPENCLAW_CTR})"
echo "    Fleet:           $(hermes_fleet_dir)"

load_fleet_env_only
fleet="$(hermes_fleet_dir)"
home="$(profile_home "$PROFILE_ID")"

# --- 1. Fleet env knobs (non-secrets, no overwrite of existing keys) --------
fleet_env="${fleet}/env.local"
if [[ "$DRY_RUN" == "0" ]]; then
  # Host may need sudo to create under 0700 hermes-owned tree.
  if [[ ! -w "$fleet" ]]; then
    echo "Fleet dir not writable by $(id -un): ${fleet}" >&2
    echo "Stop Lemuel briefly and reclaim, or run with sudo for seeding:" >&2
    echo "  cd ${HERMES_ROOT} && ./hermes.sh stop default && ./hermes.sh own host" >&2
    echo "  # then re-run this script; finally: ./hermes.sh start default" >&2
    exit 1
  fi
fi

run mkdir -p "${fleet}/profiles"
run ensure_profile_home "$PROFILE_ID"

if [[ "$DRY_RUN" == "0" ]]; then
  touch "$fleet_env"
  chmod 600 "$fleet_env" 2>/dev/null || true
  # PROFILE_IDS / AGENT_IDS
  if ! grep -qE '^PROFILE_IDS=' "$fleet_env" 2>/dev/null; then
    if grep -qE '^AGENT_IDS=' "$fleet_env" 2>/dev/null; then
      :
    else
      printf '\n# Multi-profile (Hermes-native). default=Lemuel, olivia=Olivia Tara\nPROFILE_IDS="default olivia"\n' >>"$fleet_env"
    fi
  fi
  envfile_set_if_empty "$fleet_env" AGENT_B_EMAIL "olivia@agenthood.me"
  envfile_set_if_empty "$fleet_env" AGENT_B_DISPLAY_NAME "Olivia Tara"
  envfile_set_if_empty "$fleet_env" AGENT_B_PUBLIC_HOST "oliviatara.dihola.io"
  # Hermes side of infra divide: 10443 (+ Telegram via 80→10443); OpenClaw keeps :8443.
  envfile_set_if_empty "$fleet_env" AGENT_B_INGRESS_PORT "10443"
  envfile_set_if_empty "$fleet_env" AGENT_B_EXTRA_INGRESS_PORTS "7443"
  envfile_set_if_empty "$fleet_env" AGENT_B_API_PORT "11643"
  envfile_set_if_empty "$fleet_env" AGENT_B_DEPLOY_MODE "pod"
  envfile_set_if_empty "$fleet_env" AGENT_B_SMTP_PORT "587"
  envfile_set_if_empty "$fleet_env" AGENT_B_SMTP_ENCRYPTION "start-tls"
  envfile_set_if_empty "$fleet_env" AGENT_B_JOIN_POD "hermes-agent-pod"
  # Distinct loopback ports — shared netns with Lemuel on hermes-agent-pod.
  envfile_set_if_empty "$fleet_env" AGENT_B_TELEGRAM_WEBHOOK_PORT "8743"
  envfile_set_if_empty "$fleet_env" AGENT_B_WEBHOOK_PORT "8744"
  envfile_set_if_empty "$fleet_env" AGENT_B_A2A_PORT "9920"
  envfile_set_if_empty "$fleet_env" AGENT_B_AUTH_PORT "9921"
  envfile_set_if_empty "$fleet_env" AGENT_B_HOOKS_PORT "9922"
  envfile_set_if_empty "$fleet_env" AGENT_B_API_SERVER_PORT "8742"
fi

# Profile-local non-secrets
prof_env="${home}/env.local"
if [[ "$DRY_RUN" == "0" ]]; then
  touch "$prof_env"
  chmod 600 "$prof_env"
  envfile_set_if_empty "$prof_env" HERMES_EMAIL "olivia@agenthood.me"
  envfile_set_if_empty "$prof_env" HERMES_EMAIL_DISPLAY_NAME "Olivia Tara"
  envfile_set_if_empty "$prof_env" HERMES_PUBLIC_HOST "oliviatara.dihola.io"
  envfile_set_if_empty "$prof_env" HERMES_INGRESS_PORT "10443"
  envfile_set_if_empty "$prof_env" HERMES_EXTRA_INGRESS_PORTS "7443"
  envfile_set_if_empty "$prof_env" HERMES_API_PORT "11643"
  envfile_set_if_empty "$prof_env" HERMES_DEPLOY_MODE "pod"
  envfile_set_if_empty "$prof_env" HERMES_SMTP_PORT "587"
  envfile_set_if_empty "$prof_env" HERMES_SMTP_ENCRYPTION "start-tls"
  envfile_set_if_empty "$prof_env" WEBHOOK_ENABLED "true"
  envfile_set_if_empty "$prof_env" WEBHOOK_PORT "8744"
  envfile_set_if_empty "$prof_env" TELEGRAM_WEBHOOK_PORT "8743"
  envfile_set_if_empty "$prof_env" API_SERVER_PORT "8742"
  envfile_set_if_empty "$prof_env" A2A_PORT "9920"
  envfile_set_if_empty "$prof_env" IDENTYCLAW_AUTH_PORT "9921"
  envfile_set_if_empty "$prof_env" IDENTYCLAW_HOOKS_PORT "9922"
  envfile_set_if_empty "$prof_env" A2A_PUBLIC_URL "https://oliviatara.dihola.io:7443"
  envfile_set_if_empty "$prof_env" IDENTYCLAW_WEBHOOK_URL "https://oliviatara.dihola.io:7443"
  envfile_set_if_empty "$prof_env" IDENTYCLAW_CONTACT_URI "email:agenthood.me:olivia@agenthood.me"
fi

# --- 2. File secrets via running OpenClaw container (mode 0700 on host) ------
echo "==> Copying file secrets (create-only)"
copy_via_ctr() {
  local src_in_ctr="$1" dst_host="$2"
  if [[ -s "$dst_host" ]]; then
    echo "  keep existing ${dst_host}"
    return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY: podman cp ${OPENCLAW_CTR}:${src_in_ctr} → ${dst_host}"
    return 0
  fi
  mkdir -p "$(dirname "$dst_host")"
  if podman cp "${OPENCLAW_CTR}:${src_in_ctr}" "$dst_host" 2>/dev/null; then
    chmod 600 "$dst_host" 2>/dev/null || true
    echo "  copied $(basename "$dst_host")"
  else
    echo "  WARN: missing ${src_in_ctr}" >&2
  fi
}

OC=/home/node/.openclaw
run mkdir -p "${home}/secrets/near-credentials" "${home}/secrets/identyclaw" "${home}/secrets/himalaya"
copy_via_ctr "${OC}/secrets/near-credentials/5f451f161793275f03b82ee3cdb93d75ec57d90878d9aaff0d5bcd5a457d488e.json" \
  "${home}/secrets/near-credentials/5f451f161793275f03b82ee3cdb93d75ec57d90878d9aaff0d5bcd5a457d488e.json"
copy_via_ctr "${OC}/secrets/near-credentials/.active" "${home}/secrets/near-credentials/.active"
copy_via_ctr "${OC}/secrets/identyclaw/sessions.json" "${home}/secrets/identyclaw/sessions.json"
copy_via_ctr "${OC}/secrets/identyclaw/jwt-aHR0cHM6Ly9hcGkuaWRlbnR5Y2xhdy5jb20.txt" \
  "${home}/secrets/identyclaw/jwt-aHR0cHM6Ly9hcGkuaWRlbnR5Y2xhdy5jb20.txt"
# Himalaya reshape
copy_via_ctr "${OC}/secrets/imap.pass" "${home}/secrets/himalaya/imap.pass"
copy_via_ctr "${OC}/secrets/smtp.pass" "${home}/secrets/himalaya/smtp.pass"
if [[ "$DRY_RUN" == "0" ]]; then
  if [[ -s "${home}/secrets/himalaya/imap.pass" && ! -f "${home}/secrets/himalaya/imap.sh" ]]; then
    cat >"${home}/secrets/himalaya/imap.sh" <<'EOF'
#!/bin/sh
cat "$(dirname "$0")/imap.pass"
EOF
    cp -a "${home}/secrets/himalaya/imap.sh" "${home}/secrets/himalaya/smtp.sh"
    chmod 700 "${home}/secrets/himalaya"/*.sh
  fi
  near_json="${home}/secrets/near-credentials/5f451f161793275f03b82ee3cdb93d75ec57d90878d9aaff0d5bcd5a457d488e.json"
  if [[ -s "$near_json" ]]; then
    printf '%s\n' "$near_json" >"${home}/secrets/near-credentials/.active"
  fi
fi

# --- 3. .env secrets (create-only) from container .env + secret files --------
echo "==> Seeding profile .env (create-only, never Lemuel)"
gateway_env="${home}/.env"
if [[ "$DRY_RUN" == "0" ]]; then
  touch "$gateway_env"
  chmod 600 "$gateway_env"
fi

# Pull allowlisted keys from OpenClaw .env via python in the container → host.
if [[ "$DRY_RUN" == "0" ]]; then
  tmp_env="$(mktemp)"
  podman exec "$OPENCLAW_CTR" sh -c "cat ${OC}/.env" >"$tmp_env" 2>/dev/null || true
  # Also materialize file-backed tokens into the tmp map
  for key in TELEGRAM_BOT_TOKEN TELEGRAM_WEBHOOK_SECRET OPENROUTER_API_KEY; do
    if podman exec "$OPENCLAW_CTR" test -f "${OC}/secrets/${key}" 2>/dev/null; then
      val="$(podman exec "$OPENCLAW_CTR" cat "${OC}/secrets/${key}" | tr -d '\r\n')"
      if [[ -n "$val" ]]; then
        if grep -qE "^${key}=" "$tmp_env" 2>/dev/null; then
          # prefer file secret if env empty
          cur="$(grep -E "^${key}=" "$tmp_env" | tail -1 | sed "s/^${key}=//")"
          [[ -z "$cur" ]] && sed -i "s|^${key}=.*|${key}=${val}|" "$tmp_env"
        else
          printf '%s=%s\n' "$key" "$val" >>"$tmp_env"
        fi
      fi
    fi
  done

  python3 - "$tmp_env" "$gateway_env" "$home" <<'PY'
import pathlib, sys
src, dst, home = map(pathlib.Path, sys.argv[1:4])
allow = {
    "TELEGRAM_BOT_TOKEN", "TELEGRAM_WEBHOOK_SECRET", "TELEGRAM_WEBHOOK_URL",
    "TELEGRAM_ALLOWED_USERS", "TELEGRAM_HOME_CHANNEL", "TELEGRAM_HOME_CHANNEL_THREAD_ID",
    "DISCORD_BOT_TOKEN", "DISCORD_ALLOWED_USERS",
    "OPENROUTER_API_KEY", "WEBHOOK_SECRET", "WEBHOOK_ENABLED", "WEBHOOK_PORT",
    "HERMES_GATEWAY_TOKEN", "API_SERVER_KEY",
    "IDENTYCLAW_JWT_AUDIENCE", "IDENTYCLAW_JWT_ISSUER", "IDENTYCLAW_A2A_AUTH",
    "A2A_PUBLIC_URL", "A2A_AGENT_NAME", "A2A_HOST", "A2A_PORT",
    "NEAR_CREDENTIALS_FILE_PATH", "RODIT_NEAR_CREDENTIALS_SOURCE",
}
# Map OpenClaw gateway token → Hermes
aliases = {"OPENCLAW_GATEWAY_TOKEN": "HERMES_GATEWAY_TOKEN"}
existing = {}
if dst.exists():
    for line in dst.read_text().splitlines():
        if not line or line.lstrip().startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        existing[k] = v

def take(k, v):
    if k in existing and existing[k].strip():
        return
    existing[k] = v

near = home / "secrets/near-credentials/5f451f161793275f03b82ee3cdb93d75ec57d90878d9aaff0d5bcd5a457d488e.json"
if src.exists():
    for line in src.read_text().splitlines():
        if not line or line.lstrip().startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        k = aliases.get(k, k)
        if k not in allow and k not in aliases.values():
            continue
        if not v.strip():
            continue
        take(k, v)

# Defaults / path rewrites for Hermes layout
take("RODIT_NEAR_CREDENTIALS_SOURCE", "file")
if near.exists():
    take("NEAR_CREDENTIALS_FILE_PATH", str(near))
take("TELEGRAM_WEBHOOK_URL", "https://oliviatara.dihola.io:80/telegram")
take("TELEGRAM_WEBHOOK_PORT", "8743")
take("WEBHOOK_ENABLED", "true")
take("WEBHOOK_PORT", "8744")
take("API_SERVER_PORT", "8742")
take("A2A_PUBLIC_URL", "https://oliviatara.dihola.io:7443")
take("A2A_HOST", "127.0.0.1")
take("A2A_PORT", "9920")
take("A2A_AUTH_SIDECAR_PORT", "9921")
take("IDENTYCLAW_AUTH_PORT", "9921")
take("IDENTYCLAW_HOOKS_PORT", "9922")
take("IDENTYCLAW_A2A_AUTH", "passport-jwt")
take("IDENTYCLAW_JWT_ISSUER", "https://api.identyclaw.com")
# Olivia NEAR account id is the JWT audience for inbound peers
take("IDENTYCLAW_JWT_AUDIENCE", "5f451f161793275f03b82ee3cdb93d75ec57d90878d9aaff0d5bcd5a457d488e")
# Never keep OpenClaw workspace paths — terminal/shell cd would fail on Hermes.
for stale in ("MESSAGING_CWD", "TERMINAL_CWD", "OPENCLAW_HOME", "OPENCLAW_STATE_DIR"):
    existing.pop(stale, None)
existing["MESSAGING_CWD"] = "/opt/data"
# Generate webhook secret if missing
import secrets
if not existing.get("WEBHOOK_SECRET", "").strip():
    existing["WEBHOOK_SECRET"] = secrets.token_hex(32)
if not existing.get("TELEGRAM_WEBHOOK_SECRET", "").strip():
    existing["TELEGRAM_WEBHOOK_SECRET"] = secrets.token_hex(32)

lines = [f"{k}={v}\n" for k, v in sorted(existing.items())]
dst.write_text("".join(lines))
dst.chmod(0o600)
print(f"  wrote {dst} ({len(existing)} keys, create-only merge)")
PY
  rm -f "$tmp_env"
fi

# --- 4. Persona / memory via hermes claw migrate ----------------------------
echo "==> Memory/persona import (hermes claw migrate --preset user-data)"
select_profile "$PROFILE_ID"
if [[ "$DRY_RUN" == "1" ]]; then
  echo "DRY: HERMES_HOME=${home} hermes claw migrate --source ${OPENCLAW_SRC} --preset user-data --yes"
else
  # Stage a host-readable copy of the OpenClaw workspace for the migrator.
  # Container paths are not visible to a host-side hermes; use podman cp of
  # the workspace subset into a temp source tree.
  stage="$(mktemp -d)"
  mkdir -p "${stage}/workspace" "${stage}/workspace/memory"
  podman cp "${OPENCLAW_CTR}:${OC}/workspace/SOUL.md" "${stage}/workspace/SOUL.md" 2>/dev/null || true
  podman cp "${OPENCLAW_CTR}:${OC}/workspace/USER.md" "${stage}/workspace/USER.md" 2>/dev/null || true
  podman cp "${OPENCLAW_CTR}:${OC}/workspace/AGENTS.md" "${stage}/workspace/AGENTS.md" 2>/dev/null || true
  podman cp "${OPENCLAW_CTR}:${OC}/workspace/IDENTITY.md" "${stage}/workspace/IDENTITY.md" 2>/dev/null || true
  podman cp "${OPENCLAW_CTR}:${OC}/workspace/DREAMS.md" "${stage}/workspace/DREAMS.md" 2>/dev/null || true
  # daily memory files
  podman exec "$OPENCLAW_CTR" sh -c "ls ${OC}/workspace/memory/*.md 2>/dev/null" \
    | while read -r f; do
        [[ -n "$f" ]] || continue
        base="$(basename "$f")"
        podman cp "${OPENCLAW_CTR}:${f}" "${stage}/workspace/memory/${base}" 2>/dev/null || true
      done

  mkdir -p "${home}/migration/openclaw-archive"
  [[ -f "${stage}/workspace/IDENTITY.md" ]] && cp -a "${stage}/workspace/IDENTITY.md" "${home}/migration/openclaw-archive/" || true
  [[ -f "${stage}/workspace/DREAMS.md" ]] && cp -a "${stage}/workspace/DREAMS.md" "${home}/migration/openclaw-archive/" || true

  # Prefer in-container migrator so we match the running Hermes image.
  if container_is_running hermes 2>/dev/null; then
    z="$(selinux_mount_suffix)"
    podman run --rm \
      --user 10000:10000 \
      --entrypoint hermes \
      -v "${home}:/opt/data:rw${z}" \
      -v "${home}:${home}:rw${z}" \
      -v "${stage}:/import:ro${z}" \
      -e "HERMES_HOME=/opt/data" \
      -e "HOME=/opt/data" \
      "${HERMES_IMAGE:-docker.io/nousresearch/hermes-agent:latest}" \
      claw migrate --source /import --preset user-data --yes \
      --workspace-target /opt/data/workspace || {
        echo "WARN: claw migrate failed — copying SOUL/USER manually" >&2
        [[ -f "${stage}/workspace/SOUL.md" && ! -f "${home}/SOUL.md" ]] && cp -a "${stage}/workspace/SOUL.md" "${home}/SOUL.md"
        mkdir -p "${home}/memories"
        if [[ -f "${stage}/workspace/USER.md" && ! -s "${home}/memories/USER.md" ]]; then
          # Rough convert: store as a single § entry
          {
            echo "Imported from OpenClaw USER.md:"
            cat "${stage}/workspace/USER.md"
          } >"${home}/memories/USER.md"
          chmod 600 "${home}/memories/USER.md"
        fi
      }
  else
    echo "WARN: hermes container not running — manual SOUL/USER copy" >&2
    [[ -f "${stage}/workspace/SOUL.md" && ! -f "${home}/SOUL.md" ]] && cp -a "${stage}/workspace/SOUL.md" "${home}/SOUL.md"
  fi
  rm -rf "$stage"
fi

# Ensure gateway.standalone for Passport isolation
if [[ "$DRY_RUN" == "0" ]]; then
  if [[ -f "${home}/config.yaml" ]]; then
    if ! grep -q 'standalone:' "${home}/config.yaml" 2>/dev/null; then
      printf '\ngateway:\n  standalone: true\n' >>"${home}/config.yaml"
    fi
  else
    printf 'gateway:\n  standalone: true\n' >"${home}/config.yaml"
    chmod 600 "${home}/config.yaml"
  fi
fi

echo "==> Seed complete for ${home}"

# --- 5. Optional cutover ----------------------------------------------------
if [[ "$DO_CUTOVER" != "1" ]]; then
  echo ""
  echo "Next: review ${home}/.env (no Lemuel keys touched), then:"
  echo "  ${HERMES_ROOT}/hermes.sh migrate-olivia --cutover"
  echo "  # or manually:"
  echo "  podman stop openclaw-nginx openclaw-agent-b"
  echo "  ${HERMES_ROOT}/hermes.sh start olivia"
  exit 0
fi

echo "==> Cutover: stop OpenClaw agent-b only; Olivia joins hermes-agent-pod (OpenClaw keeps :8443)"
run podman stop openclaw-agent-b 2>/dev/null || true

# Copy LE certs into fleet if missing (SAN covers oliviatara; shared hermes-nginx uses fleet certs)
if [[ "$DRY_RUN" == "0" ]]; then
  fleet_certs="$(hermes_fleet_dir)/certs"
  if [[ ! -s "${fleet_certs}/fullchain.pem" && -s "${OPENCLAW_APP}/certs/fullchain.pem" ]]; then
    mkdir -p "${fleet_certs}"
    cp -a "${OPENCLAW_APP}/certs/fullchain.pem" "${fleet_certs}/" 2>/dev/null \
      || podman unshare cp -a "${OPENCLAW_APP}/certs/fullchain.pem" "${fleet_certs}/" || true
    cp -a "${OPENCLAW_APP}/certs/privkey.pem" "${fleet_certs}/" 2>/dev/null \
      || podman unshare cp -a "${OPENCLAW_APP}/certs/privkey.pem" "${fleet_certs}/" || true
  fi
fi

select_profile olivia
if [[ "$DRY_RUN" == "1" ]]; then
  echo "DRY: ${HERMES_ROOT}/hermes.sh start olivia"
else
  bash "${HERMES_ROOT}/hermes.sh" start olivia
fi

echo "==> Cutover done. Smoke:"
echo "  curl -sk https://oliviatara.dihola.io:10443/health"
echo "  curl -sk https://oliviatara.dihola.io:80/health"
echo "  curl -sk https://oliviatara.dihola.io:7443/health"
echo "  curl -sk https://joe.dihola.io:8443/health"
echo "  curl -sk https://daniel.dihola.io:8443/health"
echo "  curl -sk https://identyclaw-concierge.identyclaw.com:10443/health"
echo "  ${HERMES_ROOT}/hermes.sh -p olivia idcp me"
echo "  ${HERMES_ROOT}/hermes.sh -p default idcp me"
