# The nginx mirror (mirror/) in front of the real site, run by mirror/smoke.sh.
# {{mirror}} is the mirror domain, {{origin}} the one it serves (gizlet.io).

# Plain HTTP goes to HTTPS.
GET http://{{mirror}}/github.com/gizlet/os
HTTP 301
[Asserts]
header "Location" == "https://{{mirror}}/github.com/gizlet/os"

GET https://www.{{mirror}}/github.com/gizlet/gizlet
HTTP 301
[Asserts]
header "Location" == "https://{{mirror}}/github.com/gizlet/gizlet"

# Pages link to the mirror's hosts, compressed again after the rewrite.
GET https://{{mirror}}/?lang=en
[Options]
compressed: true
HTTP 200
[Asserts]
header "Content-Encoding" == "gzip"
header "Content-Security-Policy" contains "https://dl.{{mirror}}"
header "Content-Security-Policy" not contains "{{origin}}"
body contains "https://api.{{mirror}}/v1"
body contains "https://{{mirror}}/?lang=ja"
body not contains "https://{{origin}}"
# The publishing example posts to the mirror with a token for the Worker's OIDC audience.
body contains "https://api.{{mirror}}/v1/publish"
body contains "audience=https://api.{{origin}}\""
body replace "audience=https://api.{{origin}}" "" not contains "https://api.{{origin}}"

GET https://{{mirror}}/static/site.css
HTTP 200
[Asserts]
header "Content-Type" contains "text/css"

# JSON URLs point at the mirror.
GET https://api.{{mirror}}/v1/resolve?url=github.com/gizlet/os
HTTP 200
[Asserts]
jsonpath "$.share_url" == "https://{{mirror}}/github.com/gizlet/os"
jsonpath "$.api_url" == "https://api.{{mirror}}/v1/gizlets/github.com/gizlet/os"
jsonpath "$.github_url" == "https://github.com/gizlet/os"

# The public API stays open to any origin.
GET https://api.{{mirror}}/v1
Origin: https://example.com
HTTP 200
[Asserts]
header "Access-Control-Allow-Origin" == "*"
jsonpath "$.name" == "Gizlet API"

# Account routes accept the mirror's site as their own.
OPTIONS https://api.{{mirror}}/v1/me
Origin: https://{{mirror}}
Access-Control-Request-Method: GET
HTTP 204
[Asserts]
header "Access-Control-Allow-Origin" == "https://{{mirror}}"
header "Access-Control-Allow-Credentials" == "true"

GET https://api.{{mirror}}/v1/me
HTTP 401

# Better Auth passes the origin check (a 403 otherwise) and rejects the password.
POST https://{{mirror}}/v1/auth/sign-in/email
Origin: https://{{mirror}}
Referer: https://{{mirror}}/login
{"email": "mirror-smoke@example.invalid", "password": "not-the-password-1"}
HTTP 401

# Downloads: redirects to the mirror's site, and answers from dl as they are.
GET https://dl.{{mirror}}/
HTTP 302
[Asserts]
header "Location" == "https://{{mirror}}"

GET https://dl.{{mirror}}/github.com/gizlet/no-such-gizlet/v0.0.0/x.gzl
HTTP 404

POST https://dl.{{mirror}}/github.com/gizlet/os/v1/x.gzl
HTTP 403
