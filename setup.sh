#!/usr/bin/env bash
set -e

# ==========================================================
# SelfSteal SNI Site - Auto Deploy Script
# Развертывание реального сайта-визитки в Docker (порт 80 и 443)
# с валидным SSL Let's Encrypt для маскировки REALITY
# ==========================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}=================================================================${NC}"
echo -e "${CYAN}   🌐 SelfSteal SNI — Развертывание сайта-маскировки (Docker)   ${NC}"
echo -e "${CYAN}   Сайт открывается в браузере и подходит для REALITY на серверах ${NC}"
echo -e "${CYAN}=================================================================${NC}\n"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR] Пожалуйста, запустите скрипт с правами root: sudo ./setup.sh${NC}"
  exit 1
fi

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

DOMAIN=""
EMAIL=""

# Парсинг аргументов
while [[ $# -gt 0 ]]; do
  case $1 in
    -d|--domain)
      DOMAIN="$2"
      shift 2
      ;;
    -e|--email)
      EMAIL="$2"
      shift 2
      ;;
    -h|--help)
      echo "Использование: $0 [домен] [email] [опции]"
      echo "Опции:"
      echo "  -d, --domain <домен>  Доменное имя для сайта-визитки"
      echo "  -e, --email <email>   Email для регистрации сертификата Let's Encrypt"
      echo "  -h, --help            Показать эту справку"
      exit 0
      ;;
    *)
      if [ -z "$DOMAIN" ]; then
        DOMAIN="$1"
      elif [ -z "$EMAIL" ]; then
        EMAIL="$1"
      fi
      shift
      ;;
  esac
done

# Интерактивный ввод домена, если не передан
if [ -z "$DOMAIN" ]; then
    echo -e "${YELLOW}Введите ваш домен, привязанный к IP этого сервера:${NC}"
    read -p "Домен (например, site.example.com): " DOMAIN
fi

DOMAIN=$(echo "$DOMAIN" | sed -e 's|^[^/]*//||' -e 's|/.*$||' -e 's/^[ \t]*//;s/[ \t]*$//')

if [ -z "$DOMAIN" ]; then
    echo -e "${RED}[ERROR] Домен не может быть пустым!${NC}"
    exit 1
fi

echo -e "\n${GREEN}[✓] Выбран домен:${NC} ${BOLD}$DOMAIN${NC}"

# Интерактивный ввод email
if [ -z "$EMAIL" ]; then
    read -p "Email для уведомлений Let's Encrypt (Enter для admin@$DOMAIN): " EMAIL
    if [ -z "$EMAIL" ]; then
        EMAIL="admin@$DOMAIN"
    fi
fi

# Определение внешнего IP
SERVER_IP=$(curl -s --max-time 5 https://api.ipify.org || curl -s --max-time 5 https://ifconfig.me || curl -s --max-time 5 https://icanhazip.com || echo "127.0.0.1")
echo -e "${GREEN}[✓] Внешний IP сервера:${NC} $SERVER_IP"

# Проверка DNS
echo -e "\n${YELLOW}[...] Проверка DNS A-записи для $DOMAIN...${NC}"
RESOLVED_IP=$(python3 -c "import socket; print(socket.gethostbyname('$DOMAIN'))" 2>/dev/null || true)

if [ "$RESOLVED_IP" != "$SERVER_IP" ]; then
    echo -e "${YELLOW}[ВНИМАНИЕ] Домен $DOMAIN резолвится в IP: '${RESOLVED_IP:-НЕ НАЙДЕН}'.${NC}"
    echo -e "${YELLOW}Ожидаемый IP сервера: $SERVER_IP${NC}"
    echo -e "${YELLOW}Если вы только что добавили A-запись, обновление DNS может занять несколько минут.${NC}"
    read -p "Продолжить выпуск сертификата прямо сейчас? (y/n, по умолчанию y): " PROCEED
    PROCEED=${PROCEED:-y}
    if [[ "$PROCEED" != "y" && "$PROCEED" != "Y" ]]; then
        echo -e "${RED}[ОТМЕНА] Подождите обновления DNS и перезапустите скрипт.${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}[✓] DNS запись верна:${NC} $DOMAIN -> $RESOLVED_IP"
fi

# Проверка и установка зависимостей
echo -e "\n${YELLOW}[...] Проверка системных пакетов...${NC}"
MISSING_PKGS=""
for pkg in curl git socat certbot python3; do
    if ! command -v "$pkg" &> /dev/null; then
        MISSING_PKGS="$MISSING_PKGS $pkg"
    fi
done

if [ -n "$MISSING_PKGS" ]; then
    echo -e "${YELLOW}[...] Установка отсутствующих пакетов:$MISSING_PKGS...${NC}"
    if command -v apt-get &> /dev/null; then
        apt-get update -qq && apt-get install -y -qq $MISSING_PKGS 2>/dev/null || apt-get install -y -qq curl git certbot python3
    elif command -v yum &> /dev/null; then
        yum install -y -q $MISSING_PKGS 2>/dev/null || true
    fi
fi

# Проверка Docker
if ! command -v docker &> /dev/null; then
    echo -e "${YELLOW}[...] Docker не найден. Устанавливаем Docker...${NC}"
    curl -fsSL https://get.docker.com | sh
fi

if ! docker compose version &> /dev/null; then
    echo -e "${YELLOW}[...] Установка плагина docker-compose...${NC}"
    if command -v apt-get &> /dev/null; then
        apt-get update -qq && apt-get install -y -qq docker-compose-plugin
    fi
fi

# Открытие портов 80 и 443 в файрволе
if command -v iptables &> /dev/null; then
    iptables -I INPUT 1 -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
    iptables -I INPUT 1 -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
fi
if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
    ufw allow 80/tcp 2>/dev/null || true
    ufw allow 443/tcp 2>/dev/null || true
fi

# Останавливаем старый контейнер, если был запущен, чтобы освободить порт 80 для certbot
docker compose down --remove-orphans 2>/dev/null || true

# Получение SSL-сертификата
echo -e "\n${YELLOW}[...] Проверка SSL-сертификата Let's Encrypt для $DOMAIN...${NC}"
CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
mkdir -p /var/www/certbot

if [ -d "$CERT_DIR" ] && [ -f "$CERT_DIR/fullchain.pem" ]; then
    echo -e "${GREEN}[✓] Сертификат для $DOMAIN уже существует! Используем его.${NC}"
else
    echo -e "${YELLOW}[...] Запрос сертификата через Certbot...${NC}"
    
    # Временно останавливаем возможные хост-серверы на 80 порту
    systemctl stop nginx 2>/dev/null || true
    systemctl stop apache2 2>/dev/null || true

    certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --keep-until-expiring
fi

if [ ! -f "$CERT_DIR/fullchain.pem" ]; then
    echo -e "${RED}[ERROR] Сертификат не был найден в $CERT_DIR! Проверьте логи certbot.${NC}"
    exit 1
fi

# Настройка автоматического обновления сертификата (renewal hook)
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/selfsteal-reload.sh <<'EOF'
#!/bin/sh
docker exec selfsteal_site nginx -s reload 2>/dev/null || docker restart selfsteal_site 2>/dev/null || true
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/selfsteal-reload.sh

# Генерация конфигураций
echo -e "\n${YELLOW}[...] Генерация конфигурации Nginx и переменных окружения...${NC}"

cat > .env <<EOF
DOMAIN=$DOMAIN
PORT_HTTP=80
PORT_HTTPS=443
EOF

sed "s|\${DOMAIN}|$DOMAIN|g" nginx/conf.d/default.conf.template > nginx/conf.d/default.conf

# Запуск Docker контейнера
echo -e "\n${YELLOW}[...] Запуск веб-сайта в Docker Compose (порты 80 и 443)...${NC}"
docker compose up -d

echo -e "\n${YELLOW}[...] Проверка доступности сайта...${NC}"
sleep 2

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1/ || echo "000")
HTTPS_CODE=$(curl -s -o /dev/null -w "%{http_code}" -k https://127.0.0.1/ || echo "000")

if [[ "$HTTPS_CODE" == "200" || "$HTTPS_CODE" == "301" || "$HTTPS_CODE" == "302" ]]; then
    echo -e "${GREEN}[✓] Сайт успешно запущен и работает! (HTTP: $HTTP_CODE -> HTTPS: $HTTPS_CODE)${NC}"
else
    echo -e "${YELLOW}[ВНИМАНИЕ] Проверка вернула: HTTP $HTTP_CODE, HTTPS $HTTPS_CODE. Проверьте docker logs selfsteal_site.${NC}"
fi

# Итоговый вывод
echo -e "\n${GREEN}=================================================================${NC}"
echo -e "${GREEN}   🎉 САЙТ УСПЕШНО РАЗВЕРНУТ И ДОСТУПЕН В СЕТИ!                 ${NC}"
echo -e "${GREEN}=================================================================${NC}"
echo -e " 🌐 Ссылка в браузере:           ${BOLD}https://$DOMAIN${NC}"
echo -e " 🔒 SSL Сертификат:              ${GREEN}Let's Encrypt (CN=$DOMAIN, автопродление включено)${NC}"
echo -e " 🚪 Порты:                       ${CYAN}80 (HTTP -> HTTPS) и 443 (HTTPS)${NC}"
echo -e "\n${CYAN}-----------------------------------------------------------------${NC}"
echo -e "${BOLD}👉 КАК ПРОПИСАТЬ ЭТОТ САЙТ В REALITY НА ЛЮБОМ СЕРВЕРЕ И ИНБАУНДЕ:${NC}"
echo -e "${CYAN}-----------------------------------------------------------------${NC}"
echo -e " В панели 3x-ui (или конфиге Xray) в блоке Reality укажите:"
echo -e "   • Target (Dest):    ${GREEN}$DOMAIN:443${NC}  (или $SERVER_IP:443)"
echo -e "   • SNI (ServerNames):${GREEN}$DOMAIN${NC}"
echo -e "   • SpiderX:          ${GREEN}/${NC}"
echo -e "${CYAN}-----------------------------------------------------------------${NC}"
echo -e "\n Теперь этот сайт работает как независимый легитимный веб-ресурс."
echo -e " Вы можете указывать его в REALITY на этом сервере или на любых других ваших нодах!"
echo -e "${GREEN}=================================================================${NC}\n"
