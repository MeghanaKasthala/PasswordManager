#!/bin/sh

echo "Starting Nginx in the background..."
# Nginx needs to be running so Certbot can verify the domain via port 80
nginx -g "daemon off;" &
NGINX_PID=$!

# Wait a few seconds to let Nginx fully start
sleep 3

echo "Requesting SSL certificate from Let's Encrypt for passwordvaultmanager.duckdns.org..."
# Run certbot non-interactively using the nginx plugin. This will automatically rewrite nginx.conf
# and reload Nginx to use the new SSL certificates on port 443!
certbot --nginx -m kasthalameghana77@gmail.com --agree-tos --no-eff-email -d passwordvaultmanager.duckdns.org --non-interactive || echo "Certbot failed, but Nginx is still running."

echo "Keeping container alive by tailing Nginx..."
wait $NGINX_PID
