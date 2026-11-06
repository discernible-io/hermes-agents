# Thin security overlay for CVE-2026-111497 (Brotli decoder).
# Upstream hermes-agent:latest already ships Node 26.12.1 (fixed); this layer
# upgrades Debian libbrotli1 and Python brotlicffi until upstream includes them.
#
# Build:
#   podman build -f deploy/hermes-agent.brotli-patch.Dockerfile \
#     -t localhost/hermes-agent:brotli-patched .
# Run:
#   HERMES_IMAGE=localhost/hermes-agent:brotli-patched ./hermes.sh start

FROM docker.io/nousresearch/hermes-agent:latest

USER root
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get -o Acquire::Retries=3 update \
 && apt-get -o Acquire::Retries=3 install -y --no-install-recommends --only-upgrade \
      libbrotli1 \
 && rm -rf /var/lib/apt/lists/*

# Upgrade brotlicffi in the Hermes uv venv.
RUN set -eux; \
  UV_BIN="$(ls -d /opt/hermes/tools/uv-*-linux-x64/uv 2>/dev/null | head -1)"; \
  if [ -n "$UV_BIN" ] && [ -x /opt/hermes/.venv/bin/python ]; then \
    "$UV_BIN" pip install --python /opt/hermes/.venv/bin/python --upgrade 'brotlicffi==1.2.1.0'; \
  else \
    echo "brotlicffi not upgraded (uv/venv missing)"; \
  fi

# Keep USER root: upstream entrypoint/s6 expects to start as root.
