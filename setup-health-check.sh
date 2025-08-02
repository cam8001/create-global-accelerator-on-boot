#!/bin/bash

# Setup nginx health check endpoint for Global Accelerator
set -e

echo "Setting up nginx health check endpoint..."

# Check if health endpoint already exists and works
if curl -s http://localhost/health 2>/dev/null | grep -q "OK"; then
    echo "Health check endpoint already exists and is working"
    exit 0
fi

# Install nginx
apt update
apt install nginx -y

# Create nginx configuration for health check
tee /etc/nginx/sites-available/health > /dev/null <<EOF
server {
    listen 80;
    server_name _;
    
    location /health {
        return 200 "OK";
        add_header Content-Type text/plain;
    }
}
EOF

# Enable configuration and remove default
ln -sf /etc/nginx/sites-available/health /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Enable and start nginx
systemctl enable nginx
systemctl restart nginx

echo "Health check endpoint configured at http://localhost/health"

# Test the endpoint
if curl -s http://localhost/health | grep -q "OK"; then
    echo "Health check endpoint is working correctly"
else
    echo "ERROR: Health check endpoint test failed" >&2
    exit 1
fi