#!/usr/bin/env bash
set -euo pipefail

echo "====================================="
echo " Remnawave SaaS Installer"
echo "====================================="

read -rp "Panel domain: " PANEL_DOMAIN
read -rp "Subscription domain: " SUB_DOMAIN
read -rp "Admin email: " ADMIN_EMAIL

APP_DIR="/opt/remnawave"

rm -rf $APP_DIR
mkdir -p $APP_DIR
cd $APP_DIR

### SYSTEM
apt update -y
apt install -y curl wget git jq openssl ufw ca-certificates

### DOCKER
curl -fsSL https://get.docker.com | sh
systemctl enable docker

mkdir -p /usr/local/lib/docker/cli-plugins
curl -SL https://github.com/docker/compose/releases/download/v2.27.0/docker-compose-linux-x86_64 \
 -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

### CADDY
apt install -y caddy

### FIREWALL
ufw allow 22
ufw allow 80
ufw allow 443
ufw --force enable

### SECRETS
POSTGRES_PASSWORD=$(openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 32)
SESSION_SECRET=$(openssl rand -hex 32)

### ENV
cat > .env <<EOF
NODE_ENV=production

DATABASE_URL=postgresql://remnawave:${POSTGRES_PASSWORD}@db:5432/remnawave

JWT_AUTH_SECRET=${JWT_SECRET}
JWT_REFRESH_SECRET=${JWT_SECRET}
SESSION_SECRET=${SESSION_SECRET}

APP_URL=https://${PANEL_DOMAIN}
SUB_PUBLIC_DOMAIN=https://${SUB_DOMAIN}
EOF

### NETWORK FIX
docker network rm remnawave-network 2>/dev/null || true
docker network create remnawave-network

### COMPOSE
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
      - db
      - redis
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
    external: true
EOF

### START STACK
docker compose up -d

### WAIT BACKEND
echo "Waiting backend..."
for i in {1..30}; do
  if curl -fs http://127.0.0.1:3000 >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

### CADDY
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

echo "DONE"
echo "https://${PANEL_DOMAIN}"
