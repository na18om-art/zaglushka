
#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "ERROR: line $LINENO. Check output above." >&2' ERR

[[ $EUID -eq 0 ]] || {
    echo "Run as root"
    exit 1
}

. /etc/os-release

[[ ${ID:-} == debian && ${VERSION_ID:-} == 12 ]] || {
    echo "Requires Debian 12"
    exit 1
}

read -rp "Domain: " DOMAIN

[[ $DOMAIN =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}$ ]] || {
    echo "Invalid domain"
    exit 1
}

read -rp "Email for Lets Encrypt: " EMAIL

[[ $EMAIL == *@*.* ]] || {
    echo "Invalid email"
    exit 1
}

if [[ -e /etc/x-ui/x-ui.db || -e /usr/local/x-ui/x-ui ]]; then
    echo "3x-ui already exists. Refusing to overwrite."
    exit 1
fi

# Check ports BEFORE installing Nginx

if ss -ltnH | awk '{print $4}' |
    grep -Eq '(^|:)(80|443|8443|10000)$'; then
    echo "One of ports 80,443,8443,10000 is occupied."
    exit 1
fi

apt-get update

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    nginx certbot python3 sqlite3 curl openssl \
    dnsutils ca-certificates iproute2

PUBLIC_IP=$(curl -4fsS --max-time 10 https://api.ipify.org)

if ! dig +short A "$DOMAIN" | grep -Fxq "$PUBLIC_IP"; then
    echo "DNS A for $DOMAIN does not match public IP $PUBLIC_IP"
    exit 1
fi

PANEL_PORT=9595
PANEL_USER="admin_$(openssl rand -hex 4)"
PANEL_PASS="$(openssl rand -hex 20)"
PANEL_PATH="$(openssl rand -hex 12)"

SITE_DIR="/var/www/xhttp-decoy"
RESULT="/root/xhttp-install-result.txt"

umask 077

mkdir -p "$SITE_DIR"

cat > "$SITE_DIR/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Welcome</title>
</head>
<body>
<h1>Welcome</h1>
<p>Website is under construction.</p>
</body>
</html>
HTML

chmod 755 "$SITE_DIR"
chmod 644 "$SITE_DIR/index.html"

# Temporary HTTP site for Let's Encrypt

cat > /etc/nginx/sites-available/xhttp-decoy <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    root $SITE_DIR;

    location /.well-known/acme-challenge/ {
        try_files \$uri =404;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

ln -sfn /etc/nginx/sites-available/xhttp-decoy \
    /etc/nginx/sites-enabled/xhttp-decoy

rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl enable --now nginx
systemctl reload nginx

certbot certonly --webroot \
    -w "$SITE_DIR" \
    -d "$DOMAIN" \
    --email "$EMAIL" \
    --agree-tos \
    --non-interactive \
    --no-eff-email

# Install 3x-ui

echo
echo "Installing 3x-ui..."
echo "Choose SQLite, Skip SSL (4), localhost binding (y)."
echo

bash <(curl -fsSL \
    https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)

[[ -x /usr/local/x-ui/x-ui ]] || {
    echo "3x-ui binary missing"
    exit 1
}

# Configure panel

/usr/local/x-ui/x-ui setting \
    -username "$PANEL_USER" \
    -password "$PANEL_PASS" \
    -port "$PANEL_PORT" \
    -webBasePath "$PANEL_PATH"

/usr/local/x-ui/x-ui setting -listenIP 127.0.0.1

# Save credentials before further configuration

cat > "$RESULT" <<EOF
Domain: $DOMAIN
Panel URL: https://$DOMAIN:8443/$PANEL_PATH/
Username: $PANEL_USER
Password: $PANEL_PASS
Status: installation in progress
EOF

chmod 600 "$RESULT"

DB=/etc/x-ui/x-ui.db

[[ -f $DB ]] || {
    echo "Database not found: $DB"
    exit 1
}

# Create VLESS + XHTTP inbound without clients

systemctl stop x-ui

python3 - "$DB" <<'PY'
import sqlite3
import json
import sys

db = sys.argv[1]
con = sqlite3.connect(db)
con.row_factory = sqlite3.Row

cols = {
    row["name"]: row
    for row in con.execute("PRAGMA table_info(inbounds)")
}

required = {
    "remark", "enable", "listen", "port",
    "protocol", "settings", "stream_settings", "tag"
}

missing = required - cols.keys()

if missing:
    raise SystemExit(
        "Unexpected schema: " + repr(sorted(missing))
    )

if con.execute(
    "SELECT 1 FROM inbounds WHERE port=10000"
).fetchone():
    raise SystemExit("Inbound port 10000 already exists")

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
        settings, separators=(",", ":")
    ),
    "stream_settings": json.dumps(
        stream, separators=(",", ":")
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

con.execute(
    "INSERT INTO inbounds (" +
    ",".join('"' + key + '"' for key in keys) +
    ") VALUES (" +
    ",".join("?" for _ in keys) + ")",
    [values[key] for key in keys]
)

con.commit()

print(
    "Created inbound ID:",
    con.execute(
        "SELECT id FROM inbounds WHERE port=10000"
    ).fetchone()[0]
)

con.close()
PY

systemctl start x-ui

# HTTPS Nginx configuration

cat > /etc/nginx/sites-available/xhttp-decoy <<EOF
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
    listen 443 ssl;
    server_name $DOMAIN;
    root $SITE_DIR;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    location ^~ /vless-xhttp {
        proxy_pass http://127.0.0.1:10000;
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

server {
    listen 8443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

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

# Hosts are configured manually in 3x-ui

# Automatic SSL renewal

mkdir -p /etc/letsencrypt/renewal-hooks/deploy

cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/sh
/usr/sbin/nginx -t && /bin/systemctl reload nginx
EOF

chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

systemctl enable --now certbot.timer

# Read actual panel path

PANEL_PATH=$(sqlite3 "$DB" \
    "SELECT value FROM settings WHERE key='webBasePath';")

PANEL_PATH="${PANEL_PATH#/}"
PANEL_PATH="${PANEL_PATH%/}"

[[ -n "$PANEL_PATH" ]] || {
    echo "Panel base path is empty"
    exit 1
}

# Wait for panel startup

echo "Waiting for 3x-ui panel..."

PANEL_HTTP=000

for attempt in $(seq 1 60); do
    PANEL_HTTP=$(curl -sS --max-time 3 \
        -o /dev/null \
        -w '%{http_code}' \
        "http://127.0.0.1:$PANEL_PORT/$PANEL_PATH/" \
        2>/dev/null || true)

    if [[ "$PANEL_HTTP" == 200 || "$PANEL_HTTP" == 302 ]]; then
        break
    fi

    sleep 2
done

if [[ "$PANEL_HTTP" != 200 && "$PANEL_HTTP" != 302 ]]; then
    echo "WARNING: panel did not respond (HTTP $PANEL_HTTP)"
    echo "Credentials saved to $RESULT"
    exit 1
fi

# Final installation result

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
VLESS + XHTTP: configured
Hosts: configure manually in 3x-ui
SSL: automatic renewal enabled
----------------------------------------
EOF

chmod 600 "$RESULT"

echo
cat "$RESULT"
echo
echo "Saved to: $RESULT"
