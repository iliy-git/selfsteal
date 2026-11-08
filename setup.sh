#!/usr/bin/env bash
set -e

# ==========================================================
# SelfSteal SNI Business Card Site - Auto Deploy Script
# ==========================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}====================================================${NC}"
echo -e "${CYAN}   🚀 Развертывание сайта-визитки в Docker (SelfSteal) ${NC}"
echo -e "${CYAN}====================================================${NC}\n"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR] Пожалуйста, запустите скрипт от имени root (sudo ./setup.sh)${NC}"
  exit 1
fi

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

DOMAIN="$1"
if [ -z "$DOMAIN" ]; then
    echo -e "${YELLOW}Введите домен, который вы привязали к этому серверу:${NC}"
    read -p "Домен (например, site.example.com): " DOMAIN
fi

DOMAIN=$(echo "$DOMAIN" | sed -e 's|^[^/]*//||' -e 's|/.*$||' -e 's/^[ \t]*//;s/[ \t]*$//')

if [ -z "$DOMAIN" ]; then
    echo -e "${RED}[ERROR] Домен не может быть пустым!${NC}"
    exit 1
fi

echo -e "\n${GREEN}[✓] Выбран домен:${NC} $DOMAIN"

EMAIL="$2"
if [ -z "$EMAIL" ]; then
    read -p "Email для уведомлений Let's Encrypt (Enter для admin@$DOMAIN): " EMAIL
    if [ -z "$EMAIL" ]; then
        EMAIL="admin@$DOMAIN"
    fi
fi

SERVER_IP=$(curl -s --max-time 5 https://api.ipify.org || curl -s --max-time 5 https://ifconfig.me || echo "87.232.123.225")
echo -e "\n${YELLOW}[...] Проверка DNS A-записи для $DOMAIN...${NC}"

RESOLVED_IP=$(python3 -c "import socket; print(socket.gethostbyname('$DOMAIN'))" 2>/dev/null || true)

if [ "$RESOLVED_IP" != "$SERVER_IP" ]; then
    echo -e "${YELLOW}[ВНИМАНИЕ] Домен $DOMAIN сейчас резолвится в IP: '${RESOLVED_IP:-НЕ НАЙДЕН}'.${NC}"
    echo -e "${YELLOW}Ожидаемый IP сервера: $SERVER_IP${NC}"
    echo -e "${YELLOW}Если вы только что добавили A-запись у регистратора, обновление DNS может занять от 2 до 15 минут.${NC}"
    read -p "Продолжить выпуск сертификата прямо сейчас? (y/n, по умолчанию y): " PROCEED
    PROCEED=${PROCEED:-y}
    if [[ "$PROCEED" != "y" && "$PROCEED" != "Y" ]]; then
        echo -e "${RED}[ОТМЕНА] Подождите обновления DNS и запустите скрипт снова.${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}[✓] DNS запись верна:${NC} $DOMAIN -> $RESOLVED_IP"
fi

if ! command -v certbot &> /dev/null; then
    echo -e "${YELLOW}[...] Установка certbot...${NC}"
    apt-get update -qq && apt-get install -y -qq certbot
fi

echo -e "\n${YELLOW}[...] Запрос SSL-сертификата Let's Encrypt для $DOMAIN...${NC}"

CERT_DIR="/etc/letsencrypt/live/$DOMAIN"

if [ -d "$CERT_DIR" ] && [ -f "$CERT_DIR/fullchain.pem" ]; then
    echo -e "${GREEN}[✓] Сертификат для $DOMAIN уже существует! Используем его.${NC}"
else
    mkdir -p /var/www/html/.well-known/acme-challenge
    if certbot certonly --webroot -w /var/www/html -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --keep-until-expiring; then
        echo -e "${GREEN}[✓] Сертификат успешно получен через webroot!${NC}"
    else
        echo -e "${YELLOW}[...] Webroot не сработал, пробуем через временную остановку standalone...${NC}"
        systemctl stop nginx || true
        certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --keep-until-expiring
        systemctl start nginx || true
        echo -e "${GREEN}[✓] Сертификат успешно получен через standalone!${NC}"
    fi
fi

if [ ! -f "$CERT_DIR/fullchain.pem" ]; then
    echo -e "${RED}[ERROR] Сертификат не был найден в $CERT_DIR! Проверьте логи certbot.${NC}"
    exit 1
fi

echo -e "\n${YELLOW}[...] Генерация конфигурационных файлов...${NC}"

PORT="8443"
BIND_IP="127.0.0.1"

cat > .env <<EOF
DOMAIN=$DOMAIN
PORT=$PORT
BIND_IP=$BIND_IP
EOF

sed "s|\${DOMAIN}|$DOMAIN|g" nginx/conf.d/default.conf.template > nginx/conf.d/default.conf

echo -e "\n${YELLOW}[...] Запуск Docker Compose...${NC}"
docker compose down --remove-orphans 2>/dev/null || true
docker compose up -d

echo -e "\n${YELLOW}[...] Проверка локальной доступности сайта...${NC}"
sleep 2

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -k https://127.0.0.1:$PORT/ || true)

echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN}  🎉 САЙТ-ВИЗИТКА УСПЕШНО РАЗВЕРНУТ В DOCKER!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e " Статус локального HTTPS ($PORT): ${GREEN}HTTP $HTTP_CODE${NC}"
echo -e " Локальный порт для SelfSteal:   ${CYAN}127.0.0.1:$PORT${NC}"
echo -e " Домен сайта:                    ${CYAN}https://$DOMAIN${NC}"
echo -e "\n${YELLOW}👉 ЧТО УКАЗАТЬ В ПАНЕЛИ 3X-UI ДЛЯ VLESS REALITY:${NC}"
echo -e " 1. Target (Dest):  ${GREEN}127.0.0.1:8443${NC}"
echo -e " 2. SNI:            ${GREEN}$DOMAIN${NC}"
echo -e "\n Теперь маскировка полностью соответствует требованиям SelfSteal!"
echo -e " При проверке любого порта сканер видит настоящий сайт с валидным SSL."
echo -e "${GREEN}============================================================${NC}\n"
