#!/usr/bin/env bash
set -Eeuo pipefail

clear

echo "========================================="
echo "   Remnawave Production Installer"
echo "========================================="
echo ""

read -p "Panel domain (example: panel.domain.com): " PANEL_DOMAIN
read -p "Subscription domain (example: sub.domain.com): " SUB_DOMAIN
read -p "Admin email (Let's Encrypt): " ADMIN_EMAIL

SERVER_IP=$(curl -4 -s ifconfig.me)

echo ""
echo "========================================="
echo " DNS CHECK"
echo "========================================="
echo ""

PANEL_IP=$(dig +short ${PANEL_DOMAIN} A | tail -n1)
SUB_IP=$(dig +short ${SUB_DOMAIN} A | tail -n1)

echo "Server IP: ${SERVER_IP}"
echo "Panel DNS: ${PANEL_IP}"
echo "Sub DNS:   ${SUB_IP}"
echo ""

if [[ "${PANEL_IP}" != "${SERVER_IP}" ]]; then
  echo "ERROR: ${PANEL_DOMAIN} does not point to this server"
  exit 1
fi

if [[ "${SUB_IP}" != "${SERVER_IP}" ]]; then
  echo "ERROR: ${SUB_DOMAIN} does not point to this server"
  exit 1
fi

echo "DNS OK"
sleep 2

mkdir -p /opt/remnawave
cd /opt/remnawave

echo ""
echo "========================================="
echo " INSTALLING PACKAGES"
echo "========================================="
echo ""

apt update -y

apt install -y \
curl \
wget \
git \
unzip \
jq \
openssl \
ufw \
ca-certificates \
gnupg \
lsb-release \
software-properties-common \
apt-transport-https \
debian-keyring \
debian-archive-keyring \
dnsutils

echo ""
echo "========================================="
echo " INSTALLING DOCKER"
echo "========================================="
echo ""

curl -fsSL https://get.docker.com | bash

systemctl enable docker
systemctl start docker

mkdir -p ~/.docker/cli-plugins

curl -SL \
https://github.com/docker/compose/releases/download/v2.39.1/docker-compose-linux-x86_64 \
-o ~/.docker/cli-plugins/docker-compose

chmod +x ~/.docker/cli-plugins/docker-compose

echo ""
echo "========================================="
echo " INSTALLING CADDY"
echo "========================================="
echo ""

curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
| gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
| tee /etc/apt/sources.list.d/caddy-stable.list

apt update -y
apt install -y caddy

systemctl enable caddy

echo ""
echo "========================================="
echo " CONFIGURING FIREWALL"
echo "========================================="
echo ""

ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

echo ""
echo "========================================="
echo " SYSTEM TUNING"
echo "========================================="
echo ""

cat >> /etc/sysctl.conf <<EOF

# Remnawave tuning
fs.file-max = 100000
net.core.somaxconn = 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535
EOF

sysctl -p

mkdir -p /etc/docker

cat > /etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

systemctl restart docker

echo ""
echo "========================================="
echo " GENERATING SECRETS"
echo "========================================="
echo ""

POSTGRES_PASSWORD=$(openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 64)
SESSION_SECRET=$(openssl rand -hex 64)

docker network rm remnawave-network 2>/dev/null || true
docker network create remnawave-network

mkdir -p /opt/remnawave/backups

echo ""
echo "========================================="
echo " CREATING ENV"
echo "========================================="
echo ""

cat > /opt/remnawave/.env <<EOF
###################################
# APP
###################################

NODE_ENV=production

APP_PORT=3000
SUBSCRIPTION_PORT=3010

###################################
# DOMAIN
###################################

APP_URL=https://${PANEL_DOMAIN}
SUB_PUBLIC_DOMAIN=https://${SUB_DOMAIN}

###################################
# DATABASE
###################################

POSTGRES_HOST=postgres
POSTGRES_PORT=5432
POSTGRES_DB=remnawave
POSTGRES_USER=remnawave
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}

DATABASE_URL=postgresql://remnawave:${POSTGRES_PASSWORD}@postgres:5432/remnawave?schema=public

###################################
# REDIS
###################################

REDIS_HOST=redis
REDIS_PORT=6379
REDIS_URL=redis://redis:6379

###################################
# AUTH
###################################

JWT_AUTH_SECRET=${JWT_SECRET}
JWT_REFRESH_SECRET=${JWT_SECRET}
SESSION_SECRET=${SESSION_SECRET}

###################################
# TELEGRAM
###################################

TELEGRAM_BOT_TOKEN=
TELEGRAM_ADMIN_ID=

EOF

echo ""
echo "========================================="
echo " CREATING DOCKER COMPOSE"
echo "========================================="
echo ""

cat > /opt/remnawave/docker-compose.yml <<EOF
services:

  postgres:
    image: postgres:17
    container_name: remnawave-db
    restart: unless-stopped

    environment:
      POSTGRES_DB: remnawave
      POSTGRES_USER: remnawave
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}

    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U remnawave"]
      interval: 10s
      timeout: 5s
      retries: 10

    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

    volumes:
      - postgres_data:/var/lib/postgresql/data

    networks:
      - remnawave-network

  redis:
    image: valkey/valkey:9-alpine
    container_name: remnawave-redis
    restart: unless-stopped

    command: valkey-server --appendonly yes

    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

    volumes:
      - redis_data:/data

    networks:
      - remnawave-network

  backend:
    image: remnawave/backend:latest
    container_name: remnawave-backend
    restart: unless-stopped

    env_file:
      - .env

    depends_on:
      postgres:
        condition: service_healthy

    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:3000/health"]
      interval: 30s
      timeout: 10s
      retries: 5

    labels:
      - "com.centurylinklabs.watchtower.enable=true"

    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

    ports:
      - "127.0.0.1:3000:3000"

    networks:
      - remnawave-network

  subscription:
    image: remnawave/subscription-page:latest
    container_name: remnawave-subscription
    restart: unless-stopped

    environment:
      NEXT_PUBLIC_BACKEND_URL: https://${PANEL_DOMAIN}

    depends_on:
      - backend

    labels:
      - "com.centurylinklabs.watchtower.enable=true"

    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

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

echo ""
echo "========================================="
echo " CONFIGURING CADDY"
echo "========================================="
echo ""

cat > /etc/caddy/Caddyfile <<EOF
{
    email ${ADMIN_EMAIL}

    servers {
        protocols h1 h2 h3
    }
}

${PANEL_DOMAIN} {

    encode gzip zstd

    reverse_proxy 127.0.0.1:3000

    header {
        Strict-Transport-Security "max-age=31536000;"
        X-Frame-Options "DENY"
        X-Content-Type-Options "nosniff"
    }
}

${SUB_DOMAIN} {

    encode gzip zstd

    reverse_proxy 127.0.0.1:3010
}
EOF

systemctl restart caddy

echo ""
echo "========================================="
echo " STARTING REMNAWAVE"
echo "========================================="
echo ""

cd /opt/remnawave

docker compose pull

docker compose up -d

echo ""
echo "Waiting for containers..."
sleep 20

echo ""
echo "========================================="
echo " CONTAINER STATUS"
echo "========================================="
echo ""

docker ps

echo ""
echo "========================================="
echo " SSL CHECK"
echo "========================================="
echo ""

curl -I https://${PANEL_DOMAIN} || true

echo ""
echo "========================================="
echo " INSTALL COMPLETE"
echo "========================================="
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

echo "Logs:"
echo "docker logs -f remnawave-backend"
echo ""

echo "Restart:"
echo "cd /opt/remnawave && docker compose restart"
echo ""

echo "Update:"
echo "cd /opt/remnawave && docker compose pull && docker compose up -d"
echo ""
