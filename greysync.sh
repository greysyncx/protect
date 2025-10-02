#!/bin/bash
# GreySync Protect + Panel Builder
# Versi 2.0 (Final Fix)

RED="\033[1;31m"
GREEN="\033[1;32m"
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
RESET="\033[0m"
BOLD="\033[1m"

VERSION="2.0"

CONTROLLER_USER="/var/www/pterodactyl/app/Http/Controllers/Admin/UserController.php"
SERVICE_SERVER="/var/www/pterodactyl/app/Services/Servers/ServerDeletionService.php"
BACKUP_DIR="backup_greysync_protect"

clear
echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║         GreySync Protect + Panel Builder             ║"
echo "║                   Version $VERSION                    ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"

echo -e "${YELLOW}[1]${RESET} Pasang Protect & Build Panel"
echo -e "${YELLOW}[2]${RESET} Restore dari Backup & Build Panel"
echo -e "${YELLOW}[3]${RESET} Pasang Protect Admin (Eksternal)"
echo -e "${YELLOW}[4]${RESET} Uninstall Protect (tanpa build panel)"
read -p "$(echo -e "${CYAN}Pilih opsi [1/2/3/4]: ${RESET}")" OPSI


# ======================== OPSI 1 =========================
if [ "$OPSI" = "1" ]; then
    read -p "$(echo -e "${CYAN}Masukkan User ID Admin Utama (contoh: 1): ${RESET}")" ADMIN_ID
    [[ -z "$ADMIN_ID" ]] && { echo -e "${RED}❌ Admin ID kosong.${RESET}"; exit 1; }

    mkdir -p "$BACKUP_DIR"

    echo -e "${YELLOW}📦 Membackup file...${RESET}"
    cp "$CONTROLLER_USER" "$BACKUP_DIR/UserController.php.bak"
    cp "$SERVICE_SERVER" "$BACKUP_DIR/ServerDeletionService.php.bak"

    echo -e "${GREEN}🔧 Menerapkan Protect ke Admin ID: $ADMIN_ID${RESET}"

    # --- Patch UserController ---
    awk -v admin_id="$ADMIN_ID" -v ver="$VERSION" '
    /public function delete\(Request \$request, User \$user\)/ {print; in_func=1; next}
    in_func==1 && /^\s*{/ {
        print;
        print "        if ($request->user()->id !== " admin_id ") {";
        print "            throw new DisplayException(\"❌ Akses ditolak! Hanya Admin ID " admin_id " yang boleh hapus user. ©GreySync v" ver "\");";
        print "        }";
        in_func=0; next;
    }
    {print}
    ' "$BACKUP_DIR/UserController.php.bak" > "$CONTROLLER_USER"

    # --- Patch ServerDeletionService ---
    cp "$SERVICE_SERVER" "$SERVICE_SERVER.tmp"
    awk '
    BEGIN{added=0}
    {
        print
        if (!added && $0 ~ /^namespace /) {
            print "use Illuminate\\Support\\Facades\\Auth;"
            print "use Pterodactyl\\Exceptions\\DisplayException;"
            added=1
        }
    }' "$SERVICE_SERVER.tmp" > "$SERVICE_SERVER"

    awk -v admin_id="$ADMIN_ID" -v ver="$VERSION" '
    /public function handle\(Server \$server\)/ {print; in_func=1; next}
    in_func==1 && /^\s*{/ {
        print;
        print "        $user = Auth::user();";
        print "        if ($user && $user->id !== " admin_id ") {";
        print "            throw new DisplayException(\"❌ Akses ditolak! Hanya Admin ID " admin_id " yang boleh hapus server. ©GreySync v" ver "\");";
        print "        }";
        in_func=0; next;
    }
    {print}
    ' "$SERVICE_SERVER" > "$SERVICE_SERVER.patched" && mv "$SERVICE_SERVER.patched" "$SERVICE_SERVER"
    rm -f "$SERVICE_SERVER.tmp"

    echo -e "${GREEN}✅ Patch Protect selesai.${RESET}"

    echo -e "${YELLOW}⚙️  Install Node.js 20 & build panel...${RESET}"
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - >/dev/null
    sudo apt-get install -y nodejs >/dev/null

    cd /var/www/pterodactyl || exit 1
    npm i -g yarn >/dev/null
    yarn install --ignore-engines >/dev/null
    yarn build:production --progress

    echo -e "${GREEN}🎉 Protect v$VERSION berhasil dipasang.${RESET}"


# ================= OPSI 2 =======================
elif [ "$OPSI" = "2" ]; then
    echo -e "${YELLOW}♻ Restore file...${RESET}"
    [[ -f "$BACKUP_DIR/UserController.php.bak" ]] && cp "$BACKUP_DIR/UserController.php.bak" "$CONTROLLER_USER"
    [[ -f "$BACKUP_DIR/ServerDeletionService.php.bak" ]] && cp "$BACKUP_DIR/ServerDeletionService.php.bak" "$SERVICE_SERVER"

    cd /var/www/pterodactyl || exit 1
    yarn build:production --progress
    echo -e "${GREEN}✅ Restore & rebuild selesai.${RESET}"


# ============= OPSI 3 =====================
elif [ "$OPSI" = "3" ]; then
    bash <(curl -s https://raw.githubusercontent.com/greysyncx/protect/main/greyz.sh)


# =========== OPSI 4 ==================
elif [ "$OPSI" = "4" ]; then
    echo -e "${CYAN}🗑 Uninstall Protect...${RESET}"
    [[ -f "$BACKUP_DIR/UserController.php.bak" ]] && cp "$BACKUP_DIR/UserController.php.bak" "$CONTROLLER_USER"
    [[ -f "$BACKUP_DIR/ServerDeletionService.php.bak" ]] && cp "$BACKUP_DIR/ServerDeletionService.php.bak" "$SERVICE_SERVER"
    echo -e "${GREEN}✅ Uninstall selesai.${RESET}"
else
    echo -e "${RED}❌ Opsi tidak valid.${RESET}"
    exit 1
fi
