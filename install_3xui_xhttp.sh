#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
log(){ printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die 'Run as root.'
[[ -r /etc/os-release ]] || die 'Cannot identify OS.'
. /etc/os-release
[[ "$ID" == debian && "${VERSION_ID%%.*}" == 12 ]] || die 'Designed for Debian 12 only.'
[[ ! -e /etc/x-ui/x-ui.db && ! -e /usr/local/x-ui/x-ui ]] || die 'Existing 3x-ui detected. Use a clean VPS.'
[[ ! -f /etc/nginx/sites-enabled/default ]] || die 'Existing Nginx site detected. Use a clean VPS.'
read -rp 'Domain (e.g. vpn.example.com): ' DOMAIN
DOMAIN=${DOMAIN,,}
[[ "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || die 'Invalid domain.'
read -rp 'Email for Lets Encrypt: ' EMAIL
[[ "$EMAIL" == *@*.* ]] || die 'Invalid email.'
read -rp 'Panel HTTPS port [8443]: ' PANEL_PORT
PANEL_PORT=${PANEL_PORT:-8443}
[[ "$PANEL_PORT" =~ ^[0-9]+$ ]] && ((PANEL_PORT >= 1024 && PANEL_PORT <= 65535 && PANEL_PORT != 443 && PANEL_PORT != 80 && PANEL_PORT != 10000)) || die 'Invalid panel port.'
read -rp 'Public site title [Welcome]: ' SITE_TITLE
SITE_TITLE=${SITE_TITLE:-Welcome}
log 'Installing dependencies'
apt-get update -qq
apt-get install -y -qq curl ca-certificates openssl nginx certbot python3-certbot-nginx jq dnsutils sqlite3 python3
PUBLIC_IP=$(curl -4fsS --max-time 10 https://api.ipify.org) || die 'Cannot determine public IPv4.'
RESOLVED=$(dig +short A "$DOMAIN" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
grep -Fxq "$PUBLIC_IP" <<< "$RESOLVED" || die "DNS A record for $DOMAIN does not contain $PUBLIC_IP (got: $RESOLVED)."
for p in 80 443 "$PANEL_PORT" 10000; do
  if ss -H -ltn "sport = :$p" | grep -q . && [[ $p != 80 ]]; then die "Port $p already in use."; fi
done
UUID=$(cat /proc/sys/kernel/random/uuid)
PANEL_USER="admin_$(openssl rand -hex 4)"
PANEL_PASS=$(openssl rand -base64 24 | tr -d '/+=' | head -c 28)
PANEL_PATH="$(openssl rand -hex 10)"
XRAY_PATH="/vless-xhttp-$(openssl rand -hex 8)"
SITE_DIR=/var/www/vpn-placeholder
mkdir -p "$SITE_DIR" /etc/3xui-bootstrap
cat > "$SITE_DIR/index.html" <<HTML
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${SITE_TITLE//</&lt;}</title><style>body{font-family:system-ui,sans-serif;display:grid;place-items:center;min-height:95vh;background:#f7f8fa;color:#333}main{text-align:center}</style></head><body><main><h1>${SITE_TITLE//</&lt;}</h1><p>Website is online.</p></main></body></html>
HTML
cat > /etc/nginx/sites-available/vpn-bootstrap <<NGINX
server {
    listen 80;
    server_name $DOMAIN;
    root $SITE_DIR;
    location / { try_files \$uri \$uri/ =404; }
}
NGINX
ln -sf /etc/nginx/sites-available/vpn-bootstrap /etc/nginx/sites-enabled/vpn-bootstrap
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl enable --now nginx && systemctl reload nginx
log 'Obtaining TLS certificate'
certbot certonly --webroot -w "$SITE_DIR" -d "$DOMAIN" --email "$EMAIL" --agree-tos --non-interactive --no-eff-email || die 'Certificate request failed. Check DNS and inbound TCP/80.'
log 'Installing 3x-ui from official upstream'
# Official installer. Review upstream before running in high-assurance environments.
bash <(curl -fsSL https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh) <<INSTALL_INPUT
n
INSTALL_INPUT
[[ -x /usr/local/x-ui/x-ui ]] || die '3x-ui binary missing after install.'
# The CLI commands are supplied by the installed 3x-ui version.
/usr/local/x-ui/x-ui setting -username "$PANEL_USER" -password "$PANEL_PASS" -port 36901 -webBasePath "$PANEL_PATH" || die 'Cannot configure panel. Check installed 3x-ui CLI version.'
/usr/local/x-ui/x-ui restart
# Wait for database creation and then create a minimal XHTTP inbound via 3x-ui database.
DB=/etc/x-ui/x-ui.db
for _ in $(seq 1 30); do [[ -s "$DB" ]] && break; sleep 1; done
[[ -s "$DB" ]] || die '3x-ui database not found.'
# Stop 3x-ui before direct DB update; database layout is version-sensitive.
systemctl stop x-ui
python3 - "$DB" "$UUID" "$XRAY_PATH" <<'PY'
import sys,sqlite3,json,time
path,uid,xpath=sys.argv[1:]
con=sqlite3.connect(path)
cols={x[1] for x in con.execute('pragma table_info(inbounds)')}
required={'user_id','up','down','total','remark','enable','expiry_time','listen','port','protocol','settings','stream_settings','tag','sniffing'}
if not required.issubset(cols):
    raise SystemExit('Unsupported 3x-ui inbound schema; aborting without modifying it.')
client={'id':uid,'flow':'','email':'default','limitIp':0,'totalGB':0,'expiryTime':0,'enable':True,'tgId':'','subId':''}
settings={'clients':[client],'decryption':'none','fallbacks':[]}
stream={'network':'xhttp','security':'none','xhttpSettings':{'path':xpath,'mode':'auto','host':''}}
sniff={'enabled':False,'destOverride':['http','tls','quic'],'metadataOnly':False,'routeOnly':False}
vals={'user_id':1,'up':0,'down':0,'total':0,'remark':'VLESS-XHTTP','enable':1,'expiry_time':0,'listen':'127.0.0.1','port':10000,'protocol':'vless','settings':json.dumps(settings,separators=(',',':')),'stream_settings':json.dumps(stream,separators=(',',':')),'tag':'in-10000','sniffing':json.dumps(sniff,separators=(',',':'))}
keys=list(vals)
con.execute('INSERT INTO inbounds ('+','.join(keys)+') VALUES ('+','.join('?'*len(keys))+')',[vals[k] for k in keys])
con.commit()
con.close()
PY
systemctl start x-ui
log 'Configuring Nginx TLS and XHTTP reverse proxy'
cat > /etc/nginx/sites-available/vpn-bootstrap <<NGINX
server {
    listen 80;
    server_name $DOMAIN;
    root $SITE_DIR;
    location /.well-known/acme-challenge/ { try_files \$uri =404; }
    location / { return 301 https://\$host\$request_uri; }
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
    location / { try_files \$uri \$uri/ =404; }
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
nginx -t && systemctl reload nginx
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-vpn-nginx.sh <<'HOOK'
#!/bin/sh
systemctl reload nginx
HOOK
chmod 700 /etc/letsencrypt/renewal-hooks/deploy/reload-vpn-nginx.sh
systemctl enable --now certbot.timer
# Public path URL encoded in VLESS query.
ENC_PATH=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$XRAY_PATH")
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
log 'Verifying services'
ss -ltnp | grep -E ':(443|36901|10000)\b' || true
printf '\nDONE. Credentials saved at /root/3xui-install-result.txt\n'
cat /root/3xui-install-result.txt
