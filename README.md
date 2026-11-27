# Gizlet Mirror

Run Gizlet under your own domain with an nginx reverse proxy and optional download caching. GitHub Actions publishes Linux `amd64` and `arm64` images to `ghcr.io/gizlet/gizlet-mirror`.

## Deploy

By default, point the mirror domain and its `www`, `api`, and `dl` hosts at your server and obtain a TLS certificate for all four names. For `gizlet.example`, the four hosts serve the site, the redirect to the site, the JSON API, and downloads respectively.

```sh
docker run -d --name gizlet-mirror --restart unless-stopped \
  -p 80:80 -p 443:443 \
  -e MIRROR_DOMAIN=gizlet.example \
  --mount type=bind,src=/mnt/big-disk/gizlet,dst=/cache \
  --mount type=bind,src=/etc/letsencrypt,dst=/etc/letsencrypt,readonly \
  --mount type=bind,src=/var/www/acme,dst=/var/www/acme,readonly \
  ghcr.io/gizlet/gizlet-mirror:latest
```

Create the host directories first. HTTP serves ACME challenges from `/var/www/acme` and redirects other requests to HTTPS. Restart the container after renewing the certificate.

With caching enabled, mount a persistent directory or Docker named volume at `/cache`. Use a separate local volume per container. To stream downloads without caching, set `-e CACHE_ENABLED=false` and omit the `/cache` mount and any S3 settings.

| Variable | Default | Purpose |
| --- | --- | --- |
| `MIRROR_DOMAIN` | Required | Domain to serve, without a scheme |
| `ORIGIN_DOMAIN` | `gizlet.io` | Gizlet origin |
| `SERVE_SITE` | `true` | Set to `false` to serve only the API and downloads |
| `SSL_CERT`, `SSL_KEY` | `/etc/letsencrypt/live/<mirror>/fullchain.pem`, `privkey.pem` | Mirror certificate and key |
| `CA_BUNDLE` | `/etc/ssl/certs/ca-certificates.crt` | Origin CA bundle |
| `RESOLVER` | `1.1.1.1 8.8.8.8` | DNS resolvers used by nginx |
| `ACME_ROOT` | `/var/www/acme` | Webroot for HTTP certificate challenges |
| `HTTP_PORT`, `HTTPS_PORT` | `80`, `443` | Container listen ports |
| `ORIGIN_HTTPS_PORT` | `443` | HTTPS port on the origin hosts |
| `CACHE_ENABLED` | `true` | Set to `false` to stream downloads without local or S3 caching |
| `CACHE_MAX_SIZE` | `100g` | nginx disk cache target size |
| `CACHE_MIN_FREE` | `5g` | Free space nginx tries to maintain on the cache filesystem |
| `CACHE_INACTIVE` | `30d` | Evict entries that have not been accessed for this long |

For an API and download mirror, add `-e SERVE_SITE=false` to `docker run`. Only `api.<mirror>` and `dl.<mirror>` need DNS records and TLS certificate coverage. HTTPS requests to the bare mirror domain and `www.<mirror>` return `404` if they reach nginx with valid TLS. Website links and redirects point to `ORIGIN_DOMAIN`.

## Downloads

Downloads come from `dl.<origin>`. With the default origin, Gizlet's download service reads files from Cloudflare R2 and handles GitHub fallbacks. With `CACHE_ENABLED=false`, the mirror streams responses from that service and forwards byte-range requests for resume, checksum headers, and the origin's `Cache-Control` headers.

### Local cache

The mirror caches complete responses that the origin marks public and immutable. It admits versioned Gizlet OS files and packages addressed by a `sha256` query parameter. Credentials, mutable downloads, redirects, and private or `no-store` responses bypass storage. The download header `X-Mirror-Cache` reports nginx's result. A cached file supports Range and resume. A Range request starting at byte zero can fill an empty cache. On a cache miss, a resume from a later byte goes directly to the origin.

### S3

With caching enabled, set `S3_BUCKET` to add a shared second cache behind local disk. A full download missed on disk looks in S3, then falls back to the origin. A successful S3 read warms the disk cache. Origin downloads fill S3 in the background when the upload slot is available. A failed S3 lookup or upload does not prevent origin downloads.

| Variable | Default | Purpose |
| --- | --- | --- |
| `S3_BUCKET` | Unset | Existing bucket for cache objects |
| `S3_ENDPOINT` | AWS S3 | Custom service URL, including `https://`. Custom endpoints use path-style requests. |
| `S3_PREFIX` | `gizlet-mirror` | Prefix within the bucket |
| `AWS_REGION` | `us-east-1` | Signing region, for example `auto` on Cloudflare R2 |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` | AWS credential chain | Static or temporary credentials when needed |

For S3-compatible storage such as Cloudflare R2 or MinIO, set the endpoint and provider credentials. Keep the bucket private and grant the mirror `s3:GetObject` and `s3:PutObject` only for its cache prefix. Use the bucket's lifecycle policy to expire old objects. nginx's local size and eviction settings apply to local storage.

The S3 layer stages at most one full response at a time on `/cache`. It stages responses up to 5 GB. Larger responses still use the local nginx cache.

## Domain and account behavior

The proxy rewrites Gizlet URLs, redirects, cookie domains, and account CORS headers for the mirror. The OIDC publishing audience remains `https://api.gizlet.io`. GitHub sign-in and linking use the origin callback. Email and password sign-in and the device flow work on the mirror. To have account emails link to a mirror, the Gizlet maintainers add its domain to the origin's `SITE_DOMAINS` setting. The origin sees the mirror server's address for account rate limits, so sign-in limits are shared among its users.

## Development

Run `bash tests/native-nginx.sh` with nginx 1.27.3 or newer, dnsmasq, curl, and OpenSSL on your path. The script starts local DNS and HTTPS fixtures on high ports and checks both site modes, URL rewriting, disk cache hits, and uncached Range downloads. It uses an isolated nginx prefix and runs as the current user.

Run `go test -race ./...`, `docker build -t gizlet-mirror:test .`, and `bash tests/disk.sh` to test the S3 helper and the container. `./smoke.sh` checks the live Gizlet origin with Hurl and includes one sign-in attempt with an invalid password.

## Releases

GitHub Actions tests each pull request, push to `main`, and release tag. Successful `main` builds publish `sha-<commit>` images. To publish a release, push a `vMAJOR.MINOR.PATCH` Git tag from `main`. GitHub Actions publishes the matching image tag after the tests pass and points `latest` to the newest version.
