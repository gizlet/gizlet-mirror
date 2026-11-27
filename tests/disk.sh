#!/usr/bin/env bash
set -euo pipefail

engine="${CONTAINER_ENGINE:-docker}"
image="${MIRROR_IMAGE:-gizlet-mirror:test}"
name="gizlet-mirror-disk-$$"
work="$(mktemp -d)"
cleanup() {
  "$engine" rm -f "$name" "$name-origin" >/dev/null 2>&1 || true
  "$engine" network rm "$name" >/dev/null 2>&1 || true
  "$engine" volume rm "$name" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=mirror.test \
  -addext 'subjectAltName=DNS:mirror.test,DNS:dl.mirror.test,DNS:dl.origin.test' \
  -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
cat > "$work/default.conf" <<'EOF'
server {
    listen 443 ssl;
    ssl_certificate /certs/cert.pem;
    ssl_certificate_key /certs/key.pem;

    location = /releases/v1.2.3/manifest.json {
        alias /usr/share/nginx/html/index.html;
        add_header Cache-Control "public, max-age=3600, immutable";
    }

    location = /releases/v1.2.3/private {
        alias /usr/share/nginx/html/index.html;
        add_header Cache-Control "no-store";
    }
}
EOF

if "$engine" run --rm "$image" > "$work/no-volume.log" 2>&1; then
  exit 1
fi
grep -q 'Mount a persistent volume at /cache' "$work/no-volume.log"

"$engine" network create "$name" >/dev/null
"$engine" volume create "$name" >/dev/null
"$engine" run -d --name "$name-origin" --network "$name" --network-alias dl.origin.test \
  -v "$work/cert.pem:/certs/cert.pem:ro" -v "$work/key.pem:/certs/key.pem:ro" \
  -v "$work/default.conf:/etc/nginx/conf.d/default.conf:ro" \
  --entrypoint nginx "$image" -g 'daemon off;' >/dev/null
resolver="$("$engine" exec "$name-origin" awk '/^nameserver / {print $2; exit}' /etc/resolv.conf)"
start_mirror() {
  local cache_enabled="$1"
  shift
  "$engine" run -d --name "$name" --network "$name" -p '127.0.0.1::443' \
    -e MIRROR_DOMAIN=mirror.test -e ORIGIN_DOMAIN=origin.test \
    -e CACHE_ENABLED="$cache_enabled" \
    -e SSL_CERT=/certs/cert.pem -e SSL_KEY=/certs/key.pem -e CA_BUNDLE=/certs/cert.pem \
    -e RESOLVER="$resolver" -e CACHE_MAX_SIZE=64m -e CACHE_MIN_FREE=1m \
    -v "$work/cert.pem:/certs/cert.pem:ro" -v "$work/key.pem:/certs/key.pem:ro" \
    "$@" "$image" >/dev/null
  port="$("$engine" port "$name" 443/tcp | head -1 | cut -d: -f2)"
}
request() {
  local path="$1"
  shift
  curl -ksS --noproxy '*' --max-time 5 --resolve "dl.mirror.test:$port:127.0.0.1" \
    -D "$work/headers" -o "$work/body" "$@" "https://dl.mirror.test:$port$path"
}
expect() { grep -qi "$1" "$work/headers"; }
artifact=/releases/v1.2.3/manifest.json
start_mirror true -v "$name:/cache"
for attempt in $(seq 1 30); do
  if request "$artifact" -H 'Range: bytes=5-9' 2>/dev/null && expect '^HTTP/.* 206'; then break; fi
  sleep 1
done
expect '^HTTP/.* 206'
expect '^X-Mirror-Cache: MISS'
request "$artifact" -H 'Range: bytes=0-3'
expect '^HTTP/.* 206'
expect '^X-Mirror-Cache: MISS'
request "$artifact"
expect '^X-Mirror-Cache: HIT'
cp "$work/body" "$work/full"
request "$artifact" -H 'Range: bytes=5-9'
expect '^HTTP/.* 206'
expect '^X-Mirror-Cache: HIT'
dd if="$work/full" bs=1 skip=5 count=5 2>/dev/null | cmp - "$work/body"
request "$artifact" -H 'Authorization: Bearer fixture'
expect '^X-Mirror-Cache: BYPASS'
for attempt in 1 2; do
  request /releases/v1.2.3/private
  expect '^X-Mirror-Cache: MISS'
done
"$engine" rm -f "$name" "$name-origin" >/dev/null
start_mirror true -v "$name:/cache"
for attempt in $(seq 1 15); do
  if request "$artifact" 2>/dev/null && expect '^X-Mirror-Cache: HIT'; then break; fi
  sleep 1
done
expect '^X-Mirror-Cache: HIT'
cmp "$work/full" "$work/body"
"$engine" rm -f "$name" >/dev/null
start_mirror false -e S3_BUCKET=unused -e SERVE_SITE=false
for attempt in $(seq 1 15); do
  if curl -sS --noproxy '*' --max-time 3 --cacert "$work/cert.pem" \
    --resolve "mirror.test:$port:127.0.0.1" -D "$work/headers" -o /dev/null \
    "https://mirror.test:$port/" 2>/dev/null && expect '^HTTP/.* 404'; then break; fi
  sleep 1
done
expect '^HTTP/.* 404'
"$engine" exec "$name" nginx -t
echo 'Persistent disk cache and no-cache container startup checks passed.'
