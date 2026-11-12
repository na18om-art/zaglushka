
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

log() {
    printf '\n==> %s\n' "$*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

[[ $EUID -eq 0 ]] || die "Run as root."
[[ -r /etc/os-release ]] || die "Cannot identify OS."

. /etc/os-release

[[ "$ID" == debian && "${VERSION_ID%%.*}" == 12 ]] ||
    die "Designed for Debian 12 only."

[[ ! -e /etc/x-ui/x-ui.db && ! -e /usr/local/x-ui/x-ui ]] ||
    die "Existing 3x-ui detected. Use a clean VPS."

[[ ! -f /etc/nginx/sites-enabled/default ]] ||
    die "Existing Nginx site detected. Use a clean VPS."

read -rp "Domain (e.g. vpn.example.com): " DOMAIN
DOMAIN=${DOMAIN,,}

[[ "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] ||
    die "Invalid domain."

read -rp "Email for Lets Encrypt: " EMAIL
[[ "$EMAIL" == *@*.* ]] || die "Invalid email."

read -rp "Panel HTTPS port [8443]: " PANEL_PORT
PANEL_PORT=${PANEL_PORT:-8443}

[[ "$PANEL_PORT" =~ ^[0-9]+$ ]] &&
((PANEL_PORT >= 1024 && PANEL_PORT <= 65535 &&
  PANEL_PORT != 443 && PANEL_PORT != 80 &&
  PANEL_PORT != 10000)) ||
    die "Invalid panel port."

read -rp "Public site title [Welcome]: " SITE_TITLE
SITE_TITLE=${SITE_TITLE:-Welcome}

log "Installing dependencies"

apt-get update -qq

apt-get install -y -qq \
    curl ca-certificates openssl nginx certbot \
    python3-certbot-nginx jq dnsutils sqlite3 python3

PUBLIC_IP=$(curl -4fsS --max-time 10 https://api.ipify.org) ||
    die "Cannot determine public IPv4."

RESOLVED=$(dig +short A "$DOMAIN" |
    grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)

grep -Fxq "$PUBLIC_IP" <<< "$RESOLVED" ||
    die "DNS A record for $DOMAIN does not contain $PUBLIC_IP (got: $RESOLVED)."

for p in 80 443 "$PANEL_PORT" 10000; do
    if ss -H -ltn "sport = :$p" | grep -q . &&
       [[ $p != 80 ]]; then
        die "Port $p already in use."
    fi
done

UUID=$(cat /proc/sys/kernel/random/uuid)
PANEL_USER="admin_$(openssl rand -hex 4)"
PANEL_PASS=$(openssl rand -base64 24 | tr -d '/+=' | head -c 28)
PANEL_PATH="$(openssl rand -hex 10)"
XRAY_PATH="/vless-xhttp-$(openssl rand -hex 8)"

SITE_DIR=/var/www/vpn-placeholder

mkdir -p "$SITE_DIR" /etc/3xui-bootstrap

cat > "$SITE_DIR/index.html" <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${SITE_TITLE//</&lt;}</title>
<style>
body {
    font-family:system-ui,sans-serif;
    display:grid;
    place-items:center;
    min-height:95vh;
    background:#f7f8fa;
    color:#333
}
main { text-align:center }
</style>
</head>
<body>
<main>
<h1>${SITE_TITLE//</&lt;}</h1>
<p>Website is online.</p>
</main>
</body>
</html>
HTML

cat > /etc/nginx/sites-available/vpn-bootstrap <<NGINX
server {
    listen 80;
    server_name $DOMAIN;
    root $SITE_DIR;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
NGINX

ln -sf /etc/nginx/sites-available/vpn-bootstrap \
    /etc/nginx/sites-enabled/vpn-bootstrap

rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl enable --now nginx
systemctl reload nginx

log "Obtaining TLS certificate"

certbot certonly \
    --webroot \
    -w "$SITE_DIR" \
    -d "$DOMAIN" \
    --email "$EMAIL" \
    --agree-tos \
    --non-interactive \
    --no-eff-email ||
    die "Certificate request failed. Check DNS and inbound TCP/80."

log "Installing 3x-ui from official upstream"

bash <(curl -fsSL \
    https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh) <<INSTALL_INPUT
n
INSTALL_INPUT

[[ -x /usr/local/x-ui/x-ui ]] ||
    die "3x-ui binary missing after install."

/usr/local/x-ui/x-ui setting \
    -username "$PANEL_USER" \
    -password "$PANEL_PASS" \
    -port 36901 \
    -webBasePath "$PANEL_PATH" ||
    die "Cannot configure panel."

/usr/local/x-ui/x-ui setting -listenIP 127.0.0.1

/usr/local/x-ui/x-ui restart

DB=/etc/x-ui/x-ui.db

for _ in $(seq 1 30); do
    [[ -s "$DB" ]] && break
    sleep 1
done

[[ -s "$DB" ]] || die "3x-ui database not found."

systemctl stop x-ui

python3 - "$DB" "$UUID" "$XRAY_PATH" "$DOMAIN" <<'PY'
import sys
import sqlite3
import json

path, uid, xpath, domain = sys.argv[1:]

con = sqlite3.connect(path)

cols = {
    x[1] for x in con.execute("pragma table_info(inbounds)")
}

required = {
    "user_id", "up", "down", "total", "remark",
    "enable", "expiry_time", "listen", "port",
    "protocol", "settings", "stream_settings",
    "tag", "sniffing"
}

if not required.issubset(cols):
    raise SystemExit("Unsupported 3x-ui inbound schema.")

client = {
    "id": uid,
    "flow": "",
    "email": "default",
    "limitIp": 0,
    "totalGB": 0,
    "expiryTime": 0,
    "enable": True,
    "tgId": 0,
    "subId": ""
}

settings = {
    "clients": [client],
    "decryption": "none",
    "fallbacks": []
}

stream = {
    "network": "xhttp",
    "security": "none",
    "xhttpSettings": {
        "path": xpath,
        "mode": "auto",
        "host": domain
    }
}

sniff = {
    "enabled": False,
    "destOverride": ["http", "tls", "quic"],
    "metadataOnly": False,
    "routeOnly": False
}

vals = {
    "user_id": 1,
    "up": 0,
    "down": 0,
    "total": 0,
    "remark": "VLESS-XHTTP",
    "enable": 1,
    "expiry_time": 0,
    "listen": "127.0.0.1",
    "port": 10000,
    "protocol": "vless",
    "settings": json.dumps(settings, separators=(",", ":")),
    "stream_settings": json.dumps(stream, separators=(",", ":")),
    "tag": "in-10000",
    "sniffing": json.dumps(sniff, separators=(",", ":"))
}

keys = list(vals)

con.execute(
    "INSERT INTO inbounds (" + ",".join(keys) + ") VALUES (" +
    ",".join("?" * len(keys)) + ")",
    [vals[k] for k in keys]
)

con.commit()
con.close()
PY

systemctl start x-ui

log "Configuring Nginx TLS and XHTTP reverse proxy"

cat > /etc/nginx/sites-available/vpn-bootstrap <<NGINX
server {
    listen 80;
    server_name $DOMAIN;
    root $SITE_DIR;

    location /.well-known/acme-challenge/ {
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    root $SITE_DIR;
    index index.html;

    location ^~ $XRAY_PATH {
        proxy_pass http://127.0.0.1:10000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
        proxy_request_buffering off;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}

server {
    listen $PANEL_PORT ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        proxy_pass http://127.0.0.1:36901;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
NGINX

nginx -t
systemctl reload nginx

log "Configuring managed Hosts"

cat > /root/configure_3xui_hosts.py <<'PY_HOSTS'
#!/usr/bin/env python3

import argparse
import json
import urllib.parse
import urllib.request
import http.cookiejar
import sys

p = argparse.ArgumentParser()

for k in ("domain", "username", "password", "basepath"):
    p.add_argument("--" + k, required=True)

p.add_argument("--inbound", type=int, default=1)
a = p.parse_args()

base = (
    "http://127.0.0.1:36901/" +
    a.basepath.strip("/") + "/"
)

jar = http.cookiejar.CookieJar()

opener = urllib.request.build_opener(
    urllib.request.HTTPCookieProcessor(jar)
)

def request(path, data=None, json_body=False):
    headers = {}

    if data is not None:
        if json_body:
            data = json.dumps(data).encode()
            headers["Content-Type"] = "application/json"
        else:
            data = urllib.parse.urlencode(data).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"

    req = urllib.request.Request(
        base + path,
        data=data,
        headers=headers
    )

    with opener.open(req, timeout=15) as resp:
        return json.loads(resp.read())

login = request(
    "login",
    {
        "username": a.username,
        "password": a.password
    }
)

if not login.get("success"):
    raise SystemExit(
        "3x-ui login failed: " + str(login.get("msg"))
    )

existing = request(
    "panel/api/hosts/byInbound/" + str(a.inbound)
)

if not existing.get("success"):
    raise SystemExit(
        "Hosts lookup failed: " + str(existing.get("msg"))
    )

for host in existing.get("obj") or []:
    if a.domain in json.dumps(host):
        print("Managed Host already present:", a.domain)
        sys.exit(0)

payload = {
    "inboundIds": [a.inbound],
    "remark": "XHTTP " + a.domain,
    "hosts": [a.domain],
    "port": 443,
    "security": "tls",
    "sni": a.domain,
    "host": a.domain,
    "fingerprint": "chrome",
    "alpn": ["http/1.1"]
}

res = request(
    "panel/api/hosts/add",
    payload,
    True
)

if not res.get("success"):
    raise SystemExit(
        "Hosts creation failed: " + str(res.get("msg"))
    )

print("Managed Host created:", a.domain)
PY_HOSTS

chmod 700 /root/configure_3xui_hosts.py

for _ in $(seq 1 30); do
    curl -fsS --max-time 2 -o /dev/null \
        "http://127.0.0.1:36901/$PANEL_PATH/" &&
        break || sleep 1
done

python3 /root/configure_3xui_hosts.py \
    --domain "$DOMAIN" \
    --username "$PANEL_USER" \
    --password "$PANEL_PASS" \
    --basepath "$PANEL_PATH" ||
    die "Managed Hosts setup failed."

cat > /etc/letsencrypt/renewal-hooks/deploy/reload-vpn-nginx.sh <<'HOOK'
#!/bin/sh
systemctl reload nginx
HOOK

chmod 700 \
    /etc/letsencrypt/renewal-hooks/deploy/reload-vpn-nginx.sh

systemctl enable --now certbot.timer

ENC_PATH=$(python3 -c \
    'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' \
    "$XRAY_PATH")

VLESS="vless://$UUID@$DOMAIN:443?encryption=none&security=tls&sni=$DOMAIN&fp=chrome&type=xhttp&path=$ENC_PATH&mode=auto#VLESS-XHTTP"

cat > /root/3xui-install-result.txt <<RESULT
Website: https://$DOMAIN/
Panel: https://$DOMAIN:$PANEL_PORT/$PANEL_PATH/
Panel user: $PANEL_USER
Panel password: $PANEL_PASS
VLESS link: $VLESS
Local XHTTP: 127.0.0.1:10000
RESULT

chmod 600 /root/3xui-install-result.txt

log "Verifying services"

ss -ltnp | grep -E ':(443|36901|10000)\b' || true

printf '\nDONE. Credentials saved at /root/3xui-install-result.txt\n'

cat /root/3xui-install-result.txt
