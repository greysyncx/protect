#!/bin/bash
# GreySync Protect + Panel Builder
# Versi 1.6 (Final Fix)

RED="\033[1;31m"
GREEN="\033[1;32m"
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
RESET="\033[0m"
BOLD="\033[1m"
VERSION="1.6"

CONTROLLER_USER="/var/www/pterodactyl/app/Http/Controllers/Admin/UserController.php"
SERVICE_SERVER="/var/www/pterodactyl/app/Services/Servers/ServerDeletionService.php"

clear
echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║            GreySync Protect + Panel Builder          ║"
echo "║                   Version $VERSION                   ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"

echo -e "${YELLOW}[1]${RESET} Pasang Protect & Build Panel"
echo -e "${YELLOW}[2]${RESET} Restore dari Backup & Build Panel"
echo -e "${YELLOW}[3]${RESET} Pasang Protect Admin (Eksternal)"
read -p "$(echo -e "${CYAN}Pilih opsi [1/2/3]: ${RESET}")" OPSI

if [ "$OPSI" = "1" ]; then
    read -p "$(echo -e "${CYAN}Masukkan User ID Admin Utama (contoh: 1): ${RESET}")" ADMIN_ID
    [ -z "$ADMIN_ID" ] && echo -e "${RED}❌ Admin ID wajib diisi.${RESET}" && exit 1

    echo -e "${YELLOW}📦 Membuat backup...${RESET}"
    cp "$CONTROLLER_USER" "${CONTROLLER_USER}.bak"
    cp "$SERVICE_SERVER" "${SERVICE_SERVER}.bak"

    echo -e "${GREEN}🔧 Memasang Protect Delete User...${RESET}"
    awk -v admin_id="$ADMIN_ID" -v version="$VERSION" '
    /public function delete\(Request \$request, User \$user\): RedirectResponse/ {
        print; in_func = 1; next;
    }
    in_func == 1 && /^\s*{/ {
        print;
        print "        if ($request->user()->id !== " admin_id ") {";
        print "            throw new DisplayException(\"Lu siapa mau hapus user orang? Izin dulu sama ID " admin_id " ©GreySync v" version "\");";
        print "        }";
        in_func = 0; next;
    }
    { print }
    ' "${CONTROLLER_USER}.bak" > "$CONTROLLER_USER"

    echo -e "${GREEN}✔ UserController terproteksi.${RESET}"

    echo -e "${GREEN}🔧 Memasang Protect Delete Server...${RESET}"
    awk '
    BEGIN { added=0 }
    {
        print
        if (!added && $0 ~ /^namespace Pterodactyl\\Services\\Servers;/) {
            print "use Illuminate\\Support\\Facades\\Auth;"
            print "use Pterodactyl\\Exceptions\\DisplayException;"
            added=1
        }
    }' "$SERVICE_SERVER" > "$SERVICE_SERVER.tmp" && mv "$SERVICE_SERVER.tmp" "$SERVICE_SERVER"

    awk -v admin_id="$ADMIN_ID" -v version="$VERSION" '
    /public function handle\(Server \$server\): void/ {
        print; in_func=1; next;
    }
    in_func==1 && /^\s*{/ {
        print;
        print "        $user = Auth::user();";
        print "        if ($user && $user->id !== " admin_id ") {";
        print "            throw new DisplayException(\"Lu siapa mau hapus server orang? Izin dulu sama ID " admin_id " ©GreySync v" version "\");";
        print "        }";
        in_func=0; next;
    }
    { print }
    ' "$SERVICE_SERVER" > "${SERVICE_SERVER}.patched" && mv "${SERVICE_SERVER}.patched" "$SERVICE_SERVER"

    echo -e "${GREEN}✔ ServerDeletionService terproteksi.${RESET}"

    echo -e "${YELLOW}⚙️  Install Node.js 16 & Build Panel...${RESET}"
    sudo apt-get update -y >/dev/null
    sudo apt-get remove -y nodejs >/dev/null
    curl -fsSL https://deb.nodesource.com/setup_16.x | sudo -E bash - >/dev/null
    sudo apt-get install -y nodejs >/dev/null

    cd /var/www/pterodactyl || { echo -e "${RED}❌ Gagal masuk direktori panel.${RESET}"; exit 1; }
    npm i -g yarn >/dev/null
    yarn add cross-env >/dev/null
    yarn build:production --progress

    echo -e "${GREEN}🎉 Protect v$VERSION berhasil dipasang.${RESET}"

elif [ "$OPSI" = "2" ]; then
    echo -e "${YELLOW}♻ Restore backup...${RESET}"
    [ -f "${CONTROLLER_USER}.bak" ] && cp "${CONTROLLER_USER}.bak" "$CONTROLLER_USER" && echo -e "${GREEN}✔ UserController dipulihkan.${RESET}"
    [ -f "${SERVICE_SERVER}.bak" ] && cp "${SERVICE_SERVER}.bak" "$SERVICE_SERVER" && echo -e "${GREEN}✔ ServerDeletionService dipulihkan.${RESET}"

    cd /var/www/pterodactyl || exit 1
    yarn build:production --progress
    echo -e "${GREEN}✅ Restore & rebuild selesai.${RESET}"

elif [ "$OPSI" = "3" ]; then
    echo -e "${CYAN}🔗 Menjalankan Protect Admin Eksternal (greyz.sh)...${RESET}"
    bash <(curl -s https://raw.githubusercontent.com/greysyncx/protect/main/greyz.sh)

else
    echo -e "${RED}❌ Opsi tidak valid.${RESET}"
    exit 1
fi
