#!/bin/bash
clear

echo "=== XRAY VLESS WS + H2 + QUOTA AUTO INSTALLER ==="

# CEK ROOT
if [[ $EUID -ne 0 ]]; then
  echo "Jalankan sebagai root!"
  exit 1
fi

# INPUT DOMAIN
read -p "Masukkan domain: " DOMAIN

# INSTALL DEPENDENCY
apt update -y
apt install -y curl wget unzip socat cron vnstat nginx jq bc

systemctl enable vnstat
systemctl start vnstat

# INSTALL XRAY
bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh)
systemctl enable xray

# FOLDER
mkdir -p /etc/xray/{users,quota}
mkdir -p /etc/ssl/xray

# CONFIG XRAY
cat > /usr/local/etc/xray/config.json << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": 10000,
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/vlessws" }
      }
    },
    {
      "port": 10001,
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "streamSettings": {
        "network": "http",
        "httpSettings": { "path": "/vlessh2" }
      }
    }
  ],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

# SSL SELF SIGNED
openssl req -x509 -nodes -days 365 \
-newkey rsa:2048 \
-keyout /etc/ssl/xray/privkey.pem \
-out /etc/ssl/xray/fullchain.pem \
-subj "/CN=$DOMAIN"

# NGINX CONFIG
cat > /etc/nginx/conf.d/xray.conf << EOF
server {
  listen 443 ssl http2;
  server_name $DOMAIN;

  ssl_certificate /etc/ssl/xray/fullchain.pem;
  ssl_certificate_key /etc/ssl/xray/privkey.pem;

  location /vlessws {
    proxy_pass http://127.0.0.1:10000;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
  }

  location /vlessh2 {
    proxy_pass http://127.0.0.1:10001;
    proxy_http_version 2;
    proxy_set_header Host \$host;
  }
}
EOF

systemctl restart nginx
systemctl restart xray

# SCRIPT ADD USER
cat > /usr/bin/add-vless << 'EOF'
#!/bin/bash
read -p "Username: " user
read -p "Quota (GB): " quota

uuid=$(cat /proc/sys/kernel/random/uuid)
quota_bytes=$((quota * 1024 * 1024 * 1024))

jq ".inbounds[].settings.clients += [{
  \"id\":\"$uuid\",
  \"email\":\"$user\"
}]" /usr/local/etc/xray/config.json > /tmp/x && mv /tmp/x /usr/local/etc/xray/config.json

echo "$quota_bytes" > /etc/xray/quota/$user
systemctl restart xray

echo "=========================="
echo "USER   : $user"
echo "UUID   : $uuid"
echo "QUOTA  : $quota GB"
echo "LINK WS:"
echo "vless://$uuid@$DOMAIN:443?path=/vlessws&security=tls&type=ws#$user"
echo "LINK H2:"
echo "vless://$uuid@$DOMAIN:443?path=/vlessh2&security=tls&type=http#$user"
echo "=========================="
EOF

chmod +x /usr/bin/add-vless

# SCRIPT CHECK QUOTA
cat > /usr/bin/check-quota << 'EOF'
#!/bin/bash
for user in $(ls /etc/xray/quota); do
  limit=$(cat /etc/xray/quota/$user)
  usage=$(vnstat --oneline | cut -d';' -f11)
  usage_bytes=$(echo "$usage*1024*1024" | bc)

  if [ "$usage_bytes" -ge "$limit" ]; then
    jq "del(.inbounds[].settings.clients[] | select(.email==\"$user\"))" \
    /usr/local/etc/xray/config.json > /tmp/x && mv /tmp/x /usr/local/etc/xray/config.json
    systemctl restart xray
    echo "$(date) $user QUOTA HABIS" >> /var/log/xray-quota.log
  fi
done
EOF

chmod +x /usr/bin/check-quota

# SCRIPT RESET QUOTA
cat > /usr/bin/reset-quota << 'EOF'
#!/bin/bash
for user in $(ls /etc/xray/quota); do
  echo "Reset quota $user"
done
EOF

chmod +x /usr/bin/reset-quota

# CRON
(crontab -l 2>/dev/null; echo "*/5 * * * * /usr/bin/check-quota") | crontab -
(crontab -l 2>/dev/null; echo "0 0 * * * /usr/bin/reset-quota") | crontab -

echo ""
echo "✅ INSTALLASI SELESAI"
echo "Gunakan perintah: add-vless"
echo "============================="install-vless-quota.sh
