#!/usr/bin/env bash
# Multi-profile helpers for hermes.sh (Hermes-native profiles, not OpenClaw agents/).
#
# Layout (Hermes upstream):
#   $(hermes_fleet_dir)/                 # default profile HERMES_HOME (Lemuel)
#   $(hermes_fleet_dir)/env.local        # fleet deploy knobs (ports, PROFILE_IDS)
#   $(hermes_fleet_dir)/profiles/<name>/ # named profiles (e.g. olivia)
#
# Each running gateway gets its own HERMES_HOME. Passport/NEAR identities differ
# per profile, so we use per-profile pods (or join an existing pod) with
# gateway.standalone: true rather than relying on multiplex alone.

# Fleet root = sibling -app directory (always).
hermes_fleet_dir() {
  if [[ -n "${HERMES_FLEET_DIR:-}" ]]; then
    printf '%s' "$HERMES_FLEET_DIR"
    return
  fi
  if [[ -n "${HERMES_APP_DIR:-}" && -z "${HERMES_AGENT_ID:-}${HERMES_PROFILE:-}" ]]; then
    # Legacy override: whole app is the single home.
    printf '%s' "$HERMES_APP_DIR"
    return
  fi
  printf '%s' "$(cd "${HERMES_ROOT}/../.." && pwd)/hermes-agents-app"
}

# True when profiles/ exists or PROFILE_IDS / AGENT_IDS is set.
hermes_is_multi_profile() {
  local fleet
  fleet="$(hermes_fleet_dir)"
  [[ -n "${PROFILE_IDS:-}${AGENT_IDS:-}" ]] && return 0
  [[ -d "${fleet}/profiles" ]] || return 1
  # Any identity-bearing profile dir?
  local d
  for d in "${fleet}/profiles"/*/; do
    [[ -d "$d" ]] || continue
    [[ -f "${d}config.yaml" || -f "${d}.env" || -f "${d}SOUL.md" || -f "${d}profile.yaml" ]] && return 0
  done
  return 1
}

# List configured profile ids (space-separated). "default" = fleet root.
configured_profile_ids() {
  local fleet ids="" id d
  fleet="$(hermes_fleet_dir)"
  load_fleet_env_only
  ids="${PROFILE_IDS:-${AGENT_IDS:-}}"
  # Unquote if someone wrote PROFILE_IDS="default olivia"
  ids="${ids%\"}"
  ids="${ids#\"}"
  ids="${ids%\'}"
  ids="${ids#\'}"
  if [[ -n "$ids" ]]; then
    # Map legacy agent-b → olivia, agent-l → default when present in AGENT_IDS.
    local out="" mapped
    for id in $ids; do
      mapped="$(hermes_normalize_profile_id "$id")"
      if [[ -z "$out" ]]; then out="$mapped"; else out="$out $mapped"; fi
    done
    echo "$out"
    return 0
  fi
  # Discover: default if it looks like a Hermes home, plus profiles/*.
  if [[ -f "${fleet}/config.yaml" || -f "${fleet}/.env" || -f "${fleet}/SOUL.md" ]]; then
    ids="default"
  fi
  for root in "${fleet}/homes" "${fleet}/profiles"; do
    [[ -d "$root" ]] || continue
    for d in "${root}"/*/; do
      [[ -d "$d" ]] || continue
      id="$(basename "$d")"
      [[ "$id" == *"*"* ]] && continue
      [[ -f "${d}config.yaml" || -f "${d}.env" || -f "${d}SOUL.md" || -f "${d}profile.yaml" ]] || continue
      case " $ids " in
        *" $id "*) ;;
        *)
          if [[ -z "$ids" ]]; then ids="$id"; else ids="$ids $id"; fi
          ;;
      esac
    done
  done
  echo "${ids:-default}"
}

# Accept agent-b / agent-c / agent-l aliases from the OpenClaw-era plan.
hermes_normalize_profile_id() {
  case "$1" in
    agent-l|lemuel|lhsrldbjsnlh) echo "default" ;;
    agent-b|olivia|olivia-tara|cdcjcfbksfbd) echo "olivia" ;;
    agent-c|cornelius) echo "cornelius" ;;
    *) echo "$1" ;;
  esac
}

# Env prefix for fleet knobs: default → HERMES_ / AGENT_L_; olivia → AGENT_B_; cornelius → AGENT_C_
profile_env_prefix() {
  local id
  id="$(hermes_normalize_profile_id "$1")"
  case "$id" in
    default) echo "AGENT_L" ;;
    olivia) echo "AGENT_B" ;;
    cornelius) echo "AGENT_C" ;;
    *)
      # PROFILE_OLIVIA → already; else uppercase with dashes to underscores
      printf 'PROFILE_%s' "$(echo "$id" | tr '[:lower:]-' '[:upper:]_')"
      ;;
  esac
}

profile_env_value() {
  local id="$1" field="$2" default="${3:-}"
  local prefix combined alt
  prefix="$(profile_env_prefix "$id")"
  combined="${prefix}_${field}"
  if [[ -n "${!combined:-}" ]]; then
    echo "${!combined}"
    return 0
  fi
  # Fallbacks for default profile: bare HERMES_* keys.
  if [[ "$(hermes_normalize_profile_id "$id")" == "default" ]]; then
    alt="HERMES_${field}"
    if [[ -n "${!alt:-}" ]]; then
      echo "${!alt}"
      return 0
    fi
  fi
  echo "$default"
}

# Absolute HERMES_HOME for a profile id.
# Named profiles live under homes/<id>/ (NOT profiles/<id>/): Hermes walks
# HERMES_HOME up out of a profiles/ directory to the fleet root (see
# get_default_hermes_root), which breaks Passport isolation and cron/kanban paths.
profile_home() {
  local id fleet
  id="$(hermes_normalize_profile_id "${1:?profile id}")"
  fleet="$(hermes_fleet_dir)"
  if [[ "$id" == "default" ]]; then
    printf '%s' "$fleet"
  elif [[ -d "${fleet}/homes/${id}" ]]; then
    printf '%s' "${fleet}/homes/${id}"
  elif [[ -d "${fleet}/profiles/${id}" ]]; then
    # Legacy path from early migration attempts — still resolve if present.
    printf '%s' "${fleet}/profiles/${id}"
  else
    printf '%s' "${fleet}/homes/${id}"
  fi
}

profile_container() {
  local id
  id="$(hermes_normalize_profile_id "$1")"
  if [[ "$id" == "default" ]]; then
    echo "${HERMES_DEFAULT_CONTAINER:-hermes}"
  else
    echo "hermes-${id}"
  fi
}

profile_pod() {
  local id
  id="$(hermes_normalize_profile_id "$1")"
  if [[ "$id" == "default" ]]; then
    echo "${HERMES_DEFAULT_POD:-hermes-agent-pod}"
  else
    # Olivia joins hermes-agent-pod so OpenClaw keeps :8443 and Hermes
    # Telegram stays on infra 80→10443 (SNI via shared hermes-nginx).
    local join
    join="$(profile_env_value "$id" JOIN_POD "")"
    if [[ -n "$join" ]]; then
      echo "$join"
      return 0
    fi
    if [[ "$id" == "olivia" ]]; then
      echo "${HERMES_OLIVIA_POD:-hermes-agent-pod}"
      return 0
    fi
    echo "hermes-${id}-pod"
  fi
}

# True when this profile shares fleet hermes-nginx (no per-profile nginx sidecar).
profile_shares_fleet_nginx() {
  local id pod fleet_pod
  id="$(hermes_normalize_profile_id "$1")"
  [[ "$id" == "default" ]] && return 1
  pod="$(profile_pod "$id")"
  fleet_pod="${HERMES_DEFAULT_POD:-hermes-agent-pod}"
  [[ "$pod" == "$fleet_pod" ]]
}

profile_nginx_container() {
  local id
  id="$(hermes_normalize_profile_id "$1")"
  if [[ "$id" == "default" ]]; then
    echo "${HERMES_DEFAULT_NGINX_CONTAINER:-hermes-nginx}"
  elif profile_shares_fleet_nginx "$id"; then
    # Shared ingress: fleet nginx owns the TLS listener; no hermes-olivia-nginx.
    echo "${HERMES_DEFAULT_NGINX_CONTAINER:-hermes-nginx}"
  else
    echo "hermes-${id}-nginx"
  fi
}

profile_auth_container() {
  local id
  id="$(hermes_normalize_profile_id "$1")"
  if [[ "$id" == "default" ]]; then
    echo "${HERMES_DEFAULT_AUTH_CONTAINER:-hermes-identyclaw-auth}"
  else
    echo "hermes-${id}-auth"
  fi
}

# Load only fleet env.local (no agent home). Safe to call before select_profile.
# While the default gateway owns the fleet tree (0700), fall back to podman exec.
load_fleet_env_only() {
  local f tmp
  f="$(hermes_fleet_dir)/env.local"
  if [[ -r "$f" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$f"
    set +a
    return 0
  fi
  if container_is_running "${HERMES_DEFAULT_CONTAINER:-hermes}" 2>/dev/null; then
    tmp="$(mktemp)"
    if podman exec "${HERMES_DEFAULT_CONTAINER:-hermes}" \
      sh -c 'test -r /opt/data/env.local && cat /opt/data/env.local' \
      >"$tmp" 2>/dev/null; then
      set -a
      # shellcheck disable=SC1090
      source "$tmp"
      set +a
    fi
    rm -f "$tmp"
  fi
}

# Bind hermes_app_dir / container names / ports to a profile for subsequent cmds.
select_profile() {
  local id home prefix
  id="$(hermes_normalize_profile_id "${1:?profile id required}")"
  home="$(profile_home "$id")"
  export HERMES_PROFILE="$id"
  export HERMES_AGENT_ID="$id"
  export HERMES_APP_DIR="$home"
  export HERMES_HOME="$home"
  export IDENTYCLAW_HOME="$home"
  export HERMES_CONTAINER
  export HERMES_POD
  export HERMES_NGINX_CONTAINER
  export HERMES_IDENTYCLAW_AUTH_CONTAINER
  HERMES_CONTAINER="$(profile_container "$id")"
  HERMES_POD="$(profile_pod "$id")"
  HERMES_NGINX_CONTAINER="$(profile_nginx_container "$id")"
  HERMES_IDENTYCLAW_AUTH_CONTAINER="$(profile_auth_container "$id")"

  # Apply per-profile port/host overrides from fleet env.
  load_fleet_env_only
  local v
  v="$(profile_env_value "$id" PUBLIC_HOST "${HERMES_PUBLIC_HOST:-}")"
  [[ -n "$v" ]] && export HERMES_PUBLIC_HOST="$v"
  v="$(profile_env_value "$id" INGRESS_PORT "${HERMES_INGRESS_PORT:-}")"
  [[ -n "$v" ]] && export HERMES_INGRESS_PORT="$v"
  v="$(profile_env_value "$id" API_PORT "${HERMES_API_PORT:-}")"
  [[ -n "$v" ]] && export HERMES_API_PORT="$v"
  v="$(profile_env_value "$id" EXTRA_INGRESS_PORTS "${HERMES_EXTRA_INGRESS_PORTS:-}")"
  [[ -n "$v" ]] && export HERMES_EXTRA_INGRESS_PORTS="$v"
  v="$(profile_env_value "$id" TELEGRAM_PORT "${HERMES_TELEGRAM_PORT:-}")"
  [[ -n "$v" ]] && export HERMES_TELEGRAM_PORT="$v"
  v="$(profile_env_value "$id" EMAIL "${HERMES_EMAIL:-}")"
  [[ -n "$v" ]] && export HERMES_EMAIL="$v"
  v="$(profile_env_value "$id" DISPLAY_NAME "${HERMES_EMAIL_DISPLAY_NAME:-}")"
  [[ -n "$v" ]] && export HERMES_EMAIL_DISPLAY_NAME="$v"
  v="$(profile_env_value "$id" SMTP_PORT "${HERMES_SMTP_PORT:-}")"
  [[ -n "$v" ]] && export HERMES_SMTP_PORT="$v"
  v="$(profile_env_value "$id" SMTP_ENCRYPTION "${HERMES_SMTP_ENCRYPTION:-}")"
  [[ -n "$v" ]] && export HERMES_SMTP_ENCRYPTION="$v"
  v="$(profile_env_value "$id" A2A_PORT "${A2A_PORT:-}")"
  [[ -n "$v" ]] && export A2A_PORT="$v"
  v="$(profile_env_value "$id" AUTH_PORT "${IDENTYCLAW_AUTH_PORT:-}")"
  [[ -n "$v" ]] && export IDENTYCLAW_AUTH_PORT="$v"
  v="$(profile_env_value "$id" HOOKS_PORT "${IDENTYCLAW_HOOKS_PORT:-}")"
  [[ -n "$v" ]] && export IDENTYCLAW_HOOKS_PORT="$v"
  v="$(profile_env_value "$id" WEBHOOK_PORT "${WEBHOOK_PORT:-}")"
  [[ -n "$v" ]] && export WEBHOOK_PORT="$v"
  v="$(profile_env_value "$id" TELEGRAM_WEBHOOK_PORT "${TELEGRAM_WEBHOOK_PORT:-}")"
  [[ -n "$v" ]] && export TELEGRAM_WEBHOOK_PORT="$v"
  v="$(profile_env_value "$id" API_SERVER_PORT "${API_SERVER_PORT:-}")"
  [[ -n "$v" ]] && export API_SERVER_PORT="$v"
  v="$(profile_env_value "$id" DEPLOY_MODE "${HERMES_DEPLOY_MODE:-}")"
  [[ -n "$v" ]] && export HERMES_DEPLOY_MODE="$v"

  # Source profile-local env.local if present (non-secrets).
  if [[ -r "${home}/env.local" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${home}/env.local"
    set +a
  fi

  # Joe/Daniel stay on OpenClaw :8443 — never proxy them through Hermes nginx.
  unset OPENCLAW_PROXY_UPSTREAMS || true
}

# Resolve CLI target: all | default | olivia | agent-b | …
resolve_profile_targets() {
  local arg="${1:-}"
  if [[ -z "$arg" || "$arg" == "all" ]]; then
    configured_profile_ids
    return 0
  fi
  hermes_normalize_profile_id "$arg"
}

# Ensure profile home skeleton exists (does not overwrite).
ensure_profile_home() {
  local id home fleet
  id="$(hermes_normalize_profile_id "$1")"
  home="$(profile_home "$id")"
  fleet="$(hermes_fleet_dir)"
  if [[ "$id" != "default" ]]; then
    mkdir -p "${fleet}/homes" 2>/dev/null || true
  fi
  mkdir -p "$home" \
    "$home/secrets/near-credentials" \
    "$home/secrets/identyclaw" \
    "$home/secrets/himalaya" \
    "$home/memories" \
    "$home/skills" \
    "$home/bin" \
    "$home/certs" \
    "$home/nginx" \
    "$home/logs/nginx" 2>/dev/null || true
  chmod 700 "$home" "$home/secrets" 2>/dev/null || true
  if [[ "$id" != "default" ]]; then
    # Prefer a clean home (not under profiles/) so Hermes does not walk up.
    if [[ ! -f "${home}/config.yaml" ]]; then
      if [[ -w "$home" ]] || [[ -w "$(dirname "$home")" ]]; then
        printf '%s\n' "gateway:" "  standalone: true" >"${home}/config.yaml" 2>/dev/null || true
        chmod 600 "${home}/config.yaml" 2>/dev/null || true
      fi
    fi
  fi
}

# Shell-quote a value for env files when it contains whitespace/specials.
envfile_quote_value() {
  local value="$1"
  if [[ "$value" =~ [[:space:]\$\`\"] || "$value" == *\'* ]]; then
    # Prefer double quotes with escaped internals
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\\\$}"
    value="${value//\`/\\\`}"
    printf '"%s"' "$value"
  else
    printf '%s' "$value"
  fi
}

# Create-only upsert into a KEY=VALUE file (never overwrite non-empty values).
envfile_set_if_empty() {
  local file="$1" key="$2" value="$3" qcur qval
  touch "$file"
  chmod 600 "$file" 2>/dev/null || true
  qcur="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -1 | sed "s/^${key}=//" || true)"
  # Treat empty or empty-quoted as unset
  if [[ -n "$qcur" && "$qcur" != '""' && "$qcur" != "''" ]]; then
    return 0
  fi
  qval="$(envfile_quote_value "$value")"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$file" "$key" "$qval" <<'PY'
import pathlib, sys
path, key, value = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
lines = path.read_text().splitlines(True) if path.exists() else []
out, found = [], False
for line in lines:
    if line.startswith(key + "=") and not found:
        out.append(f"{key}={value}\n")
        found = True
    else:
        out.append(line)
if not found:
    out.append(f"{key}={value}\n")
path.write_text("".join(out))
PY
  else
    if grep -qE "^${key}=" "$file" 2>/dev/null; then
      sed -i "s|^${key}=.*|${key}=${qval}|" "$file"
    else
      printf '%s=%s\n' "$key" "$qval" >>"$file"
    fi
  fi
}

# Copy file only when destination missing or empty.
copy_secret_file_if_absent() {
  local src="$1" dst="$2"
  [[ -f "$src" ]] || return 1
  if [[ -s "$dst" ]]; then
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  cp -a "$src" "$dst"
  chmod 600 "$dst" 2>/dev/null || true
  return 0
}
