#!/bin/bash

RED="\033[1;31m"
GREEN="\033[1;32m"
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
RESET="\033[0m"
BOLD="\033[1m"
VERSION="1.4"

clear
echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║         GreySync Protect + Panel Builder             ║"
echo "║                    Version $VERSION                  ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"

echo -e "${YELLOW}[1]${RESET} Pasang Protect & Build Panel"
echo -e "${YELLOW}[2]${RESET} Restore dari Backup"
echo -e "${YELLOW}[3]${RESET} Pasang Protect Admin"
read -p "$(echo -e "${CYAN}Pilih opsi [1/2/3]: ${RESET}")" OPSI

CONTROLLER_USER="/var/www/pterodactyl/app/Http/Controllers/Admin/UserController.php"
SERVICE_SERVER="/var/www/pterodactyl/app/Services/Servers/ServerDeletionService.php"
BACKUP_DIR="backup_greysync"

mkdir -p "$BACKUP_DIR"

if [ "$OPSI" = "1" ]; then
    read -p "$(echo -e "${CYAN}Masukkan User ID Admin Utama (contoh: 1): ${RESET}")" ADMIN_ID

    echo -e "${YELLOW}➤ Menambahkan Protect Delete User...${RESET}"
    cp "$CONTROLLER_USER" "$BACKUP_DIR/UserController.$(date +%F-%H%M%S).bak"

    awk -v admin_id="$ADMIN_ID" '
    /public function delete\(Request \$request, User \$user\): RedirectResponse/ {
        print; in_func = 1; next;
    }
    in_func == 1 && /^\s*{/ {
        print;
        print "        if ($request->user()->id !== " admin_id ") {";
        print "            throw new DisplayException(\"Lu Siapa Mau Delet User Lain Tolol?\\n©GreySync黙\");";
        print "        }";
        in_func = 0; next;
    }
    { print }
    ' "$CONTROLLER_USER" > "$CONTROLLER_USER.tmp" \
        && mv "$CONTROLLER_USER.tmp" "$CONTROLLER_USER"

    echo -e "${GREEN}✔ Protect UserController selesai.${RESET}"

    echo -e "${YELLOW}➤ Menambahkan Protect Delete Server...${RESET}"
    cp "$SERVICE_SERVER" "$BACKUP_DIR/ServerDeletionService.$(date +%F-%H%M%S).bak"

    if ! grep -q "use Illuminate\\Support\\Facades\\Auth;" "$SERVICE_SERVER"; then
        sed -i '/^namespace Pterodactyl\\Services\\Servers;/a use Illuminate\\Support\\Facades\\Auth;\nuse Pterodactyl\\Exceptions\\DisplayException;' "$SERVICE_SERVER"
    fi

    awk -v admin_id="$ADMIN_ID" '
    /public function handle\(Server \$server\): void/ {
        print; in_func = 1; next;
    }
    in_func == 1 && /^\s*{/ {
        print;
        print "        \$user = Auth::user();";
        print "        if (\$user && \$user->id !== " admin_id ") {";
        print "            throw new DisplayException(\"Lu Siapa Mau Delet Server Lain Tolol?\\n©GreySync黙\");";
        print "        }";
        in_func = 0; next;
    }
    { print }
    ' "$SERVICE_SERVER" > "$SERVICE_SERVER.tmp" \
        && mv "$SERVICE_SERVER.tmp" "$SERVICE_SERVER"

    echo -e "${GREEN}✔ Protect ServerDeletionService selesai.${RESET}"

    echo -e "${GREEN}🎉 Protect V$VERSION berhasil dipasang. Tidak perlu build ulang panel.${RESET}"

elif [ "$OPSI" = "2" ]; then
    echo -e "${CYAN}♻ Mengembalikan file dari backup...${RESET}"
    ls -1t "$BACKUP_DIR" | head -n 5
    echo -e "${YELLOW}Pilih file backup yang mau dikembalikan (ketik namanya):${RESET}"
    read FILE
    if [ -f "$BACKUP_DIR/$FILE" ]; then
        cp "$BACKUP_DIR/$FILE" "${CONTROLLER_USER}"
        echo -e "${GREEN}✔ Dipulihkan dari $FILE${RESET}"
    else
        echo -e "${RED}❌ File backup tidak ditemukan.${RESET}"
    fi

elif [ "$OPSI" = "3" ]; then
    bash <(curl -s https://raw.githubusercontent.com/greysyncx/protect/main/greyz.sh)
else
    echo -e "${RED}❌ Opsi tidak valid.${RESET}"
fi
