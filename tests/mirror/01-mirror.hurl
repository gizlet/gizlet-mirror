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
header "Content-Security-Policy" contains "img-src 'self'"
header "Content-Security-Policy" not contains "{{origin}}"
body contains "https://{{mirror}}/api/v1"
body contains "https://{{mirror}}/?lang=ja"

GET https://{{mirror}}/static/site.css
HTTP 200
[Asserts]
header "Content-Type" contains "text/css"

# JSON URLs point at the mirror.
GET https://{{mirror}}/api/v1/resolve?url=github.com/gizlet/os
HTTP 200
[Asserts]
jsonpath "$.share_url" == "https://{{mirror}}/github.com/gizlet/os"
jsonpath "$.api_url" == "https://{{mirror}}/api/v1/gizlets/github.com/gizlet/os"
jsonpath "$.github_url" == "https://github.com/gizlet/os"

# The public API stays open to any origin.
GET https://{{mirror}}/api/v1
Origin: https://example.com
HTTP 200
[Asserts]
header "Access-Control-Allow-Origin" == "*"
jsonpath "$.name" == "Gizlet API"

# Account routes accept the mirror's site as their own.
OPTIONS https://{{mirror}}/api/v1/me
Origin: https://{{mirror}}
Access-Control-Request-Method: GET
HTTP 204
[Asserts]
header "Access-Control-Allow-Origin" == "https://{{mirror}}"
header "Access-Control-Allow-Credentials" == "true"

GET https://{{mirror}}/api/v1/me
HTTP 401

# Better Auth passes the origin check (a 403 otherwise) and rejects the password.
POST https://{{mirror}}/api/v1/auth/sign-in/email
Origin: https://{{mirror}}
Referer: https://{{mirror}}/login
{"email": "mirror-smoke@example.invalid", "password": "not-the-password-1"}
HTTP 401

GET https://{{mirror}}/assets/github.com/gizlet/no-such-gizlet/v0.0.0/x.gzl
HTTP 404

POST https://{{mirror}}/assets/github.com/gizlet/os/v1/x.gzl
HTTP 403
