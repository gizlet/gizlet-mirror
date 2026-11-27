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
if [[ "$mirror" == "$origin" || "$mirror" == *".$origin" ]]; then
  echo "the mirror domain must not be $origin or one of its subdomains" >&2
  exit 2
fi

ssl_cert="${SSL_CERT:-/etc/letsencrypt/live/$mirror/fullchain.pem}"
ssl_key="${SSL_KEY:-/etc/letsencrypt/live/$mirror/privkey.pem}"
ca_bundle="${CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"
resolver="${RESOLVER:-1.1.1.1 8.8.8.8}"
acme_root="${ACME_ROOT:-/var/www/acme}"
https_port="${HTTPS_PORT:-443}"
http_port="${HTTP_PORT:-80}"
cache_max_size="${CACHE_MAX_SIZE:-100g}"
cache_min_free="${CACHE_MIN_FREE:-5g}"
cache_inactive="${CACHE_INACTIVE:-30d}"
download_upstream="https://gizlet_mirror_dl"
if [[ -n "${S3_BUCKET:-}" ]]; then download_upstream="http://127.0.0.1:8081"; fi

for v in "$ssl_cert" "$ssl_key" "$ca_bundle" "$acme_root"; do
  [[ "$v" =~ ^/[A-Za-z0-9._/-]+$ ]] || { echo "not an absolute path of plain characters: $v" >&2; exit 2; }
done
addresses='^[][A-Za-z0-9.: -]+$'
[[ "$resolver" =~ $addresses ]] || { echo "RESOLVER is not a list of addresses: $resolver" >&2; exit 2; }
[[ "$https_port" =~ ^[0-9]+$ && "$http_port" =~ ^[0-9]+$ ]] || { echo "ports must be numbers" >&2; exit 2; }
size='^[1-9][0-9]*[kKmMgG]?$'
duration='^[1-9][0-9]*[smhdwMy]?$'
[[ "$cache_max_size" =~ $size && "$cache_min_free" =~ $size ]] || { echo "invalid cache size (example: 500g)" >&2; exit 2; }
[[ "$cache_inactive" =~ $duration ]] || { echo "invalid CACHE_INACTIVE (example: 30d)" >&2; exit 2; }

# Every value is checked above to hold no sed metacharacters but "." and "/" ("|" is the delimiter).
re() { printf '%s' "$1" | sed 's/\./\\\\./g'; }
sed \
  -e "s|@MIRROR_RE@|$(re "$mirror")|g" \
  -e "s|@ORIGIN_RE@|$(re "$origin")|g" \
  -e "s|@MIRROR@|$mirror|g" \
  -e "s|@ORIGIN@|$origin|g" \
  -e "s|@SSL_CERT@|$ssl_cert|g" \
  -e "s|@SSL_KEY@|$ssl_key|g" \
  -e "s|@CA_BUNDLE@|$ca_bundle|g" \
  -e "s|@RESOLVER@|$resolver|g" \
  -e "s|@ACME_ROOT@|$acme_root|g" \
  -e "s|@HTTPS_PORT@|$https_port|g" \
  -e "s|@HTTP_PORT@|$http_port|g" \
  -e "s|@CACHE_MAX_SIZE@|$cache_max_size|g" \
  -e "s|@CACHE_MIN_FREE@|$cache_min_free|g" \
  -e "s|@CACHE_INACTIVE@|$cache_inactive|g" \
  -e "s|@DOWNLOAD_UPSTREAM@|$download_upstream|g" \
  "$here/nginx.conf.template"
