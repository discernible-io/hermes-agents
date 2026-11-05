#!/usr/bin/env bash
# Render nginx.conf for Hermes webhook TLS sidecar (single- or multi-vhost).
# Usage: render-nginx-conf.sh <output-path>
#
# Env (from env.local via caller / select_profile):
#   HERMES_PUBLIC_HOST   required (primary server_name)
#   HERMES_INGRESS_PORT  default 8443
#   WEBHOOK_PORT         Hermes HMAC webhook adapter (default 8644)
#   TELEGRAM_WEBHOOK_PORT  Telegram adapter listen (default 8643 in pod mode)
#   A2A_PORT             A2A JSON-RPC + /api/login* (default 9900)
#   IDENTYCLAW_HOOKS_PORT  RODiT /hooks/* (default 9911)
#
# Optional temporary OpenClaw proxies (Olivia cutover on :8443):
#   OPENCLAW_PROXY_UPSTREAMS=joe.dihola.io:18795,daniel.dihola.io:18799
#   Extra hostnames share HERMES_INGRESS_PORT and proxy all locations to that
#   gateway port (same-pod 127.0.0.1 when joined to identyclaw-agents-pod).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=lib.sh
source "$REPO_ROOT/scripts/lib.sh"

out="${1:?output path required}"

load_env

host="${HERMES_PUBLIC_HOST:-}"
[[ -n "$host" ]] || {
  echo "HERMES_PUBLIC_HOST is required to render nginx.conf" >&2
  exit 1
}
ingress_port="${HERMES_INGRESS_PORT:-8443}"
webhook_port="${WEBHOOK_PORT:-8644}"
telegram_port="${TELEGRAM_WEBHOOK_PORT:-8643}"
a2a_port="${A2A_PORT:-9900}"
hooks_port="${IDENTYCLAW_HOOKS_PORT:-9911}"
extra_hosts="${HERMES_EXTRA_SERVER_NAMES:-}"
# Joe/Daniel OpenClaw proxies are Olivia/:8443-only. load_env may re-import
# OPENCLAW_PROXY_UPSTREAMS from fleet env.local after select_profile unset it.
proxies="${OPENCLAW_PROXY_UPSTREAMS:-}"
case "${HERMES_PROFILE:-${HERMES_AGENT_ID:-}}" in
  olivia | agent-b) ;;
  *) proxies="" ;;
esac

mkdir -p "$(dirname "$out")"

# --- helpers (emit into conf) -----------------------------------------------
render_hermes_server() {
  local s_name="$1" listen_port="$2" wh="$3" tg="$4" a2a="$5" hooks="$6"
  local up_suffix="${7:-}"
  cat <<EOF

    # Hermes profile vhost @ ${s_name}:${listen_port}
    server {
        listen ${listen_port} ssl;
        http2 on;
        server_name ${s_name};
        ssl_certificate /app/certs/fullchain.pem;
        ssl_certificate_key /app/certs/privkey.pem;
        include /etc/nginx/inc/security-headers.inc;

        location @request_error {
            internal;
            default_type text/plain;
            return 400 "request too large\\n";
        }

        location = /health {
            limit_req zone=hermes_health burst=10 nodelay;
            default_type text/plain;
            return 200 "healthy\\n";
        }

        location ^~ /webhooks/ {
            limit_req zone=hermes_ingress burst=240 nodelay;
            limit_req zone=hermes_public burst=120 nodelay;
            include /etc/nginx/inc/hermes-proxy.inc;
            proxy_pass http://hermes_webhook${up_suffix};
        }

        location ^~ /telegram {
            limit_req zone=hermes_ingress burst=240 nodelay;
            limit_req zone=hermes_public burst=120 nodelay;
            include /etc/nginx/inc/hermes-proxy.inc;
            proxy_pass http://hermes_telegram${up_suffix};
        }

        location ^~ /hooks/ {
            limit_req zone=hermes_ingress burst=240 nodelay;
            limit_req zone=hermes_public burst=120 nodelay;
            include /etc/nginx/inc/hermes-proxy.inc;
            proxy_pass http://hermes_identyclaw_hooks${up_suffix};
        }

        location ^~ /api/login {
            limit_req zone=hermes_ingress burst=240 nodelay;
            limit_req zone=hermes_public burst=120 nodelay;
            include /etc/nginx/inc/hermes-proxy.inc;
            proxy_pass http://hermes_a2a${up_suffix};
        }

        location ^~ /.well-known/ {
            limit_req zone=hermes_ingress burst=240 nodelay;
            limit_req zone=hermes_public burst=120 nodelay;
            include /etc/nginx/inc/hermes-proxy.inc;
            proxy_pass http://hermes_a2a${up_suffix};
        }

        location = /a2a {
            limit_req zone=hermes_ingress burst=240 nodelay;
            limit_req zone=hermes_public burst=120 nodelay;
            include /etc/nginx/inc/hermes-proxy.inc;
            proxy_pass http://hermes_a2a${up_suffix}/;
        }

        location ^~ /a2a/ {
            limit_req zone=hermes_ingress burst=240 nodelay;
            limit_req zone=hermes_public burst=120 nodelay;
            include /etc/nginx/inc/hermes-proxy.inc;
            proxy_pass http://hermes_a2a${up_suffix}/;
        }

        location = /metrics {
            limit_req zone=hermes_ingress burst=120 nodelay;
            include /etc/nginx/inc/hermes-proxy.inc;
            proxy_pass http://hermes_a2a${up_suffix};
        }

        location = / {
            limit_req zone=hermes_ingress burst=240 nodelay;
            limit_req zone=hermes_public burst=120 nodelay;
            include /etc/nginx/inc/hermes-proxy.inc;
            proxy_pass http://hermes_a2a${up_suffix};
        }

        # OpenClaw-compatible Telegram path used by some Bot API setups.
        location = /telegram-webhook {
            limit_req zone=hermes_ingress burst=240 nodelay;
            limit_req zone=hermes_public burst=120 nodelay;
            include /etc/nginx/inc/hermes-proxy.inc;
            proxy_pass http://hermes_telegram${up_suffix};
        }

        location / {
            return 404;
        }
    }
EOF
}

render_openclaw_proxy_server() {
  local s_name="$1" listen_port="$2" gw_port="$3" up_name="$4"
  cat <<EOF

    upstream ${up_name} {
        server 127.0.0.1:${gw_port};
    }

    # Temporary OpenClaw proxy @ ${s_name}:${listen_port} → :${gw_port}
    server {
        listen ${listen_port} ssl;
        http2 on;
        server_name ${s_name};
        ssl_certificate /app/certs/fullchain.pem;
        ssl_certificate_key /app/certs/privkey.pem;
        include /etc/nginx/inc/security-headers.inc;

        location = /health {
            limit_req zone=hermes_health burst=10 nodelay;
            default_type text/plain;
            return 200 "healthy\\n";
        }

        location / {
            limit_req zone=hermes_ingress burst=240 nodelay;
            limit_req zone=hermes_public burst=120 nodelay;
            include /etc/nginx/inc/hermes-proxy.inc;
            proxy_pass http://${up_name};
        }
    }
EOF
}

{
  cat <<EOF
# TLS sidecar for Hermes Agent — public surface:
#   Webhooks: POST /webhooks/<route> (HMAC via Hermes WEBHOOK_SECRET)
#   Telegram: POST /telegram (TELEGRAM_WEBHOOK_SECRET)
#   A2A: / .well-known /api/login* (Passport peer login + JSON-RPC)
#   IdentyClaw: /hooks/wake /hooks/agent (RODiT-signed)
# nginx terminates TLS and reverse-proxies webhook paths only.
# Operator API stays on host HERMES_API_PORT (default 11642 → container :8642).
# Generated by render-nginx-conf.sh — do not edit by hand.
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /tmp/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    include /etc/nginx/inc/http-common.inc;

    upstream hermes_webhook {
        server 127.0.0.1:${webhook_port};
    }

    upstream hermes_telegram {
        server 127.0.0.1:${telegram_port};
    }

    upstream hermes_a2a {
        server 127.0.0.1:${a2a_port};
    }

    upstream hermes_identyclaw_hooks {
        server 127.0.0.1:${hooks_port};
    }
EOF

  # Primary Hermes vhost
  render_hermes_server "$host" "$ingress_port" "$webhook_port" "$telegram_port" "$a2a_port" "$hooks_port"

  # Extra Hermes server_names (same upstreams)
  extra_hosts="${extra_hosts//,/ }"
  for eh in $extra_hosts; do
    eh="${eh//[[:space:]]/}"
    [[ -n "$eh" && "$eh" != "$host" ]] || continue
    render_hermes_server "$eh" "$ingress_port" "$webhook_port" "$telegram_port" "$a2a_port" "$hooks_port"
  done

  # Temporary OpenClaw proxies (joe/daniel during Olivia cutover)
  idx=0
  proxies="${proxies//,/ }"
  for entry in $proxies; do
    entry="${entry//[[:space:]]/}"
    [[ -n "$entry" ]] || continue
    phost="${entry%%:*}"
    pport="${entry##*:}"
    [[ -n "$phost" && -n "$pport" && "$phost" != "$pport" ]] || continue
    idx=$((idx + 1))
    render_openclaw_proxy_server "$phost" "$ingress_port" "$pport" "openclaw_proxy_${idx}"
  done

  cat <<EOF
}
EOF
} >"$out"

echo "Rendered ${out} (host=${host}, ingress=${ingress_port}, webhook=${webhook_port}, telegram=${telegram_port}, a2a=${a2a_port}, hooks=${hooks_port}, proxies=${proxies:-none})"
