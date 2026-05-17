#!/bin/bash
set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Проверка root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Запустите от root${NC}"
   exit 1
fi

# Баннер
echo -e "${BLUE}"
echo "╔══════════════════════════════════════╗"
echo "║     Remnawave Auto Installer        ║"
echo "║     Panel + Sub + [Node] + Proxy    ║"
echo "╚══════════════════════════════════════╝"
echo -e "${NC}"

# --- Сбор параметров ---
echo -e "${YELLOW}[1/8] Введите домен для панели (например, panel.example.com):${NC}"
read -p "> " PANEL_DOMAIN

echo -e "${YELLOW}[2/8] Введите домен для подписки (например, sub.example.com):${NC}"
read -p "> " SUB_DOMAIN

echo -e "${YELLOW}[3/8] Нужна ли установка ноды Remnawave?${NC}"
echo -e "  ${CYAN}1) Да, установить ноду на этом же сервере${NC}"
echo -e "  ${CYAN}2) Нет, только панель и подписка${NC}"
read -p "Выбор [1-2]: " NODE_CHOICE
INSTALL_NODE=false
if [[ "$NODE_CHOICE" == "1" ]]; then
    INSTALL_NODE=true
    echo -e "${YELLOW}[3.1] Введите домен/IP для ноды (можно просто IP):${NC}"
    read -p "> " NODE_ADDRESS
else
    echo -e "${GREEN}Нода установлена не будет. Вы сможете подключить внешние ноды позже.${NC}"
fi

echo -e "${YELLOW}[4/8] Выберите прокси-сервер:${NC}"
echo "  1) Caddy (рекомендуется, авто-SSL)"
echo "  2) Nginx"
read -p "Выбор [1-2]: " PROXY_CHOICE
if [[ "$PROXY_CHOICE" == "2" ]]; then
    PROXY="nginx"
else
    PROXY="caddy"
fi

echo -e "${YELLOW}[5/8] Введите ваш email для Let's Encrypt:${NC}"
read -p "> " EMAIL

echo -e "${YELLOW}[6/8] Придумайте пароль администратора панели:${NC}"
read -s -p "> " ADMIN_PASS
echo ""

echo -e "${YELLOW}[7/8] Порт для панели (по умолчанию 3000):${NC}"
read -p "> " PANEL_PORT
PANEL_PORT=${PANEL_PORT:-3000}

echo -e "${YELLOW}[8/8] Порт для страницы подписки (по умолчанию 4000):${NC}"
read -p "> " SUB_PORT
SUB_PORT=${SUB_PORT:-4000}

# Генерация секретов
JWT_SECRET=$(openssl rand -base64 48 | tr -d '\n')
NODE_SECRET=$(openssl rand -base64 32 | tr -d '\n')
SUB_TOKEN=$(openssl rand -hex 16)
DB_PASS=$(openssl rand -base64 24 | tr -d '\n')

# Вывод сводки перед установкой
echo -e "\n${BLUE}══════════════════════════════════════${NC}"
echo -e "${CYAN}Сводка конфигурации:${NC}"
echo -e "  Домен панели:    ${GREEN}$PANEL_DOMAIN${NC}"
echo -e "  Домен подписки:  ${GREEN}$SUB_DOMAIN${NC}"
if $INSTALL_NODE; then
    echo -e "  Установка ноды:  ${GREEN}Да${NC}"
    echo -e "  Адрес ноды:      ${GREEN}$NODE_ADDRESS${NC}"
else
    echo -e "  Установка ноды:  ${YELLOW}Нет${NC}"
fi
echo -e "  Прокси:          ${GREEN}$PROXY${NC}"
echo -e "  Email:           ${GREEN}$EMAIL${NC}"
echo -e "  Порт панели:     ${GREEN}$PANEL_PORT${NC}"
echo -e "  Порт подписки:   ${GREEN}$SUB_PORT${NC}"
echo -e "${BLUE}══════════════════════════════════════${NC}"

echo -e "\n${YELLOW}Начать установку? [y/N]:${NC}"
read -p "> " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "${RED}Установка отменена.${NC}"
    exit 0
fi

echo -e "\n${GREEN}Начинаю установку...${NC}\n"

# --- Обновление системы ---
echo -e "${BLUE}[1/6] Обновление системы...${NC}"
apt update && apt upgrade -y
apt install -y curl wget git unzip gnupg ca-certificates lsb-release

# --- Docker ---
echo -e "${BLUE}[2/6] Установка Docker...${NC}"
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sh
fi

# --- Создание структуры ---
echo -e "${BLUE}[3/6] Создание структуры директорий...${NC}"
BASE_DIR="/opt/remnawave"
mkdir -p "$BASE_DIR"/{panel,node,sub,caddy,nginx}

# --- Конфигурация панели ---
echo -e "${BLUE}[4/6] Настройка панели Remnawave...${NC}"
cat > "$BASE_DIR/panel/docker-compose.yml" << EOF
version: '3.8'
services:
  panel:
    image: remnawave/panel:latest
    container_name: remnawave-panel
    restart: unless-stopped
    environment:
      - JWT_SECRET=$JWT_SECRET
      - DATABASE_URL=postgresql://remnawave:$DB_PASS@db:5432/remnawave
      - NODE_SECRET=$NODE_SECRET
      - SUBSCRIPTION_TOKEN=$SUB_TOKEN
      - PANEL_PORT=$PANEL_PORT
      - ADMIN_USERNAME=admin
      - ADMIN_PASSWORD=$ADMIN_PASS
    ports:
      - "127.0.0.1:$PANEL_PORT:$PANEL_PORT"
    depends_on:
      db:
        condition: service_healthy
    networks:
      - remnawave

  db:
    image: postgres:16-alpine
    container_name: remnawave-db
    restart: unless-stopped
    environment:
      - POSTGRES_USER=remnawave
      - POSTGRES_PASSWORD=$DB_PASS
      - POSTGRES_DB=remnawave
    volumes:
      - ./pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U remnawave"]
      interval: 5s
      timeout: 5s
      retries: 5
    networks:
      - remnawave

networks:
  remnawave:
    driver: bridge
EOF

# --- Конфигурация ноды (если выбрана) ---
if $INSTALL_NODE; then
    echo -e "${BLUE}[5/6] Настройка ноды Remnawave...${NC}"
    cat > "$BASE_DIR/node/docker-compose.yml" << EOF
version: '3.8'
services:
  node:
    image: remnawave/node:latest
    container_name: remnawave-node
    restart: unless-stopped
    environment:
      - PANEL_DOMAIN=$PANEL_DOMAIN
      - NODE_SECRET=$NODE_SECRET
      - NODE_PORT=443
      - SSL_MODE=auto
    network_mode: host
    privileged: true
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
EOF
fi

# --- Конфигурация саба ---
echo -e "${BLUE}[5/6] Настройка страницы подписки...${NC}"
cat > "$BASE_DIR/sub/docker-compose.yml" << EOF
version: '3.8'
services:
  sub:
    image: remnawave/sub:latest
    container_name: remnawave-sub
    restart: unless-stopped
    environment:
      - PANEL_URL=https://$PANEL_DOMAIN
      - SUB_TOKEN=$SUB_TOKEN
      - PORT=$SUB_PORT
    ports:
      - "127.0.0.1:$SUB_PORT:$SUB_PORT"
    networks:
      - remnawave

networks:
  remnawave:
    external: true
    name: remnawave_panel_remnawave
EOF

# --- Настройка прокси ---
echo -e "${BLUE}[6/6] Настройка прокси ($PROXY)...${NC}"
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
    header X-Content-Type-Options "nosniff"
}
EOF

    cat > "$BASE_DIR/caddy/docker-compose.yml" << EOF
version: '3.8'
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
    cat > "$BASE_DIR/nginx/nginx.conf" << 'EOF'
events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    
    # Панель
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
    
    # Саб
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
version: '3.8'
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
echo -e "\n${GREEN}Запуск сервисов...${NC}"

echo -e "  ▶ Запуск панели..."
cd "$BASE_DIR/panel" && docker compose up -d

echo -e "  ▶ Ожидание инициализации БД (15 секунд)..."
sleep 15

echo -e "  ▶ Запуск страницы подписки..."
cd "$BASE_DIR/sub" && docker compose up -d

if $INSTALL_NODE; then
    echo -e "  ▶ Запуск ноды..."
    cd "$BASE_DIR/node" && docker compose up -d
fi

if [[ "$PROXY" == "caddy" ]]; then
    echo -e "  ▶ Запуск Caddy..."
    cd "$BASE_DIR/caddy" && docker compose up -d
else
    echo -e "  ▶ Запуск Nginx..."
    cd "$BASE_DIR/nginx" && docker compose up -d
fi

# --- Проверка статуса ---
echo -e "\n${BLUE}Проверка статуса сервисов...${NC}"
sleep 5

check_container() {
    local name=$1
    local status=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo "not found")
    if [[ "$status" == "running" ]]; then
        echo -e "  ${GREEN}✓${NC} $name: ${GREEN}running${NC}"
    else
        echo -e "  ${RED}✗${NC} $name: ${RED}$status${NC}"
    fi
}

check_container "remnawave-panel"
check_container "remnawave-db"
check_container "remnawave-sub"
if $INSTALL_NODE; then
    check_container "remnawave-node"
fi
if [[ "$PROXY" == "caddy" ]]; then
    check_container "remnawave-caddy"
else
    check_container "remnawave-nginx"
fi

# --- Вывод итогов ---
echo -e "\n${GREEN}╔══════════════════════════════════════╗${NC}"
echo -e "${GREEN}║      Установка завершена!           ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════╝${NC}\n"

echo -e "${BLUE}📌 Доступы:${NC}"
echo -e "  Панель:     ${GREEN}https://$PANEL_DOMAIN${NC}"
echo -e "  Подписка:   ${GREEN}https://$SUB_DOMAIN${NC}"
echo -e "  Логин:      ${GREEN}admin${NC}"
echo -e "  Пароль:     ${GREEN}$ADMIN_PASS${NC}"

if $INSTALL_NODE; then
    echo -e "\n${BLUE}📡 Информация о ноде:${NC}"
    echo -e "  Адрес:      ${GREEN}$NODE_ADDRESS${NC}"
    echo -e "  Порт:       ${GREEN}443${NC}"
else
    echo -e "\n${YELLOW}ℹ️  Нода не установлена. Для добавления:${NC}"
    echo -e "  1. Зайдите в панель (Администрирование → Узлы)"
    echo -e "  2. Создайте новый узел"
    echo -e "  3. Используйте NodeSecret из секретов ниже"
    echo -e "  4. Установите ноду на целевом сервере командой:"
    echo -e "     ${CYAN}bash <(curl -fsSL https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnanode.sh) @ install${NC}"
fi

echo -e "\n${BLUE}🔑 Секреты (сохраните!):${NC}"
echo -e "  JWT Secret:  ${YELLOW}$JWT_SECRET${NC}"
echo -e "  Node Secret: ${YELLOW}$NODE_SECRET${NC}"
echo -e "  Sub Token:   ${YELLOW}$SUB_TOKEN${NC}"
echo -e "  DB Password: ${YELLOW}$DB_PASS${NC}"

echo -e "\n${BLUE}📁 Расположение файлов:${NC}"
echo -e "  Конфиги:     ${CYAN}$BASE_DIR/${NC}"

echo -e "\n${BLUE}🛠  Полезные команды:${NC}"
echo -e "  Статус всех: ${GREEN}docker ps --filter 'name=remnawave'${NC}"
echo -e "  Логи панели: ${GREEN}docker logs -f remnawave-panel${NC}"
echo -e "  Логи саба:   ${GREEN}docker logs -f remnawave-sub${NC}"
if $INSTALL_NODE; then
    echo -e "  Логи ноды:   ${GREEN}docker logs -f remnawave-node${NC}"
fi

echo -e "\n${RED}⚠️  ВАЖНО:${NC}"
echo -e "${RED}  1. Дождитесь получения SSL-сертификатов (1-2 минуты)${NC}"
if ! $INSTALL_NODE; then
    echo -e "${RED}  2. Не забудьте добавить узел через панель управления${NC}"
fi
echo -e "${RED}  3. Сохраните секреты в надёжном месте${NC}"

# Сохранение секретов в файл
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