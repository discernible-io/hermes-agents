#!/usr/bin/env bash
# Render nginx.conf for Hermes webhook TLS sidecar.
# Usage: render-nginx-conf.sh <output-path>
# Env (from env.local via caller):
#   HERMES_PUBLIC_HOST   required
#   HERMES_INGRESS_PORT  default 8443 (Telegram Bot API allowed webhook port)
#   WEBHOOK_PORT         Hermes HMAC webhook adapter (default 8644, pod-local)
#   TELEGRAM_WEBHOOK_PORT  Telegram adapter listen (default 8643 in pod mode)
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

mkdir -p "$(dirname "$out")"

cat >"$out" <<EOF
# TLS sidecar for Hermes Agent — public surface:
#   Webhooks: POST /webhooks/<route> (HMAC via Hermes WEBHOOK_SECRET)
#   Telegram: POST /telegram (TELEGRAM_WEBHOOK_SECRET)
# nginx terminates TLS and reverse-proxies webhook paths only.
# Ingress listens on 8443 — Telegram Bot API only accepts 443, 80, 88, 8443.
# Operator API stays on host HERMES_API_PORT (default 11642 → container :8642).
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

    # Hermes — webhooks + Telegram + A2A @ ${host}:${ingress_port}
    server {
        listen ${ingress_port} ssl;
        http2 on;
        server_name ${host};
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
            proxy_pass http://hermes_webhook;
        }

        location ^~ /telegram {
            limit_req zone=hermes_ingress burst=240 nodelay;
            limit_req zone=hermes_public burst=120 nodelay;
            include /etc/nginx/inc/hermes-proxy.inc;
            proxy_pass http://hermes_telegram;
        }

        location ^~ /.well-known/ {
            limit_req zone=hermes_ingress burst=240 nodelay;
            limit_req zone=hermes_public burst=120 nodelay;
            include /etc/nginx/inc/hermes-proxy.inc;
            proxy_pass http://hermes_a2a;
        }

        location = /metrics {
            limit_req zone=hermes_ingress burst=120 nodelay;
            include /etc/nginx/inc/hermes-proxy.inc;
            proxy_pass http://hermes_a2a;
        }

        location = / {
            limit_req zone=hermes_ingress burst=240 nodelay;
            limit_req zone=hermes_public burst=120 nodelay;
            include /etc/nginx/inc/hermes-proxy.inc;
            proxy_pass http://hermes_a2a;
        }

        location / {
            return 404;
        }
    }
}
EOF

echo "Rendered ${out} (host=${host}, ingress=${ingress_port}, webhook_upstream=${webhook_port}, telegram_upstream=${telegram_port})"
