#!/usr/bin/env bash
# Render nginx.conf for Hermes webhook TLS sidecar (single- or multi-vhost).
# Usage: render-nginx-conf.sh <output-path>
#
# Env (from env.local via caller / select_profile):
#   HERMES_PUBLIC_HOST   required (primary server_name — Lemuel)
#   HERMES_INGRESS_PORT  default 8443 (this host: 10443)
#   WEBHOOK_PORT         Hermes HMAC webhook adapter (default 8644)
#   TELEGRAM_WEBHOOK_PORT  Telegram adapter listen (default 8643 in pod mode)
#   A2A_PORT             A2A JSON-RPC + /api/login* (default 9900)
#   IDENTYCLAW_HOOKS_PORT  RODiT /hooks/* (default 9911)
#
# Shared Hermes ingress (Olivia on same :10443 / :7443 via SNI):
#   AGENT_B_PUBLIC_HOST + AGENT_B_{TELEGRAM_WEBHOOK,WEBHOOK,A2A,HOOKS}_PORT
#   → upstreams hermes_*_olivia + second vhost. OpenClaw keeps :8443.
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

# Olivia shares fleet hermes-nginx when joined to hermes-agent-pod.
olivia_host="${AGENT_B_PUBLIC_HOST:-}"
olivia_tg="${AGENT_B_TELEGRAM_WEBHOOK_PORT:-}"
olivia_wh="${AGENT_B_WEBHOOK_PORT:-}"
olivia_a2a="${AGENT_B_A2A_PORT:-}"
olivia_hooks="${AGENT_B_HOOKS_PORT:-}"
# Never proxy OpenClaw joe/daniel through Hermes (OpenClaw owns :8443).
proxies=""

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

render_upstream_block() {
  local suffix="$1" wh="$2" tg="$3" a2a="$4" hooks="$5"
  cat <<EOF

    upstream hermes_webhook${suffix} {
        server 127.0.0.1:${wh};
    }

    upstream hermes_telegram${suffix} {
        server 127.0.0.1:${tg};
    }

    upstream hermes_a2a${suffix} {
        server 127.0.0.1:${a2a};
    }

    upstream hermes_identyclaw_hooks${suffix} {
        server 127.0.0.1:${hooks};
    }
EOF
}

{
  cat <<EOF
# TLS sidecar for Hermes Agent — public surface:
#   Webhooks: POST /webhooks/<route> (HMAC via Hermes WEBHOOK_SECRET)
#   Telegram: POST /telegram (TELEGRAM_WEBHOOK_SECRET) via infra 80→10443
#   A2A: / .well-known /api/login* (Passport peer login + JSON-RPC) on :7443
#   IdentyClaw: /hooks/wake /hooks/agent (RODiT-signed)
# nginx terminates TLS and reverse-proxies webhook paths only.
# Operator API stays on host HERMES_API_PORT (default 11642 → container API_SERVER_PORT).
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
EOF

  render_upstream_block "" "$webhook_port" "$telegram_port" "$a2a_port" "$hooks_port"

  # Primary Hermes vhost (Lemuel / default)
  render_hermes_server "$host" "$ingress_port" "$webhook_port" "$telegram_port" "$a2a_port" "$hooks_port"

  # Extra Hermes server_names (same upstreams as primary)
  extra_hosts="${extra_hosts//,/ }"
  for eh in $extra_hosts; do
    eh="${eh//[[:space:]]/}"
    [[ -n "$eh" && "$eh" != "$host" ]] || continue
    [[ -n "$olivia_host" && "$eh" == "$olivia_host" ]] && continue
    render_hermes_server "$eh" "$ingress_port" "$webhook_port" "$telegram_port" "$a2a_port" "$hooks_port"
  done

  # Olivia Tara — shared Hermes ingress (SNI), distinct loopback upstreams
  if [[ -n "$olivia_host" && -n "$olivia_tg" && -n "$olivia_wh" && -n "$olivia_a2a" && -n "$olivia_hooks" ]]; then
    if [[ "$olivia_host" != "$host" ]]; then
      render_upstream_block "_olivia" "$olivia_wh" "$olivia_tg" "$olivia_a2a" "$olivia_hooks"
      render_hermes_server "$olivia_host" "$ingress_port" "$olivia_wh" "$olivia_tg" "$olivia_a2a" "$olivia_hooks" "_olivia"
    fi
  fi

  cat <<EOF
}
EOF
} >"$out"

echo "Rendered ${out} (host=${host}, ingress=${ingress_port}, webhook=${webhook_port}, telegram=${telegram_port}, a2a=${a2a_port}, hooks=${hooks_port}, olivia=${olivia_host:-none})"
