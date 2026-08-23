#!/usr/bin/env bash
# Issue a self-signed RSA certificate for hermes nginx TLS (fullchain.pem + privkey.pem).
# Hermes webhook auth uses HMAC (WEBHOOK_SECRET) — not TLS client certs — so a
# self-signed server cert is sufficient for transport encryption during bootstrap.
#
# Usage: ./scripts/generate-self-signed-certs.sh [CERT_DIR] [--force]
# Env:
#   TLS_CN     Common Name / primary DNS SAN (default: HERMES_PUBLIC_HOST or localhost)
#   CERT_DAYS  Validity in days (default: 825)
#   EXTRA_SANS Comma-separated extra SAN entries (e.g. DNS:alt.example.com)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

CERT_DIR=""
FORCE=false
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=true ;;
    *) [ -z "${CERT_DIR}" ] && CERT_DIR="${arg}" ;;
  esac
done
CERT_DIR="${CERT_DIR:-${REPO_ROOT}/../../hermes-agents-app/certs}"
TLS_CN="${TLS_CN:-${HERMES_PUBLIC_HOST:-localhost}}"
CERT_DAYS="${CERT_DAYS:-825}"

if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl is required on PATH." >&2
  exit 1
fi

mkdir -p "${CERT_DIR}"

if [ -s "${CERT_DIR}/fullchain.pem" ] && [ -s "${CERT_DIR}/privkey.pem" ] && [ "${FORCE}" != true ]; then
  echo "Certs already exist at ${CERT_DIR} (fullchain.pem, privkey.pem). Use --force to replace." >&2
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

SAN="DNS:${TLS_CN},DNS:localhost,IP:127.0.0.1"
if [ -n "${EXTRA_SANS:-}" ]; then
  SAN="${SAN},${EXTRA_SANS}"
fi

# RSA 3072: works across OpenSSL 1.1/3; nginx.conf includes ECDHE-RSA ciphers.
openssl req -x509 -newkey rsa:3072 \
  -keyout "${TMP}/privkey.pem" \
  -out "${TMP}/fullchain.pem" \
  -days "${CERT_DAYS}" \
  -nodes \
  -subj "/CN=${TLS_CN}" \
  -addext "subjectAltName=${SAN}"

chmod 0644 "${TMP}/fullchain.pem"
chmod 0640 "${TMP}/privkey.pem"

mv "${TMP}/fullchain.pem" "${CERT_DIR}/fullchain.pem"
mv "${TMP}/privkey.pem" "${CERT_DIR}/privkey.pem"

echo "Wrote self-signed cert: ${CERT_DIR}/fullchain.pem"
echo "Wrote key: ${CERT_DIR}/privkey.pem (CN=${TLS_CN}, SAN: ${SAN})"
