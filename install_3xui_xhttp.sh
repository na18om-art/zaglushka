
#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "ERROR at line $LINENO" >&2' ERR

# ==========================================
# Debian 12 / 3x-ui / VLESS XHTTP / Nginx
# ==========================================

[[ $EUID -eq 0 ]] || {
    echo "Run as root"
    exit 1
}

source /etc/os-release

[[ "$ID" == "debian" && "$VERSION_ID" == "12" ]] || {
    echo "Debian 12 required"
    exit 1
}

read -rp "Domain: " DOMAIN
read -rp "Email for Lets Encrypt: " EMAIL

DOMAIN="${DOMAIN,,}"

[[ "$DOMAIN" =~ ^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$ ]] || {
    echo "Invalid domain"
    exit 1
}

[[ "$EMAIL" == *@*.* ]] || {
    echo "Invalid email"
    exit 1
}

# ==========================================
# Variables
# ==========================================

PANEL_PORT=9595
TCP_PORT=9443
DECOY_PORT=8080
XRAY_PORT=10000
PANEL_USER="admin_$(openssl rand -hex 4)"
PANEL_PASS="$(openssl rand -hex 20)"
PANEL_PATH="$(openssl rand -hex 12)"

SITE_DIR="/var/www/xhttp-decoy"
NGINX_CONF="/etc/nginx/sites-available/xhttp-decoy"
RESULT="/root/xhttp-install-result.txt"
DB="/etc/x-ui/x-ui.db"

umask 077

# ==========================================
# Existing installation protection
# ==========================================

if [[ -e "$DB" || -e /usr/local/x-ui/x-ui ]]; then
    echo "3x-ui already installed."
    echo "Refusing to overwrite existing installation."
    exit 1
fi

# Check ports before installing packages.
# Port 80 may already be occupied by Nginx.

if ss -ltnH | awk '{print $4}' |
    grep -Eq '(^|:)(443|8443|9443|10000|9595|8080)$'; then
    echo "Required port already occupied."
    exit 1
fi

if ss -ltnpH | grep -E '(^|:)(80)[[:space:]]' |
    grep -qv 'nginx'; then
    echo "Port 80 is occupied by a non-Nginx service."
    exit 1
fi

# ==========================================
# Dependencies
# ==========================================

apt-get update

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    nginx \
    certbot \
    python3 \
    sqlite3 \
    curl \
    openssl \
    dnsutils \
    ca-certificates \
    iproute2

# ==========================================
# DNS validation
# ==========================================

PUBLIC_IP=$(curl -4fsS --max-time 15 \
    https://api.ipify.org)

echo "Server IP: $PUBLIC_IP"

if ! dig +short A "$DOMAIN" |
    grep -Fxq "$PUBLIC_IP"; then
    echo "DNS does not point to $PUBLIC_IP"
    exit 1
fi

# ==========================================
# Decoy website
# ==========================================

mkdir -p "$SITE_DIR"

cat > "$SITE_DIR/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport"
      content="width=device-width,initial-scale=1">
<title>Welcome</title>
<style>
body {
    font-family: Arial, sans-serif;
    margin: 0;
    min-height: 100vh;
    display: flex;
    justify-content: center;
    align-items: center;
    background: #f5f5f5;
    color: #333;
}
main {
    text-align: center;
}
</style>
</head>
<body>
<main>
<h1>Welcome</h1>
<p>Website is under construction.</p>
</main>
</body>
</html>
HTML

# IMPORTANT: Nginx must be able to traverse
# the directory and read the website files.

chmod 755 /var/www
chmod 755 "$SITE_DIR"
chmod 644 "$SITE_DIR/index.html"

mkdir -p "$SITE_DIR/.well-known/acme-challenge"

chmod 755 "$SITE_DIR/.well-known"
chmod 755 "$SITE_DIR/.well-known/acme-challenge"

# ==========================================
# Temporary HTTP configuration
# ==========================================

cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    root $SITE_DIR;
    index index.html;

    location ^~ /.well-known/acme-challenge/ {
        default_type text/plain;
        try_files \$uri =404;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

ln -sfn "$NGINX_CONF" \
    /etc/nginx/sites-enabled/xhttp-decoy

rm -f /etc/nginx/sites-enabled/default

nginx -t

systemctl enable --now nginx
systemctl reload nginx

# ==========================================
# Verify HTTP challenge
# ==========================================

TEST_FILE="test-$(openssl rand -hex 8)"

printf 'OK\n' > \
    "$SITE_DIR/.well-known/acme-challenge/$TEST_FILE"

chmod 644 \
    "$SITE_DIR/.well-known/acme-challenge/$TEST_FILE"

HTTP_RESPONSE=$(curl -fsS \
    --max-time 15 \
    "http://$DOMAIN/.well-known/acme-challenge/$TEST_FILE" \
    || true)

rm -f \
    "$SITE_DIR/.well-known/acme-challenge/$TEST_FILE"

if [[ "$HTTP_RESPONSE" != "OK" ]]; then
    echo "HTTP challenge verification failed."
    echo "Check DNS, Nginx and port 80."
    exit 1
fi

echo "HTTP challenge verification successful."

# ==========================================
# Let's Encrypt SSL
# ==========================================

certbot certonly \
    --webroot \
    -w "$SITE_DIR" \
    -d "$DOMAIN" \
    --email "$EMAIL" \
    --agree-tos \
    --non-interactive \
    --no-eff-email \
    --keep-until-expiring

CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

[[ -s "$CERT" && -s "$KEY" ]] || {
    echo "SSL certificate not found."
    exit 1
}

echo "SSL certificate ready."

# ==========================================
# Install 3x-ui
# ==========================================

echo
echo "Installing 3x-ui..."
echo "Choose SQLite."
echo "Skip built-in SSL configuration."
echo "Use localhost binding if prompted."
echo

bash <(curl -fsSL \
    https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)

[[ -x /usr/local/x-ui/x-ui ]] || {
    echo "3x-ui binary not found."
    exit 1
}

# ==========================================
# Configure panel
# ==========================================

/usr/local/x-ui/x-ui setting \
    -username "$PANEL_USER" \
    -password "$PANEL_PASS" \
    -port "$PANEL_PORT" \
    -webBasePath "$PANEL_PATH"

/usr/local/x-ui/x-ui setting \
    -listenIP 127.0.0.1

# Save credentials immediately.

cat > "$RESULT" <<EOF
Domain: $DOMAIN
Panel URL: https://$DOMAIN:8443/$PANEL_PATH/
Username: $PANEL_USER
Password: $PANEL_PASS
Status: installation in progress
EOF

chmod 600 "$RESULT"

[[ -f "$DB" ]] || {
    echo "3x-ui database missing."
    exit 1
}

# ==========================================
# Create VLESS XHTTP and VLESS TCP TLS inbounds
# Clients are added manually in 3x-ui.
# ==========================================

systemctl stop x-ui

python3 - "$DB" "$DOMAIN" <<'PY'
import sqlite3
import json
import sys

db = sys.argv[1]
domain = sys.argv[2]

con = sqlite3.connect(db)
con.row_factory = sqlite3.Row

cols = {
    row["name"]: row
    for row in con.execute(
        "PRAGMA table_info(inbounds)"
    )
}

required = {
    "remark",
    "enable",
    "listen",
    "port",
    "protocol",
    "settings",
    "stream_settings",
    "tag"
}

missing = required - cols.keys()

if missing:
    raise SystemExit(
        "Unexpected database schema: "
        + repr(sorted(missing))
    )

existing = con.execute(
    "SELECT id FROM inbounds WHERE port = 10000"
).fetchone()

if existing:
    raise SystemExit(
        "Inbound port 10000 already exists"
    )

settings = {
    "clients": [],
    "decryption": "none",
    "fallbacks": []
}

stream = {
    "network": "xhttp",
    "security": "none",
    "xhttpSettings": {
        "path": "/vless-xhttp",
        "mode": "stream-up",
        "host": "",
        "extra": {
            "xPaddingBytes": "100-1000"
        }
    }
}

values = {
    "user_id": 1,
    "up": 0,
    "down": 0,
    "total": 0,
    "remark": "VLESS XHTTP",
    "enable": 1,
    "expiry_time": 0,
    "listen": "127.0.0.1",
    "port": 10000,
    "protocol": "vless",
    "settings": json.dumps(
        settings,
        separators=(",", ":")
    ),
    "stream_settings": json.dumps(
        stream,
        separators=(",", ":")
    ),
    "tag": "inbound-10000",
    "sniffing": json.dumps({
        "enabled": False,
        "destOverride": []
    })
}

for name, spec in cols.items():
    if (
        spec["notnull"]
        and spec["dflt_value"] is None
        and name not in values
        and not spec["pk"]
    ):
        raise SystemExit(
            "Unknown required column: " + name
        )

values = {
    key: value
    for key, value in values.items()
    if key in cols
}

keys = list(values)

query = (
    "INSERT INTO inbounds ("
    + ",".join('"' + k + '"' for k in keys)
    + ") VALUES ("
    + ",".join("?" for _ in keys)
    + ")"
)

con.execute(
    query,
    [values[k] for k in keys]
)

# Second inbound: VLESS over raw TCP with TLS on port 9443.
# Unauthenticated HTTPS requests fall back to Nginx decoy on 8080.
tcp_settings = {
    "clients": [],
    "decryption": "none",
    "fallbacks": [{"dest": 8080}]
}
tcp_stream = {
    "network": "tcp",
    "security": "tls",
    "tcpSettings": {"acceptProxyProtocol": False},
    "tlsSettings": {
        "serverName": domain,
        "certificates": [{
            "certificateFile": f"/etc/letsencrypt/live/{domain}/fullchain.pem",
            "keyFile": f"/etc/letsencrypt/live/{domain}/privkey.pem"
        }],
        "alpn": ["http/1.1"],
        "minVersion": "1.2"
    }
}
tcp_values = dict(values)
tcp_values.update({
    "remark": "VLESS TCP TLS",
    "listen": "0.0.0.0",
    "port": 9443,
    "settings": json.dumps(tcp_settings, separators=(",", ":")),
    "stream_settings": json.dumps(tcp_stream, separators=(",", ":")),
    "tag": "inbound-9443"
})
con.execute(query, [tcp_values[k] for k in keys])
con.commit()
con.close()

print("VLESS XHTTP and TCP TLS inbounds created.")
PY

systemctl start x-ui

# ==========================================
# Final Nginx HTTPS configuration
# ==========================================

cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    root $SITE_DIR;

    location ^~ /.well-known/acme-challenge/ {
        default_type text/plain;
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    root $SITE_DIR;
    index index.html;

    ssl_certificate $CERT;
    ssl_certificate_key $KEY;

    ssl_protocols TLSv1.2 TLSv1.3;

    location ^~ /vless-xhttp {
        proxy_pass http://127.0.0.1:$XRAY_PORT;
        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_request_buffering off;
        proxy_buffering off;
        proxy_cache off;

        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;

        client_max_body_size 0;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}

# HTTP decoy used as fallback for VLESS TCP TLS on port 9443.
server {
    listen 127.0.0.1:8080;
    server_name $DOMAIN;
    root $SITE_DIR;
    index index.html;
    location / {
        try_files \$uri \$uri/ =404;
    }
}

server {
    listen 8443 ssl;
    server_name $DOMAIN;

    ssl_certificate $CERT;
    ssl_certificate_key $KEY;

    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        proxy_pass http://127.0.0.1:$PANEL_PORT;
        proxy_http_version 1.1;

        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

nginx -t
systemctl reload nginx

# ==========================================
# Automatic SSL renewal
# ==========================================

mkdir -p \
    /etc/letsencrypt/renewal-hooks/deploy

cat > \
/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/sh
/usr/sbin/nginx -t &&
/bin/systemctl reload nginx
/bin/systemctl restart x-ui
EOF

chmod 755 \
    /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

systemctl enable --now certbot.timer

# ==========================================
# Read actual panel path
# ==========================================

PANEL_PATH=$(sqlite3 "$DB" \
    "SELECT value FROM settings WHERE key='webBasePath';")

PANEL_PATH="${PANEL_PATH#/}"
PANEL_PATH="${PANEL_PATH%/}"

[[ -n "$PANEL_PATH" ]] || {
    echo "Panel path is empty."
    exit 1
}

# ==========================================
# Wait for panel startup
# ==========================================

echo "Waiting for 3x-ui panel..."

PANEL_HTTP=000

for attempt in $(seq 1 60); do

    PANEL_HTTP=$(curl -sS \
        --max-time 3 \
        -o /dev/null \
        -w '%{http_code}' \
        "http://127.0.0.1:$PANEL_PORT/$PANEL_PATH/" \
        2>/dev/null || true)

    if [[ "$PANEL_HTTP" == 200 ||
          "$PANEL_HTTP" == 302 ]]; then
        break
    fi

    sleep 2
done

if [[ "$PANEL_HTTP" != 200 &&
      "$PANEL_HTTP" != 302 ]]; then
    echo "Panel did not respond."
    echo "Credentials saved to $RESULT"
    exit 1
fi

# ==========================================
# Final result
# ==========================================

cat > "$RESULT" <<EOF
========================================
       INSTALLATION COMPLETE
========================================

DOMAIN:
$DOMAIN

PANEL URL:
https://$DOMAIN:8443/$PANEL_PATH/

USERNAME:
$PANEL_USER

PASSWORD:
$PANEL_PASS

----------------------------------------
3x-ui: installed
VLESS XHTTP: configured
VLESS TCP TLS: configured (port 9443)
TCP fallback: decoy website via Nginx on 127.0.0.1:8080
XHTTP path: /vless-xhttp
HTTPS port: 443
Panel HTTPS port: 8443
Hosts: configure manually
Clients: add manually to BOTH inbounds
SSL: automatic renewal enabled
IMPORTANT: open TCP port 9443 in provider firewall
----------------------------------------
EOF

chmod 600 "$RESULT"

echo
cat "$RESULT"
echo
echo "Saved to: $RESULT"
