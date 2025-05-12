#!/bin/bash

set -xe

set -a
source .env
set +a

# --- Install Nginx ---
sudo apt update
sudo apt install -y nginx

# --- Remove default site if it exists ---
sudo rm -f /etc/nginx/sites-enabled/default
sudo rm -f /etc/nginx/sites-available/default

# --- Write MAAS reverse proxy config with WebSocket support ---
sudo tee /etc/nginx/sites-available/maas >/dev/null <<EOF
server {
    listen 80;
    server_name _;

    # Redirect root to /MAAS/
    location = / {
        return 302 /MAAS/;
    }

    # Reverse proxy for MAAS
    location /MAAS/ {
        proxy_pass http://localhost:5240/MAAS/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF

# --- Enable the MAAS site ---
sudo ln -sf /etc/nginx/sites-available/maas /etc/nginx/sites-enabled/maas

# --- Test and reload Nginx ---
sudo nginx -t
sudo systemctl reload nginx

echo "✅ Nginx reverse proxy is active."
echo "🌐 Access MAAS at: http://$MAAS_IP"
