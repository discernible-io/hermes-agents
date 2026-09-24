#!/usr/bin/env bash
# Install IdentyClaw into an existing Hermes home (vanilla Hermes, not this Podman wrapper).
#
# Usage:
#   ./install.sh                 # Tier 1: idcp + skill (call federated peers)
#   ./install.sh --peer          # Tier 1 + A2A overlay + signed /hooks/* plugins
#   ./install.sh --client        # same as default Tier 1
#   HERMES_HOME=/path ./install.sh --peer
#
# Requires: node + npm (Node ≥ 22.19). Does not start Hermes or the auth sidecar.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_HOME="${HERMES_HOME:-${IDENTYCLAW_HOME:-$HOME/.hermes}}"
MODE=client
ENABLE_CONFIG=1

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \?//'
  cat <<EOF

Options:
  --client          Install idcp CLI + skill only (default)
  --peer            Also install a2a-platform + identyclaw-webhooks plugins
  --no-enable       Install plugins/files but do not edit config.yaml
  -h, --help        Show this help

Environment:
  HERMES_HOME       Target Hermes profile (default: ~/.hermes)
  IDENTYCLAW_HOME   Optional override preferred by idcp for secrets layout
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --client) MODE=client; shift ;;
    --peer) MODE=peer; shift ;;
    --no-enable) ENABLE_CONFIG=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

pkg_auth="${ROOT}/packages/hermes-identyclaw-auth"
pkg_a2a="${ROOT}/packages/hermes-identyclaw-a2a"
pkg_hooks="${ROOT}/packages/hermes-identyclaw-webhooks"
skill_src="${ROOT}/deploy/skills/identyclaw"

die() { echo "error: $*" >&2; exit 1; }

require_cmds() {
  command -v node >/dev/null 2>&1 || die "node is required (Node ≥ 22.19)"
  command -v npm >/dev/null 2>&1 || die "npm is required"
}

install_auth_and_skill() {
  [[ -d "$pkg_auth" ]] || die "missing ${pkg_auth}"
  [[ -d "$skill_src" ]] || die "missing ${skill_src}"

  mkdir -p "${HERMES_HOME}/bin" \
    "${HERMES_HOME}/skills/identity/identyclaw" \
    "${HERMES_HOME}/secrets/near-credentials" \
    "${HERMES_HOME}/secrets/identyclaw"

  echo "Installing auth package deps in ${pkg_auth} ..."
  (cd "$pkg_auth" && npm install --omit=dev)

  ln -sfn "${pkg_auth}/bin/idcp.mjs" "${HERMES_HOME}/bin/idcp"
  chmod +x "${pkg_auth}/bin/idcp.mjs" "${pkg_auth}/bin/sidecar.mjs" 2>/dev/null || true

  cp -a "${skill_src}/." "${HERMES_HOME}/skills/identity/identyclaw/"

  # Prefer this Hermes home for idcp secrets unless the operator already set one.
  if [[ -z "${IDENTYCLAW_HOME:-}" ]]; then
    if [[ -f "${HERMES_HOME}/.env" ]] || [[ -f "${HERMES_HOME}/config.yaml" ]]; then
      # Soft hint file for operators; idcp also honors HERMES_HOME.
      :
    fi
  fi
}

install_peer_plugins() {
  [[ -d "$pkg_a2a" && -d "$pkg_hooks" ]] || die "missing peer packages under ${ROOT}/packages/"
  local plugins_dir="${HERMES_HOME}/plugins"
  mkdir -p "$plugins_dir"
  rm -rf "${plugins_dir}/a2a-platform" "${plugins_dir}/identyclaw-webhooks"
  cp -a "$pkg_a2a" "${plugins_dir}/a2a-platform"
  cp -a "$pkg_hooks" "${plugins_dir}/identyclaw-webhooks"
  rm -rf "${plugins_dir}/a2a-platform/__pycache__" \
    "${plugins_dir}/identyclaw-webhooks/__pycache__"
  echo "Installed plugins → ${plugins_dir}/a2a-platform , identyclaw-webhooks"
}

enable_peer_config() {
  [[ "$ENABLE_CONFIG" == 1 ]] || {
    echo "Skipping config.yaml enablement (--no-enable)"
    return 0
  }
  command -v python3 >/dev/null 2>&1 || {
    echo "python3 missing — enable plugins manually in ${HERMES_HOME}/config.yaml" >&2
    return 0
  }
  if [[ ! -f "${HERMES_HOME}/config.yaml" ]]; then
    cat > "${HERMES_HOME}/config.yaml" <<'YAML'
# Minimal Hermes config stub created by IdentyClaw install.sh.
# Merge with your real config if Hermes setup writes a fuller file later.
YAML
    echo "Created stub ${HERMES_HOME}/config.yaml"
  fi
  python3 - "$HERMES_HOME" <<'PY'
import pathlib, sys
home = pathlib.Path(sys.argv[1])
cfg = home / "config.yaml"
text = cfg.read_text() if cfg.is_file() else ""
marker = "# identyclaw-peer (managed by install.sh)"
block = f"""
{marker}
plugins:
  enabled:
    - a2a-platform
    - identyclaw-webhooks
  entries:
    a2a-platform:
      enabled: true
      allow_tool_override: true
      granted_capabilities:
        - tools.override
    identyclaw-webhooks:
      enabled: true
platforms:
  a2a:
    enabled: true
  identyclaw_hooks:
    enabled: true
"""
if marker in text:
    print(f"{cfg} already has install.sh marker (left unchanged)")
else:
    cfg.write_text(text.rstrip() + "\n" + block + "\n")
    print(f"Appended IdentyClaw peer enablement to {cfg}")
    print("Review/merge if you already had a plugins: or platforms: section.")
PY
}

print_next_steps() {
  echo ""
  echo "Installed into HERMES_HOME=${HERMES_HOME}"
  echo "  bin/idcp  → ${HERMES_HOME}/bin/idcp"
  echo "  skill     → ${HERMES_HOME}/skills/identity/identyclaw/"
  if [[ "$MODE" == peer ]]; then
    echo "  plugins   → ${HERMES_HOME}/plugins/a2a-platform"
    echo "             ${HERMES_HOME}/plugins/identyclaw-webhooks"
  fi
  echo ""
  echo "Put ${HERMES_HOME}/bin on PATH for the Hermes CLI and gateway process."
  echo ""
  echo "Next (Tier 1):"
  echo "  export PATH=\"${HERMES_HOME}/bin:\$PATH\""
  echo "  idcp enroll"
  echo "  # mint Passport at https://purchase.identyclaw.com (recipient = printed account_id)"
  echo "  idcp ensure_session"
  echo "  idcp me"
  if [[ "$MODE" == peer ]]; then
    echo ""
    echo "Next (Tier 2 peer):"
    echo "  export NEAR_CREDENTIALS_FILE_PATH=\$(ls ${HERMES_HOME}/secrets/near-credentials/*.json | head -1)"
    echo "  export A2A_PUBLIC_URL=https://your-public-host"
    echo "  node ${pkg_auth}/bin/sidecar.mjs --port \${IDENTYCLAW_AUTH_PORT:-9910}"
    echo "  # restart Hermes gateway so plugins load"
  fi
}

require_cmds
[[ -d "$HERMES_HOME" ]] || mkdir -p "$HERMES_HOME"

install_auth_and_skill
if [[ "$MODE" == peer ]]; then
  install_peer_plugins
  enable_peer_config
fi
print_next_steps
