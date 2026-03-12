#!/bin/sh
set -e

DOMAIN="passwordvaultmanager.duckdns.org"
EMAIL="kasthalameghana77@gmail.com"
CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"

echo "=== Starting SSL Setup for $DOMAIN ==="

# Check if we already have a valid certificate
if [ -f "$CERT_PATH" ]; then
    echo "==> Certificate already exists. Renewing if needed..."
    certbot renew --quiet || echo "Renewal check done."
else
    echo "==> No certificate found. Requesting new certificate from Let's Encrypt..."
    echo "==> Stopping Nginx temporarily to free port 80 for ACME challenge..."
    
    # Use standalone mode - Certbot will temporarily spin up its own HTTP server
    # This avoids any conflicts with Nginx and is more reliable than the nginx plugin
    certbot certonly \
        --standalone \
        --non-interactive \
        --agree-tos \
        --no-eff-email \
        -m "$EMAIL" \
        -d "$DOMAIN" \
        --verbose \
        2>&1 | tee /var/log/certbot.log

    if [ -f "$CERT_PATH" ]; then
        echo "==> SUCCESS! Certificate obtained."
    else
        echo "==> FAILED to obtain certificate. Check /var/log/certbot.log"
        echo "==> Starting Nginx with HTTP only..."
        nginx -g "daemon off;"
        exit 0
    fi
fi

echo "==> Configuring Nginx with SSL..."
# Write the HTTPS nginx config
cat > /etc/nginx/conf.d/default.conf << EOF
server {
    listen 80;
    server_name $DOMAIN;
    # Redirect HTTP to HTTPS
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;
    root /usr/share/nginx/html;
    index index.html;
    client_max_body_size 55m;
    server_tokens off;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript application/javascript application/xml+rss application/json;

    location = /healthz {
        access_log off;
        add_header Content-Type text/plain;
        return 200 "ok";
    }

    location /api/ {
        proxy_pass http://backend:8080/api/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }

    location /actuator/ {
        proxy_pass http://backend:8080/actuator/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
}
EOF

echo "==> Starting Nginx with SSL..."
nginx -g "daemon off;"
