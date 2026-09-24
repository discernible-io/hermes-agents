#!/usr/bin/env bash
# Install IdentyClaw into an existing Hermes home (vanilla Hermes, not this Podman wrapper).
#
# Plugin sources live in sibling checkouts (default) or GitHub clones:
#   ../hermes-identyclaw-auth
#   ../hermes-identyclaw-a2a
#   ../hermes-identyclaw-webhook  (local sibling may also be …-webhooks)
#
# Usage:
#   ./install.sh                 # Tier 1: idcp + skill (call federated peers)
#   ./install.sh --peer          # Tier 1 + A2A overlay + signed /hooks/* plugins
#   ./install.sh --client        # same as default Tier 1
#   HERMES_HOME=/path ./install.sh --peer
#   ./install.sh --fetch --peer  # clone missing siblings from GitHub first
#
# Requires: node + npm (Node ≥ 22.19). Does not start Hermes or the auth sidecar.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT="$(cd "${ROOT}/.." && pwd)"
HERMES_HOME="${HERMES_HOME:-${IDENTYCLAW_HOME:-$HOME/.hermes}}"
MODE=client
ENABLE_CONFIG=1
FETCH=0

# Override any path with IDENTYCLAW_AUTH_DIR / IDENTYCLAW_A2A_DIR / IDENTYCLAW_WEBHOOKS_DIR.
AUTH_REPO_URL="${IDENTYCLAW_AUTH_REPO:-https://github.com/discernible-io/hermes-identyclaw-auth.git}"
A2A_REPO_URL="${IDENTYCLAW_A2A_REPO:-https://github.com/discernible-io/hermes-identyclaw-a2a.git}"
WEBHOOKS_REPO_URL="${IDENTYCLAW_WEBHOOKS_REPO:-https://github.com/discernible-io/hermes-identyclaw-webhook.git}"

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \?//'
  cat <<EOF

Options:
  --client          Install idcp CLI + skill only (default)
  --peer            Also install a2a-platform + identyclaw-webhooks plugins
  --fetch           Clone missing sibling plugin repos from GitHub into ${PARENT}/
  --no-enable       Install plugins/files but do not edit config.yaml
  -h, --help        Show this help

Environment:
  HERMES_HOME              Target Hermes profile (default: ~/.hermes)
  IDENTYCLAW_HOME          Optional override preferred by idcp for secrets layout
  IDENTYCLAW_AUTH_DIR      Path to hermes-identyclaw-auth checkout
  IDENTYCLAW_A2A_DIR       Path to hermes-identyclaw-a2a checkout
  IDENTYCLAW_WEBHOOKS_DIR  Path to hermes-identyclaw-webhook checkout
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --client) MODE=client; shift ;;
    --peer) MODE=peer; shift ;;
    --fetch) FETCH=1; shift ;;
    --no-enable) ENABLE_CONFIG=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }

require_cmds() {
  command -v node >/dev/null 2>&1 || die "node is required (Node ≥ 22.19)"
  command -v npm >/dev/null 2>&1 || die "npm is required"
}

resolve_plugin_dir() {
  # Usage: resolve_plugin_dir <override> <git-url> <sibling-name> [alt-sibling-name...]
  local override="$1" url="$2"
  shift 2
  local names=("$@") name sibling tried=()
  if [[ -n "$override" ]]; then
    printf '%s' "$override"
    return 0
  fi
  for name in "${names[@]}"; do
    sibling="${PARENT}/${name}"
    tried+=("$sibling")
    if [[ -d "$sibling" ]]; then
      printf '%s' "$sibling"
      return 0
    fi
  done
  sibling="${PARENT}/$(basename "${url%.git}")"
  if [[ "$FETCH" == 1 ]]; then
    command -v git >/dev/null 2>&1 || die "git is required for --fetch"
    echo "Cloning ${url} → ${sibling} ..." >&2
    git clone --depth 1 "$url" "$sibling"
    printf '%s' "$sibling"
    return 0
  fi
  die "missing plugin checkout — tried: ${tried[*]} (set IDENTYCLAW_*_DIR or pass --fetch)"
}

pkg_auth="$(resolve_plugin_dir "${IDENTYCLAW_AUTH_DIR:-}" "$AUTH_REPO_URL" hermes-identyclaw-auth)"
skill_src=""
if [[ -d "${pkg_auth}/skills/identyclaw" ]]; then
  skill_src="${pkg_auth}/skills/identyclaw"
elif [[ -d "${pkg_auth}/skills/identity/identyclaw" ]]; then
  skill_src="${pkg_auth}/skills/identity/identyclaw"
else
  die "missing skill under ${pkg_auth}/skills/identyclaw"
fi

pkg_a2a=""
pkg_hooks=""
if [[ "$MODE" == peer ]]; then
  pkg_a2a="$(resolve_plugin_dir "${IDENTYCLAW_A2A_DIR:-}" "$A2A_REPO_URL" hermes-identyclaw-a2a)"
  # GitHub repo is singular (-webhook); local sibling may still be -webhooks.
  pkg_hooks="$(resolve_plugin_dir "${IDENTYCLAW_WEBHOOKS_DIR:-}" "$WEBHOOKS_REPO_URL" \
    hermes-identyclaw-webhook hermes-identyclaw-webhooks)"
fi

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
}

install_peer_plugins() {
  [[ -d "$pkg_a2a" && -d "$pkg_hooks" ]] || die "missing peer plugin checkouts"
  local plugins_dir="${HERMES_HOME}/plugins"
  mkdir -p "$plugins_dir"
  rm -rf "${plugins_dir}/a2a-platform" "${plugins_dir}/identyclaw-webhooks"
  # Copy plugin files only (skip local __pycache__).
  mkdir -p "${plugins_dir}/a2a-platform" "${plugins_dir}/identyclaw-webhooks"
  cp -a "$pkg_a2a"/. "${plugins_dir}/a2a-platform/"
  cp -a "$pkg_hooks"/. "${plugins_dir}/identyclaw-webhooks/"
  rm -rf "${plugins_dir}/a2a-platform/__pycache__" \
    "${plugins_dir}/identyclaw-webhooks/__pycache__" \
    "${plugins_dir}/a2a-platform/.git" \
    "${plugins_dir}/identyclaw-webhooks/.git"
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
  # Prefer the Podman wrapper merge helper when this umbrella checkout has it.
  local merge_py="${ROOT}/deploy/scripts/merge-identyclaw-peer-config.py"
  if [[ -f "$merge_py" ]]; then
    python3 "$merge_py" "$HERMES_HOME"
    return 0
  fi
  python3 - "$HERMES_HOME" <<'PY'
import pathlib, sys
home = pathlib.Path(sys.argv[1])
cfg = home / "config.yaml"
text = cfg.read_text() if cfg.is_file() else ""
marker = "# identyclaw-peer (managed by install.sh)"
if marker in text or "identyclaw-webhooks" in text:
    print(f"{cfg} already has IdentyClaw peer settings (left unchanged)")
    raise SystemExit(0)
# Only append when there is no existing plugins: key (avoid YAML last-wins wipe).
if "\nplugins:" in text or text.startswith("plugins:"):
    print(f"{cfg} already has plugins: — enable a2a-platform + identyclaw-webhooks manually", file=sys.stderr)
    raise SystemExit(0)
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
cfg.write_text(text.rstrip() + "\n" + block + "\n")
print(f"Appended IdentyClaw peer enablement to {cfg}")
PY
}

print_next_steps() {
  echo ""
  echo "Installed into HERMES_HOME=${HERMES_HOME}"
  echo "  auth src  → ${pkg_auth}"
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
