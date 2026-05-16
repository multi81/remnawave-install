#!/usr/bin/env bash
set -e

clear

echo "======================================="
echo " Remnawave Production Installer"
echo "======================================="

read -p "Panel domain: " PANEL_DOMAIN
read -p "Subscription domain: " SUB_DOMAIN
read -p "Admin email: " ADMIN_EMAIL

mkdir -p /opt/remnawave
cd /opt/remnawave

apt update -y
apt install -y curl wget git unzip jq openssl software-properties-common

# Docker
curl -fsSL https://get.docker.com | bash

# Docker Compose
mkdir -p ~/.docker/cli-plugins

curl -SL \
https://github.com/docker/compose/releases/download/v2.39.1/docker-compose-linux-x86_64 \
-o ~/.docker/cli-plugins/docker-compose

chmod +x ~/.docker/cli-plugins/docker-compose

# Caddy
apt install -y debian-keyring debian-archive-keyring apt-transport-https

curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
| gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
| tee /etc/apt/sources.list.d/caddy-stable.list

apt update -y
apt install -y caddy

# Firewall
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# Random secrets
POSTGRES_PASSWORD=$(openssl rand -hex 24)
JWT_SECRET=$(openssl rand -hex 32)
SESSION_SECRET=$(openssl rand -hex 32)

# Docker network
docker network rm remnawave-network 2>/dev/null || true
docker network create remnawave-network

# ENV
cat > /opt/remnawave/.env <<EOF
############################
# DATABASE
############################

DATABASE_URL=postgresql://remnawave:${POSTGRES_PASSWORD}@postgres:5432/remnawave

############################
# APP
############################

APP_PORT=3000
SUBSCRIPTION_PORT=3010

JWT_AUTH_SECRET=${JWT_SECRET}
JWT_REFRESH_SECRET=${JWT_SECRET}

SESSION_SECRET=${SESSION_SECRET}

############################
# DOMAIN
############################

APP_URL=https://${PANEL_DOMAIN}
SUB_PUBLIC_DOMAIN=https://${SUB_DOMAIN}

############################
# NODE
############################

NODE_ENV=production

############################
# TELEGRAM
############################

TELEGRAM_BOT_TOKEN=
TELEGRAM_ADMIN_ID=

EOF

# docker-compose
cat > /opt/remnawave/docker-compose.yml <<EOF
services:

  postgres:
    image: postgres:17
    container_name: remnawave-db
    restart: always
    environment:
      POSTGRES_DB: remnawave
      POSTGRES_USER: remnawave
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - remnawave-network

  redis:
    image: valkey/valkey:9-alpine
    container_name: remnawave-redis
    restart: always
    command: valkey-server --appendonly yes
    volumes:
      - redis_data:/data
    networks:
      - remnawave-network

  backend:
    image: remnawave/backend:latest
    container_name: remnawave-backend
    restart: always
    env_file:
      - .env
    depends_on:
      - postgres
      - redis
    ports:
      - "127.0.0.1:3000:3000"
    networks:
      - remnawave-network

  subscription:
    image: remnawave/subscription-page:latest
    container_name: remnawave-subscription
    restart: always
    environment:
      BACKEND_URL: http://backend:3000
    depends_on:
      - backend
    ports:
      - "127.0.0.1:3010:3010"
    networks:
      - remnawave-network

volumes:
  postgres_data:
  redis_data:

networks:
  remnawave-network:
    external: true
EOF

# Caddy
cat > /etc/caddy/Caddyfile <<EOF
{
    email ${ADMIN_EMAIL}
}

${PANEL_DOMAIN} {
    encode gzip
    reverse_proxy 127.0.0.1:3000
}

${SUB_DOMAIN} {
    encode gzip
    reverse_proxy 127.0.0.1:3010
}
EOF

systemctl restart caddy

# Start stack
cd /opt/remnawave

docker compose pull
docker compose up -d

echo ""
echo "======================================="
echo " INSTALL COMPLETE"
echo "======================================="
echo ""
echo "Panel:"
echo "https://${PANEL_DOMAIN}"
echo ""
echo "Subscription:"
echo "https://${SUB_DOMAIN}"
echo ""
echo "Config:"
echo "/opt/remnawave/.env"
echo ""
