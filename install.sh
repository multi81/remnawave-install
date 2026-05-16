#!/usr/bin/env bash
set -e

clear

echo "========================================="
echo "   Remnawave STABLE Installer v2"
echo "========================================="

read -p "Panel domain: " PANEL_DOMAIN
read -p "Subscription domain: " SUB_DOMAIN
read -p "Admin email: " ADMIN_EMAIL

SERVER_IP=$(curl -4 -s ifconfig.me)

echo ""
echo "Server IP: $SERVER_IP"
echo ""

############################################
# DNS (НЕ БЛОКИРУЕМ УСТАНОВКУ)
############################################

PANEL_IP=$(dig +short $PANEL_DOMAIN | tail -n1 || true)
SUB_IP=$(dig +short $SUB_DOMAIN | tail -n1 || true)

echo "DNS CHECK (non-blocking)"
echo "$PANEL_DOMAIN -> $PANEL_IP"
echo "$SUB_DOMAIN -> $SUB_IP"

if [[ "$PANEL_IP" != "$SERVER_IP" || "$SUB_IP" != "$SERVER_IP" ]]; then
  echo ""
  echo "⚠️ WARNING: DNS not ready yet"
  echo "Install will continue anyway"
  echo ""
fi

############################################
# SYSTEM
############################################

apt update -y
apt install -y curl wget git unzip jq openssl ufw dnsutils

############################################
# DOCKER
############################################

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | bash
fi

systemctl enable docker
systemctl start docker

mkdir -p /root/.docker/cli-plugins

curl -SL \
https://github.com/docker/compose/releases/download/v2.24.6/docker-compose-linux-x86_64 \
-o /root/.docker/cli-plugins/docker-compose

chmod +x /root/.docker/cli-plugins/docker-compose

############################################
# CADDY
############################################

if ! command -v caddy >/dev/null 2>&1; then
  apt install -y debian-keyring debian-archive-keyring apt-transport-https

  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | gpg --dearmor -o /usr/share/keyrings/caddy.gpg

  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | tee /etc/apt/sources.list.d/caddy.list

  apt update -y
  apt install -y caddy
fi

############################################
# FIREWALL
############################################

ufw allow 22 || true
ufw allow 80 || true
ufw allow 443 || true
ufw --force enable

############################################
# CLEAN INSTALL
############################################

rm -rf /opt/remnawave
mkdir -p /opt/remnawave
cd /opt/remnawave

docker network rm remnawave-network 2>/dev/null || true
docker network create remnawave-network

############################################
# SECRETS
############################################

POSTGRES_PASSWORD=$(openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 64)
SESSION_SECRET=$(openssl rand -hex 64)

############################################
# ENV (ВАЖНО: FIX PRISMA)
############################################

cat > .env <<EOF
NODE_ENV=production

APP_PORT=3000
SUBSCRIPTION_PORT=3010

DATABASE_URL=postgresql://remnawave:${POSTGRES_PASSWORD}@postgres:5432/remnawave

JWT_AUTH_SECRET=${JWT_SECRET}
JWT_REFRESH_SECRET=${JWT_SECRET}
SESSION_SECRET=${SESSION_SECRET}

APP_URL=https://${PANEL_DOMAIN}
SUB_PUBLIC_DOMAIN=https://${SUB_DOMAIN}
EOF

############################################
# DOCKER COMPOSE (FIXED HEALTH + NO RACE)
############################################

cat > docker-compose.yml <<EOF
services:

  postgres:
    image: postgres:17
    restart: unless-stopped
    environment:
      POSTGRES_DB: remnawave
      POSTGRES_USER: remnawave
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - pg:/var/lib/postgresql/data
    networks:
      - net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U remnawave"]
      interval: 5s
      timeout: 5s
      retries: 20

  redis:
    image: valkey/valkey:9-alpine
    restart: unless-stopped
    command: valkey-server --appendonly yes
    volumes:
      - redis:/data
    networks:
      - net

  backend:
    image: remnawave/backend:latest
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
      - net

  sub:
    image: remnawave/subscription-page:latest
    restart: unless-stopped
    environment:
      BACKEND_URL: http://backend:3000
    depends_on:
      - backend
    ports:
      - "127.0.0.1:3010:3010"
    networks:
      - net

volumes:
  pg:
  redis:

networks:
  net:
    external: true
EOF

############################################
# CADDY (FIXED)
############################################

cat > /etc/caddy/Caddyfile <<EOF
{
  email ${ADMIN_EMAIL}
}

${PANEL_DOMAIN} {
  reverse_proxy 127.0.0.1:3000
}

${SUB_DOMAIN} {
  reverse_proxy 127.0.0.1:3010
}
EOF

systemctl restart caddy

############################################
# START STACK
############################################

docker compose up -d

############################################
# WAIT BACKEND HEALTH (IMPORTANT FIX)
############################################

echo "Waiting backend..."

for i in {1..60}; do
  if curl -s http://127.0.0.1:3000 >/dev/null; then
    echo "Backend OK"
    break
  fi
  sleep 2
done

############################################
# RESULT
############################################

echo ""
echo "========================================="
echo " INSTALL COMPLETE"
echo "========================================="
echo ""
echo "Panel: https://${PANEL_DOMAIN}"
echo "Sub:   https://${SUB_DOMAIN}"
echo ""
echo "Check logs:"
echo "docker logs -f remnawave-backend"
