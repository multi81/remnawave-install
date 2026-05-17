#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[0;36m'
NC='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}Запустите от root${NC}" && exit 1

echo -e "${BLUE}"
echo "╔══════════════════════════════════════╗"
echo "║     Remnawave Auto Installer        ║"
echo "║     Panel + Sub + [Node] + Proxy    ║"
echo "╚══════════════════════════════════════╝"
echo -e "${NC}"

# --- Сбор параметров ---
echo -ne "${YELLOW}[1/8] Домен панели (пример: panel.example.com): ${NC}"
read PANEL_DOMAIN

echo -ne "${YELLOW}[2/8] Домен подписки (пример: sub.example.com): ${NC}"
read SUB_DOMAIN

echo -e "${YELLOW}[3/8] Устанавливать ноду на этом сервере?${NC}"
echo -e "  ${CYAN}1) Да${NC}"
echo -e "  ${CYAN}2) Нет${NC}"
read -p "Выбор [1-2]: " NODE_CHOICE
INSTALL_NODE=false
if [[ "$NODE_CHOICE" == "1" ]]; then
    INSTALL_NODE=true
    echo -ne "${YELLOW}[3.1] IP или домен для ноды: ${NC}"
    read NODE_ADDRESS
fi

echo -e "${YELLOW}[4/8] Выберите прокси-сервер:${NC}"
echo "  1) Caddy (авто-SSL)"
echo "  2) Nginx"
read -p "Выбор [1-2]: " PROXY_CHOICE
PROXY="caddy"
[[ "$PROXY_CHOICE" == "2" ]] && PROXY="nginx"

echo -ne "${YELLOW}[5/8] Email для Let's Encrypt: ${NC}"
read EMAIL

echo -ne "${YELLOW}[6/8] Пароль администратора панели: ${NC}"
read -s ADMIN_PASS
echo ""

echo -ne "${YELLOW}[7/8] Порт панели [3000]: ${NC}"
read PANEL_PORT
PANEL_PORT=${PANEL_PORT:-3000}

echo -ne "${YELLOW}[8/8] Порт страницы подписки [4000]: ${NC}"
read SUB_PORT
SUB_PORT=${SUB_PORT:-4000}

# Генерация секретов
JWT_SECRET=$(openssl rand -base64 48 | tr -d '\n')
NODE_SECRET=$(openssl rand -base64 32 | tr -d '\n')
SUB_TOKEN=$(openssl rand -hex 16)
DB_PASS=$(openssl rand -base64 24 | tr -d '\n')

# Сводка
echo -e "\n${BLUE}══════════════════════════════════════${NC}"
echo -e "${CYAN}Сводка конфигурации:${NC}"
echo -e "  Панель:          ${GREEN}$PANEL_DOMAIN${NC}"
echo -e "  Подписка:        ${GREEN}$SUB_DOMAIN${NC}"
echo -e "  Установка ноды:  ${GREEN}$($INSTALL_NODE && echo "$NODE_ADDRESS" || echo "Нет")${NC}"
echo -e "  Прокси:          ${GREEN}$PROXY${NC}"
echo -e "  Email:           ${GREEN}$EMAIL${NC}"
echo -e "  Порт панели:     ${GREEN}$PANEL_PORT${NC}"
echo -e "  Порт подписки:   ${GREEN}$SUB_PORT${NC}"
echo -e "${BLUE}══════════════════════════════════════${NC}"

echo -ne "\n${YELLOW}Начать установку? [y/N]: ${NC}"
read CONFIRM
[[ ! "$CONFIRM" =~ ^[Yy]$ ]] && echo -e "${RED}Отмена.${NC}" && exit 0

# --- Проверка и освобождение портов 80/443 ---
echo -e "\n${BLUE}Проверка портов 80 и 443...${NC}"
if ss -tlnp | grep -qE ':(80|443)\s'; then
    echo -e "${RED}⚠ Порты 80 или 443 уже заняты!${NC}"
    ss -tlnp | grep -E ':(80|443)\s'
    echo -ne "${YELLOW}Освободить порты принудительно? (остановит мешающие сервисы) [y/N]: ${NC}"
    read FREE_PORTS
    if [[ "$FREE_PORTS" =~ ^[Yy]$ ]]; then
        # Останавливаем системные веб-серверы
        for svc in nginx apache2 httpd; do
            if systemctl is-active --quiet $svc 2>/dev/null; then
                echo -e "${YELLOW}Останавливаю $svc...${NC}"
                systemctl stop $svc
                systemctl disable $svc
            fi
        done
        # Принудительно убиваем процессы на портах
        fuser -k 80/tcp 2>/dev/null || true
        fuser -k 443/tcp 2>/dev/null || true
        sleep 2
        echo -e "${GREEN}Порты освобождены.${NC}"
    else
        echo -e "${RED}Установка отменена.${NC}"
        exit 1
    fi
fi

# --- Установка зависимостей ---
echo -e "\n${GREEN}Начинаю установку...${NC}\n"
echo -e "${BLUE}[1/5] Обновление системы и установка Docker...${NC}"
apt update && apt upgrade -y
apt install -y curl wget gnupg ca-certificates lsb-release
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sh
fi

# --- Подготовка директорий ---
BASE_DIR="/opt/remnawave"
mkdir -p "$BASE_DIR"/{panel,node,sub,caddy,nginx}
echo -e "${BLUE}[2/5] Создание конфигураций...${NC}"

# .env для панели
cat > "$BASE_DIR/panel/.env" << EOF
JWT_SECRET=$JWT_SECRET
DATABASE_URL=postgresql://remnawave:$DB_PASS@remnawave-db:5432/remnawave
NODE_SECRET=$NODE_SECRET
SUBSCRIPTION_TOKEN=$SUB_TOKEN
ADMIN_USERNAME=admin
ADMIN_PASSWORD=$ADMIN_PASS
EOF

# docker-compose панели
cat > "$BASE_DIR/panel/docker-compose.yml" << EOF
services:
  remnawave-db:
    image: postgres:17
    container_name: remnawave-db
    hostname: remnawave-db
    restart: always
    environment:
      POSTGRES_USER: remnawave
      POSTGRES_PASSWORD: $DB_PASS
      POSTGRES_DB: remnawave
    ports:
      - '127.0.0.1:6767:5432'
    volumes:
      - remnawave-db-data:/var/lib/postgresql/data
    networks:
      - remnawave-network
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U remnawave -d remnawave']
      interval: 3s
      timeout: 10s
      retries: 3

  remnawave-redis:
    image: valkey/valkey:8.0.2-alpine
    container_name: remnawave-redis
    hostname: remnawave-redis
    restart: always
    networks:
      - remnawave-network
    volumes:
      - remnawave-redis-data:/data
    healthcheck:
      test: ['CMD', 'valkey-cli', 'ping']
      interval: 3s
      timeout: 10s
      retries: 3

  remnawave:
    image: remnawave/backend:latest
    container_name: remnawave
    hostname: remnawave
    restart: always
    ports:
      - '127.0.0.1:$PANEL_PORT:3000'
    env_file:
      - .env
    networks:
      - remnawave-network
    depends_on:
      remnawave-db:
        condition: service_healthy
      remnawave-redis:
        condition: service_healthy

networks:
  remnawave-network:
    name: remnawave-network
    driver: bridge

volumes:
  remnawave-db-data:
  remnawave-redis-data:
EOF

# docker-compose страницы подписки
cat > "$BASE_DIR/sub/docker-compose.yml" << EOF
services:
  remnawave-sub:
    image: remnawave/subscription-page:latest
    container_name: remnawave-sub
    hostname: remnawave-sub
    restart: always
    environment:
      PANEL_URL: https://$PANEL_DOMAIN
      SUB_TOKEN: $SUB_TOKEN
      PORT: $SUB_PORT
    ports:
      - '127.0.0.1:$SUB_PORT:$SUB_PORT'
    networks:
      - remnawave-network

networks:
  remnawave-network:
    external: true
    name: remnawave-network
EOF

# Конфигурация ноды, если выбрана
if $INSTALL_NODE; then
    cat > "$BASE_DIR/node/docker-compose.yml" << EOF
services:
  remnawave-node:
    image: remnawave/node:latest
    container_name: remnawave-node
    hostname: remnawave-node
    restart: always
    environment:
      PANEL_DOMAIN: $PANEL_DOMAIN
      NODE_SECRET: $NODE_SECRET
      NODE_PORT: '443'
      SSL_MODE: auto
    network_mode: host
    privileged: true
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
EOF
fi

# Настройка прокси
if [[ "$PROXY" == "caddy" ]]; then
    cat > "$BASE_DIR/caddy/Caddyfile" << EOF
{
    email $EMAIL
    admin off
}

$PANEL_DOMAIN {
    reverse_proxy 127.0.0.1:$PANEL_PORT
    header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
    header X-Content-Type-Options "nosniff"
    header X-Frame-Options "DENY"
    header X-XSS-Protection "1; mode=block"
}

$SUB_DOMAIN {
    reverse_proxy 127.0.0.1:$SUB_PORT
    header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
}
EOF
    cat > "$BASE_DIR/caddy/docker-compose.yml" << EOF
services:
  caddy:
    image: caddy:2-alpine
    container_name: remnawave-caddy
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
volumes:
  caddy_data:
  caddy_config:
EOF
else
    # Nginx
    cat > "$BASE_DIR/nginx/nginx.conf" << 'EOF'
events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    server {
        listen 80;
        server_name PANEL_DOMAIN_PLACEHOLDER;
        return 301 https://$server_name$request_uri;
    }

    server {
        listen 443 ssl http2;
        server_name PANEL_DOMAIN_PLACEHOLDER;

        ssl_certificate /etc/nginx/ssl/panel.crt;
        ssl_certificate_key /etc/nginx/ssl/panel.key;

        location / {
            proxy_pass http://127.0.0.1:PANEL_PORT_PLACEHOLDER;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
    }

    server {
        listen 80;
        server_name SUB_DOMAIN_PLACEHOLDER;
        return 301 https://$server_name$request_uri;
    }

    server {
        listen 443 ssl http2;
        server_name SUB_DOMAIN_PLACEHOLDER;

        ssl_certificate /etc/nginx/ssl/sub.crt;
        ssl_certificate_key /etc/nginx/ssl/sub.key;

        location / {
            proxy_pass http://127.0.0.1:SUB_PORT_PLACEHOLDER;
            proxy_http_version 1.1;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        }
    }
}
EOF
    sed -i "s/PANEL_DOMAIN_PLACEHOLDER/$PANEL_DOMAIN/g" "$BASE_DIR/nginx/nginx.conf"
    sed -i "s/SUB_DOMAIN_PLACEHOLDER/$SUB_DOMAIN/g" "$BASE_DIR/nginx/nginx.conf"
    sed -i "s/PANEL_PORT_PLACEHOLDER/$PANEL_PORT/g" "$BASE_DIR/nginx/nginx.conf"
    sed -i "s/SUB_PORT_PLACEHOLDER/$SUB_PORT/g" "$BASE_DIR/nginx/nginx.conf"

    mkdir -p "$BASE_DIR/nginx/ssl"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$BASE_DIR/nginx/ssl/panel.key" \
        -out "$BASE_DIR/nginx/ssl/panel.crt" \
        -subj "/CN=$PANEL_DOMAIN"
    cp "$BASE_DIR/nginx/ssl/panel.key" "$BASE_DIR/nginx/ssl/sub.key"
    cp "$BASE_DIR/nginx/ssl/panel.crt" "$BASE_DIR/nginx/ssl/sub.crt"

    cat > "$BASE_DIR/nginx/docker-compose.yml" << EOF
services:
  nginx:
    image: nginx:alpine
    container_name: remnawave-nginx
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./ssl:/etc/nginx/ssl:ro
EOF
fi

# --- Запуск сервисов ---
echo -e "${BLUE}[3/5] Запуск панели и Redis...${NC}"
cd "$BASE_DIR/panel"
docker compose up -d

echo -e "${BLUE}    Ожидание готовности базы данных и Redis...${NC}"
sleep 20

echo -e "${BLUE}[4/5] Запуск страницы подписки и ноды...${NC}"
cd "$BASE_DIR/sub"
docker compose up -d

if $INSTALL_NODE; then
    cd "$BASE_DIR/node"
    docker compose up -d
fi

echo -e "${BLUE}[5/5] Запуск $PROXY...${NC}"
if [[ "$PROXY" == "caddy" ]]; then
    cd "$BASE_DIR/caddy"
    docker compose up -d
else
    cd "$BASE_DIR/nginx"
    docker compose up -d
    # Удаление дефолтной заглушки nginx
    echo -e "${BLUE}    Удаление стандартной страницы Nginx...${NC}"
    sleep 5
    docker exec remnawave-nginx rm -f /etc/nginx/conf.d/default.conf 2>/dev/null || true
    docker restart remnawave-nginx
fi

# --- Проверка статуса ---
echo -e "\n${BLUE}Статус контейнеров:${NC}"
docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E 'remnawave|NAMES'

# --- Итоговая информация ---
echo -e "\n${GREEN}╔══════════════════════════════════════╗${NC}"
echo -e "${GREEN}║      Установка завершена!           ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════╝${NC}\n"

echo -e "${BLUE}📌 Доступы:${NC}"
echo -e "  Панель:     ${GREEN}https://$PANEL_DOMAIN${NC}"
echo -e "  Подписка:   ${GREEN}https://$SUB_DOMAIN${NC}"
echo -e "  Логин:      ${GREEN}admin${NC}"
echo -e "  Пароль:     ${GREEN}$ADMIN_PASS${NC}"

if $INSTALL_NODE; then
    echo -e "\n${BLUE}📡 Нода:${NC}"
    echo -e "  Адрес:      ${GREEN}$NODE_ADDRESS${NC}"
    echo -e "  Порт:       ${GREEN}443${NC}"
else
    echo -e "\n${YELLOW}ℹ️  Нода не установлена. Добавьте узел в панели управления.${NC}"
fi

echo -e "\n${BLUE}🔑 Секреты (сохраните!):${NC}"
echo -e "  JWT Secret:  ${YELLOW}$JWT_SECRET${NC}"
echo -e "  Node Secret: ${YELLOW}$NODE_SECRET${NC}"
echo -e "  Sub Token:   ${YELLOW}$SUB_TOKEN${NC}"
echo -e "  DB Password: ${YELLOW}$DB_PASS${NC}"

SECRETS_FILE="$BASE_DIR/secrets.txt"
cat > "$SECRETS_FILE" << EOF
Remnawave Installation Secrets
Generated: $(date)
==============================
Panel URL: https://$PANEL_DOMAIN
Sub URL: https://$SUB_DOMAIN
Admin Login: admin
Admin Password: $ADMIN_PASS
JWT Secret: $JWT_SECRET
Node Secret: $NODE_SECRET
Sub Token: $SUB_TOKEN
DB Password: $DB_PASS
EOF
chmod 600 "$SECRETS_FILE"
echo -e "\n${GREEN}Секреты сохранены в: ${CYAN}$SECRETS_FILE${NC}"

echo -e "\n${BLUE}🛠  Полезные команды:${NC}"
echo -e "  Статус:      ${GREEN}docker ps --filter 'name=remnawave'${NC}"
echo -e "  Логи панели: ${GREEN}docker logs -f remnawave${NC}"
echo -e "  Логи саба:   ${GREEN}docker logs -f remnawave-sub${NC}"
if $INSTALL_NODE; then
    echo -e "  Логи ноды:   ${GREEN}docker logs -f remnawave-node${NC}"
fi

echo -e "\n${RED}⚠️  SSL-сертификаты будут получены в течение 1-2 минут.${NC}"