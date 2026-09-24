#!/usr/bin/env bash
# Hermes Agent — Podman operator CLI (sibling app-dir layout).
#
# Repo (synced):   ~/hermes-agents  — wrapper lives in deploy/
# Runtime (local): ~/hermes-agents-app  → mounted at /opt/data
#
# Usage:
#   ./hermes.sh init
#   ./hermes.sh nuke [--yes]   # delete -app and re-seed (overwrites; confirmation required)
#   ./hermes.sh setup          # populate -app (wizard, mail, Passport); NEAR enroll; self-signed TLS last
#   ./hermes.sh start
#   ./hermes.sh stop
#   ./hermes.sh status
#   ./hermes.sh logs
#   ./hermes.sh pull
#   ./hermes.sh chat
#   ./hermes.sh exec -- hermes config set model.provider openrouter
#   ./hermes.sh own host       # reclaim app dir after stop
#   ./hermes.sh idcp-setup     # Resume Passport: auto enroll → purchase → session
#   ./hermes.sh idcp-install   # IdentyClaw helper + skill into app dir
#   ./hermes.sh idcp <cmd…>    # ensure_session | create_hola | …
#   ./hermes.sh identyclaw-peer-install  # opt-in A2A overlay + /hooks/* + auth sidecar
#   ./hermes.sh identyclaw-auth-start    # start localhost auth sidecar on host
#   ./hermes.sh identyclaw-auth-stop
#   ./hermes.sh himalaya-install
#   ./hermes.sh himalaya-password
#   ./hermes.sh himalaya-test
#   ./hermes.sh generate-certs [--force]
#   ./hermes.sh build-nginx

set -euo pipefail
[[ "${TRACE:-0}" == 1 ]] && set -x

HERMES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_REPO="$(cd "${HERMES_ROOT}/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$HERMES_ROOT/scripts/lib.sh"

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \?//'
}

identyclaw_peer_enabled() {
  # App dir is often 0700/UID 10000 after prepare_app_for_container — host test -f fails.
  local flag
  flag="$(hermes_app_dir)/.identyclaw-peer-enabled"
  [[ -n "${IDENTYCLAW_PEER_ACTIVE:-}" ]] && return 0
  [[ -f "$flag" ]] && return 0
  command -v podman >/dev/null 2>&1 && podman unshare test -f "$flag" 2>/dev/null
}

# Snapshot while the app tree is still host-readable (before prepare_app_for_container).
identyclaw_peer_snapshot() {
  if [[ -f "$(hermes_app_dir)/.identyclaw-peer-enabled" ]]; then
    export IDENTYCLAW_PEER_ACTIVE=1
  else
    unset IDENTYCLAW_PEER_ACTIVE || true
  fi
}

identyclaw_plugin_parent() {
  # Sibling checkouts live next to hermes-agents by default.
  printf '%s' "$(cd "${HERMES_REPO}/.." && pwd)"
}

identyclaw_auth_pkg() {
  if [[ -n "${IDENTYCLAW_AUTH_DIR:-}" ]]; then
    printf '%s' "$IDENTYCLAW_AUTH_DIR"
    return 0
  fi
  printf '%s' "$(identyclaw_plugin_parent)/hermes-identyclaw-auth"
}

identyclaw_a2a_pkg() {
  if [[ -n "${IDENTYCLAW_A2A_DIR:-}" ]]; then
    printf '%s' "$IDENTYCLAW_A2A_DIR"
    return 0
  fi
  printf '%s' "$(identyclaw_plugin_parent)/hermes-identyclaw-a2a"
}

identyclaw_webhooks_pkg() {
  if [[ -n "${IDENTYCLAW_WEBHOOKS_DIR:-}" ]]; then
    printf '%s' "$IDENTYCLAW_WEBHOOKS_DIR"
    return 0
  fi
  local parent
  parent="$(identyclaw_plugin_parent)"
  # GitHub repo is singular; local sibling may still be plural.
  if [[ -d "${parent}/hermes-identyclaw-webhook" ]]; then
    printf '%s' "${parent}/hermes-identyclaw-webhook"
  else
    printf '%s' "${parent}/hermes-identyclaw-webhooks"
  fi
}

identyclaw_auth_container() {
  printf '%s' "${HERMES_IDENTYCLAW_AUTH_CONTAINER:-hermes-identyclaw-auth}"
}

# Auth sidecar shares the gateway network namespace (localhost-only bind). Sidecar
# intentionally refuses non-loopback hosts — do not use host.containers.internal.
start_identyclaw_auth_container() {
  identyclaw_peer_enabled || return 0
  local app z name port cred args=()
  app="$(hermes_app_dir)"
  z="$(selinux_mount_suffix)"
  name="$(identyclaw_auth_container)"
  port="${IDENTYCLAW_AUTH_PORT:-9910}"
  cred="${NEAR_CREDENTIALS_FILE_PATH:-}"

  podman rm -f "$name" 2>/dev/null || true

  args=(
    run -d --replace
    --name "$name"
    --restart always
  )
  if hermes_is_pod_mode && podman pod exists "${HERMES_POD:-hermes-agent-pod}" 2>/dev/null; then
    args+=(--pod "${HERMES_POD}")
  else
    args+=(--network "container:${HERMES_CONTAINER}")
  fi
  args+=(
    -v "${app}:/opt/data:rw${z}"
    -v "${app}:${app}:rw${z}"
    -v "${HERMES_ROOT}/idcp:/opt/idcp:ro${z}"
    -e "IDENTYCLAW_HOME=${app}"
    -e "HERMES_HOME=${app}"
    -e "IDENTYCLAW_AUTH_PORT=${port}"
    -e "IDENTYCLAW_NEAR_CONTRACT_ID=${IDENTYCLAW_NEAR_CONTRACT_ID:-genaaaa-identyclaw-com.near}"
    -e "NEAR_CONTRACT_ID=${IDENTYCLAW_NEAR_CONTRACT_ID:-genaaaa-identyclaw-com.near}"
  )
  if [[ -n "$cred" ]]; then
    args+=(-e "NEAR_CREDENTIALS_FILE_PATH=${cred}" -e "CREDENTIALS_FILE_PATH=${cred}" -e "RODIT_NEAR_CREDENTIALS_SOURCE=file")
  fi
  if [[ -n "${IDENTYCLAW_JWT_AUDIENCE:-}" ]]; then
    args+=(-e "IDENTYCLAW_JWT_AUDIENCE=${IDENTYCLAW_JWT_AUDIENCE}")
  fi
  # Reuse the Hermes image (ships Node); override entrypoint to the auth sidecar.
  args+=(--entrypoint node "$HERMES_IMAGE" /opt/idcp/bin/sidecar.mjs --port "$port")
  podman "${args[@]}"
  echo "Auth sidecar ${name} on gateway network 127.0.0.1:${port}"
}

# Shared hermes gateway run args (caller adds --pod or host -p ports).
# Secrets come from --env-file $(hermes_app_dir)/.env — never -e KEY=secret.
# Prefer HERMES_GATEWAY_ENV_FILE_HOST (host-readable staging copy) when set:
# prepare_app_for_container chowns the app tree to UID 10000 before podman run,
# which makes the live .env unreadable to the deploy user for --env-file.
hermes_gateway_run_args() {
  local app z podman_sock envf
  app="$(hermes_app_dir)"
  z="$(selinux_mount_suffix)"
  local -n _out="$1"

  _out=(
    run -d --replace
    --name "$HERMES_CONTAINER"
    --restart always
    -v "${app}:/opt/data:rw${z}"
    -v "${app}:${app}:rw${z}"
    -v "${HERMES_ROOT}/idcp:/opt/idcp:ro${z}"
    -v "${HERMES_ROOT}/idcp:${HERMES_ROOT}/idcp:ro${z}"
    -e "HERMES_HOME=${app}"
    -e "IDENTYCLAW_HOME=${app}"
    -e "HOME=${app}"
    -e "PATH=${app}/bin:/opt/data/bin:/opt/hermes/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  )

  # Passport peer stack: auth sidecar shares the gateway netns (127.0.0.1).
  if identyclaw_peer_enabled; then
    _out+=(-e "IDENTYCLAW_AUTH_HOST=${IDENTYCLAW_AUTH_HOST:-127.0.0.1}")
    _out+=(-e "IDENTYCLAW_AUTH_PORT=${IDENTYCLAW_AUTH_PORT:-9910}")
    _out+=(-e "IDENTYCLAW_HOOKS_PORT=${IDENTYCLAW_HOOKS_PORT:-9911}")
    _out+=(-e "IDENTYCLAW_HOOKS_HOST=${IDENTYCLAW_HOOKS_HOST:-127.0.0.1}")
    if [[ -n "${NEAR_CREDENTIALS_FILE_PATH:-}" ]]; then
      _out+=(-e "NEAR_CREDENTIALS_FILE_PATH=${NEAR_CREDENTIALS_FILE_PATH}")
      _out+=(-e "RODIT_NEAR_CREDENTIALS_SOURCE=file")
    fi
    if [[ -n "${IDENTYCLAW_JWT_AUDIENCE:-}" ]]; then
      _out+=(-e "IDENTYCLAW_JWT_AUDIENCE=${IDENTYCLAW_JWT_AUDIENCE}")
    fi
    if [[ -n "${A2A_PUBLIC_URL:-}" ]]; then
      _out+=(-e "A2A_PUBLIC_URL=${A2A_PUBLIC_URL}")
    fi
  fi

  envf="${HERMES_GATEWAY_ENV_FILE_HOST:-}"
  if [[ -z "$envf" || ! -f "$envf" ]]; then
    envf="$(hermes_gateway_env_file)"
  fi
  if [[ -f "$envf" ]]; then
    _out+=(--env-file "$envf")
  else
    echo "Warning: missing ${envf} — gateway starts without --env-file secrets" >&2
  fi

  podman_sock="${PODMAN_SOCK:-/run/user/$(id -u)/podman/podman.sock}"
  if [[ -S "$podman_sock" ]]; then
    _out+=(-v "${podman_sock}:/var/run/docker.sock")
    _out+=(-e HERMES_DOCKER_BINARY=docker)
    # Hermes process runs as uid 10000; sock is root-owned in the userns.
    _out+=(--group-add root)
  else
    echo "Warning: ${podman_sock} missing — Docker terminal backend will fail." >&2
    echo "  Enable with: systemctl --user enable --now podman.socket" >&2
  fi

  if [[ -n "${HERMES_DASHBOARD:-}" ]]; then
    _out+=(-e "HERMES_DASHBOARD=${HERMES_DASHBOARD}")
  fi
}

cmd_start_standalone() {
  local args=()
  # Drop leftover pod/nginx if switching from pod mode.
  if podman pod exists "${HERMES_POD:-hermes-agent-pod}" 2>/dev/null; then
    stop_hermes_pod_stack
  else
    podman rm -f "$(identyclaw_auth_container)" 2>/dev/null || true
    podman rm -f "$HERMES_CONTAINER" 2>/dev/null || true
  fi
  hermes_gateway_run_args args
  args+=(-p "${HERMES_API_PORT}:8642")
  # Telegram Bot API inbound webhooks: 443, 80, 88, or 8443 only.
  args+=(-p "${HERMES_TELEGRAM_PORT}:${TELEGRAM_WEBHOOK_PORT:-8443}")
  if [[ -n "${HERMES_DASHBOARD_PORT:-}" ]]; then
    args+=(-p "${HERMES_DASHBOARD_PORT}:9119")
  elif [[ "${HERMES_DASHBOARD:-}" == "1" || "${HERMES_DASHBOARD:-}" == "true" ]]; then
    args+=(-p "${HERMES_DASHBOARD_PORT:-11919}:9119")
  fi
  args+=("$HERMES_IMAGE" gateway run)

  podman "${args[@]}"
  start_identyclaw_auth_container
  echo "Started ${HERMES_CONTAINER} (standalone, restart=always) — API ${HERMES_API_PORT}, Telegram webhook ${HERMES_TELEGRAM_PORT}"
}

cmd_start_pod() {
  local app z args=() nginx_conf
  app="$(hermes_app_dir)"
  z="$(selinux_mount_suffix)"

  # Force webhook adapter on in pod mode.
  export WEBHOOK_ENABLED=true
  export WEBHOOK_PORT="${WEBHOOK_PORT:-8644}"

  normalize_tls_certs
  ensure_pod_logs_for_container "${app}/logs/nginx"

  if ! podman image exists "$HERMES_NGINX_IMAGE" 2>/dev/null; then
    build_hermes_nginx_image
  fi

  stop_hermes_pod_stack

  # nginx owns HERMES_INGRESS_PORT (8443 for Telegram). Adapter must listen elsewhere.
  if [[ "${TELEGRAM_WEBHOOK_PORT}" == "${HERMES_INGRESS_PORT}" ]]; then
    export TELEGRAM_WEBHOOK_PORT=8643
    echo "Note: TELEGRAM_WEBHOOK_PORT set to 8643 (nginx listens on ${HERMES_INGRESS_PORT})" >&2
  fi

  # Optional Passport mint-time aliases (e.g. HERMES_EXTRA_INGRESS_PORTS=7443 →
  # host:7443 → container HERMES_INGRESS_PORT). Same nginx TLS listener.
  local pod_ports=(
    -p "${HERMES_INGRESS_PORT}:${HERMES_INGRESS_PORT}"
    -p "${HERMES_API_PORT}:8642"
  )
  local extras extra_port
  extras="${HERMES_EXTRA_INGRESS_PORTS:-}"
  extras="${extras//,/ }"
  for extra_port in $extras; do
    extra_port="${extra_port//[[:space:]]/}"
    [[ -n "$extra_port" ]] || continue
    if [[ "$extra_port" == "${HERMES_INGRESS_PORT}" || "$extra_port" == "8642" ]]; then
      continue
    fi
    pod_ports+=(-p "${extra_port}:${HERMES_INGRESS_PORT}")
    echo "Extra ingress publish: host :${extra_port} → nginx :${HERMES_INGRESS_PORT}"
  done

  echo "Creating pod ${HERMES_POD} (ingress ${HERMES_INGRESS_PORT}, API ${HERMES_API_PORT}) ..."
  podman pod create \
    --name "$HERMES_POD" \
    "${pod_ports[@]}"

  hermes_gateway_run_args args
  args+=(--pod "$HERMES_POD")
  if [[ -n "${HERMES_DASHBOARD_PORT:-}" ]]; then
    echo "Note: HERMES_DASHBOARD_PORT is ignored in pod mode; use loopback API or extend the pod publish list." >&2
  fi
  args+=("$HERMES_IMAGE" gateway run)
  podman "${args[@]}"
  start_identyclaw_auth_container

  nginx_conf="${app}/nginx/nginx.conf"
  echo "Starting nginx sidecar ${HERMES_NGINX_CONTAINER} ..."
  # All binds under APP_DIR (certs, logs, rendered conf, copied nginx/inc).
  podman run -d \
    --pod "$HERMES_POD" \
    --name "$HERMES_NGINX_CONTAINER" \
    --replace \
    --restart always \
    -v "${app}/certs:/app/certs:ro${z}" \
    -v "${app}/logs/nginx:/var/log/nginx${z}" \
    -v "${app}/nginx/inc:/etc/nginx/inc:ro${z}" \
    -v "${nginx_conf}:/etc/nginx/nginx.conf:ro${z}" \
    "$HERMES_NGINX_IMAGE"

  echo "Started pod ${HERMES_POD} (restart=always)"
  echo "  API:      http://127.0.0.1:${HERMES_API_PORT}"
  echo "  Ingress:  https://${HERMES_PUBLIC_HOST}:${HERMES_INGRESS_PORT}/health"
  echo "  Webhooks: https://${HERMES_PUBLIC_HOST}:${HERMES_INGRESS_PORT}/webhooks/<route>"
  echo "  Telegram: https://${HERMES_PUBLIC_HOST}:${HERMES_INGRESS_PORT}/telegram"
}

cmd_start() {
  require_podman
  ensure_app_layout
  ensure_idcp_layout
  load_env

  # Rootless Podman: linger so pods survive SSH/Cursor logout (SKIP_LINGER=1 to skip).
  bash "${HERMES_ROOT}/scripts/ensure-podman-linger.sh" || true

  # Host-owned writes before prepare_app_for_container (which chowns to hermes 10000).
  # Sync secrets into .env for --env-file; never inject them as -e KEY=value.
  sync_gateway_env_file || true

  if hermes_is_pod_mode; then
    require_pod_webhook_env
    ensure_pod_internal_listen_ports
    export WEBHOOK_ENABLED=true
    export WEBHOOK_PORT="${WEBHOOK_PORT:-8644}"
    # Ensure toggles land in .env after pod-mode defaults.
    sync_gateway_env_file || true
    ensure_webhook_pod_layout
    ensure_tls_certs
    ensure_hermes_nginx_conf
    ensure_webhook_config_seed || true
    normalize_tls_certs
  fi

  # Stage a host-readable .env copy for podman --env-file (app tree becomes
  # UID-10000-only after prepare_app_for_container).
  local staged_env=""
  staged_env="$(mktemp)"
  if [[ -r "$(hermes_gateway_env_file)" ]]; then
    cp "$(hermes_gateway_env_file)" "$staged_env"
    chmod 600 "$staged_env"
    export HERMES_GATEWAY_ENV_FILE_HOST="$staged_env"
  else
    rm -f "$staged_env"
    staged_env=""
    unset HERMES_GATEWAY_ENV_FILE_HOST || true
  fi

  # Peer flag must be snapshotted before chown hides the 0700 app tree from the host.
  identyclaw_peer_snapshot

  prepare_app_for_container

  if hermes_is_pod_mode; then
    cmd_start_pod
  else
    cmd_start_standalone
  fi

  [[ -n "$staged_env" ]] && rm -f "$staged_env"
  unset HERMES_GATEWAY_ENV_FILE_HOST || true

  # Persist in volume config so rebuilds keep terminal sandboxes usable.
  ensure_egress_defaults
  ensure_sandbox_volumes
  # Optional Migadu mail (when HERMES_EMAIL is set in env.local).
  ensure_himalaya || echo "Warning: himalaya setup incomplete" >&2
  echo "App dir owned by container hermes UID while running; use ./hermes.sh stop to reclaim for host edits."
  if hermes_is_pod_mode; then
    podman ps --filter "pod=${HERMES_POD}" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
  else
    podman ps --filter "name=^${HERMES_CONTAINER}$" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
  fi
}

cmd_init() {
  local app env_file existed=0
  require_podman
  require_setup_prereqs || exit 1
  app="$(hermes_app_dir)"
  env_file="$(hermes_env_file)"
  [[ -f "$env_file" ]] && existed=1
  ensure_app_layout
  load_env
  echo "Pulling ${HERMES_IMAGE} ..."
  podman pull "$HERMES_IMAGE"
  echo "App dir: ${app}"
  if [[ "$existed" == "1" ]]; then
    echo "env.local already exists (leaving unchanged). To replace the -app dir: $0 nuke"
  fi
  echo "Next: ./hermes.sh setup   # populate -app; last: auto NEAR account + Passport mint"
}

# Wipe sibling -app (env.local, secrets, Passport keys, Hermes data) and re-run init.
cmd_nuke() {
  local yes=0 arg app
  for arg in "$@"; do
    case "$arg" in
      --yes|-y) yes=1 ;;
      -h|--help)
        echo "Usage: $0 nuke [--yes]"
        echo "  Deletes $(hermes_app_dir) and re-seeds env.local from the template."
        echo "  init never overwrites; nuke is the overwrite path."
        return 0
        ;;
      *)
        echo "Usage: $0 nuke [--yes]" >&2
        exit 1
        ;;
    esac
  done
  app="$(hermes_app_dir)"
  if ! app_dir_is_nukeable "$app"; then
    echo "Refusing to nuke ${app} (expected a sibling *-app directory, not HOME or the git checkout)" >&2
    exit 1
  fi
  if [[ -e "$app" ]]; then
    confirm_app_nuke "$app" "$yes" || { echo "aborted"; exit 1; }
    if command -v podman >/dev/null 2>&1; then
      cmd_stop >/dev/null 2>&1 || true
    fi
    restore_app_ownership 2>/dev/null || true
    remove_app_dir "$app" || exit 1
  else
    echo "No app dir yet at ${app} — running init"
  fi
  cmd_init
}

# Host-side idcp (used during setup when the gateway is stopped).
_idcp_host() {
  local app
  app="$(hermes_app_dir)"
  IDENTYCLAW_HOME="$app" HERMES_HOME="$app" HERMES_APP_DIR="$app" \
    node "$HERMES_ROOT/idcp/bin/idcp.mjs" "$@"
}

_idcp_account_id() {
  local app dir
  app="$(hermes_app_dir)"
  dir="${app}/secrets/near-credentials"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$dir" <<'PY'
import json, pathlib, sys
d = pathlib.Path(sys.argv[1])
if not d.is_dir():
    sys.exit(0)
files = sorted(d.glob("*.json"))
if not files:
    sys.exit(0)
try:
    raw = json.loads(files[0].read_text())
except Exception:
    sys.exit(0)
aid = raw.get("account_id") or raw.get("implicit_account_id") or ""
if aid:
    print(aid)
PY
  fi
}

# Install idcp deps + skill + volume hints.
_idcp_install_core() {
  ensure_app_layout
  ensure_idcp_layout
  local app
  app="$(hermes_app_dir)"
  if ! command -v npm >/dev/null 2>&1; then
    echo "npm required on host for IdentyClaw (idcp-install)" >&2
    exit 1
  fi
  if ! command -v node >/dev/null 2>&1; then
    echo "node required on host for IdentyClaw" >&2
    exit 1
  fi
  echo "Installing idcp deps in ${HERMES_ROOT}/idcp ..."
  (cd "$HERMES_ROOT/idcp" && npm install --omit=dev)

  # So Docker/Podman sandboxes (terminal backend) can reach idcp + secrets via host paths.
  if command -v python3 >/dev/null 2>&1 && [[ -f "$app/config.yaml" ]]; then
    python3 - "$app" "$HERMES_ROOT" <<'PY'
import sys, pathlib
app, repo = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
cfg = app / "config.yaml"
text = cfg.read_text()
vols = [
    f'    - "{repo / "idcp"}:/opt/idcp:ro"',
    f'    - "{app / "secrets"}:/opt/data/secrets:ro"',
    f'    - "{app / "secrets" / "identyclaw"}:/opt/data/secrets/identyclaw:rw"',
    f'    - "{app / "bin"}:/opt/data/bin:ro"',
]
marker = "# idcp-docker-volumes (managed by hermes.sh idcp-install)"
if marker in text:
    print("config.yaml already has idcp docker_volumes marker")
else:
    block = "\n".join([
        "",
        marker,
        "# Ensure terminal.docker_volumes includes:",
        *vols,
        "",
    ])
    cfg.write_text(text.rstrip() + "\n" + block)
    print(f"Appended idcp volume hints to {cfg}")
    print("Merge those lines into terminal.docker_volumes in config.yaml if not already listed.")
PY
  fi

  echo "Skill → ${app}/skills/identity/identyclaw/"
  echo "Secrets → ${app}/secrets/"
}

cmd_setup() {
  require_setup_prereqs || exit 1
  require_podman
  ensure_app_layout
  load_env
  if container_is_running "$HERMES_CONTAINER" || hermes_is_pod_mode; then
    echo "Stopping running gateway before setup..."
    if hermes_is_pod_mode; then
      stop_hermes_pod_stack
    else
      podman stop "$HERMES_CONTAINER" >/dev/null 2>&1 || true
      podman rm -f "$HERMES_CONTAINER" 2>/dev/null || true
    fi
  fi
  # Bypass s6 entrypoint — otherwise reconcile can start the gateway mid-wizard
  # and leave root-owned kanban locks hermes cannot write.
  clear_gateway_runtime_state
  echo "Running interactive setup (no gateway). Complete Nous Portal / API prompts in this TTY."
  run_hermes_cli "$HERMES_IMAGE" setup
  load_env
  ensure_egress_defaults
  restore_app_ownership
  _hermes_collect_operator_secrets
  _hermes_collect_passport_fields
  echo ""
  echo "=== IdentyClaw Passport ==="
  cmd_idcp_setup || true
  setup_ensure_self_signed_certs || true
  echo ""
  echo "Setup finished. Start with: ./hermes.sh start"
  echo "Then chat: ./hermes.sh chat    # console; or Telegram if configured during the wizard"
}

# Mail password + public host when missing (wizard does not collect these).
_hermes_collect_operator_secrets() {
  local envf password host
  envf="$(hermes_env_file)"
  load_env
  echo ""
  echo "==> Operator secrets (Enter skips; values already on disk are kept)"
  if [[ -n "${HERMES_EMAIL:-}" ]]; then
    if [[ -n "${HERMES_MAIL_PASSWORD:-}" ]]; then
      write_himalaya_secrets "$HERMES_MAIL_PASSWORD" || true
    elif ! podman unshare test -s "$(hermes_app_dir)/secrets/himalaya/imap.pass" 2>/dev/null \
      && ! [[ -s "$(hermes_app_dir)/secrets/himalaya/imap.pass" ]]; then
      password="$(identyclaw_prompt_secret "  Migadu mailbox password for ${HERMES_EMAIL} (Enter skips)")"
      if [[ -n "$password" ]]; then
        write_himalaya_secrets "$password" || true
      else
        echo "    (no mailbox password — later: ./hermes.sh himalaya-password)"
      fi
    fi
    ensure_himalaya || echo "    (himalaya layout incomplete — later: ./hermes.sh himalaya-install)" >&2
  fi
  if [[ -z "${HERMES_PUBLIC_HOST:-}" ]]; then
    host="$(identyclaw_prompt_with_default "  Public hostname (HERMES_PUBLIC_HOST, Enter skips)" "")"
    if [[ -n "$host" ]]; then
      upsert_env_local_kv "$envf" HERMES_PUBLIC_HOST "$host"
      export HERMES_PUBLIC_HOST="$host"
    fi
  fi
}

_hermes_collect_passport_fields() {
  local envf webhook avatar contact dotenv
  envf="$(hermes_env_file)"
  dotenv="$(hermes_gateway_env_file)"
  if [[ -r "$dotenv" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$dotenv" || true
    set +a
  fi
  load_env
  echo ""
  echo "==> Passport fields (Enter keeps the value; empty means collect at purchase.identyclaw.com)"
  webhook="$(hermes_passport_webhook_url)"
  avatar="${IDENTYCLAW_AVATAR_URL:-}"
  contact="$(hermes_passport_contact_uri)"
  if [[ -t 0 && "${SKIP_SETUP_PROMPTS:-0}" != "1" ]]; then
    [[ -z "$webhook" || "$webhook" == *127.0.0.1* || "$webhook" == *localhost* ]] \
      && webhook="$(identyclaw_prompt_with_default "  A2A / webhook URL" "$webhook")"
    [[ -z "$avatar" ]] && avatar="$(identyclaw_prompt_with_default "  Avatar image URL" "$avatar")"
    [[ -z "$contact" ]] && contact="$(identyclaw_prompt_with_default "  ContactURI" "$contact")"
  fi
  upsert_env_local_kv "$envf" IDENTYCLAW_WEBHOOK_URL "$webhook"
  upsert_env_local_kv "$envf" IDENTYCLAW_AVATAR_URL "$avatar"
  upsert_env_local_kv "$envf" IDENTYCLAW_CONTACT_URI "$contact"
  [[ -n "$webhook" ]] && export IDENTYCLAW_WEBHOOK_URL="$webhook"
  [[ -n "$avatar" ]] && export IDENTYCLAW_AVATAR_URL="$avatar"
  [[ -n "$contact" ]] && export IDENTYCLAW_CONTACT_URI="$contact"
}

# Natural IdentyClaw path: auto enroll (no operator input) → purchase guide → session.
# Invoked from setup (last step) or standalone to resume after mint.
cmd_idcp_setup() {
  ensure_app_layout
  load_env
  _idcp_install_core

  echo ""
  echo "Creating NEAR implicit account (automatic — no operator input) ..."
  local enroll_json account_id
  enroll_json="$(_idcp_host enroll)"
  echo "$enroll_json"
  account_id="$(
    printf '%s' "$enroll_json" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    d={}
print(d.get("account_id") or "")
' 2>/dev/null || true
  )"
  account_id="${account_id//[[:space:]]/}"
  if [[ -z "$account_id" ]]; then
    account_id="$(_idcp_account_id)"
    account_id="${account_id//[[:space:]]/}"
  fi
  if [[ -z "$account_id" ]]; then
    echo "Could not determine implicit_account_id after enroll." >&2
    return 1
  fi
  echo "Recipient account (automatic): ${account_id}"

  local tmp_sess tmp_me
  tmp_sess="$(mktemp)"
  tmp_me="$(mktemp)"
  if _idcp_host ensure_session >"$tmp_sess" 2>/dev/null \
    && _idcp_host me >"$tmp_me" 2>/dev/null; then
    echo ""
    echo "Passport already active on home (api.identyclaw.com):"
    cat "$tmp_me"
    rm -f "$tmp_sess" "$tmp_me"
    _hermes_print_chat_next
    return 0
  fi
  rm -f "$tmp_sess" "$tmp_me"

  local dotenv
  dotenv="$(hermes_gateway_env_file)"
  if [[ -r "$dotenv" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$dotenv" || true
    set +a
  fi
  print_passport_purchase_guide \
    "$account_id" \
    "${IDENTYCLAW_WEBHOOK_URL:-$(hermes_passport_webhook_url)}" \
    "${IDENTYCLAW_AVATAR_URL:-}" \
    "${IDENTYCLAW_CONTACT_URI:-$(hermes_passport_contact_uri)}"

  if [[ ! -t 0 ]]; then
    echo "Non-interactive TTY: after minting, re-run: ./hermes.sh idcp-setup" >&2
    echo "Account id saved under $(hermes_app_dir)/secrets/near-credentials/" >&2
    return 0
  fi

  # shellcheck disable=SC2162
  read -r -p "Press Enter after the Passport mint confirms (Ctrl-C to pause; resume with ./hermes.sh idcp-setup) ... "

  local attempt=1 max_attempts=8
  while (( attempt <= max_attempts )); do
    echo "Activating home session (attempt ${attempt}/${max_attempts}) ..."
    if _idcp_host ensure_session && _idcp_host me; then
      echo ""
      echo "IdentyClaw home session ready."
      _hermes_print_chat_next
      return 0
    fi
    if (( attempt == max_attempts )); then
      break
    fi
    echo "Login failed — Passport may still be indexing, or mint not finished."
    # shellcheck disable=SC2162
    read -r -p "Press Enter to retry (or Ctrl-C and later: ./hermes.sh idcp-setup) ... "
    (( ++attempt ))
  done

  echo "Could not activate session yet. After mint confirms:" >&2
  echo "  ./hermes.sh idcp-setup" >&2
  echo "  # or: ./hermes.sh idcp ensure_session && ./hermes.sh idcp me" >&2
  return 1
}

_hermes_print_chat_next() {
  local tg="${TELEGRAM_BOT_USERNAME:-}"
  tg="${tg#@}"
  echo ""
  echo "After mint + start, chat as the operator:"
  echo "  Console:   ./hermes.sh chat"
  if [[ -n "$tg" ]]; then
    echo "  Telegram:  @${tg}"
  else
    echo "  Telegram:  configure during ./hermes.sh setup (Hermes wizard) or in $(hermes_gateway_env_file)"
  fi
}

cmd_idcp_install() {
  load_env
  _idcp_install_core
  echo "Next: ./hermes.sh idcp-setup   # enroll → purchase → ensure_session"
  if container_is_running "${HERMES_CONTAINER:-hermes}"; then
    echo "Gateway is running — recreate to pick up /opt/idcp mount: ./hermes.sh start"
  fi
}

# Opt-in Passport peer stack: overlay A2A + RODiT /hooks/* + auth sidecar (does not replace HMAC webhooks).
# App dir is often owned by container UID 10000 while the gateway runs — write via podman unshare then.
cmd_identyclaw_peer_install() {
  ensure_app_layout
  ensure_idcp_layout
  load_env
  local app pkg_auth pkg_a2a pkg_hooks plugins_dir
  app="$(hermes_app_dir)"
  pkg_auth="$(identyclaw_auth_pkg)"
  pkg_a2a="$(identyclaw_a2a_pkg)"
  pkg_hooks="$(identyclaw_webhooks_pkg)"
  plugins_dir="${app}/plugins"

  if ! command -v npm >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1; then
    echo "node + npm required for IdentyClaw peer stack" >&2
    exit 1
  fi
  [[ -d "$pkg_auth" && -d "$pkg_a2a" && -d "$pkg_hooks" ]] || {
    echo "missing IdentyClaw plugin checkouts:" >&2
    echo "  auth     → ${pkg_auth}" >&2
    echo "  a2a      → ${pkg_a2a}" >&2
    echo "  webhooks → ${pkg_hooks}" >&2
    echo "Clone them next to hermes-agents, or set IDENTYCLAW_AUTH_DIR / IDENTYCLAW_A2A_DIR / IDENTYCLAW_WEBHOOKS_DIR." >&2
    exit 1
  }

  _idcp_install_core
  echo "Installing auth package deps in ${pkg_auth} ..."
  (cd "$pkg_auth" && npm install --omit=dev)

  # Host cannot mkdir/cp into a 0700 tree owned by the running gateway — use userns root.
  if [[ ! -w "$app" ]]; then
    if ! command -v podman >/dev/null 2>&1; then
      echo "App dir ${app} is not writable (gateway owns it) and podman is missing." >&2
      echo "Stop the gateway and reclaim: ./hermes.sh stop && ./hermes.sh own host" >&2
      exit 1
    fi
    echo "App dir owned by gateway UID — installing plugins via podman unshare ..."
    podman unshare bash -c "
      set -euo pipefail
      mkdir -p $(printf '%q' "$app/plugins") $(printf '%q' "$app/bin") \
        $(printf '%q' "$app/run") $(printf '%q' "$app/logs")
      rm -rf $(printf '%q' "$app/plugins/a2a-platform") \
        $(printf '%q' "$app/plugins/identyclaw-webhooks")
      cp -a $(printf '%q' "$pkg_a2a") $(printf '%q' "$app/plugins/a2a-platform")
      cp -a $(printf '%q' "$pkg_hooks") $(printf '%q' "$app/plugins/identyclaw-webhooks")
      rm -rf $(printf '%q' "$app/plugins/a2a-platform/__pycache__") \
        $(printf '%q' "$app/plugins/identyclaw-webhooks/__pycache__")
    "
    podman unshare touch "${app}/.identyclaw-peer-enabled"
    # Keep hermes ownership on new files when the tree is UID 10000.
    podman unshare bash -c "
      app=$(printf '%q' "$app")
      owner=\$(stat -c '%u' \"\$app\" 2>/dev/null || echo 10000)
      chown -R \"\$owner:\$owner\" \
        \"\$app/plugins/a2a-platform\" \
        \"\$app/plugins/identyclaw-webhooks\" \
        \"\$app/.identyclaw-peer-enabled\" 2>/dev/null || true
    "
  else
    mkdir -p "$plugins_dir" "$app/bin"
    rm -rf "${plugins_dir}/a2a-platform" "${plugins_dir}/identyclaw-webhooks"
    cp -a "$pkg_a2a" "${plugins_dir}/a2a-platform"
    cp -a "$pkg_hooks" "${plugins_dir}/identyclaw-webhooks"
    rm -rf "${plugins_dir}/a2a-platform/__pycache__" "${plugins_dir}/identyclaw-webhooks/__pycache__"
    touch "${app}/.identyclaw-peer-enabled"
  fi
  # Refresh container-safe /opt/idcp wrappers (never bake a host packages path).
  ensure_idcp_layout

  # Enable plugins in config.yaml (opt-in). Merge into existing keys — never append a
  # second top-level plugins:/platforms: block (YAML last-wins would wipe Telegram).
  if command -v python3 >/dev/null 2>&1; then
    local merge_py="${HERMES_ROOT}/scripts/merge-identyclaw-peer-config.py"
    if [[ -w "$app" ]]; then
      python3 "$merge_py" "$app"
    else
      podman unshare python3 "$merge_py" "$app"
    fi
  fi

  # Resolve NEAR creds path for sidecar / gateway (upsert_env_local_kv already handles UID 10000)
  local cred=""
  if [[ -w "$app" ]]; then
    if [[ -d "${app}/secrets/near-credentials" ]]; then
      cred="$(find "${app}/secrets/near-credentials" -maxdepth 1 -name '*.json' | head -1 || true)"
    fi
  else
    cred="$(podman unshare bash -c "find $(printf '%q' "${app}/secrets/near-credentials") -maxdepth 1 -name '*.json' 2>/dev/null | head -1" || true)"
  fi
  if [[ -n "$cred" ]]; then
    upsert_env_local_kv "$(hermes_env_file)" NEAR_CREDENTIALS_FILE_PATH "$cred"
    upsert_env_local_kv "$(hermes_env_file)" RODIT_NEAR_CREDENTIALS_SOURCE file
    if [[ -e "$(hermes_gateway_env_file)" ]] || podman unshare test -e "$(hermes_gateway_env_file)" 2>/dev/null; then
      upsert_env_local_kv "$(hermes_gateway_env_file)" NEAR_CREDENTIALS_FILE_PATH "$cred"
      upsert_env_local_kv "$(hermes_gateway_env_file)" RODIT_NEAR_CREDENTIALS_SOURCE file
    fi
  fi
  upsert_env_local_kv "$(hermes_env_file)" IDENTYCLAW_AUTH_PORT "${IDENTYCLAW_AUTH_PORT:-9910}"
  upsert_env_local_kv "$(hermes_env_file)" IDENTYCLAW_HOOKS_PORT "${IDENTYCLAW_HOOKS_PORT:-9911}"

  echo ""
  echo "IdentyClaw peer stack installed (opt-in)."
  echo "  Plugins → ${plugins_dir}/a2a-platform , identyclaw-webhooks"
  echo "  Flag    → ${app}/.identyclaw-peer-enabled"
  if container_is_running "${HERMES_CONTAINER:-hermes}"; then
    echo ""
    echo "Gateway is running — recreate after env edits so plugins load:"
    echo "  ./hermes.sh start"
  fi
  echo ""
  echo "Next:"
  echo "  1. Ensure NEAR_CREDENTIALS_FILE_PATH → secrets/near-credentials/*.json"
  echo "     (JWT aud = RoditClient.getConfigOwnRodit().own_rodit.owner_id — do not hardcode)"
  echo "  2. Set A2A_PUBLIC_URL to your public HTTPS base (Agent Card / discovery)"
  echo "  3. ./hermes.sh start   # recreates gateway + in-pod auth sidecar + nginx /hooks + /api/login"
  echo "  4. ./hermes.sh build-nginx && restart if nginx routes are stale"
  echo "  (Optional host-only debug: ./hermes.sh identyclaw-auth-start — not used by the gateway)"
}

cmd_identyclaw_auth_start() {
  ensure_app_layout
  load_env
  local app pkg pidfile logfile port
  app="$(hermes_app_dir)"
  pkg="$(identyclaw_auth_pkg)"
  pidfile="${app}/run/identyclaw-auth.pid"
  logfile="${app}/logs/identyclaw-auth.log"
  port="${IDENTYCLAW_AUTH_PORT:-9910}"
  if [[ -w "$app" ]]; then
    mkdir -p "${app}/run" "${app}/logs"
  else
    podman unshare mkdir -p "${app}/run" "${app}/logs"
  fi
  if [[ -r "$pidfile" ]] || podman unshare test -r "$pidfile" 2>/dev/null; then
    local oldpid
    oldpid="$(cat "$pidfile" 2>/dev/null || podman unshare cat "$pidfile" 2>/dev/null || true)"
    if [[ -n "$oldpid" ]] && kill -0 "$oldpid" 2>/dev/null; then
      echo "Auth sidecar already running (pid ${oldpid})"
      return 0
    fi
  fi
  [[ -d "$pkg/node_modules" ]] || (cd "$pkg" && npm install --omit=dev)
  if [[ -z "${NEAR_CREDENTIALS_FILE_PATH:-}" ]]; then
    local cred
    if [[ -w "$app" ]]; then
      cred="$(find "${app}/secrets/near-credentials" -maxdepth 1 -name '*.json' 2>/dev/null | head -1 || true)"
    else
      cred="$(podman unshare bash -c "find $(printf '%q' "${app}/secrets/near-credentials") -maxdepth 1 -name '*.json' 2>/dev/null | head -1" || true)"
    fi
    [[ -n "$cred" ]] && export NEAR_CREDENTIALS_FILE_PATH="$cred" RODIT_NEAR_CREDENTIALS_SOURCE=file
  fi
  export IDENTYCLAW_HOME="$app" HERMES_HOME="$app" IDENTYCLAW_AUTH_PORT="$port"
  # Sidecar binds host 127.0.0.1; logs/pid may live under container-owned app dir.
  if [[ -w "$app" ]]; then
    nohup node "${pkg}/bin/sidecar.mjs" --port "$port" >>"$logfile" 2>&1 &
    echo $! >"$pidfile"
  else
    # Log on host-writable path under the package; keep pid via unshare.
    logfile="${pkg}/.sidecar.log"
    nohup node "${pkg}/bin/sidecar.mjs" --port "$port" >>"$logfile" 2>&1 &
    echo $! | podman unshare tee "$pidfile" >/dev/null
  fi
  sleep 0.3
  local pid
  pid="$(cat "$pidfile" 2>/dev/null || podman unshare cat "$pidfile" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    echo "Auth sidecar listening on 127.0.0.1:${port} (pid ${pid}, log ${logfile})"
  else
    echo "Auth sidecar failed to start — see ${logfile}" >&2
    exit 1
  fi
}

cmd_identyclaw_auth_stop() {
  local app pidfile
  app="$(hermes_app_dir)"
  pidfile="${app}/run/identyclaw-auth.pid"
  if [[ -f "$pidfile" ]]; then
    kill "$(cat "$pidfile")" 2>/dev/null || true
    rm -f "$pidfile"
    echo "Auth sidecar stopped"
  else
    echo "No auth sidecar pidfile"
  fi
}

cmd_idcp() {
  ensure_app_layout
  ensure_idcp_layout
  load_env
  local app
  app="$(hermes_app_dir)"
  if [[ ! -d "$HERMES_ROOT/idcp/node_modules" ]]; then
    echo "Run ./hermes.sh setup (or idcp-install) first" >&2
    exit 1
  fi
  if container_is_running "$HERMES_CONTAINER"; then
    # Prefer in-container helper (same UID / mounts as the agent).
    local path_env
    path_env="${app}/bin:/opt/data/bin:/opt/hermes/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    podman exec \
      -e "IDENTYCLAW_HOME=${app}" \
      -e "HERMES_HOME=${app}" \
      -e "PATH=${path_env}" \
      "$HERMES_CONTAINER" \
      node /opt/idcp/bin/idcp.mjs "$@"
  else
    _idcp_host "$@"
  fi
}

cmd_stop() {
  require_podman
  load_env
  if hermes_is_pod_mode || podman pod exists "${HERMES_POD:-hermes-agent-pod}" 2>/dev/null; then
    stop_hermes_pod_stack
    echo "Stopped pod ${HERMES_POD:-hermes-agent-pod}"
  else
    podman rm -f "$(identyclaw_auth_container)" 2>/dev/null || true
    podman stop "$HERMES_CONTAINER" 2>/dev/null || true
    podman rm -f "$HERMES_CONTAINER" 2>/dev/null || true
    echo "Stopped ${HERMES_CONTAINER}"
  fi
  restore_app_ownership
}

cmd_status() {
  require_podman
  load_env
  echo "Repo:    $HERMES_ROOT"
  echo "App dir: $(hermes_app_dir)"
  echo "Image:   ${HERMES_IMAGE:-?(run init)}"
  echo "Mode:    ${HERMES_DEPLOY_MODE:-standalone}"
  if hermes_is_pod_mode || podman pod exists "${HERMES_POD:-hermes-agent-pod}" 2>/dev/null; then
    echo "Pod:     ${HERMES_POD:-hermes-agent-pod}"
    echo "Nginx:   ${HERMES_NGINX_IMAGE:-}"
    if [[ -n "${HERMES_PUBLIC_HOST:-}" ]]; then
      echo "Ingress:  https://${HERMES_PUBLIC_HOST}:${HERMES_INGRESS_PORT:-8443}/health"
      echo "Webhook:  https://${HERMES_PUBLIC_HOST}:${HERMES_INGRESS_PORT:-8443}/webhooks/<route>"
      echo "Telegram: https://${HERMES_PUBLIC_HOST}:${HERMES_INGRESS_PORT:-8443}/telegram"
    fi
    podman ps -a --filter "pod=${HERMES_POD:-hermes-agent-pod}" \
      --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}' || true
  else
    echo "API:      http://127.0.0.1:${HERMES_API_PORT}"
    echo "Telegram: host ${HERMES_TELEGRAM_PORT} → container ${TELEGRAM_WEBHOOK_PORT} (Bot API allows 443/80/88/8443)"
    podman ps -a --filter "name=^${HERMES_CONTAINER:-hermes}$" \
      --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}'
  fi
}

cmd_generate_certs() {
  require_podman
  ensure_app_layout
  load_env
  ensure_tls_certs "$@"
  echo "Next (pod mode): ./hermes.sh build-nginx && ./hermes.sh start"
}

cmd_build_nginx() {
  require_podman
  load_env
  build_hermes_nginx_image
}

cmd_logs() {
  require_podman
  load_env
  podman logs --tail "${LINES:-100}" -f "$HERMES_CONTAINER"
}

cmd_pull() {
  require_podman
  load_env
  podman pull "$HERMES_IMAGE"
  echo "Pulled ${HERMES_IMAGE}. Recreate with: ./hermes.sh start"
}

cmd_chat() {
  require_podman
  ensure_app_layout
  ensure_idcp_layout
  load_env
  local app path_env
  app="$(hermes_app_dir)"
  path_env="${app}/bin:/opt/data/bin:/opt/hermes/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  if container_is_running "$HERMES_CONTAINER"; then
    # Gateway may have left host-root-owned crumbs; hermes must own .env (0600).
    prepare_app_for_container || true
    # Gateway image PATH may omit /opt/hermes/bin when we prepend app bin.
    exec podman exec -it \
      -e "PATH=${path_env}" \
      -e "HERMES_HOME=${app}" \
      -e "IDENTYCLAW_HOME=${app}" \
      -e "HOME=${app}" \
      "$HERMES_CONTAINER" \
      /opt/hermes/bin/hermes "$@"
  fi
  echo "Note: gateway '${HERMES_CONTAINER}' is not running — starting ephemeral chat with Podman socket." >&2
  echo "  For a persistent gateway (recommended): ./hermes.sh start" >&2
  run_hermes_cli "$HERMES_IMAGE" "$@"
  restore_app_ownership
}

cmd_exec() {
  require_podman
  ensure_app_layout
  load_env
  if [[ "${1:-}" == "--" ]]; then shift; fi
  if [[ $# -eq 0 ]]; then
    echo "usage: ./hermes.sh exec -- <cmd...>" >&2
    exit 1
  fi
  if container_is_running "$HERMES_CONTAINER"; then
    local app path_env
    app="$(hermes_app_dir)"
    path_env="${app}/bin:/opt/data/bin:/opt/hermes/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    podman exec -it \
      -e "PATH=${path_env}" \
      -e "HERMES_HOME=${app}" \
      -e "IDENTYCLAW_HOME=${app}" \
      -e "HOME=${app}" \
      "$HERMES_CONTAINER" "$@"
  else
    # If first arg is already "hermes", drop it — entrypoint is hermes.
    if [[ "$1" == "hermes" ]]; then shift; fi
    run_hermes_cli "$HERMES_IMAGE" "$@"
    restore_app_ownership
  fi
}

cmd_own() {
  require_podman
  load_env
  local who="${1:-host}"
  case "$who" in
    host)
      if container_is_running "$HERMES_CONTAINER" \
        || container_is_running "${HERMES_NGINX_CONTAINER:-hermes-nginx}"; then
        echo "Stop the gateway first: ./hermes.sh stop" >&2
        exit 1
      fi
      restore_app_ownership
      echo "App dir owned by host user: $(hermes_app_dir)"
      ;;
    *)
      echo "usage: ./hermes.sh own host" >&2
      exit 1
      ;;
  esac
}

cmd_himalaya_install() {
  require_podman
  ensure_app_layout
  load_env
  export HERMES_EMAIL="${HERMES_EMAIL:-hermes@agenthood.me}"
  export HERMES_EMAIL_DISPLAY_NAME="${HERMES_EMAIL_DISPLAY_NAME:-Hermes Trimegisto}"
  echo "Installing Himalaya for ${HERMES_EMAIL} ..."
  install_himalaya_binary
  write_himalaya_config
  write_himalaya_helpers
  if [[ -n "${HERMES_MAIL_PASSWORD:-}" ]]; then
    write_himalaya_secrets "$HERMES_MAIL_PASSWORD"
  else
    echo "Password not in env — next: ./hermes.sh himalaya-password"
  fi
  if container_is_running "${HERMES_CONTAINER:-hermes}"; then
    ensure_sandbox_volumes || true
  fi
  echo "Done. Test with: ./hermes.sh himalaya-test"
}

cmd_himalaya_password() {
  require_podman
  ensure_app_layout
  load_env
  local password="${1:-${HERMES_MAIL_PASSWORD:-}}"
  if [[ -z "$password" ]]; then
    if [[ -t 0 ]]; then
      printf "Migadu password for %s: " "${HERMES_EMAIL:-hermes@agenthood.me}" >&2
      # shellcheck disable=SC2162
      read -rs password
      echo >&2
    else
      echo "usage: ./hermes.sh himalaya-password [PASSWORD]" >&2
      echo "  or set HERMES_MAIL_PASSWORD in hermes-agents-app/env.local" >&2
      exit 1
    fi
  fi
  write_himalaya_secrets "$password"
}

cmd_himalaya_test() {
  require_podman
  ensure_app_layout
  load_env
  himalaya_test
}

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    init) cmd_init "$@" ;;
    nuke) cmd_nuke "$@" ;;
    setup) cmd_setup "$@" ;;
    start) cmd_start "$@" ;;
    stop) cmd_stop "$@" ;;
    status) cmd_status "$@" ;;
    logs) cmd_logs "$@" ;;
    pull) cmd_pull "$@" ;;
    chat) cmd_chat "$@" ;;
    exec) cmd_exec "$@" ;;
    own) cmd_own "$@" ;;
    idcp-setup) cmd_idcp_setup "$@" ;;
    idcp-install) cmd_idcp_install "$@" ;;
    idcp) cmd_idcp "$@" ;;
    identyclaw-peer-install) cmd_identyclaw_peer_install "$@" ;;
    identyclaw-auth-start) cmd_identyclaw_auth_start "$@" ;;
    identyclaw-auth-stop) cmd_identyclaw_auth_stop "$@" ;;
    himalaya-install) cmd_himalaya_install "$@" ;;
    himalaya-password) cmd_himalaya_password "$@" ;;
    himalaya-test) cmd_himalaya_test "$@" ;;
    generate-certs) cmd_generate_certs "$@" ;;
    build-nginx) cmd_build_nginx "$@" ;;
    -h|--help|help|"") usage ;;
    *)
      echo "Unknown command: $cmd" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
