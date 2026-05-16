#!/usr/bin/env bash
set -euo pipefail

### =========================
### COLORS
### =========================
GREEN="\e[32m"
RED="\e[31m"
NC="\e[0m"

echo -e "${GREEN}=====================================${NC}"
echo " Remnawave SaaS Installer (PROD v3)"
echo -e "${GREEN}=====================================${NC}"

### =========================
### INPUTS
### =========================
read -rp "Panel domain: " PANEL_DOMAIN
read -rp "Subscription domain: " SUB_DOMAIN
read -rp "Admin email (LE): " ADMIN_EMAIL

APP_DIR="/opt/remnawave"

### =========================
### CLEAN OLD INSTALL
### =========================
echo "[1/10] Cleaning old stack..."
docker compose down -v 2>/dev/null || true
docker rm -f remnawave-backend remnawave-db remnawave-subscription 2>/dev/null || true

rm -rf $APP_DIR
mkdir -p $APP_DIR
cd $APP_DIR

### =========================
### SYSTEM PACKAGES
### =========================
echo "[2/10] Installing dependencies..."
apt update -y
apt install -y curl wget git jq openssl ufw ca-certificates

### =========================
### DOCKER
### =========================
echo "[3/10] Installing Docker..."
curl -fsSL https://get.docker.com | sh

systemctl enable docker
systemctl start docker

### docker compose plugin
mkdir -p /usr/local/lib/docker/cli-plugins
curl -SL https://github.com/docker/compose/releases/download/v2.27.0/docker-compose-linux-x86_64 \
  -o /usr/local/lib/docker/cli-plugins/docker-compose

chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

### =========================
### CADDY
### =========================
echo "[4/10] Installing Caddy..."
apt install -y debian-keyring debian-archive-keyring apt-transport-https

curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
 | gpg --dearmor -o /usr/share/keyrings/caddy.gpg

curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
 | tee /etc/apt/sources.list.d/caddy.list

apt update -y
apt install -y caddy

### =========================
### FIREWALL
### =========================
ufw allow 22
ufw allow 80
ufw allow 443
ufw --force enable

### =========================
### SECRETS
### =========================
echo "[5/10] Generating secrets..."

POSTGRES_PASSWORD=$(openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 32)
SESSION_SECRET=$(openssl rand -hex 32)

### =========================
### DOCKER NETWORK (FIXED)
### =========================
docker network rm remnawave-network 2>/dev/null || true
docker network create remnawave-network

### =========================
### ENV (CRITICAL FIX)
### =========================
echo "[6/10] Creating .env..."

cat > .env <<EOF
NODE_ENV=production

APP_PORT=3000
SUBSCRIPTION_PORT=3010

DATABASE_URL=postgresql://remnawave:${POSTGRES_PASSWORD}@remnawave-db:5432/remnawave

JWT_AUTH_SECRET=${JWT_SECRET}
JWT_REFRESH_SECRET=${JWT_SECRET}
SESSION_SECRET=${SESSION_SECRET}

APP_URL=https://${PANEL_DOMAIN}
SUB_PUBLIC_DOMAIN=https://${SUB_DOMAIN}

TELEGRAM_BOT_TOKEN=
TELEGRAM_ADMIN_ID=
EOF

### =========================
### DOCKER COMPOSE (FIXED)
### =========================
echo "[7/10] Writing docker-compose..."

cat > docker-compose.yml <<EOF
services:

  db:
    image: postgres:17
    container_name: remnawave-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: remnawave
      POSTGRES_USER: remnawave
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - db:/var/lib/postgresql/data
    networks:
      - remnawave-network

  redis:
    image: valkey/valkey:9-alpine
    restart: unless-stopped
    networks:
      - remnawave-network

  backend:
    image: remnawave/backend:latest
    container_name: remnawave-backend
    restart: unless-stopped
    env_file:
      - .env
    depends_on:
      - db
      - redis
    ports:
      - "127.0.0.1:3000:3000"
    networks:
      - remnawave-network

  sub:
    image: remnawave/subscription-page:latest
    container_name: remnawave-sub
    restart: unless-stopped
    environment:
      BACKEND_URL: http://backend:3000
    ports:
      - "127.0.0.1:3010:3010"
    networks:
      - remnawave-network

volumes:
  db:

networks:
  remnawave-network:
    external: true
EOF

### =========================
### START DB FIRST
### =========================
echo "[8/10] Starting DB..."
docker compose up -d db redis

sleep 5

echo "[9/10] Starting backend..."
docker compose up -d backend sub

### WAIT HEALTH
echo "Waiting backend..."
for i in {1..30}; do
  if curl -fs http://127.0.0.1:3000 >/dev/null 2>&1; then
    echo "Backend OK"
    break
  fi
  sleep 2
done

### =========================
### CADDY (FINAL FIX)
### =========================
echo "[10/10] Configuring Caddy..."

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

echo ""
echo "====================================="
echo " INSTALL COMPLETE"
echo "====================================="
echo "Panel: https://${PANEL_DOMAIN}"
echo "Sub:   https://${SUB_DOMAIN}"
echo "====================================="
