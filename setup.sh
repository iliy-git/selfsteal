#!/usr/bin/env bash
set -e

# ==========================================================
# SelfSteal SNI Business Card Site - Auto Deploy Script
# Автоматическое развертывание сайта-маскировки в Docker
# и автоматическая интеграция с 3x-ui / Xray (VLESS REALITY)
# ==========================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}=================================================================${NC}"
echo -e "${CYAN}   🚀 SelfSteal SNI — Автоматическое развертывание и настройка   ${NC}"
echo -e "${CYAN}   Маскировка VLESS REALITY под собственный легитимный веб-сайт  ${NC}"
echo -e "${CYAN}=================================================================${NC}\n"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR] Пожалуйста, запустите скрипт с правами root: sudo ./setup.sh${NC}"
  exit 1
fi

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

DOMAIN=""
EMAIL=""
CONFIGURE_XUI=true

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
    --no-xui)
      CONFIGURE_XUI=false
      shift
      ;;
    -h|--help)
      echo "Использование: $0 [домен] [email] [опции]"
      echo "Опции:"
      echo "  -d, --domain <домен>  Доменное имя для сайта-визитки и SNI"
      echo "  -e, --email <email>   Email для регистрации сертификата Let's Encrypt"
      echo "  --no-xui              Не настраивать автоматически базу 3x-ui"
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
for pkg in curl git socat certbot python3 qrencode; do
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

# Получение SSL-сертификата
echo -e "\n${YELLOW}[...] Проверка SSL-сертификата Let's Encrypt для $DOMAIN...${NC}"
CERT_DIR="/etc/letsencrypt/live/$DOMAIN"

if [ -d "$CERT_DIR" ] && [ -f "$CERT_DIR/fullchain.pem" ]; then
    echo -e "${GREEN}[✓] Сертификат для $DOMAIN уже существует! Используем его.${NC}"
else
    echo -e "${YELLOW}[...] Запрос сертификата через Certbot...${NC}"
    
    # Проверяем, свободен ли 80 порт для standalone
    if ss -tulpn | grep -qE ':80\s'; then
        echo -e "${YELLOW}[...] Порт 80 занят, пробуем временно остановить веб-сервер...${NC}"
        systemctl stop nginx 2>/dev/null || true
        systemctl stop apache2 2>/dev/null || true
    fi

    certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --keep-until-expiring

    systemctl start nginx 2>/dev/null || true
    systemctl start apache2 2>/dev/null || true
fi

if [ ! -f "$CERT_DIR/fullchain.pem" ]; then
    echo -e "${RED}[ERROR] Сертификат не был найден в $CERT_DIR! Проверьте статус certbot.${NC}"
    exit 1
fi

# Настройка автоматического обновления сертификата (renewal hook)
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/selfsteal-reload.sh <<'EOF'
#!/bin/sh
docker kill -s HUP selfsteal_site 2>/dev/null || docker restart selfsteal_site 2>/dev/null || true
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/selfsteal-reload.sh

# Генерация конфигураций
echo -e "\n${YELLOW}[...] Генерация конфигурации Nginx и переменных окружения...${NC}"
PORT="8443"
BIND_IP="127.0.0.1"

cat > .env <<EOF
DOMAIN=$DOMAIN
PORT=$PORT
BIND_IP=$BIND_IP
EOF

sed "s|\${DOMAIN}|$DOMAIN|g" nginx/conf.d/default.conf.template > nginx/conf.d/default.conf

# Запуск Docker контейнера
echo -e "\n${YELLOW}[...] Запуск Docker Compose (Nginx на 127.0.0.1:$PORT)...${NC}"
docker compose down --remove-orphans 2>/dev/null || true
docker compose up -d

echo -e "\n${YELLOW}[...] Проверка локальной доступности сайта...${NC}"
sleep 2
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -k https://127.0.0.1:$PORT/ || echo "000")

if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "301" || "$HTTP_CODE" == "302" ]]; then
    echo -e "${GREEN}[✓] Сайт успешно запущен на 127.0.0.1:$PORT (HTTP $HTTP_CODE)${NC}"
else
    echo -e "${YELLOW}[ВНИМАНИЕ] Локальный HTTPS вернул код $HTTP_CODE. Проверьте docker logs selfsteal_site.${NC}"
fi

# Интеграция с 3x-ui
XUI_CONFIGURED=false
VLESS_LINK=""

if [ "$CONFIGURE_XUI" = true ]; then
    XUI_DB="/etc/x-ui/x-ui.db"
    if [ -f "$XUI_DB" ]; then
        echo -e "\n${CYAN}=================================================================${NC}"
        echo -e "${CYAN}   ⚙️ Обнаружена панель 3x-ui! Автоматическая настройка...        ${NC}"
        echo -e "${CYAN}=================================================================${NC}"
        
        XUI_RES=$(python3 "$PROJECT_DIR/scripts/configure_xui.py" --db "$XUI_DB" --domain "$DOMAIN" --dest "127.0.0.1:$PORT" --port 443 --ip "$SERVER_IP" --json)
        
        STATUS=$(echo "$XUI_RES" | python3 -c "import sys, json; print(json.load(sys.stdin).get('status', ''))" 2>/dev/null || echo "error")
        
        if [ "$STATUS" == "success" ]; then
            VLESS_LINK=$(echo "$XUI_RES" | python3 -c "import sys, json; print(json.load(sys.stdin).get('vless_link', ''))")
            ACTION=$(echo "$XUI_RES" | python3 -c "import sys, json; print(json.load(sys.stdin).get('action', ''))")
            
            echo -e "${GREEN}[✓] Инбаунд VLESS REALITY успешно настроен в 3x-ui ($ACTION)!${NC}"
            echo -e "${YELLOW}[...] Перезапуск службы 3x-ui...${NC}"
            systemctl restart x-ui 2>/dev/null || x-ui restart 2>/dev/null || true
            sleep 2

            # Проверка открытия 443 порта
            if ss -tulpn | grep -qE ':443\s'; then
                echo -e "${GREEN}[✓] Порт 443 успешно открыт и слушается Xray!${NC}"
            else
                echo -e "${YELLOW}[!] Порт 443 пока не отображается в ss. Проверьте systemctl status x-ui.${NC}"
            fi

            # Проверка маскировки HTTPS через 443 порт
            echo -e "${YELLOW}[...] Проверка внешней маскировки порта 443...${NC}"
            RESOLVE_CODE=$(curl -s -k -o /dev/null -w "%{http_code}" --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/" 2>/dev/null || echo "000")
            if [[ "$RESOLVE_CODE" == "200" || "$RESOLVE_CODE" == "301" || "$RESOLVE_CODE" == "302" ]]; then
                echo -e "${GREEN}[✓] Маскировка работает идеально! Внешний запрос на $DOMAIN:443 отдает сайт (HTTP $RESOLVE_CODE)!${NC}"
            fi

            XUI_CONFIGURED=true
        else
            echo -e "${RED}[ERROR] Ошибка настройки 3x-ui: $XUI_RES${NC}"
        fi
    else
        echo -e "\n${YELLOW}[INFO] Панель 3x-ui не установлена (/etc/x-ui/x-ui.db не найден).${NC}"
    fi
fi

# Итоговый вывод
echo -e "\n${GREEN}=================================================================${NC}"
echo -e "${GREEN}   🎉 РАЗВЕРТЫВАНИЕ SELFSTEAL УСПЕШНО ЗАВЕРШЕНО!                ${NC}"
echo -e "${GREEN}=================================================================${NC}"
echo -e " 🌐 Домен:                       ${BOLD}https://$DOMAIN${NC}"
echo -e " 🔒 SSL Сертификат:              ${GREEN}Let's Encrypt (CN=$DOMAIN, автопродление включено)${NC}"
echo -e " 🐳 Локальный сайт (Docker):     ${CYAN}127.0.0.1:$PORT (Nginx alpine)${NC}"

if [ "$XUI_CONFIGURED" = true ]; then
    echo -e " 🛡️ Маскировка Xray REALITY:     ${GREEN}Порт 443 -> Fallback 127.0.0.1:$PORT${NC}"
    echo -e " 🏷️ SNI / serverNames:           ${GREEN}$DOMAIN${NC}"
    echo -e "\n${CYAN}-----------------------------------------------------------------${NC}"
    echo -e "${BOLD}🔑 ВАША ГОТОВАЯ VLESS REALITY ССЫЛКА ДЛЯ ПОДКЛЮЧЕНИЯ:${NC}"
    echo -e "${CYAN}-----------------------------------------------------------------${NC}"
    echo -e "${GREEN}$VLESS_LINK${NC}"
    echo -e "${CYAN}-----------------------------------------------------------------${NC}"

    if command -v qrencode &>/dev/null; then
        echo -e "\n${YELLOW}📱 QR-код для быстрого сканирования со смартфона:${NC}\n"
        qrencode -t ANSIUTF8 "$VLESS_LINK"
    fi

    echo -e "\n${BOLD}💡 Подходит для клиентов:${NC} v2rayNG, Happ, Nekobox, Streisand, Shadowrocket, Hiddify, v2rayN."
else
    echo -e "\n${YELLOW}👉 ЕСЛИ ВЫ НАСТРАИВАЕТЕ 3X-UI ВРУЧНУЮ ИЛИ УСТАНОВИТЕ ЕГО ПОЗЖЕ:${NC}"
    echo -e " 1. Порт инбаунда:   ${GREEN}443${NC}"
    echo -e " 2. Target (Dest):   ${GREEN}127.0.0.1:8443${NC}"
    echo -e " 3. SNI (ServerName):${GREEN}$DOMAIN${NC}"
    echo -e "\n (Либо просто запустите ${CYAN}./setup.sh${NC} повторно после установки 3x-ui!)"
fi

echo -e "\n${GREEN}=================================================================${NC}\n"
