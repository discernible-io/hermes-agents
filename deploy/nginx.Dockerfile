# Pinned base (tag + manifest-list digest). Bump both when upgrading nginx.
FROM docker.io/nginx:1.31.7-alpine@sha256:892bb2152464f0c5d8972593a5f5afaf8054552580b699d95f8ff4af08c2d33d

ARG INGRESS_PORT=8443

# CVE-2026-111497: base image ships brotli-libs 1.2.0; 1.2.1-r0 is in Alpine 3.24.
RUN apk update && apk upgrade --no-cache \
 && apk add --no-cache openssl 'brotli-libs>=1.2.1-r0' \
 && rm /etc/nginx/conf.d/default.conf \
 && mkdir -p /app/certs /etc/nginx/inc

# Runtime nginx.conf is mounted from the app dir (rendered by render-nginx-conf.sh).
# Ship includes into the image so they are always available.
COPY nginx/inc/ /etc/nginx/inc/

RUN printf '%s\n' \
  'user nginx;' \
  'worker_processes auto;' \
  'error_log /var/log/nginx/error.log warn;' \
  'pid /tmp/nginx.pid;' \
  'events { worker_connections 1024; }' \
  'http { include /etc/nginx/mime.types; default_type application/octet-stream;' \
  '  return 503 "nginx.conf not mounted — run ./hermes.sh start in pod mode\n"; }' \
  > /etc/nginx/nginx.conf \
 && chown -R nginx:nginx /etc/nginx/nginx.conf /etc/nginx/inc /var/cache/nginx /var/log/nginx /etc/nginx/conf.d /app

USER nginx
EXPOSE ${INGRESS_PORT}

CMD ["nginx", "-g", "daemon off;"]
