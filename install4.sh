#!/usr/bin/env bash
set -euo pipefail

echo "======================================"
echo " REMNAWAVE SaaS INSTALLER v5 STABLE"
echo "======================================"

read -rp "Panel domain: " PANEL_DOMAIN
read -rp "Subscription domain: " SUB_DOMAIN
read -rp "Admin email: " ADMIN_EMAIL

APP_DIR="/opt/remnawave"

echo "[1/8] Cleaning old installation..."
systemctl stop caddy || true
docker compose down -v || true
rm -rf "$APP_DIR"

mkdir -p "$APP_DIR"
cd "$APP_DIR"

echo "[2/8] Installing dependencies..."
apt update -y
apt install -y curl wget git jq openssl ufw ca-certificates

echo "[3/8] Installing Docker..."
curl -fsSL https://get.docker.com | sh
systemctl enable docker
systemctl start docker

echo "[4/8] Installing Docker Compose..."
mkdir -p /usr/local/lib/docker/cli-plugins
curl -SL https://github.com/docker/compose/releases/download/v2.27.0/docker-compose-linux-x86_64 \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

echo "[5/8] Firewall setup..."
ufw allow 22
ufw allow 80
ufw allow 443
ufw --force enable

echo "[6/8] Generating secrets..."
POSTGRES_PASSWORD=$(openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 32)
SESSION_SECRET=$(openssl rand -hex 32)

echo "[7/8] Creating env file..."
cat > .env <<EOF
NODE_ENV=production

DATABASE_URL=postgresql://remnawave:${POSTGRES_PASSWORD}@postgres:5432/remnawave

JWT_AUTH_SECRET=${JWT_SECRET}
JWT_REFRESH_SECRET=${JWT_SECRET}
SESSION_SECRET=${SESSION_SECRET}

APP_URL=https://${PANEL_DOMAIN}
SUB_PUBLIC_DOMAIN=https://${SUB_DOMAIN}

PORT=3000
SUB_PORT=3010
EOF

echo "[8/8] Creating docker stack..."

docker network rm remnawave-network 2>/dev/null || true
docker network create remnawave-network

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
      - remnawave-network

  redis:
    image: valkey/valkey:9-alpine
    restart: unless-stopped
    networks:
      - remnawave-network

  backend:
    image: remnawave/backend:2
    restart: unless-stopped
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
    restart: unless-stopped
    depends_on:
      - backend
    ports:
      - "127.0.0.1:3010:3010"
    networks:
      - remnawave-network

volumes:
  pg:

networks:
  remnawave-network:
    external: true
EOF

echo "Starting stack..."
docker compose up -d

echo "Waiting backend health..."
for i in {1..40}; do
  if curl -fs http://127.0.0.1:3000 >/dev/null 2>&1; then
    echo "Backend OK"
    break
  fi
  sleep 3
done

echo "Installing Caddy..."
apt install -y caddy

cat > /etc/caddy/Caddyfile <<EOF
{
  email ${ADMIN_EMAIL}
}

${PANEL_DOMAIN} {
  reverse_proxy 127.0.0.1:3000
  encode gzip
}

${SUB_DOMAIN} {
  reverse_proxy 127.0.0.1:3010
  encode gzip
}
EOF

systemctl restart caddy

echo ""
echo "======================================"
echo " INSTALL COMPLETE"
echo "======================================"
echo "Panel: https://${PANEL_DOMAIN}"
echo "Sub:   https://${SUB_DOMAIN}"
echo "======================================"