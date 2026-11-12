
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "ERROR: line $LINENO. Check output above." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root'; exit 1; }
. /etc/os-release
[[ ${ID:-} == debian && ${VERSION_ID:-} == 12 ]] || { echo 'Requires Debian 12'; exit 1; }
read -rp 'Domain (example: germany.adsfree.abrdns.com): ' DOMAIN
[[ $DOMAIN =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}$ ]] || { echo 'Invalid domain'; exit 1; }
read -rp 'Email for Lets Encrypt: ' EMAIL
[[ $EMAIL == *@*.* ]] || { echo 'Invalid email'; exit 1; }
if [[ -e /etc/x-ui/x-ui.db || -e /usr/local/x-ui/x-ui ]]; then echo '3x-ui already exists. Refusing to overwrite.'; exit 1; fi
if ss -ltnH | awk '{print $4}' | grep -Eq '(^|:)(80|443|8443|10000)$'; then echo 'One of ports 80,443,8443,10000 is occupied. Refusing to overwrite.'; exit 1; fi
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx certbot python3 python3-certbot-nginx sqlite3 curl openssl dnsutils ca-certificates
PUBLIC_IP=$(curl -4fsS --max-time 10 https://api.ipify.org)
if ! dig +short A "$DOMAIN" | grep -Fxq "$PUBLIC_IP"; then echo "DNS A for $DOMAIN does not match public IP $PUBLIC_IP"; exit 1; fi
PANEL_PORT=9595
PANEL_USER="admin_$(openssl rand -hex 4)"
PANEL_PASS="$(openssl rand -hex 20)"
PANEL_PATH="$(openssl rand -hex 12)"
CLIENT_UUID=$(cat /proc/sys/kernel/random/uuid)
SITE_DIR="/var/www/xhttp-decoy"
mkdir -p "$SITE_DIR"
cat > "$SITE_DIR/index.html" <<'HTML'
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Welcome</title></head><body><h1>Welcome</h1><p>Website is under construction.</p></body></html>
HTML
# Ensure the ACME HTTP challenge can be served before requesting a certificate.
cat > /etc/nginx/sites-available/xhttp-decoy <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    root $SITE_DIR;
    location /.well-known/acme-challenge/ { try_files \$uri =404; }
    location / { try_files \$uri \$uri/ =404; }
}
EOF
ln -sfn /etc/nginx/sites-available/xhttp-decoy /etc/nginx/sites-enabled/xhttp-decoy
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable --now nginx
systemctl reload nginx
certbot certonly --webroot -w "$SITE_DIR" -d "$DOMAIN" --email "$EMAIL" --agree-tos --non-interactive --no-eff-email
# The upstream installer is interactive; run it visibly so its prompts are not silently misanswered.
echo '3x-ui upstream installer will now run. Choose Skip SSL if asked; local-only panel will be configured immediately afterward.'
bash <(curl -fsSL https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)
[[ -x /usr/local/x-ui/x-ui ]] || { echo '3x-ui binary missing'; exit 1; }
/usr/local/x-ui/x-ui setting -username "$PANEL_USER" -password "$PANEL_PASS" -port "$PANEL_PORT" -webBasePath "$PANEL_PATH"
/usr/local/x-ui/x-ui setting -listenIP 127.0.0.1
systemctl restart x-ui
DB=/etc/x-ui/x-ui.db
[[ -f $DB ]] || { echo "Database not found: $DB"; exit 1; }
# Insert an inbound using the installed database schema, preserving DB defaults.
python3 - "$DB" "$CLIENT_UUID" <<'PY'
import sqlite3, json, sys, datetime
p, uuid = sys.argv[1:]
c = sqlite3.connect(p)
c.row_factory = sqlite3.Row
cols = {r['name']:r for r in c.execute('PRAGMA table_info(inbounds)')}
required = {'remark','enable','listen','port','protocol','settings','stream_settings','tag'}
missing = required - cols.keys()
if missing: raise SystemExit('Unexpected 3x-ui schema, missing: '+repr(sorted(missing)))
if c.execute('SELECT 1 FROM inbounds WHERE port=10000').fetchone(): raise SystemExit('Port 10000 inbound already exists')
settings = {'clients':[{'id':uuid,'flow':'','email':'client1','limitIp':0,'totalGB':0,'expiryTime':0,'enable':True,'tgId':0,'subId':'','reset':0}], 'decryption':'none','fallbacks':[]}
stream = {'network':'xhttp','security':'none','xhttpSettings':{'path':'/vless-xhttp','mode':'stream-up','host':'','extra':{'xPaddingBytes':'100-1000'}}}
values={'user_id':1,'up':0,'down':0,'total':0,'remark':'VLESS XHTTP','enable':1,'expiry_time':0,'listen':'127.0.0.1','port':10000,'protocol':'vless','settings':json.dumps(settings,separators=(',',':')),'stream_settings':json.dumps(stream,separators=(',',':')),'tag':'inbound-10000','sniffing':json.dumps({'enabled':False,'destOverride':[]})}
# Reject unknown mandatory fields instead of inserting a malformed inbound.
for name, spec in cols.items():
    if spec['notnull'] and spec['dflt_value'] is None and name not in values and not spec['pk']:
        raise SystemExit('Unrecognized required inbound column: '+name)
values={k:v for k,v in values.items() if k in cols}
keys=list(values)
c.execute('INSERT INTO inbounds ('+','.join('"'+k+'"' for k in keys)+') VALUES ('+','.join('?' for _ in keys)+')',[values[k] for k in keys])
c.commit()
print('Created inbound ID:',c.execute('SELECT id FROM inbounds WHERE port=10000').fetchone()[0])
PY
systemctl restart x-ui
# TLS terminates at Nginx. Xray receives HTTP on localhost.
cat > /etc/nginx/sites-available/xhttp-decoy <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    root $SITE_DIR;
    location /.well-known/acme-challenge/ { try_files \$uri =404; }
    location / { return 301 https://\$host\$request_uri; }
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
    location / { try_files \$uri \$uri/ =404; }
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
# Set up host-group records via the documented 3x-ui API.
python3 - "$DOMAIN" "$PANEL_PORT" "$PANEL_PATH" "$PANEL_USER" "$PANEL_PASS" "$DB" <<'PY'
import sys,sqlite3,json,http.cookiejar,urllib.request,urllib.parse,time
host,port,path,user,password,db=sys.argv[1:]
base=f'http://127.0.0.1:{port}/{path.strip("/")}/'
cookie=urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar())
opener=urllib.request.build_opener(cookie)
def call(route,payload=None):
    body=None if payload is None else json.dumps(payload).encode()
    req=urllib.request.Request(base+route,data=body,headers={'Content-Type':'application/json'} if body else {})
    with opener.open(req,timeout=15) as resp: return json.load(resp)
for attempt in range(10):
    try:
        result=call('login',{'username':user,'password':password})
        if result.get('success'): break
    except Exception:
        pass
    time.sleep(2)
else: raise SystemExit('Panel API login failed; host group not configured')
con=sqlite3.connect(db)
inbound=con.execute('SELECT id FROM inbounds WHERE port=10000').fetchone()[0]
current=call(f'panel/api/hosts/byInbound/{inbound}')
if not current.get('success'): raise SystemExit('Hosts lookup failed: '+str(current))
if host not in json.dumps(current.get('obj',[])):
    payload={'inboundIds':[inbound],'remark':'XHTTP '+host,'hosts':[host],'port':443,'security':'tls','tags':['XHTTP']}
    result=call('panel/api/hosts/add',payload)
    if not result.get('success'): raise SystemExit('Hosts creation failed: '+str(result))
    print('Created host group:',host)
PY
# Reload Nginx after successful certificate renewals.
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/sh
/usr/sbin/nginx -t && /bin/systemctl reload nginx
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
systemctl enable --now certbot.timer
RESULT=/root/xhttp-install-result.txt
cat > "$RESULT" <<EOF
Panel: https://$DOMAIN:8443/$PANEL_PATH/
Username: $PANEL_USER
Password: $PANEL_PASS
VLESS URI: vless://$CLIENT_UUID@$DOMAIN:443?encryption=none&security=tls&sni=$DOMAIN&host=$DOMAIN&fp=firefox&alpn=http%2F1.1&type=xhttp&path=%2Fvless-xhttp&mode=stream-up#XHTTP
EOF
chmod 600 "$RESULT"
echo 'INSTALLATION FINISHED. Credentials and link saved to:' "$RESULT"
cat "$RESULT"
