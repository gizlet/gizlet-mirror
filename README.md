# Gizlet Mirror

Run Gizlet under your own domain with an nginx reverse proxy and a persistent download cache. GitHub Actions publishes Linux `amd64` and `arm64` images to `ghcr.io/gizlet/gizlet-mirror` after each update to `main`.

## Deploy

Point the mirror domain and its `www`, `api`, and `dl` hosts at your server. Obtain a TLS certificate for all four names before starting the container. For `gizlet.example`, the four hosts serve the site, the redirect to the site, the JSON API, and downloads respectively.

```sh
docker run -d --name gizlet-mirror --restart unless-stopped \
  -p 80:80 -p 443:443 \
  -e MIRROR_DOMAIN=gizlet.example \
  -e CACHE_MAX_SIZE=500g \
  -e CACHE_MIN_FREE=20g \
  --mount type=bind,src=/mnt/big-disk/gizlet,dst=/cache \
  --mount type=bind,src=/etc/letsencrypt,dst=/etc/letsencrypt,readonly \
  --mount type=bind,src=/var/www/acme,dst=/var/www/acme,readonly \
  ghcr.io/gizlet/gizlet-mirror:latest
```

Create the host directories first. The container requires a mount at `/cache` and creates its cache subdirectories there. A Docker named volume also works if it lives on the intended disk. Use a separate local volume per container. HTTP serves ACME challenges from `/var/www/acme` and redirects other requests to HTTPS. Restart the container after renewing the certificate.

| Variable | Default | Purpose |
| --- | --- | --- |
| `MIRROR_DOMAIN` | Required | Domain to serve, without a scheme |
| `ORIGIN_DOMAIN` | `gizlet.io` | Gizlet origin |
| `SSL_CERT`, `SSL_KEY` | `/etc/letsencrypt/live/<mirror>/fullchain.pem`, `privkey.pem` | Mirror certificate and key |
| `CA_BUNDLE` | `/etc/ssl/certs/ca-certificates.crt` | Origin CA bundle |
| `RESOLVER` | `1.1.1.1 8.8.8.8` | DNS resolvers used by nginx |
| `ACME_ROOT` | `/var/www/acme` | Webroot for HTTP certificate challenges |
| `HTTP_PORT`, `HTTPS_PORT` | `80`, `443` | Container listen ports |
| `ORIGIN_HTTPS_PORT` | `443` | HTTPS port on the origin hosts |
| `CACHE_MAX_SIZE` | `100g` | nginx disk cache target size |
| `CACHE_MIN_FREE` | `5g` | Free space nginx tries to maintain on the cache filesystem |
| `CACHE_INACTIVE` | `30d` | Evict entries that have not been accessed for this long |

## Download caching

The mirror caches complete responses that the origin marks public and immutable. It admits versioned Gizlet OS files and packages addressed by a `sha256` query parameter. Credentials, mutable downloads, redirects, and private or `no-store` responses bypass storage. The download header `X-Mirror-Cache` reports nginx's result. A cached file supports Range and resume. A Range request starting at byte zero can fill an empty cache. On a cache miss, a resume from a later byte goes directly to the origin.

### S3

Set `S3_BUCKET` to add a shared second cache behind local disk. A full download missed on disk looks in S3, then falls back to the origin. A successful S3 read warms the disk cache. Origin downloads fill S3 in the background when the upload slot is available. A failed S3 lookup or upload does not prevent origin downloads.

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

Run `bash tests/native-nginx.sh` with nginx 1.27.3 or newer, dnsmasq, curl, and OpenSSL on your path. The script starts local DNS and HTTPS fixtures on high ports, renders the config with a temporary `CACHE_PATH`, and checks host routing, URL rewriting, and cached Range downloads. It uses an isolated nginx prefix and runs as the current user.

Run `go test -race ./...`, `docker build -t gizlet-mirror:test .`, and `bash tests/disk.sh` to test the S3 helper and the container. `./smoke.sh` checks the live Gizlet origin with Hurl and includes one sign-in attempt with an invalid password.

GitHub Actions runs the native nginx and container tests on pull requests and on `main`. After both jobs pass on `main`, the workflow publishes the image to GHCR with a `sha-<commit>` tag and updates `latest` for the current head.
