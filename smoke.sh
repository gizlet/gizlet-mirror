#!/usr/bin/env bash
# Runs the mirror image with a self-signed certificate in front of the real
# gizlet.io and checks it with tests/mirror/*.hurl. Read-only on
# gizlet.io except one failed sign-in. Needs Docker, Hurl and openssl.
#
#   ./smoke.sh                     # as gizlet.xyz
#   ./smoke.sh gizlet.example
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
mirror="${1:-gizlet.xyz}"
origin="${ORIGIN_DOMAIN:-gizlet.io}"
https_port="${SMOKE_HTTPS_PORT:-18443}"
http_port="${SMOKE_HTTP_PORT:-18080}"
name="gizlet-mirror-smoke-$$"
image="${MIRROR_IMAGE:-gizlet-mirror:test}"

work="$(mktemp -d)"
cleanup() { docker rm -fv "$name" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=$mirror" \
  -addext "subjectAltName=DNS:$mirror,DNS:www.$mirror" \
  -keyout "$work/privkey.pem" -out "$work/fullchain.pem" 2>/dev/null
mkdir -p "$work/acme"

docker run -d --name "$name" \
  -e MIRROR_DOMAIN="$mirror" -e ORIGIN_DOMAIN="$origin" \
  -e CACHE_ENABLED=false \
  -e SSL_CERT=/certs/fullchain.pem -e SSL_KEY=/certs/privkey.pem \
  -p "127.0.0.1:$https_port:443" -p "127.0.0.1:$http_port:80" \
  -v "$work/fullchain.pem:/certs/fullchain.pem:ro" \
  -v "$work/privkey.pem:/certs/privkey.pem:ro" \
  -v "$work/acme:/var/www/acme:ro" \
  "$image" >/dev/null

for _ in $(seq 1 40); do
  curl -fsS -o /dev/null -k --connect-to "$mirror:443:127.0.0.1:$https_port" "https://$mirror/static/site.css" 2>/dev/null && break
  if [[ "$(docker inspect -f '{{.State.Running}}' "$name")" != true ]]; then docker logs "$name"; exit 1; fi
  sleep 0.5
done

connect=()
for h in "$mirror" "www.$mirror"; do
  connect+=(--connect-to "$h:443:127.0.0.1:$https_port" --connect-to "$h:80:127.0.0.1:$http_port")
done

status=0
hurl --test --insecure "${connect[@]}" \
  --variable "mirror=$mirror" --variable "origin=$origin" \
  "$here"/tests/mirror/*.hurl || status=$?
if [[ $status -ne 0 ]]; then docker logs "$name" 2>&1 | tail -n 40; fi
exit $status
