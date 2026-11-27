#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
mirror="${1:-}"
origin="${ORIGIN_DOMAIN:-gizlet.io}"

domain='^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'
if [[ ! "$mirror" =~ $domain ]]; then
  echo "usage: $0 <mirror-domain>   (for example gizlet.xyz)" >&2
  exit 2
fi
if [[ ! "$origin" =~ $domain ]]; then
  echo "ORIGIN_DOMAIN is not a domain: $origin" >&2
  exit 2
fi
case "$mirror" in
  "$origin"|"www.$origin")
    echo "the mirror domain conflicts with a Gizlet origin host: $mirror" >&2
    exit 2
    ;;
esac

site_domain="$mirror"
site_server_names="www.$mirror"
site_response="301 https://$mirror\$request_uri"
case "${SERVE_SITE-true}" in
  true) ;;
  false)
    site_domain="$origin"
    site_server_names="www.$mirror"
    site_response=404
    ;;
  *) echo "SERVE_SITE must be true or false" >&2; exit 2 ;;
esac

ssl_cert="${SSL_CERT:-/etc/letsencrypt/live/$mirror/fullchain.pem}"
ssl_key="${SSL_KEY:-/etc/letsencrypt/live/$mirror/privkey.pem}"
ca_bundle="${CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"
resolver="${RESOLVER:-1.1.1.1 8.8.8.8}"
acme_root="${ACME_ROOT:-/var/www/acme}"
https_port="${HTTPS_PORT:-443}"
http_port="${HTTP_PORT:-80}"
origin_https_port="${ORIGIN_HTTPS_PORT:-443}"
cache_filter=""
cache_path=""
cache_max_size=""
cache_min_free=""
cache_inactive=""
download_buffering=off
asset_upstream="https://gizlet_mirror_site"
case "${CACHE_ENABLED-true}" in
  true)
    cache_path="${CACHE_PATH:-/cache/nginx}"
    cache_max_size="${CACHE_MAX_SIZE:-100g}"
    cache_min_free="${CACHE_MIN_FREE:-5g}"
    cache_inactive="${CACHE_INACTIVE:-30d}"
    size='^[1-9][0-9]*[kKmMgG]?$'
    duration='^[1-9][0-9]*[smhdwMy]?$'
    [[ "$cache_path" =~ ^/[A-Za-z0-9._/-]+$ ]] || { echo "invalid CACHE_PATH" >&2; exit 2; }
    [[ "$cache_max_size" =~ $size && "$cache_min_free" =~ $size ]] || { echo "invalid cache size (example: 500g)" >&2; exit 2; }
    [[ "$cache_inactive" =~ $duration ]] || { echo "invalid CACHE_INACTIVE (example: 30d)" >&2; exit 2; }
    download_buffering=on
    if [[ -n "${S3_BUCKET:-}" ]]; then
      asset_upstream="http://127.0.0.1:8081"
    fi
    ;;
  false) cache_filter='/^@CACHE_BEGIN@$/,/^@CACHE_END@$/d' ;;
  *) echo "CACHE_ENABLED must be true or false" >&2; exit 2 ;;
esac

for v in "$ssl_cert" "$ssl_key" "$ca_bundle" "$acme_root"; do
  [[ "$v" =~ ^/[A-Za-z0-9._/-]+$ ]] || { echo "not an absolute path of plain characters: $v" >&2; exit 2; }
done
addresses='^[][A-Za-z0-9.: -]+$'
[[ "$resolver" =~ $addresses ]] || { echo "RESOLVER is not a list of addresses: $resolver" >&2; exit 2; }
for port in "$https_port" "$http_port" "$origin_https_port"; do
  [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && (( port <= 65535 )) || { echo "invalid port: $port" >&2; exit 2; }
done

# Every value is checked above to hold no sed metacharacters but "." and "/" ("|" is the delimiter).
re() { printf '%s' "$1" | sed 's/\./\\\\./g'; }
sed \
  -e "$cache_filter" \
  -e '/^@CACHE_.*@$/d' \
  -e "s|@MIRROR_RE@|$(re "$mirror")|g" \
  -e "s|@ORIGIN_RE@|$(re "$origin")|g" \
  -e "s|@MIRROR@|$mirror|g" \
  -e "s|@ORIGIN@|$origin|g" \
  -e "s|@SITE_DOMAIN@|$site_domain|g" \
  -e "s|@SITE_SERVER_NAMES@|$site_server_names|g" \
  -e "s|@SITE_RESPONSE@|$site_response|g" \
  -e "s|@SSL_CERT@|$ssl_cert|g" \
  -e "s|@SSL_KEY@|$ssl_key|g" \
  -e "s|@CA_BUNDLE@|$ca_bundle|g" \
  -e "s|@RESOLVER@|$resolver|g" \
  -e "s|@ACME_ROOT@|$acme_root|g" \
  -e "s|@HTTPS_PORT@|$https_port|g" \
  -e "s|@HTTP_PORT@|$http_port|g" \
  -e "s|@ORIGIN_HTTPS_PORT@|$origin_https_port|g" \
  -e "s|@CACHE_PATH@|$cache_path|g" \
  -e "s|@CACHE_MAX_SIZE@|$cache_max_size|g" \
  -e "s|@CACHE_MIN_FREE@|$cache_min_free|g" \
  -e "s|@CACHE_INACTIVE@|$cache_inactive|g" \
  -e "s|@DOWNLOAD_BUFFERING@|$download_buffering|g" \
  -e "s|@ASSET_UPSTREAM@|$asset_upstream|g" \
  -e "s|@SERVE_SITE@|${SERVE_SITE-true}|g" \
  "$here/nginx.conf.template"
