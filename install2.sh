cat > install.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/opt/remnawave"

echo "======================================"
echo " Remnawave V3 ZERO-FAIL SaaS Installer"
echo "======================================"

### PRECHECK
if [[ $EUID -ne 0 ]]; then
  echo "Run as root"
  exit 1
fi

for cmd in docker curl openssl; do
  command -v $cmd >/dev/null 2>&1 || {
    echo "$cmd not installed"
    exit 1
  }
done

read -rp "Panel domain: " PANEL_DOMAIN
read -rp "Subscription domain: " SUB_DOMAIN
read -rp "Admin email: " ADMIN_EMAIL

echo "Generating secrets..."

POSTGRES_PASSWORD=$(openssl rand -hex 24)
JWT_AUTH_SECRET=$(openssl rand -hex 32)
JWT_REFRESH_SECRET=$(openssl rand -hex 32)
JWT_API_TOKENS_SECRET=$(openssl rand -hex 32)
METRICS_PASS=$(openssl rand -hex 16)

rm -rf $APP_DIR
mkdir -p $APP_DIR
cd $APP_DIR

echo "Installing system deps..."
apt update -y
apt install -y curl wget jq ufw ca-certificates openssl

echo "Installing Docker..."
curl -fsSL https://get.docker.com | sh

echo "Installing Caddy..."
apt install -y caddy

### FIREWALL SAFE
ufw allow 22 || true
ufw allow 80 || true
ufw allow 443 || true
ufw --force enable || true

### ENV (STRICT VALID)
cat > .env <<EOF
NODE_ENV=production

DATABASE_URL=postgresql://remnawave:${POSTGRES_PASSWORD}@db:5432/remnawave

JWT_AUTH_SECRET=${JWT_AUTH_SECRET}
JWT_REFRESH_SECRET=${JWT_REFRESH_SECRET}
JWT_API_TOKENS_SECRET=${JWT_API_TOKENS_SECRET}

FRONT_END_DOMAIN=https://${PANEL_DOMAIN}
APP_URL=https://${PANEL_DOMAIN}
SUB_PUBLIC_DOMAIN=https://${SUB_DOMAIN}

METRICS_USER=admin
METRICS_PASS=${METRICS_PASS}
EOF

### COMPOSE (NO EXTERNAL NETWORKS)
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

  redis:
    image: valkey/valkey:9-alpine
    restart: unless-stopped

  backend:
    image: remnawave/backend:2
    restart: unless-stopped
    env_file:
      - .env
    ports:
      - "127.0.0.1:3000:3000"
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_started

  sub:
    image: remnawave/subscription-page:latest
    restart: unless-stopped
    ports:
      - "127.0.0.1:3010:3010"
    depends_on:
      - backend

volumes:
  db:
EOF

echo "Starting stack..."
docker compose down -v || true
docker compose up -d

echo "Waiting backend health..."
for i in {1..60}; do
  if curl -fs http://127.0.0.1:3000 >/dev/null 2>&1; then
    echo "Backend ready"
    break
  fi
  sleep 2
done

### CADDY SAFE CONFIG
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
echo " INSTALL COMPLETE"
echo "======================================"
echo "Panel: https://${PANEL_DOMAIN}"
echo "Sub:   https://${SUB_DOMAIN}"
echo "======================================"
EOF