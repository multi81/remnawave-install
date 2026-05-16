#!/usr/bin/env bash
set -e

clear

echo "========================================="
echo "   Remnawave Production Installer"
echo "========================================="
echo ""

read -p "Panel domain (example: panel.domain.com): " PANEL_DOMAIN
read -p "Subscription domain (example: sub.domain.com): " SUB_DOMAIN
read -p "Admin email (Let's Encrypt): " ADMIN_EMAIL

echo ""
echo "========================================="
echo " INSTALL STARTED"
echo "========================================="

SERVER_IP=$(curl -4 -s ifconfig.me)

echo ""
echo "Detected server IP: $SERVER_IP"
echo ""

########################################
# DNS CHECK
########################################

echo "Checking DNS..."

PANEL_IP=$(dig +short $PANEL_DOMAIN | tail -n1)
SUB_IP=$(dig +short $SUB_DOMAIN | tail -n1)

echo "$PANEL_DOMAIN -> $PANEL_IP"
echo "$SUB_DOMAIN -> $SUB_IP"

if [[ "$PANEL_IP" != "$SERVER_IP" ]] || [[ "$SUB_IP" != "$SERVER_IP" ]]; then
  echo ""
  echo "========================================="
  echo " DNS ERROR"
  echo "========================================="
  echo ""
  echo "Your domains are NOT pointed to this VPS."
  echo ""
  echo "Create A records:"
  echo ""
  echo "$PANEL_DOMAIN -> $SERVER_IP"
  echo "$SUB_DOMAIN -> $SERVER_IP"
  echo ""
  echo "Cloudflare proxy MUST be disabled (grey cloud)"
  echo ""
  echo "Wait 2-5 minutes after DNS update."
  echo ""
  exit 1
fi

echo ""
echo "DNS OK"
echo ""

########################################
# SYSTEM
########################################

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
debian-keyring \
debian-archive-keyring \
apt-transport-https \
dnsutils

########################################
# DOCKER
########################################

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | bash
fi

systemctl enable docker
systemctl start docker

########################################
# DOCKER COMPOSE
########################################

mkdir -p /root/.docker/cli-plugins

curl -SL \
https://github.com/docker/compose/releases/download/v2.39.1/docker-compose-linux-x86_64 \
-o /root/.docker/cli-plugins/docker-compose

chmod +x /root/.docker/cli-plugins/docker-compose

########################################
# CADDY
########################################

if ! command -v caddy >/dev/null 2>&1; then

curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
| gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
| tee /etc/apt/sources.list.d/caddy-stable.list

apt update -y
apt install -y caddy

fi

########################################
# FIREWALL
########################################

ufw allow 22/tcp || true
ufw allow 80/tcp || true
ufw allow 443/tcp || true

ufw --force enable

########################################
# SYSCTL
########################################

cat >/etc/sysctl.d/99-remnawave.conf <<EOF
fs.file-max = 100000
net.core.somaxconn = 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535
EOF

sysctl --system

########################################
# CLEAN OLD INSTALL
########################################

rm -rf /opt/remnawave

mkdir -p /opt/remnawave

cd /opt/remnawave

docker compose down --remove-orphans 2>/dev/null || true

docker rm -f $(docker ps -aq) 2>/dev/null || true

docker network rm remnawave-network 2>/dev/null || true

docker network create remnawave-network

########################################
# SECRETS
########################################

POSTGRES_PASSWORD=$(openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 64)
SESSION_SECRET=$(openssl rand -hex 64)

########################################
# ENV
########################################

cat > /opt/remnawave/.env <<EOF
NODE_ENV=production

APP_PORT=3000
SUBSCRIPTION_PORT=3010

DATABASE_URL=postgresql://remnawave:${POSTGRES_PASSWORD}@postgres:5432/remnawave

JWT_AUTH_SECRET=${JWT_SECRET}
JWT_REFRESH_SECRET=${JWT_SECRET}
SESSION_SECRET=${SESSION_SECRET}

APP_URL=https://${PANEL_DOMAIN}
SUB_PUBLIC_DOMAIN=https://${SUB_DOMAIN}

TELEGRAM_BOT_TOKEN=
TELEGRAM_ADMIN_ID=
EOF

########################################
# DOCKER COMPOSE
########################################

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
      retries: 5
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - remnawave-network

  redis:
    image: valkey/valkey:9-alpine
    container_name: remnawave-redis
    restart: unless-stopped
    command: valkey-server --appendonly yes
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
      redis:
        condition: service_started
    ports:
      - "127.0.0.1:3000:3000"
    networks:
      - remnawave-network

  subscription:
    image: remnawave/subscription-page:latest
    container_name: remnawave-subscription
    restart: unless-stopped
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

########################################
# CADDYFILE
########################################

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

########################################
# START
########################################

cd /opt/remnawave

docker compose pull

docker compose up -d

########################################
# WAIT
########################################

echo ""
echo "Waiting for containers..."
sleep 20

########################################
# STATUS
########################################

echo ""
docker ps

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
echo "ENV:"
echo "/opt/remnawave/.env"
echo ""
echo "Logs:"
echo "docker logs -f remnawave-backend"
echo ""
