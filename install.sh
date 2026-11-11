#!/usr/bin/env bash
# ==========================================================
# SelfSteal One-Line Installer
# Usage:
#   bash <(curl -sSL https://raw.githubusercontent.com/iliy-git/selfsteal/main/install.sh)
#   bash <(curl -sSL https://raw.githubusercontent.com/iliy-git/selfsteal/main/install.sh) mydomain.com myemail@example.com
# ==========================================================
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR] Запустите скрипт с правами root: sudo bash <(curl ...)${NC}"
  exit 1
fi

# Если скрипт запущен через пайп/subshell, перенаправляем stdin на терминал для интерактивного ввода
if [ ! -t 0 ] && [ -e /dev/tty ]; then
    exec < /dev/tty
fi

echo -e "${CYAN}=================================================================${NC}"
echo -e "${CYAN}   🚀 Запуск установщика SelfSteal SNI (One-Line Installer)      ${NC}"
echo -e "${CYAN}=================================================================${NC}\n"

# Проверяем базовые утилиты git и curl
if ! command -v git &>/dev/null || ! command -v curl &>/dev/null; then
    echo -e "${YELLOW}[...] Установка git и curl...${NC}"
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq git curl
    elif command -v yum &>/dev/null; then
        yum install -y -q git curl
    fi
fi

INSTALL_DIR="/root/selfsteal"

if [ -d "$INSTALL_DIR/.git" ]; then
    echo -e "${GREEN}[✓] Репозиторий найден в $INSTALL_DIR. Обновляем...${NC}"
    cd "$INSTALL_DIR"
    git pull --quiet || true
else
    echo -e "${YELLOW}[...] Клонирование репозитория в $INSTALL_DIR...${NC}"
    rm -rf "$INSTALL_DIR" 2>/dev/null || true
    git clone https://github.com/iliy-git/selfsteal.git "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi

chmod +x setup.sh install.sh scripts/configure_xui.py 2>/dev/null || true

echo -e "${GREEN}[✓] Запуск мастера установки setup.sh...${NC}\n"
exec ./setup.sh "$@"

