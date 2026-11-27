#!/usr/bin/env bash
set -euo pipefail

if ! awk '$5 == "/cache" { mounted = 1 } END { exit !mounted }' /proc/self/mountinfo; then
  echo "Mount a persistent volume at /cache before starting the mirror." >&2
  exit 1
fi

render.sh "${MIRROR_DOMAIN:-}" > /etc/nginx/conf.d/default.conf
install -d -o nginx -g nginx /cache/nginx
nginx -t

if [[ -z "${S3_BUCKET:-}" ]]; then
  exec nginx -g 'daemon off;'
fi

install -d -o nginx -g nginx -m 0700 /cache/s3-upload
SSL_CERT_FILE="${CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}" su-exec nginx s3-cache &
s3_pid=$!
nginx -g 'daemon off;' &
nginx_pid=$!
trap 'kill -TERM "$nginx_pid" "$s3_pid" 2>/dev/null || true' TERM INT QUIT
status=0
wait -n "$nginx_pid" "$s3_pid" || status=$?
kill -TERM "$nginx_pid" "$s3_pid" 2>/dev/null || true
wait || true
exit "$status"
