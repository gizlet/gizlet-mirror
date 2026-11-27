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
  -addext 'subjectAltName=DNS:mirror.test,DNS:www.mirror.test,DNS:api.mirror.test,DNS:dl.mirror.test,DNS:origin.test,DNS:api.origin.test,DNS:dl.origin.test' \
  -keyout "$work/key.pem" -out "$work/cert.pem" 2>"$work/openssl.log"

"$dnsmasq" --conf-file=/dev/null --keep-in-foreground --bind-interfaces \
  --listen-address=127.0.0.1 --port="$dns_port" --no-resolv \
  --address=/origin.test/127.0.0.1 --pid-file="$work/dns.pid" >"$work/dns.log" 2>&1 &
pids+=("$!")

printf '0123456789abcdefghijklmnopqrstuvwxyz\n' > "$work/artifact"
checksum="$(openssl dgst -sha256 -r "$work/artifact" | cut -d ' ' -f1)"
cat > "$work/temp-paths.conf" <<EOF
client_body_temp_path $work/client_temp;
proxy_temp_path $work/proxy_temp;
fastcgi_temp_path $work/fastcgi_temp;
uwsgi_temp_path $work/uwsgi_temp;
scgi_temp_path $work/scgi_temp;
EOF
cat > "$work/origin.conf" <<EOF
daemon off;
pid $work/origin.pid;
error_log stderr info;
events {}
http {
    access_log off;
    include $work/temp-paths.conf;
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
            return 200 '{"download":"https://dl.origin.test/releases/v1.2.3/artifact","verification_uri":"https://origin.test/device"}';
        }

        location = /redirect {
            return 302 https://origin.test/device;
        }

        location = /releases/v1.2.3/artifact {
            alias $work/artifact;
            add_header Cache-Control 'public, max-age=3600, immutable';
            add_header X-Checksum-Sha256 $checksum;
        }
    }
}
EOF
"$nginx" -e stderr -p "$work/" -c "$work/origin.conf" >"$work/origin.log" 2>&1 &
pids+=("$!")

render_mirror() {
  SSL_CERT="$work/cert.pem" SSL_KEY="$work/key.pem" CA_BUNDLE="$work/cert.pem" \
    CACHE_PATH="$work/cache" CACHE_MAX_SIZE=64m CACHE_MIN_FREE=1m \
    HTTP_PORT="$http_port" HTTPS_PORT="$https_port" ORIGIN_HTTPS_PORT="$origin_port" \
    ORIGIN_DOMAIN=origin.test RESOLVER="127.0.0.1:$dns_port" \
    "$here/render.sh" mirror.test > "$work/mirror.conf"
}
cat > "$work/nginx.conf" <<EOF
daemon off;
pid $work/mirror.pid;
error_log stderr info;
events {}
http {
    access_log off;
    include $work/temp-paths.conf;
    include $work/mirror.conf;
}
EOF

start_mirror() {
  render_mirror
  "$nginx" -t -e stderr -p "$work/" -c "$work/nginx.conf"
  "$nginx" -e stderr -p "$work/" -c "$work/nginx.conf" >"$work/mirror.log" 2>&1 &
  pids[2]=$!
}

request() {
  local host="$1" path="$2"
  shift 2
  curl -fsS --noproxy '*' --max-time 3 --cacert "$work/cert.pem" \
    --resolve "$host:$https_port:127.0.0.1" -D "$work/headers" -o "$work/body" \
    "$@" "https://$host:$https_port$path"
}

unset SERVE_SITE CACHE_ENABLED S3_BUCKET
start_mirror
for attempt in $(seq 1 15); do
  if request mirror.test / 2>/dev/null; then break; fi
  sleep 1
done
grep -Fq 'https://api.mirror.test/v1' "$work/body"
request www.mirror.test /device
grep -qi '^Location: https://mirror.test/device' "$work/headers"
curl -fsS --noproxy '*' --max-time 3 --resolve "mirror.test:$http_port:127.0.0.1" \
  -D "$work/headers" -o /dev/null "http://mirror.test:$http_port/v1"
grep -q '^HTTP/.* 301' "$work/headers"
grep -qi '^Location: https://mirror.test/v1' "$work/headers"
request api.mirror.test /v1
grep -Fq 'https://dl.mirror.test/releases/v1.2.3/artifact' "$work/body"
grep -Fq 'https://mirror.test/device' "$work/body"
request dl.mirror.test /redirect
grep -qi '^Location: https://mirror.test/device' "$work/headers"

artifact=/releases/v1.2.3/artifact
request dl.mirror.test "$artifact"
grep -qi '^X-Mirror-Cache: MISS' "$work/headers"
request dl.mirror.test "$artifact"
grep -qi '^X-Mirror-Cache: HIT' "$work/headers"
cmp "$work/artifact" "$work/body"

kill "${pids[2]}"
wait "${pids[2]}"
unset 'pids[2]'
SERVE_SITE=false CACHE_ENABLED=false S3_BUCKET=unused start_mirror
for attempt in $(seq 1 15); do
  if request api.mirror.test /v1 2>/dev/null; then break; fi
  sleep 1
done
grep -Fq 'https://origin.test/device' "$work/body"
grep -Fq 'https://dl.mirror.test/releases/v1.2.3/artifact' "$work/body"
for host in mirror.test www.mirror.test; do
  request "$host" /device --no-fail
  grep -q '^HTTP/.* 404' "$work/headers"
done
request dl.mirror.test /redirect
grep -qi '^Location: https://origin.test/device' "$work/headers"

request dl.mirror.test "$artifact"
grep -qi '^Cache-Control: public, max-age=3600, immutable' "$work/headers"
grep -qi "^X-Checksum-Sha256: $checksum" "$work/headers"
cmp "$work/artifact" "$work/body"
request dl.mirror.test "$artifact" -H 'Range: bytes=5-9'
grep -q '^HTTP/.* 206' "$work/headers"
grep -qi '^Content-Range: bytes 5-9/37' "$work/headers"
grep -qi "^X-Checksum-Sha256: $checksum" "$work/headers"
printf '56789' | cmp - "$work/body"
kill "${pids[1]}"
wait "${pids[1]}" || true
unset 'pids[1]'
request dl.mirror.test "$artifact" --no-fail
grep -q '^HTTP/.* 502' "$work/headers"
if SERVE_SITE=invalid "$here/render.sh" mirror.test > /dev/null 2>"$work/invalid.log"; then
  echo 'render.sh accepted an invalid SERVE_SITE value' >&2
  exit 1
fi
grep -Fq 'SERVE_SITE must be true or false' "$work/invalid.log"
if CACHE_ENABLED=invalid "$here/render.sh" mirror.test > /dev/null 2>"$work/invalid.log"; then
  echo 'render.sh accepted an invalid CACHE_ENABLED value' >&2
  exit 1
fi
grep -Fq 'CACHE_ENABLED must be true or false' "$work/invalid.log"
echo 'Native nginx site, TLS, and download cache modes passed.'
