#!/usr/bin/env bash
# Himalaya / Migadu helpers for hermes.sh (single- or multi-account).
# Sourced from lib.sh — expects hermes_app_dir, app_shell, container_is_running, etc.

# Mail account lines: name|email|display|is_default (1|0)
# Sources (first match wins):
#   1) HERMES_MAIL_IMPORT_DIR + smtp.env (infra-app/mail layout)
#   2) HERMES_MAIL_ACCOUNTS + HERMES_MAIL_<ACCT>_EMAIL / _FROM_NAME
#   3) legacy single HERMES_EMAIL
# Read KEY from infra-app smtp.env without sourcing (FROM_NAME may be unquoted).
himalaya_smtp_env_get() {
  local file="${1:?}" key="${2:?}" line val
  line="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -1 || true)"
  [[ -n "$line" ]] || return 1
  val="${line#*=}"
  # Strip optional surrounding quotes
  if [[ "$val" == \"*\" ]]; then
    val="${val:1:${#val}-2}"
  elif [[ "$val" == \'*\' ]]; then
    val="${val:1:${#val}-2}"
  fi
  printf '%s\n' "$val"
}

himalaya_account_defs() {
  local dir accounts default acct email display upper first=1
  dir="${HERMES_MAIL_IMPORT_DIR:-}"
  if [[ -n "$dir" && -r "${dir}/smtp.env" ]]; then
    accounts="$(himalaya_smtp_env_get "${dir}/smtp.env" SMTP_ACCOUNTS || true)"
    default="${HERMES_MAIL_DEFAULT:-}"
    if [[ -z "$default" ]]; then
      default="$(himalaya_smtp_env_get "${dir}/smtp.env" SMTP_DEFAULT || true)"
    fi
    if [[ -n "$accounts" ]]; then
      local -a _himalaya_accts=()
      IFS=',' read -r -a _himalaya_accts <<<"$accounts"
      for acct in "${_himalaya_accts[@]}"; do
        acct="$(echo "$acct" | tr -d '[:space:]')"
        [[ -n "$acct" ]] || continue
        upper="$(echo "$acct" | tr '[:lower:]' '[:upper:]')"
        email="$(himalaya_smtp_env_get "${dir}/smtp.env" "SMTP_${upper}_EMAIL" || true)"
        display="$(himalaya_smtp_env_get "${dir}/smtp.env" "SMTP_${upper}_FROM_NAME" || true)"
        [[ -n "$email" ]] || continue
        [[ -n "$display" ]] || display="${HERMES_EMAIL_DISPLAY_NAME:-Hermes Trimegisto}"
        if [[ -z "$default" && "$first" == "1" ]]; then
          default="$acct"
        fi
        if [[ "$acct" == "$default" ]]; then
          printf '%s|%s|%s|1\n' "$acct" "$email" "$display"
        else
          printf '%s|%s|%s|0\n' "$acct" "$email" "$display"
        fi
        first=0
      done
      return 0
    fi
  fi

  accounts="${HERMES_MAIL_ACCOUNTS:-}"
  if [[ -n "$accounts" ]]; then
    default="${HERMES_MAIL_DEFAULT:-}"
    local -a _himalaya_accts=()
    IFS=',' read -r -a _himalaya_accts <<<"$accounts"
    for acct in "${_himalaya_accts[@]}"; do
      acct="$(echo "$acct" | tr -d '[:space:]')"
      [[ -n "$acct" ]] || continue
      upper="$(echo "$acct" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"
      key="HERMES_MAIL_${upper}_EMAIL"
      email="${!key:-}"
      key="HERMES_MAIL_${upper}_FROM_NAME"
      display="${!key:-}"
      [[ -n "$email" ]] || {
        echo "himalaya_account_defs: missing HERMES_MAIL_${upper}_EMAIL for ${acct}" >&2
        return 1
      }
      [[ -n "$display" ]] || display="${HERMES_EMAIL_DISPLAY_NAME:-Hermes Trimegisto}"
      if [[ -z "$default" && "$first" == "1" ]]; then
        default="$acct"
      fi
      if [[ "$acct" == "$default" ]]; then
        printf '%s|%s|%s|1\n' "$acct" "$email" "$display"
      else
        printf '%s|%s|%s|0\n' "$acct" "$email" "$display"
      fi
      first=0
    done
    return 0
  fi

  email="${HERMES_EMAIL:-}"
  [[ -n "$email" ]] || return 0
  display="${HERMES_EMAIL_DISPLAY_NAME:-Hermes Trimegisto}"
  printf 'default|%s|%s|1\n' "$email" "$display"
}

himalaya_default_account() {
  local line name
  while IFS= read -r line; do
    IFS='|' read -r name _ _ def <<<"$line"
    if [[ "$def" == "1" ]]; then
      printf '%s\n' "$name"
      return 0
    fi
  done < <(himalaya_account_defs)
  return 1
}

himalaya_has_accounts() {
  himalaya_account_defs | grep -q .
}

# Write one account password + auth helper under secrets/himalaya/<name>.{pass,sh}.
# Also mirrors default account to legacy imap.pass/smtp.pass (+ .sh) for older helpers.
write_himalaya_account_secret() {
  local acct="${1:?}"
  local password="${2:?}"
  local is_default="${3:-0}"
  local app name script z
  app="$(hermes_app_dir)"
  [[ -n "$password" ]] || {
    echo "write_himalaya_account_secret: empty password for ${acct}" >&2
    return 1
  }
  name="${HERMES_CONTAINER:-hermes}"

  script=$(cat <<'EOS'
set -e
acct="$HERMES_MAIL_ACCT"
pass="$HERMES_MAIL_PASSWORD"
def="$HERMES_MAIL_IS_DEFAULT"
mkdir -p "$HERMES_HOME/secrets/himalaya"
printf "%s\n" "$pass" >"$HERMES_HOME/secrets/himalaya/${acct}.pass"
cat >"$HERMES_HOME/secrets/himalaya/${acct}.sh" <<EOF
#!/bin/sh
cat /opt/data/secrets/himalaya/${acct}.pass
EOF
chmod 700 "$HERMES_HOME/secrets/himalaya"
chmod 700 "$HERMES_HOME/secrets/himalaya/${acct}.sh"
chmod 600 "$HERMES_HOME/secrets/himalaya/${acct}.pass"
if [ "$def" = "1" ] || [ "$acct" = "default" ]; then
  cp "$HERMES_HOME/secrets/himalaya/${acct}.pass" "$HERMES_HOME/secrets/himalaya/imap.pass"
  cp "$HERMES_HOME/secrets/himalaya/${acct}.pass" "$HERMES_HOME/secrets/himalaya/smtp.pass"
  cat >"$HERMES_HOME/secrets/himalaya/imap.sh" <<EOF
#!/bin/sh
cat /opt/data/secrets/himalaya/imap.pass
EOF
  cp "$HERMES_HOME/secrets/himalaya/imap.sh" "$HERMES_HOME/secrets/himalaya/smtp.sh"
  chmod 700 "$HERMES_HOME/secrets/himalaya/imap.sh" "$HERMES_HOME/secrets/himalaya/smtp.sh"
  chmod 600 "$HERMES_HOME/secrets/himalaya/imap.pass" "$HERMES_HOME/secrets/himalaya/smtp.pass"
fi
EOS
)

  if container_is_running "$name"; then
    if ! podman exec -u hermes \
      -e "HERMES_HOME=${app}" \
      -e "HERMES_MAIL_ACCT=${acct}" \
      -e "HERMES_MAIL_PASSWORD=${password}" \
      -e "HERMES_MAIL_IS_DEFAULT=${is_default}" \
      "$name" sh -c "$script"; then
      echo "write_himalaya_account_secret: failed in running container (${acct})" >&2
      return 1
    fi
  else
    z="$(selinux_mount_suffix)"
    prepare_app_for_container
    if ! podman run --rm \
      --user 10000:10000 \
      -v "${app}:${app}:rw${z}" \
      -e "HERMES_HOME=${app}" \
      -e "HERMES_MAIL_ACCT=${acct}" \
      -e "HERMES_MAIL_PASSWORD=${password}" \
      -e "HERMES_MAIL_IS_DEFAULT=${is_default}" \
      --entrypoint sh \
      "${HERMES_IMAGE:-docker.io/nousresearch/hermes-agent:latest}" \
      -c "$script"; then
      echo "write_himalaya_account_secret: failed (${acct})" >&2
      return 1
    fi
  fi
  echo "Wrote secret for account ${acct}"
}

# Legacy single-password entry point (default / only account).
write_himalaya_secrets() {
  local password="${1:?}"
  local acct
  acct="$(himalaya_default_account 2>/dev/null || true)"
  acct="${acct:-default}"
  write_himalaya_account_secret "$acct" "$password" 1
}

# Copy Migadu passwords from infra-app/mail (smtp-password.<acct>) into hermes secrets.
# Does not print password material.
import_himalaya_passwords_from_dir() {
  local dir="${1:-${HERMES_MAIL_IMPORT_DIR:-}}"
  local line acct email display def src password missing=0
  [[ -n "$dir" && -d "$dir" ]] || {
    echo "import_himalaya_passwords_from_dir: need HERMES_MAIL_IMPORT_DIR (got: ${dir:-empty})" >&2
    return 1
  }
  while IFS= read -r line; do
    IFS='|' read -r acct email display def <<<"$line"
    src="${dir}/smtp-password.${acct}"
    if [[ ! -r "$src" ]]; then
      if [[ "$def" == "1" && -r "${dir}/smtp-password" ]]; then
        src="${dir}/smtp-password"
      else
        echo "Missing ${dir}/smtp-password.${acct}" >&2
        missing=1
        continue
      fi
    fi
    password="$(tr -d '\r\n' <"$src")"
    write_himalaya_account_secret "$acct" "$password" "$def" || return 1
  done < <(himalaya_account_defs)
  [[ "$missing" == "0" ]] || return 1
}

write_himalaya_config() {
  local smtp_port="${HERMES_SMTP_PORT:-587}"
  local smtp_enc="${HERMES_SMTP_ENCRYPTION:-start-tls}"
  local app name line acct email display def auth_cmd smtp_cmd toml tmp dest_cfg
  local -a lines=()
  app="$(hermes_app_dir)"

  while IFS= read -r line; do
    lines+=("$line")
  done < <(himalaya_account_defs)
  if [[ ${#lines[@]} -eq 0 ]]; then
    echo "write_himalaya_config: no mail accounts (set HERMES_MAIL_IMPORT_DIR, HERMES_MAIL_ACCOUNTS, or HERMES_EMAIL)" >&2
    return 1
  fi

  toml="# Generated by hermes.sh himalaya-install. Do not edit by hand."$'\n'
  for line in "${lines[@]}"; do
    IFS='|' read -r acct email display def <<<"$line"
    if [[ "$acct" == "default" ]]; then
      auth_cmd="/opt/data/secrets/himalaya/imap.sh"
      smtp_cmd="/opt/data/secrets/himalaya/smtp.sh"
    else
      auth_cmd="/opt/data/secrets/himalaya/${acct}.sh"
      smtp_cmd="$auth_cmd"
    fi
    toml+="
[accounts.${acct}]
email = \"${email}\"
display-name = \"${display}\"
default = $([[ "$def" == "1" ]] && echo true || echo false)

backend.type = \"imap\"
backend.host = \"imap.migadu.com\"
backend.port = 993
backend.encryption.type = \"tls\"
backend.login = \"${email}\"
backend.auth.type = \"password\"
backend.auth.cmd = \"${auth_cmd}\"

message.send.backend.type = \"smtp\"
message.send.backend.host = \"smtp.migadu.com\"
message.send.backend.port = ${smtp_port}
message.send.backend.encryption.type = \"${smtp_enc}\"
message.send.backend.login = \"${email}\"
message.send.backend.auth.type = \"password\"
message.send.backend.auth.cmd = \"${smtp_cmd}\"

folder.aliases.inbox = \"INBOX\"
folder.aliases.sent = \"Sent\"
folder.aliases.drafts = \"Drafts\"
folder.aliases.trash = \"Trash\"
"
  done

  tmp="$(mktemp)"
  printf '%s' "$toml" >"$tmp"
  name="${HERMES_CONTAINER:-hermes}"
  dest_cfg="${app}/sandboxes/docker/default/home/.config/himalaya"

  if container_is_running "$name"; then
    if ! podman exec -u hermes -e "HERMES_HOME=${app}" "$name" \
      sh -c "mkdir -p \"$dest_cfg\""; then
      rm -f "$tmp"
      echo "write_himalaya_config: mkdir failed" >&2
      return 1
    fi
    if ! podman cp "$tmp" "${name}:${dest_cfg}/config.toml"; then
      rm -f "$tmp"
      echo "write_himalaya_config: copy failed" >&2
      return 1
    fi
    podman exec -u root "$name" sh -c \
      "chown 10000:10000 \"${dest_cfg}/config.toml\" && chmod 600 \"${dest_cfg}/config.toml\""
  else
    prepare_app_for_container
    if ! podman unshare bash -c "
      set -e
      mkdir -p $(printf '%q' "$dest_cfg")
      cp $(printf '%q' "$tmp") $(printf '%q' "${dest_cfg}/config.toml")
      chown 10000:10000 $(printf '%q' "${dest_cfg}/config.toml")
      chmod 600 $(printf '%q' "${dest_cfg}/config.toml")
    "; then
      rm -f "$tmp"
      echo "write_himalaya_config: failed" >&2
      return 1
    fi
  fi
  rm -f "$tmp"
  echo "Wrote Himalaya config for: $(printf '%s\n' "${lines[@]}" | cut -d'|' -f1 | tr '\n' ' ')"
}

write_himalaya_helpers() {
  local app src tmp line acct email display def default_acct accounts_doc
  local name dest_scripts dest_skill lookup
  local -a lines=()
  app="$(hermes_app_dir)"
  src="${HERMES_ROOT}/scripts/himalaya"
  tmp="$(mktemp -d)"

  while IFS= read -r line; do
    lines+=("$line")
  done < <(himalaya_account_defs)
  if [[ ${#lines[@]} -eq 0 ]]; then
    echo "write_himalaya_helpers: no mail accounts" >&2
    rm -rf "$tmp"
    return 1
  fi

  default_acct="$(himalaya_default_account)"
  accounts_doc=""
  lookup="# account|email|display"$'\n'
  for line in "${lines[@]}"; do
    IFS='|' read -r acct email display def <<<"$line"
    if [[ "$def" == "1" ]]; then
      accounts_doc+="- \`${acct}\` → ${email} (${display}) **default**"$'\n'
    else
      accounts_doc+="- \`${acct}\` → ${email} (${display})"$'\n'
    fi
    lookup+="${acct}|${email}|${display}"$'\n'
  done

  mkdir -p "$tmp/scripts"
  printf '%s' "$lookup" >"$tmp/scripts/himalaya-accounts.tsv"

  sed -e "s|__DEFAULT_ACCOUNT__|${default_acct}|g" \
    "$src/himalaya-inbox.sh.in" >"$tmp/scripts/himalaya-inbox.sh"
  sed -e "s|__DEFAULT_ACCOUNT__|${default_acct}|g" \
    "$src/himalaya-read.sh.in" >"$tmp/scripts/himalaya-read.sh"
  sed -e "s|__DEFAULT_ACCOUNT__|${default_acct}|g" \
    "$src/himalaya-delete.sh.in" >"$tmp/scripts/himalaya-delete.sh"
  sed -e "s|__DEFAULT_ACCOUNT__|${default_acct}|g" \
    "$src/himalaya-send.sh.in" >"$tmp/scripts/himalaya-send.sh"

  awk -v doc="$accounts_doc" -v def="$default_acct" '
    { gsub(/__DEFAULT_ACCOUNT__/, def) }
    /__ACCOUNTS_DOC__/ { printf "%s", doc; next }
    { print }
  ' "$src/SKILL.md.in" >"$tmp/SKILL.md"
  chmod 755 "$tmp/scripts"/*.sh

  name="${HERMES_CONTAINER:-hermes}"
  dest_scripts="${app}/sandboxes/docker/default/workspace/scripts"
  dest_skill="${app}/skills/email/himalaya"

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
      "chown -R 10000:10000 \"$dest_scripts\" \"$dest_skill\" && chmod 755 \"$dest_scripts\"/*.sh && chmod 644 \"$dest_skill/SKILL.md\" \"$dest_scripts/himalaya-accounts.tsv\""
  else
    prepare_app_for_container
    if ! podman unshare bash -c "
      set -e
      mkdir -p $(printf '%q' "$dest_scripts") $(printf '%q' "$dest_skill")
      cp -a $(printf '%q' "$tmp/scripts")/. $(printf '%q' "$dest_scripts")/
      cp $(printf '%q' "$tmp/SKILL.md") $(printf '%q' "${dest_skill}/SKILL.md")
      chown -R 10000:10000 $(printf '%q' "$dest_scripts") $(printf '%q' "$dest_skill")
      chmod 755 $(printf '%q' "$dest_scripts")/*.sh
      chmod 644 $(printf '%q' "${dest_skill}/SKILL.md") $(printf '%q' "${dest_scripts}/himalaya-accounts.tsv")
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
# Imports secrets from HERMES_MAIL_IMPORT_DIR when set; else HERMES_MAIL_PASSWORD.
ensure_himalaya() {
  himalaya_has_accounts || return 0

  install_himalaya_binary || return 1
  write_himalaya_config || return 1
  write_himalaya_helpers || return 1
  if [[ -n "${HERMES_MAIL_IMPORT_DIR:-}" && -d "${HERMES_MAIL_IMPORT_DIR}" ]]; then
    import_himalaya_passwords_from_dir "${HERMES_MAIL_IMPORT_DIR}" || \
      echo "Note: could not import mail passwords from ${HERMES_MAIL_IMPORT_DIR} — run: ./hermes.sh himalaya-password --from-infra" >&2
  elif [[ -n "${HERMES_MAIL_PASSWORD:-}" ]]; then
    write_himalaya_secrets "$HERMES_MAIL_PASSWORD" || return 1
  elif ! app_shell "test -f \"\$HERMES_HOME/secrets/himalaya/imap.pass\"" \
    && ! app_shell "ls \"\$HERMES_HOME/secrets/himalaya\"/*.pass >/dev/null 2>&1"; then
    echo "Note: no mail secrets yet — run: ./hermes.sh himalaya-password [--from-infra]" >&2
  fi
  if container_is_running "${HERMES_CONTAINER:-hermes}"; then
    ensure_sandbox_volumes || true
  fi
}

himalaya_test() {
  local app name smtp_ip line acct
  local -a lines=()
  local accounts_csv="" z
  app="$(hermes_app_dir)"
  name="${HERMES_CONTAINER:-hermes}"
  smtp_ip="${MIGADU_SMTP_IPV4:-141.94.97.118}"

  if ! app_shell "test -x \"\$HERMES_HOME/bin/himalaya\""; then
    echo "himalaya binary missing — run: ./hermes.sh himalaya-install" >&2
    return 1
  fi

  while IFS= read -r line; do
    lines+=("$line")
  done < <(himalaya_account_defs)
  if [[ ${#lines[@]} -eq 0 ]]; then
    echo "no mail accounts configured" >&2
    return 1
  fi

  for line in "${lines[@]}"; do
    IFS='|' read -r acct _ _ _ <<<"$line"
    if [[ "$acct" == "default" ]]; then
      if ! app_shell "test -f \"\$HERMES_HOME/secrets/himalaya/imap.pass\""; then
        echo "mail password missing for ${acct} — run: ./hermes.sh himalaya-password" >&2
        return 1
      fi
    else
      if ! app_shell "test -f \"\$HERMES_HOME/secrets/himalaya/${acct}.pass\""; then
        echo "mail password missing for ${acct} — run: ./hermes.sh himalaya-password --from-infra" >&2
        return 1
      fi
    fi
    accounts_csv+="${acct},"
  done
  accounts_csv="${accounts_csv%,}"

  echo "Testing Himalaya IMAP + SMTP (pin ${smtp_ip}) for ${#lines[@]} account(s) ..."

  if container_is_running "$name"; then
    podman exec -i -u hermes \
      -e "HERMES_HOME=${app}" \
      -e "HOME=${app}/sandboxes/docker/default/home" \
      -e "PATH=${app}/bin:/opt/data/bin:/usr/bin:/bin" \
      -e "MIGADU_SMTP_IPV4=${smtp_ip}" \
      -e "HERMES_MAIL_TEST_ACCOUNTS=${accounts_csv}" \
      "$name" \
      sh -s <<'EOS'
set -e
himalaya --version
himalaya account list
oldifs="$IFS"
IFS=","
set -- $HERMES_MAIL_TEST_ACCOUNTS
IFS="$oldifs"
for acct in "$@"; do
  [ -n "$acct" ] || continue
  echo "=== account ${acct} ==="
  himalaya folder list -a "$acct"
  himalaya envelope list -a "$acct" --folder INBOX --page-size 5 --output json | head -c 2000
  echo
done
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
      -e "HERMES_MAIL_TEST_ACCOUNTS=${accounts_csv}" \
      --entrypoint sh \
      "${HERMES_IMAGE:-docker.io/nousresearch/hermes-agent:latest}" \
      -c '
set -e
himalaya --version
himalaya account list
oldifs="$IFS"
IFS=","
set -- $HERMES_MAIL_TEST_ACCOUNTS
IFS="$oldifs"
for acct in "$@"; do
  [ -n "$acct" ] || continue
  echo "=== account ${acct} ==="
  himalaya folder list -a "$acct"
  himalaya envelope list -a "$acct" --folder INBOX --page-size 5 --output json | head -c 2000
  echo
done
python3 -c "import socket; socket.create_connection(('"'${smtp_ip}'"', 587), timeout=8).close(); print(\"SMTP_OK\")"
'
  fi
}
