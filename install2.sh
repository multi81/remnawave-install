#!/usr/bin/env bash

set -e

clear

echo "======================================="
echo "  Remnawave Production Installer"
echo "======================================="
echo ""

read -p "Panel domain (example: panel.example.com): " PANEL_DOMAIN
read -p "Subscription domain (example: sub.example.com): " SUB_DOMAIN
read -p "Email for SSL: " SSL_EMAIL

echo ""
echo "Installing dependencies..."
sleep 1

apt update -y
apt upgrade -y

apt install -y \
    curl \
    wget \
    git \
    unzip \
    nano \
    ufw \
    fail2ban \
    ca-certificates \
    gnupg \
    lsb-release

echo ""
echo "Installing Docker..."
sleep 1

if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
fi

systemctl enable docker
systemctl start docker

echo ""
echo "Installing Docker Compose..."
sleep 1

mkdir -p /usr/local/lib/docker/cli-plugins

curl -SL \
https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
-o /usr/local/lib/docker/cli-plugins/docker-compose

chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

echo ""
echo "Installing Caddy..."
sleep 1

if ! command -v caddy >/dev/null 2>&1; then
    apt install -y debian-keyring debian-archive-keyring apt-transport-https

    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    | tee /etc/apt/sources.list.d/caddy-stable.list

    apt update -y
    apt install caddy -y
fi

echo ""
echo "Configuring firewall..."
sleep 1

ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp

ufw --force enable

systemctl enable fail2ban
systemctl start fail2ban

echo ""
echo "Creating Remnawave directory..."
sleep 1

mkdir -p /opt/remnawave
cd /opt/remnawave

echo ""
echo "Creating .env..."
sleep 1

POSTGRES_PASSWORD=$(openssl rand -hex 24)
JWT_SECRET=$(openssl rand -hex 32)

cat > .env <<EOF
DATABASE_URL=postgresql://remnawave:${POSTGRES_PASSWORD}@db:5432/remnawave

POSTGRES_DB=remnawave
POSTGRES_USER=remnawave
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}

JWT_AUTH_SECRET=${JWT_SECRET}

SUB_PUBLIC_DOMAIN=https://${SUB_DOMAIN}
PUBLIC_API_HTTPS://${PANEL_DOMAIN}

TZ=UTC
EOF

echo ""
echo "Creating docker-compose.yml..."
sleep 1

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
      - postgres_data:/var/lib/postgresql/data
    networks:
      - remnawave-network

  valkey:
    image: valkey/valkey:8-alpine
    container_name: remnawave-valkey
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
      - valkey
    ports:
      - "127.0.0.1:3000:3000"
    networks:
      - remnawave-network

  subscription:
    image: remnawave/subscription-page:latest
    container_name: remnawave-sub
    restart: unless-stopped
    env_file:
      - .env
    ports:
      - "127.0.0.1:3010:3010"
    networks:
      - remnawave-network

volumes:
  postgres_data:

networks:
  remnawave-network:
    driver: bridge
EOF

echo ""
echo "Creating Caddy config..."
sleep 1

cat > /etc/caddy/Caddyfile <<EOF
{
    email ${SSL_EMAIL}
}

${PANEL_DOMAIN} {
    reverse_proxy 127.0.0.1:3000
}

${SUB_DOMAIN} {
    reverse_proxy 127.0.0.1:3010
}
EOF

echo ""
echo "Restarting Caddy..."
sleep 1

systemctl restart caddy
systemctl enable caddy

echo ""
echo "Starting Remnawave..."
sleep 1

docker compose up -d

echo ""
echo "======================================="
echo " Installation completed"
echo "======================================="
echo ""
echo "Panel:"
echo "https://${PANEL_DOMAIN}"
echo ""
echo "Subscription page:"
echo "https://${SUB_DOMAIN}"
echo ""
echo "Logs:"
echo "docker compose logs -f"
echo ""
echo "Caddy logs:"
echo "journalctl -u caddy -f"
echo ""
