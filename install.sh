#!/bin/bash

set -e

read -p "Panel domain: " PANEL_DOMAIN
read -p "Subscription domain: " SUB_DOMAIN

EMAIL="admin@${PANEL_DOMAIN#panel.}"

mkdir -p /opt/remnawave
cd /opt/remnawave

apt update -y
apt install -y curl docker.io docker-compose-plugin caddy

systemctl enable docker
systemctl start docker

docker network create remnawave-network 2>/dev/null || true

DB_PASS=$(openssl rand -hex 12)

cat > .env <<EOF
POSTGRES_USER=remnawave
POSTGRES_PASSWORD=$DB_PASS
POSTGRES_DB=remnawave

DATABASE_URL=postgresql://remnawave:$DB_PASS@remnawave-db:5432/remnawave
EOF

cat > docker-compose.yml <<EOF
services:
  remnawave-db:
    image: postgres:17
    container_name: remnawave-db
    restart: unless-stopped
    environment:
      POSTGRES_USER: \${POSTGRES_USER}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
      POSTGRES_DB: \${POSTGRES_DB}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - remnawave-network

  valkey:
    image: valkey/valkey:9-alpine
    container_name: remnawave-valkey
    restart: unless-stopped
    networks:
      - remnawave-network

  remnawave-backend:
    image: remnawave/backend:2
    container_name: remnawave-backend
    restart: unless-stopped
    env_file:
      - .env
    depends_on:
      - remnawave-db
    ports:
      - "127.0.0.1:3000:3000"
    networks:
      - remnawave-network

  remnawave-sub:
    image: remnawave/subscription-page:latest
    container_name: remnawave-sub
    restart: unless-stopped
    ports:
      - "127.0.0.1:3010:3010"
    networks:
      - remnawave-network

volumes:
  postgres_data:

networks:
  remnawave-network:
    external: true
EOF

docker compose up -d

cat > /etc/caddy/Caddyfile <<EOF
{
    email $EMAIL
}

$PANEL_DOMAIN {
    reverse_proxy 127.0.0.1:3000
}

$SUB_DOMAIN {
    reverse_proxy 127.0.0.1:3010
}
EOF

systemctl restart caddy
systemctl enable caddy

echo ""
echo "=========================="
echo "INSTALL COMPLETE"
echo "=========================="
echo ""
echo "Panel: https://$PANEL_DOMAIN"
echo "Subscription: https://$SUB_DOMAIN"