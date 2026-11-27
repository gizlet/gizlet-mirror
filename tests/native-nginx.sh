#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
nginx="${NGINX_BIN:-nginx}"
dnsmasq="${DNSMASQ_BIN:-dnsmasq}"
http_port="${TEST_HTTP_PORT:-19080}"
https_port="${TEST_HTTPS_PORT:-19443}"
origin_port="${TEST_ORIGIN_PORT:-19444}"
dns_port="${TEST_DNS_PORT:-19535}"
work="$(mktemp -d /tmp/gizlet-nginx.XXXXXX)"
pids=()

cleanup() {
  local status=$?
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
  if [[ "$status" -ne 0 ]]; then
    for log in "$work"/*.log; do [[ ! -f "$log" ]] || cat "$log"; done
  fi
  rm -rf "$work"
}
trap cleanup EXIT

"$nginx" -v
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=mirror.test \
  -addext 'subjectAltName=DNS:mirror.test,DNS:api.mirror.test,DNS:dl.mirror.test,DNS:origin.test,DNS:api.origin.test,DNS:dl.origin.test' \
  -keyout "$work/key.pem" -out "$work/cert.pem" 2>"$work/openssl.log"

"$dnsmasq" --conf-file=/dev/null --keep-in-foreground --bind-interfaces \
  --listen-address=127.0.0.1 --port="$dns_port" --no-resolv \
  --address=/origin.test/127.0.0.1 --pid-file="$work/dns.pid" >"$work/dns.log" 2>&1 &
pids+=("$!")

printf '0123456789abcdefghijklmnopqrstuvwxyz\n' > "$work/artifact"
cat > "$work/origin.conf" <<EOF
daemon off;
pid $work/origin.pid;
error_log stderr info;
events {}
http {
    access_log off;
    server {
        listen 127.0.0.1:$origin_port ssl;
        ssl_certificate $work/cert.pem;
        ssl_certificate_key $work/key.pem;

        location = / {
            default_type text/html;
            return 200 '<a href="https://api.origin.test/v1">API</a>';
        }

        location = /v1 {
            default_type application/json;
            return 200 '{"download":"https://dl.origin.test/releases/v1.2.3/artifact"}';
        }

        location = /releases/v1.2.3/artifact {
            alias $work/artifact;
            add_header Cache-Control 'public, max-age=3600, immutable';
        }
    }
}
EOF
"$nginx" -p "$work/" -c "$work/origin.conf" >"$work/origin.log" 2>&1 &
pids+=("$!")

SSL_CERT="$work/cert.pem" SSL_KEY="$work/key.pem" CA_BUNDLE="$work/cert.pem" \
  CACHE_PATH="$work/cache" CACHE_MAX_SIZE=64m CACHE_MIN_FREE=1m \
  HTTP_PORT="$http_port" HTTPS_PORT="$https_port" ORIGIN_HTTPS_PORT="$origin_port" \
  ORIGIN_DOMAIN=origin.test RESOLVER="127.0.0.1:$dns_port" S3_BUCKET= \
  "$here/render.sh" mirror.test > "$work/mirror.conf"
cat > "$work/nginx.conf" <<EOF
daemon off;
pid $work/mirror.pid;
error_log stderr info;
events {}
http {
    access_log off;
    include $work/mirror.conf;
}
EOF
"$nginx" -t -p "$work/" -c "$work/nginx.conf"
"$nginx" -p "$work/" -c "$work/nginx.conf" >"$work/mirror.log" 2>&1 &
pids+=("$!")

request() {
  local host="$1" path="$2"
  shift 2
  curl -fsS --noproxy '*' --max-time 3 --cacert "$work/cert.pem" \
    --resolve "$host:$https_port:127.0.0.1" -D "$work/headers" -o "$work/body" \
    "$@" "https://$host:$https_port$path"
}

for attempt in $(seq 1 15); do
  if request mirror.test / 2>/dev/null; then break; fi
  sleep 1
done
grep -Fq 'https://api.mirror.test/v1' "$work/body"
curl -fsS --noproxy '*' --max-time 3 --resolve "mirror.test:$http_port:127.0.0.1" \
  -D "$work/headers" -o /dev/null "http://mirror.test:$http_port/v1"
grep -q '^HTTP/.* 301' "$work/headers"
grep -qi '^Location: https://mirror.test/v1' "$work/headers"
request api.mirror.test /v1
grep -Fq 'https://dl.mirror.test/releases/v1.2.3/artifact' "$work/body"

artifact=/releases/v1.2.3/artifact
request dl.mirror.test "$artifact"
grep -qi '^X-Mirror-Cache: MISS' "$work/headers"
cmp "$work/artifact" "$work/body"
kill "${pids[1]}"
wait "${pids[1]}" || true
request dl.mirror.test "$artifact"
grep -qi '^X-Mirror-Cache: HIT' "$work/headers"
cmp "$work/artifact" "$work/body"
request dl.mirror.test "$artifact" -H 'Range: bytes=5-9'
grep -q '^HTTP/.* 206' "$work/headers"
grep -qi '^X-Mirror-Cache: HIT' "$work/headers"
printf '56789' | cmp - "$work/body"
echo 'Native nginx routing, TLS, and disk cache checks passed.'
