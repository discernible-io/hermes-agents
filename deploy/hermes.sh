#!/usr/bin/env bash
# Hermes Agent — Podman operator CLI (sibling app-dir layout).
#
# Repo (synced):   ~/hermes-agents  — wrapper lives in deploy/
# Runtime (local): ~/hermes-agents-app  → mounted at /opt/data
#
# Usage:
#   ./hermes.sh init
#   ./hermes.sh setup          # interactive wizard (TTY)
#   ./hermes.sh start
#   ./hermes.sh stop
#   ./hermes.sh status
#   ./hermes.sh logs
#   ./hermes.sh pull
#   ./hermes.sh chat
#   ./hermes.sh exec -- hermes config set model.provider openrouter
#   ./hermes.sh own host       # reclaim app dir after stop
#   ./hermes.sh idcp-install   # IdentyClaw helper + skill into app dir
#   ./hermes.sh idcp <cmd…>    # ensure_session | create_hola | …
#   ./hermes.sh himalaya-install
#   ./hermes.sh himalaya-password
#   ./hermes.sh himalaya-test
#   ./hermes.sh generate-certs [--force]
#   ./hermes.sh build-nginx

set -euo pipefail
[[ "${TRACE:-0}" == 1 ]] && set -x

HERMES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$HERMES_ROOT/scripts/lib.sh"

usage() {
  sed -n '2,24p' "$0" | sed 's/^# \?//'
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

  echo "Creating pod ${HERMES_POD} (ingress ${HERMES_INGRESS_PORT}, API ${HERMES_API_PORT}) ..."
  podman pod create \
    --name "$HERMES_POD" \
    -p "${HERMES_INGRESS_PORT}:${HERMES_INGRESS_PORT}" \
    -p "${HERMES_API_PORT}:8642"

  hermes_gateway_run_args args
  args+=(--pod "$HERMES_POD")
  if [[ -n "${HERMES_DASHBOARD_PORT:-}" ]]; then
    echo "Note: HERMES_DASHBOARD_PORT is ignored in pod mode; use loopback API or extend the pod publish list." >&2
  fi
  args+=("$HERMES_IMAGE" gateway run)
  podman "${args[@]}"

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
  require_podman
  ensure_app_layout
  load_env
  echo "Pulling ${HERMES_IMAGE} ..."
  podman pull "$HERMES_IMAGE"
  echo "App dir: $(hermes_app_dir)"
  echo "Next: ./hermes.sh setup   # or edit $(hermes_app_dir)/.env then ./hermes.sh start"
}

cmd_setup() {
  require_podman
  ensure_app_layout
  load_env
  if container_is_running "$HERMES_CONTAINER" || hermes_is_pod_mode; then
    echo "Stopping running gateway before setup..."
    if hermes_is_pod_mode; then
      stop_hermes_pod_stack
    else
      podman stop "$HERMES_CONTAINER" >/dev/null 2>&1 || true
      podman rm -f "$HERMES_CONTAINER" >/dev/null 2>&1 || true
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
  echo "Setup finished. Start with: ./hermes.sh start"
}

cmd_idcp_install() {
  ensure_app_layout
  ensure_idcp_layout
  load_env
  local app
  app="$(hermes_app_dir)"
  if ! command -v npm >/dev/null 2>&1; then
    echo "npm required on host for idcp-install" >&2
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
    f'    - "{app / "bin"}:/opt/data/bin:ro"',
]
marker = "# idcp-docker-volumes (managed by hermes.sh idcp-install)"
if marker in text:
    print("config.yaml already has idcp docker_volumes marker")
else:
    # Append under terminal: if present; else leave a comment block for operator
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
  echo "Next: ./hermes.sh idcp enroll   # then purchase Passport, then ensure_session"
  if container_is_running "${HERMES_CONTAINER:-hermes}"; then
    echo "Gateway is running — recreate to pick up /opt/idcp mount: ./hermes.sh start"
  fi
}

cmd_idcp() {
  ensure_app_layout
  ensure_idcp_layout
  load_env
  local app
  app="$(hermes_app_dir)"
  if [[ ! -d "$HERMES_ROOT/idcp/node_modules" ]]; then
    echo "Run ./hermes.sh idcp-install first" >&2
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
    IDENTYCLAW_HOME="$app" HERMES_HOME="$app" HERMES_APP_DIR="$app" \
      node "$HERMES_ROOT/idcp/bin/idcp.mjs" "$@"
  fi
}


cmd_stop() {
  require_podman
  load_env
  if hermes_is_pod_mode || podman pod exists "${HERMES_POD:-hermes-agent-pod}" 2>/dev/null; then
    stop_hermes_pod_stack
    echo "Stopped pod ${HERMES_POD:-hermes-agent-pod}"
  else
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
    setup) cmd_setup "$@" ;;
    start) cmd_start "$@" ;;
    stop) cmd_stop "$@" ;;
    status) cmd_status "$@" ;;
    logs) cmd_logs "$@" ;;
    pull) cmd_pull "$@" ;;
    chat) cmd_chat "$@" ;;
    exec) cmd_exec "$@" ;;
    own) cmd_own "$@" ;;
    idcp-install) cmd_idcp_install "$@" ;;
    idcp) cmd_idcp "$@" ;;
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
