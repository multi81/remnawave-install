#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

clear

echo "========================================="
echo "   REMNAWAVE SaaS INSTALLER (CLEAN)"
echo "========================================="

read -p "Panel domain: " PANEL_DOMAIN
read -p "Subscription domain: " SUB_DOMAIN
read -p "Admin email: " ADMIN_EMAIL

SERVER_IP=$(curl -4 -s ifconfig.me)

echo ""
echo "Server IP: $SERVER_IP"

############################################
# NO HARD DNS BLOCK (ONLY WARNING)
############################################

echo ""
echo "Checking DNS (non-blocking)..."

PANEL_IP=$(dig +short "$PANEL_DOMAIN" | tail -n1 || true)
SUB_IP=$(dig +short "$SUB_DOMAIN" | tail -n1 || true)

echo "$PANEL_DOMAIN -> ${PANEL_IP:-NOT SET}"
echo "$SUB_DOMAIN -> ${SUB_IP:-NOT SET}"

############################################
# SYSTEM BASE
############################################

apt update -y
apt install -y curl wget git unzip jq openssl ca-certificates dnsutils ufw

############################################
# DOCKER (SAFE)
############################################

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | bash
fi

systemctl enable docker
systemctl start docker

############################################
# COMPOSE
############################################

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

ufw allow 22
ufw allow 80
ufw allow 443
ufw --force enable

############################################
# CLEAN INSTALL DIR
############################################

rm -rf /opt/remnawave
mkdir -p /opt/remnawave
cd /opt/remnawave

############################################
# NETWORK
############################################

docker network rm remnawave-net 2>/dev/null || true
docker network create remnawave-net

############################################
# SECRETS
############################################

POSTGRES_PASSWORD=$(openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 64)
SESSION_SECRET=$(openssl rand -hex 64)

############################################
# ENV (FIXED FOR PRISMA)
############################################

cat > .env <<EOF
NODE_ENV=production

DATABASE_URL=postgresql://remnawave:${POSTGRES_PASSWORD}@postgres:5432/remnawave

APP_PORT=3000
SUB_PORT=3010

JWT_AUTH_SECRET=${JWT_SECRET}
JWT_REFRESH_SECRET=${JWT_SECRET}
SESSION_SECRET=${SESSION_SECRET}

APP_URL=https://${PANEL_DOMAIN}
SUB_URL=https://${SUB_DOMAIN}
EOF

############################################
# DOCKER COMPOSE (STABLE)
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
      - postgres
      - redis
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
# CADDY
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
# START
############################################

docker compose up -d

############################################
# HEALTH CHECK (IMPORTANT FIX)
############################################

echo "Waiting backend health..."

for i in {1..60}; do
  if curl -s http://127.0.0.1:3000 >/dev/null; then
    echo "Backend OK"
    break
  fi
  sleep 3
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
echo "Logs:"
echo "docker logs -f remnawave-backend"
