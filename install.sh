#!/usr/bin/env bash
# Install IdentyClaw into an existing Hermes home (vanilla Hermes, not this Podman wrapper).
#
# Preferred path (stock Hermes Plugins CLI — same as the auth plugin playbook):
#   hermes plugins install discernible-io/hermes-identyclaw-auth --enable
#   hermes identyclaw install-deps
#   # …then for Tier 2:
#   bash "$HERMES_HOME/plugins/identyclaw-auth/scripts/install-stock-hermes.sh"
#
# This script wraps that when `hermes` is on PATH. With --local / without hermes,
# it copies sibling checkouts (or --fetch clones) into $HERMES_HOME/plugins/.
#
# Plugin sources:
#   https://github.com/discernible-io/hermes-identyclaw-auth
#   https://github.com/discernible-io/hermes-identyclaw-a2a
#   https://github.com/discernible-io/hermes-identyclaw-webhook
#
# Usage:
#   ./install.sh                 # Tier 1 via hermes plugins install (or local fallback)
#   ./install.sh --peer          # Tier 1 + A2A + signed /hooks/*
#   ./install.sh --local --peer  # force sibling-copy install (no hermes plugins CLI)
#   ./install.sh --fetch --peer  # clone missing siblings, then local install
#   HERMES_HOME=/path ./install.sh --peer
#
# Requires: node + npm (Node ≥ 22.19). Does not start Hermes by itself.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT="$(cd "${ROOT}/.." && pwd)"
HERMES_HOME="${HERMES_HOME:-${IDENTYCLAW_HOME:-$HOME/.hermes}}"
MODE=client
ENABLE_CONFIG=1
FETCH=0
FORCE_LOCAL=0

AUTH_REPO_URL="${IDENTYCLAW_AUTH_REPO:-https://github.com/discernible-io/hermes-identyclaw-auth.git}"
A2A_REPO_URL="${IDENTYCLAW_A2A_REPO:-https://github.com/discernible-io/hermes-identyclaw-a2a.git}"
WEBHOOKS_REPO_URL="${IDENTYCLAW_WEBHOOKS_REPO:-https://github.com/discernible-io/hermes-identyclaw-webhook.git}"

usage() {
  sed -n '2,26p' "$0" | sed 's/^# \?//'
  cat <<EOF

Options:
  --client          Install auth plugin only (default)
  --peer            Also install identyclaw-a2a + identyclaw-webhooks
  --fetch           Clone missing sibling plugin repos from GitHub into ${PARENT}/
  --local           Copy siblings into \$HERMES_HOME/plugins (skip hermes plugins install)
  --no-enable       Install files but do not edit config.yaml (local mode only)
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
    --local) FORCE_LOCAL=1; shift ;;
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

use_hermes_plugins_cli() {
  [[ "$FORCE_LOCAL" == 0 ]] && command -v hermes >/dev/null 2>&1
}

install_via_hermes_cli() {
  export HERMES_HOME
  export PATH="${HERMES_HOME}/bin:${HOME}/.local/bin:${PATH}"

  echo "Installing via hermes plugins install (GitHub owner/repo) ..."
  if [[ -d "${HERMES_HOME}/plugins/identyclaw-auth" ]]; then
    hermes plugins install discernible-io/hermes-identyclaw-auth --enable --force 2>/dev/null \
      || hermes plugins enable identyclaw-auth 2>/dev/null || true
  else
    hermes plugins install discernible-io/hermes-identyclaw-auth --enable
  fi

  hermes identyclaw install-deps 2>/dev/null \
    || echo "Note: run 'hermes identyclaw install-deps' after Node deps if needed"

  if [[ "$MODE" != peer ]]; then
    echo ""
    echo "Tier 1 complete. Next:"
    echo "  # Mint Passport at https://purchase.identyclaw.com (recipient = printed account_id)"
    echo "  hermes identyclaw me"
    echo "  hermes identyclaw ensure_session"
    return 0
  fi

  local playbook="${HERMES_HOME}/plugins/identyclaw-auth/scripts/install-stock-hermes.sh"
  if [[ -x "$playbook" ]]; then
    echo "Delegating Tier 2 to ${playbook} ..."
    bash "$playbook" --skip-enroll
    return 0
  fi

  # Fallback if playbook missing from an older auth install
  hermes identyclaw sidecar start 2>/dev/null || true
  if [[ -d "${HERMES_HOME}/plugins/identyclaw-a2a" ]]; then
    hermes plugins install discernible-io/hermes-identyclaw-a2a --no-enable --force
  else
    hermes plugins install discernible-io/hermes-identyclaw-a2a --no-enable
  fi
  hermes plugins disable platforms/a2a 2>/dev/null || true
  hermes plugins enable identyclaw-a2a --allow-tool-override

  if [[ -d "${HERMES_HOME}/plugins/identyclaw-webhooks" ]]; then
    hermes plugins install discernible-io/hermes-identyclaw-webhook --enable --force
  else
    hermes plugins install discernible-io/hermes-identyclaw-webhook --enable
  fi
  hermes plugins enable identyclaw-webhooks 2>/dev/null || true
}

copy_plugin_tree() {
  local src="$1" dest="$2"
  mkdir -p "$dest"
  # Copy contents; drop VCS / bytecode noise
  cp -a "${src}/." "$dest/"
  rm -rf "${dest}/.git" "${dest}/__pycache__" "${dest}/.pytest_cache"
}

install_local_auth() {
  local pkg_auth skill_src
  pkg_auth="$(resolve_plugin_dir "${IDENTYCLAW_AUTH_DIR:-}" "$AUTH_REPO_URL" hermes-identyclaw-auth)"
  if [[ -d "${pkg_auth}/skills/identyclaw" ]]; then
    skill_src="${pkg_auth}/skills/identyclaw"
  elif [[ -d "${pkg_auth}/skills/identity/identyclaw" ]]; then
    skill_src="${pkg_auth}/skills/identity/identyclaw"
  else
    die "missing skill under ${pkg_auth}/skills/identyclaw"
  fi

  mkdir -p "${HERMES_HOME}/bin" \
    "${HERMES_HOME}/plugins" \
    "${HERMES_HOME}/skills/identity/identyclaw" \
    "${HERMES_HOME}/secrets/near-credentials" \
    "${HERMES_HOME}/secrets/identyclaw"

  echo "Installing auth package deps in ${pkg_auth} ..."
  (cd "$pkg_auth" && npm ci 2>/dev/null || npm install --omit=dev)

  copy_plugin_tree "$pkg_auth" "${HERMES_HOME}/plugins/identyclaw-auth"
  ln -sfn "${HERMES_HOME}/plugins/identyclaw-auth/bin/idcp.mjs" "${HERMES_HOME}/bin/idcp"
  chmod +x "${HERMES_HOME}/plugins/identyclaw-auth/bin/"*.mjs 2>/dev/null || true
  cp -a "${skill_src}/." "${HERMES_HOME}/skills/identity/identyclaw/"

  echo "Installed auth → ${HERMES_HOME}/plugins/identyclaw-auth"
}

install_local_peer() {
  local pkg_a2a pkg_hooks
  pkg_a2a="$(resolve_plugin_dir "${IDENTYCLAW_A2A_DIR:-}" "$A2A_REPO_URL" hermes-identyclaw-a2a)"
  # GitHub repo is singular (-webhook); local sibling may still be -webhooks.
  pkg_hooks="$(resolve_plugin_dir "${IDENTYCLAW_WEBHOOKS_DIR:-}" "$WEBHOOKS_REPO_URL" \
    hermes-identyclaw-webhook hermes-identyclaw-webhooks)"

  local plugins_dir="${HERMES_HOME}/plugins"
  mkdir -p "$plugins_dir"
  # Drop legacy overlay dir name if present
  rm -rf "${plugins_dir}/a2a-platform" \
    "${plugins_dir}/identyclaw-a2a" \
    "${plugins_dir}/identyclaw-webhooks"
  copy_plugin_tree "$pkg_a2a" "${plugins_dir}/identyclaw-a2a"
  copy_plugin_tree "$pkg_hooks" "${plugins_dir}/identyclaw-webhooks"
  echo "Installed plugins → ${plugins_dir}/identyclaw-a2a , identyclaw-webhooks"
}

enable_local_peer_config() {
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
    - identyclaw-auth
    - identyclaw-a2a
    - identyclaw-webhooks
  disabled:
    - platforms/a2a
  entries:
    identyclaw-auth:
      enabled: true
    identyclaw-a2a:
      enabled: true
      allow_tool_override: true
      granted_capabilities:
        - tools.override
    identyclaw-webhooks:
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

print_local_next_steps() {
  echo ""
  echo "Installed into HERMES_HOME=${HERMES_HOME} (local/sibling copy mode)"
  echo "  plugins → ${HERMES_HOME}/plugins/identyclaw-auth"
  if [[ "$MODE" == peer ]]; then
    echo "           ${HERMES_HOME}/plugins/identyclaw-a2a"
    echo "           ${HERMES_HOME}/plugins/identyclaw-webhooks"
  fi
  echo "  bin/idcp → ${HERMES_HOME}/bin/idcp"
  echo ""
  echo "Prefer stock installs when possible:"
  echo "  hermes plugins install discernible-io/hermes-identyclaw-auth --enable"
  echo ""
  echo "Next (Tier 1):"
  echo "  export PATH=\"${HERMES_HOME}/bin:\$PATH\""
  echo "  hermes identyclaw install-deps   # or: idcp enroll"
  echo "  # mint Passport at https://purchase.identyclaw.com (recipient = printed account_id)"
  echo "  hermes identyclaw me"
  if [[ "$MODE" == peer ]]; then
    echo ""
    echo "Next (Tier 2 peer):"
    echo "  hermes identyclaw sidecar start"
    echo "  curl -fsS http://127.0.0.1:9910/health"
    echo "  # restart Hermes gateway so plugins load"
  fi
}

require_cmds
[[ -d "$HERMES_HOME" ]] || mkdir -p "$HERMES_HOME"

if use_hermes_plugins_cli; then
  install_via_hermes_cli
else
  [[ "$FORCE_LOCAL" == 1 ]] || echo "hermes CLI not on PATH — using sibling/local install (pass --local to silence)"
  install_local_auth
  if [[ "$MODE" == peer ]]; then
    install_local_peer
    enable_local_peer_config
  fi
  print_local_next_steps
fi
