#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "[ERROR] Install failed at line $LINENO. Rolling back..."; docker compose down -v 2>/dev/null || true' ERR

echo "======================================"
echo " Remnawave SaaS ZERO-ERROR v5"
echo "======================================"

# -------------------------
# ENSURE BASH ONLY
# -------------------------
if [ -z "${BASH_VERSION:-}" ]; then
  echo "❌ Run this script with bash:"
  echo "bash install-v5.sh"
  exit 1
fi

# -------------------------
# INPUTS
# -------------------------
read -rp "Panel domain: " PANEL_DOMAIN
read -rp "Subscription domain: " SUB_DOMAIN
read -rp "Admin email: " ADMIN_EMAIL

APP_DIR="/opt/remnawave"

# -------------------------
# CLEAN SAFE STATE
# -------------------------
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR"
cd "$APP_DIR"

# -------------------------
# SYSTEM PACKAGES
# -------------------------
echo "[1/9] Installing system deps..."
apt update -y
apt install -y curl wget git jq openssl ufw ca-certificates dos2unix

# -------------------------
# FIX CRLF SAFETY (important)
# -------------------------
echo "[2/9] Ensuring LF format..."
dos2unix "$0" 2>/dev/null || true

# -------------------------
# DOCKER
# -------------------------
echo "[3/9] Installing Docker..."
curl -fsSL https://get.docker.com | bash

systemctl enable docker
systemctl start docker

mkdir -p /usr/local/lib/docker/cli-plugins

curl -SL https://github.com/docker/compose/releases/download/v2.27.0/docker-compose-linux-x86_64 \
  -o /usr/local/lib/docker/cli-plugins/docker-compose

chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# -------------------------
# CADDY
# -------------------------
echo "[4/9] Installing Caddy..."
apt install -y caddy

# -------------------------
# FIREWALL
# -------------------------
ufw allow 22
ufw allow 80
ufw allow 443
ufw --force enable

# -------------------------
# SECRETS
# -------------------------
echo "[5/9] Generating secrets..."

POSTGRES_PASSWORD=$(openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 32)
SESSION_SECRET=$(openssl rand -hex 32)

# -------------------------
# DOCKER NETWORK (SAFE RESET)
# -------------------------
echo "[6/9] Setting up network..."
docker network inspect remnawave-network >/dev/null 2>&1 && \
docker network rm remnawave-network || true

docker network create remnawave-network

# -------------------------
# ENV FILE
# -------------------------
echo "[7/9] Creating env..."

cat > .env <<EOF
NODE_ENV=production

DATABASE_URL=postgresql://remnawave:${POSTGRES_PASSWORD}@db:5432/remnawave

JWT_AUTH_SECRET=${JWT_SECRET}
JWT_REFRESH_SECRET=${JWT_SECRET}
SESSION_SECRET=${SESSION_SECRET}

APP_URL=https://${PANEL_DOMAIN}
SUB_PUBLIC_DOMAIN=https://${SUB_DOMAIN}
EOF

# -------------------------
# DOCKER COMPOSE (STABLE ORDER)
# -------------------------
cat > docker-compose.yml <<EOF
services:

  db:
    image: postgres:17
    restart: unless-stopped
    environment:
      POSTGRES_DB: remnawave
      POSTGRES_USER: remnawave
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - db:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U remnawave"]
      interval: 5s
      timeout: 5s
      retries: 20
    networks:
      - remnawave-network

  redis:
    image: valkey/valkey:9-alpine
    restart: unless-stopped
    networks:
      - remnawave-network

  backend:
    image: remnawave/backend:latest
    restart: unless-stopped
    env_file:
      - .env
    ports:
      - "127.0.0.1:3000:3000"
    depends_on:
      db:
        condition: service_healthy
    networks:
      - remnawave-network

  sub:
    image: remnawave/subscription-page:latest
    restart: unless-stopped
    ports:
      - "127.0.0.1:3010:3010"
    networks:
      - remnawave-network

volumes:
  db:

networks:
  remnawave-network:
    driver: bridge
EOF

# -------------------------
# START DB FIRST
# -------------------------
echo "[8/9] Starting DB..."
docker compose up -d db redis

echo "Waiting DB health..."
sleep 10

# -------------------------
# START BACKEND
# -------------------------
echo "Starting backend..."
docker compose up -d backend sub

# WAIT BACKEND READY
echo "Waiting backend readiness..."

for i in {1..40}; do
  if curl -fs http://127.0.0.1:3000 >/dev/null 2>&1; then
    echo "[OK] Backend is ready"
    break
  fi
  sleep 3
done

if ! curl -fs http://127.0.0.1:3000 >/dev/null 2>&1; then
  echo "❌ Backend failed to start"
  exit 1
fi

# -------------------------
# CADDY ONLY AFTER BACKEND OK
# -------------------------
echo "[9/9] Configuring Caddy..."

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
echo "======================================"
echo " INSTALL SUCCESS"
echo "======================================"
echo "Panel: https://${PANEL_DOMAIN}"
echo "Sub:   https://${SUB_DOMAIN}"
echo "======================================"