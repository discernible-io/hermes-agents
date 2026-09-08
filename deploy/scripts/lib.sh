#!/usr/bin/env bash
# Shared helpers for hermes.sh — sibling app dir layout (never store secrets in the git checkout).

set -euo pipefail

HERMES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Runtime config, secrets, skills, memories — sibling of the repo clone.
hermes_app_dir() {
  if [[ -n "${HERMES_APP_DIR:-}" ]]; then
    printf '%s' "$HERMES_APP_DIR"
    return
  fi
  # HERMES_ROOT is …/hermes-agents/deploy → sibling app is …/hermes-agents-app
  printf '%s' "$(cd "${HERMES_ROOT}/../.." && pwd)/hermes-agents-app"
}

hermes_env_file() {
  echo "$(hermes_app_dir)/env.local"
}

# Hermes-native secrets store (API keys, bot tokens, WEBHOOK_SECRET, …).
# Gateway starts with --env-file pointing here — never pass secrets as -e KEY=value.
hermes_gateway_env_file() {
  echo "$(hermes_app_dir)/.env"
}

# Keys that belong in .env (secrets + Hermes runtime toggles consumed via getenv).
# env.local is for host publish ports / deploy mode / non-secret operator prefs.
_GATEWAY_ENV_KEYS=(
  OPENROUTER_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY NOUS_API_KEY
  GOOGLE_API_KEY GEMINI_API_KEY GLM_API_KEY KIMI_API_KEY MINIMAX_API_KEY
  API_SERVER_ENABLED API_SERVER_HOST API_SERVER_KEY API_SERVER_CORS_ORIGINS
  API_SERVER_MODEL_NAME
  HERMES_DASHBOARD_BASIC_AUTH_USERNAME HERMES_DASHBOARD_BASIC_AUTH_PASSWORD
  HERMES_DASHBOARD_BASIC_AUTH_SECRET HERMES_DASHBOARD_INSECURE
  IDENTYCLAW_BASE_URL
  WEBHOOK_ENABLED WEBHOOK_PORT WEBHOOK_SECRET
  TELEGRAM_BOT_TOKEN TELEGRAM_ALLOWED_USERS TELEGRAM_HOME_CHANNEL
  TELEGRAM_HOME_CHANNEL_NAME TELEGRAM_PROXY
  TELEGRAM_WEBHOOK_URL TELEGRAM_WEBHOOK_PORT TELEGRAM_WEBHOOK_SECRET
  TELEGRAM_WEBHOOK_HOST GATEWAY_ALLOW_ALL_USERS
)

# Upsert shell-sourced values into .env when the key is missing or empty there.
# Prefer existing .env values (Hermes setup / hermes config are authoritative).
# Call while the app dir is host-writable (before prepare_app_for_container).
# Does not print secret values.
sync_gateway_env_file() {
  local envf key val cur
  load_env
  envf="$(hermes_gateway_env_file)"
  mkdir -p "$(dirname "$envf")" 2>/dev/null || true
  if [[ ! -f "$envf" ]]; then
    touch "$envf" || {
      echo "Warning: cannot create ${envf}" >&2
      return 1
    }
  fi
  chmod 600 "$envf" 2>/dev/null || true
  for key in "${_GATEWAY_ENV_KEYS[@]}"; do
    val="${!key:-}"
    [[ -n "$val" ]] || continue
    if grep -qE "^${key}=" "$envf" 2>/dev/null; then
      cur="$(grep -E "^${key}=" "$envf" | head -1 | cut -d= -f2-)"
      [[ -n "$cur" ]] && continue
      # shellcheck disable=SC2001
      sed -i "s|^${key}=.*|${key}=${val}|" "$envf"
    else
      printf '%s=%s\n' "$key" "$val" >>"$envf"
    fi
  done
}

selinux_mount_suffix() {
  if [[ "$(uname -s)" == "Linux" ]] && command -v getenforce >/dev/null 2>&1; then
    local mode
    mode="$(getenforce 2>/dev/null || true)"
    if [[ "$mode" == "Enforcing" || "$mode" == "Permissive" ]]; then
      echo ",Z"
      return
    fi
  fi
  echo ""
}

require_podman() {
  command -v podman >/dev/null 2>&1 || {
    echo "podman not found" >&2
    exit 1
  }
}

_prereq_install_hint() {
  local pkgs="$1" id="" like=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    id="$(. /etc/os-release && printf '%s' "${ID:-}")"
    like="$(. /etc/os-release && printf '%s' "${ID_LIKE:-}")"
  fi
  case " ${id} ${like} " in
    *" rhel "*|*" fedora "*|*" centos "*|*" almalinux "*|*" rocky "*)
      echo "Install (AlmaLinux / RHEL / Fedora): sudo dnf install -y ${pkgs}" >&2
      ;;
    *" debian "*|*" ubuntu "*)
      echo "Install (Debian / Ubuntu): sudo apt-get install -y ${pkgs}" >&2
      ;;
    *)
      echo "Install: ${pkgs}" >&2
      ;;
  esac
}

require_setup_prereqs() {
  local missing=() name ver major
  echo "==> Checking prerequisites"
  for name in podman python3 openssl node npm; do
    if command -v "$name" >/dev/null 2>&1; then
      case "$name" in
        podman) ver="$(podman --version 2>/dev/null | head -1)" ;;
        python3) ver="$(python3 --version 2>/dev/null)" ;;
        openssl) ver="$(openssl version 2>/dev/null)" ;;
        node) ver="$(node --version 2>/dev/null)" ;;
        npm) ver="$(npm --version 2>/dev/null)" ;;
        *) ver="" ;;
      esac
      echo "    ok  ${name}${ver:+  (${ver})}"
    else
      missing+=("$name")
      echo "    missing  ${name}"
    fi
  done
  if command -v node >/dev/null 2>&1; then
    major="$(node --version 2>/dev/null | sed 's/^v//' | cut -d. -f1)"
    if [[ "${major:-0}" -lt 22 ]]; then
      echo "    warn  Node.js 22+ recommended (found $(node --version 2>/dev/null))" >&2
    fi
  fi
  if ! command -v loginctl >/dev/null 2>&1; then
    echo "    skip  loginctl (optional; needed only for enable-boot linger)"
  fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Missing required tools: ${missing[*]}" >&2
    _prereq_install_hint "podman python3 openssl nodejs npm"
    return 1
  fi
  return 0
}

load_env() {
  local f
  f="$(hermes_env_file)"
  if [[ -r "$f" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$f"
    set +a
  elif container_is_running "${HERMES_CONTAINER:-hermes}" 2>/dev/null; then
    # App dir owned by container UID — pull env.local via podman.
    local tmp
    tmp="$(mktemp)"
    if podman exec "${HERMES_CONTAINER:-hermes}" \
      sh -c 'test -r /opt/data/env.local && cat /opt/data/env.local' \
      >"$tmp" 2>/dev/null; then
      set -a
      # shellcheck disable=SC1090
      source "$tmp"
      set +a
    fi
    rm -f "$tmp"
  fi
  HERMES_IMAGE="${HERMES_IMAGE:-docker.io/nousresearch/hermes-agent:latest}"
  HERMES_CONTAINER="${HERMES_CONTAINER:-hermes}"
  # Operator API stays on 11642. Host Telegram/webhook publish defaults to 8443 —
  # Bot API only accepts inbound webhooks on 443, 80, 88, or 8443.
  # Override via env.local when 8443 is taken (this host: 10443, infra-app 80→10443).
  # Container-internal Hermes ports stay 8642 / 8644 / 9119.
  HERMES_API_PORT="${HERMES_API_PORT:-11642}"
  HERMES_TELEGRAM_PORT="${HERMES_TELEGRAM_PORT:-8443}"
  TELEGRAM_WEBHOOK_PORT="${TELEGRAM_WEBHOOK_PORT:-8443}"
  HERMES_DEPLOY_MODE="${HERMES_DEPLOY_MODE:-standalone}"
  HERMES_POD="${HERMES_POD:-hermes-agent-pod}"
  HERMES_NGINX_CONTAINER="${HERMES_NGINX_CONTAINER:-hermes-nginx}"
  HERMES_NGINX_IMAGE="${HERMES_NGINX_IMAGE:-localhost/hermes-nginx:local}"
  HERMES_INGRESS_PORT="${HERMES_INGRESS_PORT:-8443}"
  WEBHOOK_PORT="${WEBHOOK_PORT:-8644}"
}

# Rootless Podman: hermes runs as container UID 10000 → host subuid.
# Only reclaim ownership when the container is stopped (host edits).
# Never call this while the gateway is running — it breaks hermes' access to .env.
restore_app_ownership() {
  local app
  app="$(hermes_app_dir)"
  [[ -d "$app" ]] || return 0
  podman unshare chown -R 0:0 "$app" 2>/dev/null || true
}

# Give the container hermes UID (10000) the app tree so it can create runtime files.
# Call before start / one-shot CLI. Host reclaim happens on stop.
# Critical: HERMES_HOME/.env is mode 0600 — if owned by host-root (0), hermes cannot
# even stat it and chat crashes with PermissionError.
prepare_app_for_container() {
  local app
  app="$(hermes_app_dir)"
  [[ -d "$app" ]] || return 0
  # Drop stale locks from interrupted setup/gateway (often root-owned under userns).
  if ! podman unshare bash -c "
    cd $(printf '%q' "$app") || exit 1
    rm -f gateway.lock gateway.pid \
      kanban.db.init.lock kanban.db.dispatch.lock \
      kanban.db-wal kanban.db-shm 2>/dev/null || true
    # Directory + contents must be hermes (10000), not host-root-mapped UID 0.
    # Exclude certs/ — nginx (UID 101) needs ownership; normalize_tls_certs handles it.
    chown 10000:10000 . 2>/dev/null || true
    for item in * .[!.]* ..?*; do
      [ -e \"\$item\" ] || continue
      [ \"\$item\" = 'certs' ] && continue
      chown -R 10000:10000 \"\$item\" 2>/dev/null || true
    done
  "; then
    echo "Warning: could not chown $(hermes_app_dir) to hermes UID 10000" >&2
    return 1
  fi
}

# Clear “gateway was running” crumbs so an accidental s6 boot during setup
# does not auto-start the gateway alongside the wizard.
clear_gateway_runtime_state() {
  local app
  app="$(hermes_app_dir)"
  [[ -d "$app" ]] || return 0
  podman unshare bash -c "
    cd $(printf '%q' "$app") || exit 0
    rm -f gateway.lock gateway.pid
    if [[ -f gateway_state.json ]]; then
      # best-effort: leave file but avoid reconcile starting gateways mid-setup
      true
    fi
  " 2>/dev/null || true
}

container_is_running() {
  local name="${1:-}"
  [[ -n "$name" ]] || return 1
  podman ps --format '{{.Names}}' | grep -qx "$name"
}

# One-shot hermes CLI without s6 (avoids gateway starting during setup/chat).
# Run as container hermes UID so new files are not root-owned.
# Mounts Podman API socket so terminal/execute_code sandboxes work (same as gateway).
run_hermes_cli() {
  local app z podman_sock args=()
  app="$(hermes_app_dir)"
  z="$(selinux_mount_suffix)"
  prepare_app_for_container
  args=(
    run --rm -it
    --user 10000:10000
    --entrypoint hermes
    -v "${app}:/opt/data:rw${z}"
    -v "${app}:${app}:rw${z}"
    -v "${HERMES_ROOT}/idcp:/opt/idcp:ro${z}"
    -v "${HERMES_ROOT}/idcp:${HERMES_ROOT}/idcp:ro${z}"
    -e "HERMES_HOME=${app}"
    -e "IDENTYCLAW_HOME=${app}"
    -e "HOME=${app}"
    -e "PATH=${app}/bin:/opt/data/bin:/opt/hermes/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  )
  # Rootless Podman socket appears as root-owned inside the userns; hermes UID
  # needs the root supplementary group (gateway s6 does the same via usermod).
  podman_sock="${PODMAN_SOCK:-/run/user/$(id -u)/podman/podman.sock}"
  if [[ -S "$podman_sock" ]]; then
    args+=(-v "${podman_sock}:/var/run/docker.sock")
    args+=(-e HERMES_DOCKER_BINARY=docker)
    args+=(--group-add root)
  else
    echo "Warning: ${podman_sock} missing — terminal/execute_code sandboxes will fail." >&2
    echo "  Enable with: systemctl --user enable --now podman.socket" >&2
  fi
  # Dual-mount host path so nested docker -v paths resolve on the host.
  podman "${args[@]}" "$@"
}

ensure_app_layout() {
  local app
  app="$(hermes_app_dir)"
  mkdir -p "$app" 2>/dev/null || true
  chmod 700 "$app" 2>/dev/null || true
  # When the gateway owns the tree (0700), host -f checks fail even if env.local exists.
  if [[ -r "$app" ]] && [[ ! -f "$app/env.local" && -f "$HERMES_ROOT/env.example" ]]; then
    if cp "$HERMES_ROOT/env.example" "$app/env.local" 2>/dev/null; then
      chmod 600 "$app/env.local" 2>/dev/null || true
      echo "Created ${app}/env.local from env.example — edit keys before relying on the gateway."
    fi
  fi
}

app_dir_is_nukeable() {
  local app="${1:?}"
  local abs repo parent
  abs="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$app")"
  repo="$(cd "${HERMES_ROOT}/.." && pwd)"
  parent="$(cd "${HERMES_ROOT}/../.." && pwd)"
  [[ -n "$abs" && "$abs" != "/" ]] || return 1
  [[ "$abs" != "$HOME" ]] || return 1
  [[ "$(basename "$abs")" == *-app ]] || return 1
  [[ "$abs" != "$repo" ]] || return 1
  [[ "$abs" != "$HERMES_ROOT" ]] || return 1
  [[ "$abs" != "$parent" ]] || return 1
  return 0
}

confirm_app_nuke() {
  local app="${1:?}" yes="${2:-0}" base reply
  base="$(basename "$app")"
  echo "This DELETES ${app}"
  echo "  env.local, .env, Passport keys, Hermes data, TLS — all gone."
  echo "  init never overwrites; nuke is the overwrite path."
  if [[ "$yes" == "1" ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "Non-interactive TTY: pass --yes" >&2
    return 1
  fi
  # shellcheck disable=SC2162
  read -r -p "Type ${base} to confirm: " reply
  [[ "$reply" == "$base" ]]
}

remove_app_dir() {
  local app="${1:?}"
  [[ -e "$app" ]] || return 0
  echo "==> Removing ${app}"
  if rm -rf "$app" 2>/dev/null; then
    return 0
  fi
  if command -v podman >/dev/null 2>&1; then
    podman unshare rm -rf "$app"
    return 0
  fi
  echo "Could not remove ${app} (permission). Stop the gateway and retry." >&2
  return 1
}

# IdentyClaw: secrets + skill under app dir; helper code stays in synced repo.
ensure_idcp_layout() {
  local app
  app="$(hermes_app_dir)"
  mkdir -p \
    "$app/secrets/near-credentials" \
    "$app/secrets/identyclaw" \
    "$app/skills/identity/identyclaw" \
    "$app/bin" 2>/dev/null || true
  chmod 700 "$app/secrets" "$app/secrets/near-credentials" "$app/secrets/identyclaw" 2>/dev/null || true
  if [[ -f "$HERMES_ROOT/skills/identyclaw/SKILL.md" ]]; then
    cp -a "$HERMES_ROOT/skills/identyclaw/SKILL.md" "$app/skills/identity/identyclaw/SKILL.md" 2>/dev/null || true
  fi
  # Wrapper so `idcp` works inside the gateway and docker sandboxes.
  if [[ -w "$app/bin" ]] || [[ -w "$app" ]]; then
    cat >"$app/bin/idcp" <<'EOF'
#!/bin/sh
export IDENTYCLAW_HOME="${IDENTYCLAW_HOME:-${HERMES_HOME:-/opt/data}}"
export HERMES_HOME="${HERMES_HOME:-/opt/data}"
for cand in \
  "${IDENTYCLAW_IDCP:-}" \
  /opt/idcp/bin/idcp.mjs \
  "$(dirname "$0")/../../hermes-agents/deploy/idcp/bin/idcp.mjs"
do
  [ -n "$cand" ] && [ -f "$cand" ] && exec node "$cand" "$@"
done
echo "idcp: /opt/idcp not mounted — recreate gateway (./hermes.sh start) or set docker_volumes" >&2
exit 127
EOF
    chmod 755 "$app/bin/idcp" 2>/dev/null || true
  fi
}

idcp_volume_args() {
  local z
  z="$(selinux_mount_suffix)"
  # Synced helper tree (includes node_modules after idcp-install)
  printf -- '-v %s:/opt/idcp:ro%s' "$HERMES_ROOT/idcp" "$z"
}

# Default: disable iron-proxy egress gate so terminal/file sandboxes work.
# Writes into app-dir config.yaml (volume) so it survives image rebuilds.
# Opt in with HERMES_EGRESS=1 in env.local, then run: hermes egress setup
ensure_egress_defaults() {
  case "${HERMES_EGRESS:-0}" in
    1|true|TRUE|yes|YES) return 0 ;;
  esac

  local name="${HERMES_CONTAINER:-hermes}"
  local image="${HERMES_IMAGE:-docker.io/nousresearch/hermes-agent:latest}"
  local app path_env
  app="$(hermes_app_dir)"
  path_env="${app}/bin:/opt/data/bin:/opt/hermes/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

  if container_is_running "$name"; then
    podman exec \
      -e "HERMES_HOME=${app}" \
      -e "HOME=${app}" \
      -e "PATH=${path_env}" \
      "$name" \
      /opt/hermes/bin/hermes config set proxy.enabled false >/dev/null \
      || echo "Warning: could not set proxy.enabled=false in running container" >&2
    return 0
  fi

  local z
  z="$(selinux_mount_suffix)"
  [[ -f "$app/config.yaml" ]] || return 0
  prepare_app_for_container
  podman run --rm \
    --user 10000:10000 \
    --entrypoint hermes \
    -v "${app}:/opt/data:rw${z}" \
    -v "${app}:${app}:rw${z}" \
    -e "HERMES_HOME=${app}" \
    -e "HOME=${app}" \
    "$image" \
    config set proxy.enabled false >/dev/null \
    || echo "Warning: could not set proxy.enabled=false in app config" >&2
}

# Nested docker sandboxes need host-absolute volume sources (not /opt/data).
# Persists terminal.docker_volumes in app-dir config.yaml across rebuilds.
ensure_sandbox_volumes() {
  local name="${HERMES_CONTAINER:-hermes}"
  local app idcp_host
  app="$(hermes_app_dir)"
  idcp_host="${HERMES_ROOT}/idcp"

  if ! container_is_running "$name"; then
    return 0
  fi

  podman exec -i \
    -e "HERMES_HOME=${app}" \
    -e "HOME=${app}" \
    -e "PATH=${app}/bin:/opt/data/bin:/opt/hermes/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    -e "HERMES_APP_HOST=${app}" \
    -e "HERMES_IDCP_HOST=${idcp_host}" \
    -e "MIGADU_SMTP_IPV4=${MIGADU_SMTP_IPV4:-141.94.97.118}" \
    "$name" \
    /opt/hermes/.venv/bin/python3 - <<'PY' || echo "Warning: could not set terminal.docker_volumes" >&2
import json, os, pathlib, re

app = os.environ["HERMES_APP_HOST"]
idcp = os.environ["HERMES_IDCP_HOST"]
wanted = [
    f"{idcp}:/opt/idcp:ro",
    f"{app}/secrets:/opt/data/secrets:ro",
    f"{app}/bin:/opt/data/bin:ro",
]
cfg_path = pathlib.Path(app) / "config.yaml"
text = cfg_path.read_text()
lines = text.splitlines(keepends=True)
out = []
i = 0
in_term = False
wrote_vols = False
while i < len(lines):
    line = lines[i]
    if re.match(r"^terminal:\s*$", line):
        in_term = True
        out.append(line)
        i += 1
        continue
    if in_term and re.match(r"^[^\s#]", line):
        if not wrote_vols:
            out.append("  docker_volumes:\n")
            for v in wanted:
                out.append(f'    - "{v}"\n')
            wrote_vols = True
        in_term = False
        out.append(line)
        i += 1
        continue
    if in_term and re.match(r"^  docker_volumes:\s*$", line):
        out.append("  docker_volumes:\n")
        for v in wanted:
            out.append(f'    - "{v}"\n')
        i += 1
        while i < len(lines) and re.match(r"^    - |^  - ", lines[i]):
            i += 1
        wrote_vols = True
        continue
    out.append(line)
    i += 1
if in_term and not wrote_vols:
    out.append("  docker_volumes:\n")
    for v in wanted:
        out.append(f'    - "{v}"\n')
elif not wrote_vols:
    out.append("\nterminal:\n  docker_volumes:\n")
    for v in wanted:
        out.append(f'    - "{v}"\n')

cfg_path.write_text("".join(out))

# Pin Migadu SMTP to IPv4 (IPv6 resets on this host).
# Default is a current smtp.migadu.com A record — mta1 37.59.57.117 times out from this host.
smtp_ip = os.environ.get("MIGADU_SMTP_IPV4", "141.94.97.118").strip() or "141.94.97.118"
add_host = f"--add-host=smtp.migadu.com:{smtp_ip}"
text = cfg_path.read_text()
lines = text.splitlines(keepends=True)
out = []
i = 0
in_term = False
wrote_extra = False
while i < len(lines):
    line = lines[i]
    if re.match(r"^terminal:\s*$", line):
        in_term = True
        out.append(line)
        i += 1
        continue
    if in_term and re.match(r"^[^\s#]", line):
        if not wrote_extra:
            out.append("  docker_extra_args:\n")
            out.append(f'    - "{add_host}"\n')
            wrote_extra = True
        in_term = False
        out.append(line)
        i += 1
        continue
    if in_term and re.match(r"^  docker_extra_args:\s*$", line):
        out.append("  docker_extra_args:\n")
        out.append(f'    - "{add_host}"\n')
        i += 1
        while i < len(lines) and re.match(r"^    - |^  - ", lines[i]):
            i += 1
        wrote_extra = True
        continue
    out.append(line)
    i += 1
if in_term and not wrote_extra:
    out.append("  docker_extra_args:\n")
    out.append(f'    - "{add_host}"\n')

cfg_path.write_text("".join(out))

# ExtraHosts are immutable for a container's lifetime. Always drop hermes
# sandboxes whose smtp.migadu.com pin disagrees with MIGADU_SMTP_IPV4 so the
# next terminal call recreates them (otherwise SMTP hangs on a dead IP while
# IMAP still works — config.yaml can already be correct while sandboxes aren't).
import subprocess
removed = []
try:
    ps = subprocess.run(
        ["docker", "ps", "-aq", "--filter", "label=hermes-agent=1"],
        capture_output=True, text=True, timeout=15, check=False,
    )
    for cid in [x for x in ps.stdout.split() if x]:
        insp = subprocess.run(
            ["docker", "inspect", "-f", "{{json .HostConfig.ExtraHosts}}", cid],
            capture_output=True, text=True, timeout=10, check=False,
        )
        hosts = insp.stdout.strip()
        if "smtp.migadu.com" in hosts and smtp_ip not in hosts:
            subprocess.run(
                ["docker", "rm", "-f", cid],
                capture_output=True, text=True, timeout=30, check=False,
            )
            removed.append(cid[:12])
except Exception as e:
    print(json.dumps({
        "ok": True,
        "docker_volumes": wanted,
        "docker_extra_args": [add_host],
        "sandbox_recreate_error": str(e),
    }))
else:
    print(json.dumps({
        "ok": True,
        "docker_volumes": wanted,
        "docker_extra_args": [add_host],
        "sandboxes_recreated_for_smtp_pin": removed,
    }))
PY
}

detect_himalaya_arch() {
  local machine
  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64) echo "x86_64-linux" ;;
    aarch64|arm64) echo "aarch64-linux" ;;
    armv7l) echo "armv7l-linux" ;;
    i686|i386) echo "i686-linux" ;;
    *)
      echo "ERROR: unsupported CPU for Himalaya binary: $machine" >&2
      return 1
      ;;
  esac
}

# Run a shell snippet as the hermes UID against the app volume.
app_shell() {
  local app name
  app="$(hermes_app_dir)"
  name="${HERMES_CONTAINER:-hermes}"
  if container_is_running "$name"; then
    podman exec -u hermes -e "HERMES_HOME=${app}" -e "HOME=${app}" "$name" sh -c "$1"
  else
    local z image
    z="$(selinux_mount_suffix)"
    image="${HERMES_IMAGE:-docker.io/nousresearch/hermes-agent:latest}"
    prepare_app_for_container
    podman run --rm \
      --user 10000:10000 \
      -v "${app}:/opt/data:rw${z}" \
      -v "${app}:${app}:rw${z}" \
      -e "HERMES_HOME=${app}" \
      -e "HOME=${app}" \
      -w "$app" \
      --entrypoint sh \
      "$image" \
      -c "$1"
  fi
}

install_himalaya_binary() {
  local app bin ver arch url tmp
  app="$(hermes_app_dir)"
  bin="${app}/bin/himalaya"
  ver="${HIMALAYA_VERSION:-v1.2.0}"
  arch="$(detect_himalaya_arch)" || return 1

  if app_shell "test -x \"\$HERMES_HOME/bin/himalaya\" && \"\$HERMES_HOME/bin/himalaya\" --version >/dev/null 2>&1"; then
    echo "Himalaya already installed: $(app_shell "\"\$HERMES_HOME/bin/himalaya\" --version" 2>/dev/null | head -1)"
    return 0
  fi

  url="https://github.com/pimalaya/himalaya/releases/download/${ver}/himalaya.${arch}.tgz"
  echo "Downloading Himalaya ${ver} (${arch}) ..."
  tmp="$(mktemp -d)"
  # Download on host (network), extract, copy into app volume via container UID.
  if ! curl -fsSL "$url" -o "${tmp}/himalaya.tgz"; then
    echo "Failed to download ${url}" >&2
    rm -rf "$tmp"
    return 1
  fi
  tar -xzf "${tmp}/himalaya.tgz" -C "$tmp"
  if [[ ! -f "${tmp}/himalaya" ]]; then
    # some archives nest the binary
    local found
    found="$(find "$tmp" -type f -name himalaya | head -1)"
    if [[ -z "$found" ]]; then
      echo "himalaya binary missing from archive" >&2
      rm -rf "$tmp"
      return 1
    fi
    mv "$found" "${tmp}/himalaya"
  fi
  chmod 755 "${tmp}/himalaya"

  local name="${HERMES_CONTAINER:-hermes}"
  if container_is_running "$name"; then
    if ! podman exec -u hermes -e "HERMES_HOME=${app}" "$name" \
      sh -c 'mkdir -p "$HERMES_HOME/bin"'; then
      echo "Failed to create ${app}/bin in running container" >&2
      rm -rf "$tmp"
      return 1
    fi
    if ! podman cp "${tmp}/himalaya" "${name}:${app}/bin/himalaya"; then
      echo "Failed to copy himalaya into container" >&2
      rm -rf "$tmp"
      return 1
    fi
    podman exec -u root "$name" chown 10000:10000 "${app}/bin/himalaya"
    podman exec -u root "$name" chmod 755 "${app}/bin/himalaya"
  else
    # Rootless: do not bind-mount mktemp (0700) into --user 10000 — UID 10000
    # cannot traverse it. Install via userns root + chown hermes.
    prepare_app_for_container
    if ! podman unshare bash -c "
      set -e
      mkdir -p $(printf '%q' "${app}/bin")
      cp $(printf '%q' "${tmp}/himalaya") $(printf '%q' "$bin")
      chown 10000:10000 $(printf '%q' "$bin")
      chmod 755 $(printf '%q' "$bin")
    "; then
      echo "Failed to install himalaya into ${bin}" >&2
      rm -rf "$tmp"
      return 1
    fi
  fi
  rm -rf "$tmp"
  echo "Installed ${bin}"
  if ! app_shell "\"\$HERMES_HOME/bin/himalaya\" --version"; then
    echo "Warning: himalaya installed but --version failed" >&2
  fi
}

write_himalaya_secrets() {
  local password="$1"
  local app
  app="$(hermes_app_dir)"
  [[ -n "$password" ]] || {
    echo "write_himalaya_secrets: empty password" >&2
    return 1
  }

  # Pass password via env into container shell (avoid embedding in script files beyond .pass).
  local name="${HERMES_CONTAINER:-hermes}"
  if container_is_running "$name"; then
    if ! podman exec -u hermes \
      -e "HERMES_HOME=${app}" \
      -e "HERMES_MAIL_PASSWORD=${password}" \
      "$name" sh -c '
set -e
mkdir -p "$HERMES_HOME/secrets/himalaya"
printf "%s\n" "$HERMES_MAIL_PASSWORD" >"$HERMES_HOME/secrets/himalaya/imap.pass"
cp "$HERMES_HOME/secrets/himalaya/imap.pass" "$HERMES_HOME/secrets/himalaya/smtp.pass"
cat >"$HERMES_HOME/secrets/himalaya/imap.sh" <<EOF
#!/bin/sh
cat /opt/data/secrets/himalaya/imap.pass
EOF
cp "$HERMES_HOME/secrets/himalaya/imap.sh" "$HERMES_HOME/secrets/himalaya/smtp.sh"
chmod 700 "$HERMES_HOME/secrets/himalaya"
chmod 700 "$HERMES_HOME/secrets/himalaya"/*.sh
chmod 600 "$HERMES_HOME/secrets/himalaya"/*.pass
'; then
      echo "write_himalaya_secrets: failed in running container" >&2
      return 1
    fi
  else
    local z
    z="$(selinux_mount_suffix)"
    prepare_app_for_container
    if ! podman run --rm \
      --user 10000:10000 \
      -v "${app}:${app}:rw${z}" \
      -e "HERMES_HOME=${app}" \
      -e "HERMES_MAIL_PASSWORD=${password}" \
      --entrypoint sh \
      "${HERMES_IMAGE:-docker.io/nousresearch/hermes-agent:latest}" \
      -c '
set -e
mkdir -p "$HERMES_HOME/secrets/himalaya"
printf "%s\n" "$HERMES_MAIL_PASSWORD" >"$HERMES_HOME/secrets/himalaya/imap.pass"
cp "$HERMES_HOME/secrets/himalaya/imap.pass" "$HERMES_HOME/secrets/himalaya/smtp.pass"
cat >"$HERMES_HOME/secrets/himalaya/imap.sh" <<EOF
#!/bin/sh
cat /opt/data/secrets/himalaya/imap.pass
EOF
cp "$HERMES_HOME/secrets/himalaya/imap.sh" "$HERMES_HOME/secrets/himalaya/smtp.sh"
chmod 700 "$HERMES_HOME/secrets/himalaya"
chmod 700 "$HERMES_HOME/secrets/himalaya"/*.sh
chmod 600 "$HERMES_HOME/secrets/himalaya"/*.pass
'; then
      echo "write_himalaya_secrets: failed" >&2
      return 1
    fi
  fi
  echo "Wrote secrets under ${app}/secrets/himalaya/"
}

write_himalaya_config() {
  local email="${HERMES_EMAIL:-hermes@agenthood.me}"
  local display="${HERMES_EMAIL_DISPLAY_NAME:-Hermes Trimegisto}"
  local smtp_port="${HERMES_SMTP_PORT:-587}"
  local smtp_enc="${HERMES_SMTP_ENCRYPTION:-start-tls}"
  local app
  app="$(hermes_app_dir)"

  local name="${HERMES_CONTAINER:-hermes}"
  local script
  script=$(cat <<EOF
set -e
HOME_DIR="\$HERMES_HOME/sandboxes/docker/default/home"
mkdir -p "\$HOME_DIR/.config/himalaya"
cat >"\$HOME_DIR/.config/himalaya/config.toml" <<'TOML'
[accounts.default]
email = "${email}"
display-name = "${display}"
default = true

backend.type = "imap"
backend.host = "imap.migadu.com"
backend.port = 993
backend.encryption.type = "tls"
backend.login = "${email}"
backend.auth.type = "password"
backend.auth.cmd = "/opt/data/secrets/himalaya/imap.sh"

message.send.backend.type = "smtp"
message.send.backend.host = "smtp.migadu.com"
message.send.backend.port = ${smtp_port}
message.send.backend.encryption.type = "${smtp_enc}"
message.send.backend.login = "${email}"
message.send.backend.auth.type = "password"
message.send.backend.auth.cmd = "/opt/data/secrets/himalaya/smtp.sh"

folder.aliases.inbox = "INBOX"
folder.aliases.sent = "Sent"
folder.aliases.drafts = "Drafts"
folder.aliases.trash = "Trash"
TOML
chmod 600 "\$HOME_DIR/.config/himalaya/config.toml"
EOF
)
  if container_is_running "$name"; then
    if ! podman exec -u hermes -e "HERMES_HOME=${app}" "$name" sh -c "$script"; then
      echo "write_himalaya_config: failed in running container" >&2
      return 1
    fi
  else
    local z
    z="$(selinux_mount_suffix)"
    prepare_app_for_container
    if ! podman run --rm --user 10000:10000 \
      -v "${app}:${app}:rw${z}" \
      -e "HERMES_HOME=${app}" \
      --entrypoint sh \
      "${HERMES_IMAGE:-docker.io/nousresearch/hermes-agent:latest}" \
      -c "$script"; then
      echo "write_himalaya_config: failed" >&2
      return 1
    fi
  fi
  echo "Wrote Himalaya config for ${email}"
}

write_himalaya_helpers() {
  local email="${HERMES_EMAIL:-hermes@agenthood.me}"
  local display="${HERMES_EMAIL_DISPLAY_NAME:-Hermes Trimegisto}"
  local app src tmp
  app="$(hermes_app_dir)"
  src="${HERMES_ROOT}/scripts/himalaya"
  tmp="$(mktemp -d)"

  mkdir -p "$tmp/scripts"
  cp "$src/himalaya-inbox.sh" "$src/himalaya-read.sh" "$src/himalaya-delete.sh" "$tmp/scripts/"
  sed -e "s|__EMAIL__|${email}|g" -e "s|__DISPLAY_NAME__|${display}|g" \
    "$src/himalaya-send.sh.in" >"$tmp/scripts/himalaya-send.sh"
  sed -e "s|__EMAIL__|${email}|g" -e "s|__DISPLAY_NAME__|${display}|g" \
    "$src/SKILL.md.in" >"$tmp/SKILL.md"
  chmod 755 "$tmp/scripts"/*.sh

  local name="${HERMES_CONTAINER:-hermes}"
  local dest_scripts="${app}/sandboxes/docker/default/workspace/scripts"
  local dest_skill="${app}/skills/email/himalaya"

  if container_is_running "$name"; then
    if ! podman exec -u hermes -e "HERMES_HOME=${app}" "$name" \
      sh -c "mkdir -p \"$dest_scripts\" \"$dest_skill\""; then
      echo "Failed to create himalaya helper dirs in container" >&2
      rm -rf "$tmp"
      return 1
    fi
    if ! podman cp "$tmp/scripts/." "${name}:${dest_scripts}/" \
      || ! podman cp "$tmp/SKILL.md" "${name}:${dest_skill}/SKILL.md"; then
      echo "Failed to copy himalaya helpers into container" >&2
      rm -rf "$tmp"
      return 1
    fi
    podman exec -u root "$name" sh -c \
      "chown -R 10000:10000 \"$dest_scripts\" \"$dest_skill\" && chmod 755 \"$dest_scripts\"/*.sh && chmod 644 \"$dest_skill/SKILL.md\""
  else
    # Same rootless pitfall as install_himalaya_binary: mktemp is 0700 and
    # --user 10000 cannot read a bind-mounted /in. Copy via userns instead.
    prepare_app_for_container
    if ! podman unshare bash -c "
      set -e
      mkdir -p $(printf '%q' "$dest_scripts") $(printf '%q' "$dest_skill")
      cp -a $(printf '%q' "$tmp/scripts")/. $(printf '%q' "$dest_scripts")/
      cp $(printf '%q' "$tmp/SKILL.md") $(printf '%q' "${dest_skill}/SKILL.md")
      chown -R 10000:10000 $(printf '%q' "$dest_scripts") $(printf '%q' "$dest_skill")
      chmod 755 $(printf '%q' "$dest_scripts")/*.sh
      chmod 644 $(printf '%q' "${dest_skill}/SKILL.md")
    "; then
      echo "Failed to install himalaya helpers into ${dest_scripts}" >&2
      rm -rf "$tmp"
      return 1
    fi
  fi
  rm -rf "$tmp"
  echo "Helpers → ${dest_scripts}/"
  echo "Skill → ${dest_skill}/SKILL.md"
}

# Idempotent Himalaya layout. Downloads binary; writes config/helpers.
# Writes secrets only when HERMES_MAIL_PASSWORD is set.
ensure_himalaya() {
  local email="${HERMES_EMAIL:-}"
  [[ -n "$email" ]] || return 0

  install_himalaya_binary || return 1
  write_himalaya_config || return 1
  write_himalaya_helpers || return 1
  if [[ -n "${HERMES_MAIL_PASSWORD:-}" ]]; then
    write_himalaya_secrets "$HERMES_MAIL_PASSWORD" || return 1
  elif ! app_shell "test -f \"\$HERMES_HOME/secrets/himalaya/imap.pass\""; then
    echo "Note: HERMES_MAIL_PASSWORD unset and no secrets yet — run: ./hermes.sh himalaya-password" >&2
  fi
  # Refresh sandbox mounts / SMTP pin when gateway is up.
  if container_is_running "${HERMES_CONTAINER:-hermes}"; then
    ensure_sandbox_volumes || true
  fi
}

himalaya_test() {
  local app name smtp_ip
  app="$(hermes_app_dir)"
  name="${HERMES_CONTAINER:-hermes}"
  smtp_ip="${MIGADU_SMTP_IPV4:-141.94.97.118}"

  if ! app_shell "test -x \"\$HERMES_HOME/bin/himalaya\""; then
    echo "himalaya binary missing — run: ./hermes.sh himalaya-install" >&2
    return 1
  fi
  if ! app_shell "test -f \"\$HERMES_HOME/secrets/himalaya/imap.pass\""; then
    echo "mail password missing — run: ./hermes.sh himalaya-password" >&2
    return 1
  fi

  echo "Testing Himalaya IMAP + SMTP (pin ${smtp_ip}) via sandbox-equivalent mounts ..."
  # Run himalaya from the gateway container with sandbox HOME + secrets mounts paths.
  if container_is_running "$name"; then
    podman exec -i -u hermes \
      -e "HERMES_HOME=${app}" \
      -e "HOME=${app}/sandboxes/docker/default/home" \
      -e "PATH=${app}/bin:/opt/data/bin:/usr/bin:/bin" \
      -e "MIGADU_SMTP_IPV4=${smtp_ip}" \
      "$name" \
      sh -s <<'EOS'
set -e
himalaya --version
himalaya folder list
himalaya envelope list --folder INBOX --page-size 5 --output json | head -c 2000
echo
# SMTP reachability (the send failure mode: IMAP OK, SMTP hang).
python3 - <<'PY'
import os, socket, sys
ip = os.environ.get("MIGADU_SMTP_IPV4") or "141.94.97.118"
try:
    socket.create_connection((ip, 587), timeout=8).close()
except OSError as exc:
    print(f"ERROR: SMTP {ip}:587 unreachable — sends will hang ({exc})", file=sys.stderr)
    sys.exit(1)
print(f"SMTP {ip}:587 reachable")
PY
# Stale sandbox ExtraHosts still pinning a dead Migadu IP?
smtp_ip="${MIGADU_SMTP_IPV4:-141.94.97.118}"
if command -v docker >/dev/null 2>&1; then
  stale="$(docker ps -aq --filter label=hermes-agent=1 2>/dev/null || true)"
  for cid in $stale; do
    hosts="$(docker inspect -f "{{json .HostConfig.ExtraHosts}}" "$cid" 2>/dev/null || true)"
    case "$hosts" in
      *smtp.migadu.com*)
        case "$hosts" in
          *"${smtp_ip}"*) ;;
          *)
            echo "WARN: sandbox ${cid:0:12} ExtraHosts=$hosts (not pin ${smtp_ip}) — removing" >&2
            docker rm -f "$cid" >/dev/null 2>&1 || true
            ;;
        esac
        ;;
    esac
  done
fi
EOS
  else
    local z
    z="$(selinux_mount_suffix)"
    prepare_app_for_container
    podman run --rm \
      --user 10000:10000 \
      --add-host "smtp.migadu.com:${smtp_ip}" \
      -v "${app}:${app}:rw${z}" \
      -v "${app}/bin:/opt/data/bin:ro${z}" \
      -v "${app}/secrets:/opt/data/secrets:ro${z}" \
      -e "HERMES_HOME=${app}" \
      -e "HOME=${app}/sandboxes/docker/default/home" \
      -e "PATH=/opt/data/bin:/usr/bin:/bin" \
      --entrypoint sh \
      "${HERMES_IMAGE:-docker.io/nousresearch/hermes-agent:latest}" \
      -c 'himalaya --version && himalaya folder list && himalaya envelope list --folder INBOX --page-size 5 --output json | head -c 2000; echo; python3 -c "import socket; socket.create_connection(('"'${smtp_ip}'"', 587), timeout=8).close(); print(\"SMTP_OK\")"'
  fi
}

# --- Webhook TLS sidecar (pod mode) -----------------------------------------

hermes_is_pod_mode() {
  [[ "${HERMES_DEPLOY_MODE:-standalone}" == "pod" ]]
}

require_pod_webhook_env() {
  local missing=() envf
  [[ -n "${HERMES_PUBLIC_HOST:-}" ]] || missing+=("HERMES_PUBLIC_HOST")
  [[ -n "${HERMES_INGRESS_PORT:-}" ]] || missing+=("HERMES_INGRESS_PORT")
  if [[ -z "${WEBHOOK_SECRET:-}" ]]; then
    envf="$(hermes_gateway_env_file)"
    if [[ -r "$envf" ]] && grep -qE '^WEBHOOK_SECRET=.+' "$envf" 2>/dev/null; then
      :
    else
      missing+=("WEBHOOK_SECRET")
    fi
  fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Pod mode requires: ${missing[*]}" >&2
    echo "Set HERMES_PUBLIC_HOST / HERMES_INGRESS_PORT in $(hermes_env_file)" >&2
    echo "Set WEBHOOK_SECRET in $(hermes_gateway_env_file) (secrets store)" >&2
    return 1
  fi
}

# nginx owns HERMES_INGRESS_PORT (8443 for Telegram). The adapter must listen on
# a different pod-local port (8643) so nginx can proxy to it.
ensure_pod_internal_listen_ports() {
  hermes_is_pod_mode || return 0
  local envf ingress telegram
  envf="$(hermes_gateway_env_file)"
  ingress="${HERMES_INGRESS_PORT:-8443}"
  telegram="${TELEGRAM_WEBHOOK_PORT:-8443}"
  if [[ "$telegram" == "$ingress" ]]; then
    telegram=8643
    if [[ -f "$envf" ]]; then
      if grep -qE '^TELEGRAM_WEBHOOK_PORT=' "$envf" 2>/dev/null; then
        sed -i "s|^TELEGRAM_WEBHOOK_PORT=.*|TELEGRAM_WEBHOOK_PORT=${telegram}|" "$envf"
      else
        printf 'TELEGRAM_WEBHOOK_PORT=%s\n' "$telegram" >>"$envf"
      fi
    fi
    export TELEGRAM_WEBHOOK_PORT="$telegram"
    echo "Pod mode: TELEGRAM_WEBHOOK_PORT=${telegram} (nginx TLS on ${ingress})" >&2
  fi
}

ensure_webhook_pod_layout() {
  local app
  app="$(hermes_app_dir)"
  mkdir -p "$app/certs" "$app/nginx" "$app/logs/nginx" 2>/dev/null || true
  chmod 711 "$app/certs" 2>/dev/null || true
  chmod 755 "$app/nginx" "$app/logs" "$app/logs/nginx" 2>/dev/null || true
}

ensure_tls_certs() {
  local force="${1:-}"
  local cert_dir args=()
  ensure_webhook_pod_layout
  load_env
  cert_dir="$(hermes_app_dir)/certs"
  case "$force" in
    --force|1|true) args+=(--force) ;;
  esac
  [[ -n "${HERMES_PUBLIC_HOST:-}" ]] || {
    echo "HERMES_PUBLIC_HOST is required to generate TLS certs" >&2
    return 1
  }
  TLS_CN="${HERMES_PUBLIC_HOST}" \
    bash "${HERMES_ROOT}/scripts/generate-self-signed-certs.sh" "$cert_dir" "${args[@]}"
}

# Last step of setup: create self-signed PEMs if missing and print where they live.
setup_ensure_self_signed_certs() {
  local cert_dir host
  cert_dir="$(hermes_app_dir)/certs"
  mkdir -p "$cert_dir"
  echo ""
  echo "==> Self-signed TLS certificates"
  if [[ -s "${cert_dir}/fullchain.pem" && -s "${cert_dir}/privkey.pem" ]]; then
    echo "Already present (not overwritten):"
    echo "  ${cert_dir}/fullchain.pem"
    echo "  ${cert_dir}/privkey.pem"
    return 0
  fi
  host="${HERMES_PUBLIC_HOST:-}"
  if [[ -z "$host" ]]; then
    host="$(identyclaw_prompt_with_default "  Public hostname for TLS (Enter skips)" "")"
    if [[ -n "$host" ]]; then
      upsert_env_local_kv "$(hermes_env_file)" HERMES_PUBLIC_HOST "$host"
      export HERMES_PUBLIC_HOST="$host"
    fi
  fi
  if [[ -z "${HERMES_PUBLIC_HOST:-}" ]]; then
    echo "Not created — set HERMES_PUBLIC_HOST in env.local, then: ./hermes.sh generate-certs"
    return 0
  fi
  if ensure_tls_certs && [[ -s "${cert_dir}/fullchain.pem" && -s "${cert_dir}/privkey.pem" ]]; then
    echo "Created self-signed certificate (bootstrap TLS — replace with CA-issued PEMs when ready):"
    echo "  ${cert_dir}/fullchain.pem"
    echo "  ${cert_dir}/privkey.pem"
    return 0
  fi
  echo "Could not create self-signed certs — later: ./hermes.sh generate-certs" >&2
  return 1
}

normalize_tls_certs() {
  local cert_dir f
  cert_dir="$(hermes_app_dir)/certs"
  chmod 711 "$cert_dir" || true
  for f in privkey.pem tls.key; do
    if [[ -f "$cert_dir/$f" ]]; then
      podman unshare chown 101:101 "$cert_dir/$f" || true
      podman unshare chmod 600 "$cert_dir/$f" || true
    fi
  done
  for f in fullchain.pem chain.pem cert.pem tls.crt; do
    if [[ -f "$cert_dir/$f" ]]; then
      podman unshare chown 101:101 "$cert_dir/$f" || true
      podman unshare chmod 644 "$cert_dir/$f" || true
    fi
  done
}

ensure_hermes_nginx_conf() {
  local app conf
  ensure_webhook_pod_layout
  load_env
  require_pod_webhook_env || return 1
  prepare_hermes_nginx_host_files || return 1
  app="$(hermes_app_dir)"
  conf="${app}/nginx/nginx.conf"
  bash "${HERMES_ROOT}/scripts/render-nginx-conf.sh" "$conf"
}

# Copy nginx includes into APP_DIR and keep sidecar binds under the app dir only
# (never mount the git clone path — same rule as openclaw-agents).
prepare_hermes_nginx_host_files() {
  local app
  app="$(hermes_app_dir)"
  mkdir -p "${app}/nginx"
  if [[ -d "${HERMES_ROOT}/nginx/inc" ]]; then
    mkdir -p "${app}/nginx/inc"
    cp -a "${HERMES_ROOT}/nginx/inc/." "${app}/nginx/inc/"
  fi
  [[ -d "${app}/nginx/inc" ]] || {
    echo "missing ${app}/nginx/inc — expected copy from ${HERMES_ROOT}/nginx/inc" >&2
    return 1
  }
}

# Host bind sources for the nginx sidecar. All paths under APP_DIR.
# Prints "host_src:container_dst" (no SELinux suffix).
hermes_pod_nginx_bind_specs() {
  local app="${1:-$(hermes_app_dir)}"
  printf '%s\n' \
    "${app}/certs:/app/certs" \
    "${app}/logs/nginx:/var/log/nginx"
  if [[ -d "${app}/nginx/inc" ]]; then
    printf '%s\n' "${app}/nginx/inc:/etc/nginx/inc"
  fi
  printf '%s\n' "${app}/nginx/nginx.conf:/etc/nginx/nginx.conf"
}

ensure_pod_logs_for_container() {
  local log_dir="${1:?}"
  mkdir -p "$log_dir" 2>/dev/null || true
  # nginx image runs as uid 101
  podman unshare chown -R 101:101 "$log_dir" 2>/dev/null || true
  chmod 755 "$log_dir" 2>/dev/null || true
}

build_hermes_nginx_image() {
  local ingress
  load_env
  ingress="${HERMES_INGRESS_PORT:-8443}"
  echo "Building ${HERMES_NGINX_IMAGE} (INGRESS_PORT=${ingress}) ..."
  podman build \
    -f "${HERMES_ROOT}/nginx.Dockerfile" \
    -t "${HERMES_NGINX_IMAGE}" \
    --build-arg "INGRESS_PORT=${ingress}" \
    "${HERMES_ROOT}"
}

# Seed platforms.webhook in config.yaml when missing (structure only — never
# write WEBHOOK_SECRET into config; that lives in .env via --env-file).
# Also strips a previously seeded secret key from platforms.webhook if present.
ensure_webhook_config_seed() {
  local app cfg
  app="$(hermes_app_dir)"
  cfg="${app}/config.yaml"
  [[ -f "$cfg" ]] || return 0
  load_env
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$cfg" "${WEBHOOK_PORT:-8644}" <<'PY'
import pathlib, re, sys

cfg_path, port = pathlib.Path(sys.argv[1]), sys.argv[2]
text = cfg_path.read_text()
lines = text.splitlines(keepends=True)
out: list[str] = []
changed = False

# Track nesting: platforms: → webhook: → (optional) extra:
in_platforms = False
in_webhook = False
platforms_indent = -1
webhook_indent = -1

for line in lines:
    raw = line.rstrip("\n")
    stripped = raw.lstrip(" ")
    indent = len(raw) - len(stripped) if stripped else 0

    if re.match(r"^platforms:\s*(#.*)?$", raw):
        in_platforms = True
        platforms_indent = indent
        in_webhook = False
        out.append(line)
        continue

    if in_platforms and stripped and indent <= platforms_indent and not stripped.startswith("#"):
        in_platforms = False
        in_webhook = False

    if in_platforms and re.match(r"^webhook:\s*(#.*)?$", stripped):
        in_webhook = True
        webhook_indent = indent
        out.append(line)
        continue

    if in_webhook:
        if stripped and indent <= webhook_indent and not stripped.startswith("#"):
            in_webhook = False
        elif re.match(r"^secret:\s*", stripped):
            changed = True
            continue

    out.append(line)

text = "".join(out)
if changed:
    cfg_path.write_text(text if text.endswith("\n") else text + "\n")
    print("Removed platforms.webhook secret from config.yaml (use .env WEBHOOK_SECRET)")

if "platforms:" in text and re.search(r"(?m)^\s*webhook:\s*$", text):
    if not changed:
        print("config.yaml already has platforms.webhook")
    raise SystemExit(0)

block = f"""
# hermes.sh pod webhook seed (managed) — secret lives in .env (WEBHOOK_SECRET)
platforms:
  webhook:
    enabled: true
    extra:
      host: "0.0.0.0"
      port: {port}
      routes: {{}}
"""
cfg_path.write_text(text.rstrip() + "\n" + block)
print(f"Appended platforms.webhook seed (no secret) to {cfg_path}")
PY
}

stop_hermes_pod_stack() {
  local name nginx_name pod_name
  load_env
  name="${HERMES_CONTAINER:-hermes}"
  nginx_name="${HERMES_NGINX_CONTAINER:-hermes-nginx}"
  pod_name="${HERMES_POD:-hermes-agent-pod}"
  podman stop "$name" 2>/dev/null || true
  podman rm -f "$name" 2>/dev/null || true
  podman stop "$nginx_name" 2>/dev/null || true
  podman rm -f "$nginx_name" 2>/dev/null || true
  if podman pod exists "$pod_name" 2>/dev/null; then
    podman pod rm -f "$pod_name" 2>/dev/null || true
  fi
}

identyclaw_format_contact_uri() {
  local explicit="${1:-}" tg="${2:-}" email="${3:-}" domain
  explicit="${explicit//[[:space:]]/}"
  if [[ -n "$explicit" ]]; then
    printf '%s' "$explicit"
    return 0
  fi
  tg="${tg#@}"
  tg="${tg//[[:space:]]/}"
  if [[ -n "$tg" ]]; then
    printf 'telegram:telegram.com:@%s' "$tg"
    return 0
  fi
  email="${email//[[:space:]]/}"
  if [[ -n "$email" && "$email" == *@* ]]; then
    domain="${email#*@}"
    printf 'email:%s:%s' "$domain" "$email"
    return 0
  fi
}

print_passport_field() {
  local name="$1" value="${2:-}" collect_hint="${3:-enter on purchase.identyclaw.com}"
  if [[ -n "$value" ]]; then
    printf '  %-22s [selected]  %s\n' "$name" "$value"
  else
    printf '  %-22s [collect]   %s\n' "$name" "$collect_hint"
  fi
}

print_passport_webhook_field() {
  local name="$1" value="${2:-}"
  if [[ -z "$value" ]]; then
    print_passport_field "$name" "" "public HTTPS A2A / webhook URL"
    return 0
  fi
  if [[ "$value" == *127.0.0.1* || "$value" == *localhost* ]]; then
    printf '  %-22s [collect]   %s  (loopback — paste a public HTTPS URL on the portal)\n' "$name" "$value"
    return 0
  fi
  print_passport_field "$name" "$value" ""
}

identyclaw_prompt_with_default() {
  local prompt="$1" default="${2:-}" var=""
  if [[ ! -t 0 ]] || [[ "${SKIP_SETUP_PROMPTS:-0}" == "1" ]]; then
    printf '%s' "$default"
    return 0
  fi
  if [[ -n "$default" ]]; then
    read -r -p "${prompt} [${default}]: " var || true
  else
    read -r -p "${prompt}: " var || true
  fi
  printf '%s' "${var:-$default}"
}

identyclaw_prompt_secret() {
  local prompt="$1" var=""
  if [[ ! -t 0 ]] || [[ "${SKIP_SETUP_PROMPTS:-0}" == "1" ]]; then
    return 0
  fi
  read -r -s -p "${prompt}: " var || true
  echo >&2
  printf '%s' "$var"
}

hermes_passport_webhook_url() {
  local host port url
  if [[ -n "${IDENTYCLAW_WEBHOOK_URL:-}" ]]; then
    printf '%s' "$IDENTYCLAW_WEBHOOK_URL"
    return 0
  fi
  host="${HERMES_PUBLIC_HOST:-}"
  port="${HERMES_INGRESS_PORT:-${HERMES_TELEGRAM_PORT:-8443}}"
  if [[ -n "$host" ]]; then
    printf 'https://%s:%s' "$host" "$port"
    return 0
  fi
  url="${TELEGRAM_WEBHOOK_URL:-${WEBHOOK_PUBLIC_URL:-}}"
  if [[ -n "$url" ]]; then
    printf '%s' "$url"
  fi
}

hermes_passport_contact_uri() {
  identyclaw_format_contact_uri \
    "${IDENTYCLAW_CONTACT_URI:-}" \
    "${TELEGRAM_BOT_USERNAME:-}" \
    "${HERMES_EMAIL:-}"
}

print_passport_purchase_guide() {
  local account_id="${1:?}" webhook_url="${2:-}" avatar_url="${3:-}" contact_uri="${4:-}" label="${5:-}"
  echo ""
  echo "──────────────────────────────────────────────────────────────"
  if [[ -n "$label" ]]; then
    echo "Craft your Passport for ${label} at https://purchase.identyclaw.com"
  else
    echo "Craft your Passport at https://purchase.identyclaw.com"
  fi
  echo "──────────────────────────────────────────────────────────────"
  echo "1. Fund a SEPARATE checkout wallet with NEAR (e.g. HOT Wallet)."
  echo "   Do not paste the agent key file into chat or the portal."
  echo "2. Open: https://purchase.identyclaw.com"
  echo "3. Paste this 64-char hex as the NEAR recipient account:"
  echo ""
  echo "   ${account_id}"
  echo ""
  echo "4. Fill the Passport form. Values already collected by setup are [selected]:"
  print_passport_webhook_field "A2A / webhook URL" "$webhook_url"
  print_passport_field "Avatar image URL" "$avatar_url" "https://identyclaw.com/avatar.png (portal default) or any https image"
  print_passport_field "ContactURI" "$contact_uri" "scheme:authority:identifier  e.g. telegram:telegram.com:@YourBot  or  email:domain:you@domain"
  echo ""
  echo "   Also collect on the portal: name, creature/role, traits, longevity."
  echo "5. Connect the paying wallet, mint, wait for confirmation."
  echo "   Docs: https://www.discernible.io/  ·  https://api.identyclaw.com/.well-known/enrollment"
  echo "──────────────────────────────────────────────────────────────"
}

# Upsert KEY=VALUE in env.local. Works when the app tree is host-owned OR
# owned by container UID 10000 (after prepare_app_for_container / himalaya).
_upsert_env_local_kv_python() {
  python3 - "$1" "$2" "$3" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
key, value = sys.argv[2], sys.argv[3]
text = path.read_text() if path.is_file() else ""
lines = text.splitlines(True)
prefix = f"{key}="
out, found = [], False
for line in lines:
    stripped = line.lstrip()
    if stripped.startswith(prefix) and not stripped.startswith("#"):
        out.append(f"{key}={value}\n")
        found = True
    else:
        out.append(line)
if not found:
    if out and not str(out[-1]).endswith("\n"):
        out.append("\n")
    out.append(f"{key}={value}\n")
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text("".join(out))
PY
}

upsert_env_local_kv() {
  local file="${1:?}" key="${2:?}" value="${3:-}"
  local dir tmp host_ok=0
  [[ -n "$value" ]] || return 0
  dir="$(dirname "$file")"

  # Host-writable path (after restore_app_ownership / before prepare).
  # Note: when the parent is 0700/UID 10000, host [[ -e ]] is false even if
  # the file exists — never treat that as "create fresh".
  if [[ -r "$file" && -w "$file" ]]; then
    host_ok=1
  elif [[ ! -e "$file" && -w "$dir" ]]; then
    # Parent is host-writable and the path truly does not exist (or is
    # invisible — but then -w dir would also fail for 0700/10000 trees).
    host_ok=1
  fi
  if [[ "$host_ok" == 1 ]]; then
    _upsert_env_local_kv_python "$file" "$key" "$value"
    return
  fi

  # Container-owned tree: host python cannot even stat env.local. Edit via
  # userns root, then keep hermes ownership when the parent is UID 10000.
  tmp="$(mktemp)"
  # Always try userns read first — host -e/-r lie on 0700 hermes dirs.
  if podman unshare test -e "$file" 2>/dev/null; then
    if ! podman unshare cat "$file" >"$tmp" 2>/dev/null; then
      echo "upsert_env_local_kv: cannot read ${file}" >&2
      rm -f "$tmp"
      return 1
    fi
  else
    : >"$tmp"
  fi
  if ! _upsert_env_local_kv_python "$tmp" "$key" "$value"; then
    rm -f "$tmp"
    return 1
  fi
  if ! podman unshare bash -c "
    set -e
    dest=$(printf '%q' "$file")
    src=$(printf '%q' "$tmp")
    mkdir -p \"\$(dirname \"\$dest\")\"
    cp \"\$src\" \"\$dest\"
    parent=\"\$(dirname \"\$dest\")\"
    if [[ \"\$(stat -c %u \"\$parent\")\" == 10000 ]]; then
      chown 10000:10000 \"\$dest\"
    fi
    chmod 600 \"\$dest\"
  "; then
    echo "upsert_env_local_kv: cannot write ${file}" >&2
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
}


