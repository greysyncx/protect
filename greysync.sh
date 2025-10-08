#!/bin/bash

RED="\033[1;31m"
GREEN="\033[1;32m"
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
RESET="\033[0m"
BOLD="\033[1m"
VERSION="1.5"

clear
echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║         GreySync Protect + Panel Grey             ║"
echo "║                    Version $VERSION                       ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"

echo -e "${YELLOW}[1]${RESET} Pasang Protect & Build Panel"
echo -e "${YELLOW}[2]${RESET} Restore dari Backup Terakhir"
echo -e "${YELLOW}[3]${RESET} Pasang Protect Admin"
read -p "$(echo -e "${CYAN}Pilih opsi [1/2/3]: ${RESET}")" OPSI

CONTROLLER_USER="/var/www/pterodactyl/app/Http/Controllers/Admin/UserController.php"
SERVICE_SERVER="/var/www/pterodactyl/app/Services/Servers/ServerDeletionService.php"
API_SERVER_CONTROLLER="/var/www/pterodactyl/app/Http/Controllers/Api/Client/Servers/ServerController.php"
BACKUP_DIR="backup_greysyncx"

mkdir -p "$BACKUP_DIR"

if [ "$OPSI" = "1" ]; then
    read -p "$(echo -e "${CYAN}👤 Masukkan User ID Admin Utama (contoh: 1): ${RESET}")" ADMIN_ID

    echo -e "${YELLOW}➤ Membuat backup sebelum patch...${RESET}"
    DATE_TAG=$(date +%F-%H%M%S)
    cp "$CONTROLLER_USER" "$BACKUP_DIR/UserController.$DATE_TAG.bak"
    cp "$SERVICE_SERVER" "$BACKUP_DIR/ServerDeletionService.$DATE_TAG.bak"
    cp "$API_SERVER_CONTROLLER" "$BACKUP_DIR/ServerControllerAPI.$DATE_TAG.bak"

    # === Protect Delete User ===
    echo -e "${YELLOW}➤ Menambahkan Protect Delete User...${RESET}"
    awk -v admin_id="$ADMIN_ID" '
    /public function delete\(Request \$request, User \$user\): RedirectResponse/ { print; in_func = 1; next }
    in_func == 1 && /^\s*{/ {
        print;
        print "        if ($request->user()->id !== " admin_id ") {";
        print "            throw new DisplayException(\"🤬 Lu siapa mau hapus user lain?\\nJasa Pasang Anti-Rusuh t.me/greysyncx\");";
        print "        }";
        in_func = 0; next;
    }
    { print }' "$CONTROLLER_USER" > "$CONTROLLER_USER.tmp" && mv "$CONTROLLER_USER.tmp" "$CONTROLLER_USER"
    echo -e "${GREEN}✔ Protect Delete User selesai.${RESET}"

    # === Protect Delete Server ===
    echo -e "${YELLOW}➤ Menambahkan Protect Delete Server...${RESET}"
    if ! grep -q "use Illuminate\\Support\\Facades\\Auth;" "$SERVICE_SERVER"; then
        sed -i '/^namespace Pterodactyl\\Services\\Servers;/a use Illuminate\\Support\\Facades\\Auth;\nuse Pterodactyl\\Exceptions\\DisplayException;' "$SERVICE_SERVER"
    fi
    awk -v admin_id="$ADMIN_ID" '
    /public function handle\(Server \$server\): void/ { print; in_func = 1; next }
    in_func == 1 && /^\s*{/ {
        print;
        print "        \$user = Auth::user();";
        print "        if (\$user && \$user->id !== " admin_id ") {";
        print "            throw new DisplayException(\"🤬 Lu siapa mau hapus server orang?\\nJasa Pasang Anti-Rusuh t.me/greysyncx\");";
        print "        }";
        in_func = 0; next;
    }
    { print }' "$SERVICE_SERVER" > "$SERVICE_SERVER.tmp" && mv "$SERVICE_SERVER.tmp" "$SERVICE_SERVER"
    echo -e "${GREEN}✔ Protect Delete Server selesai.${RESET}"

    # === Anti Intip Server ===
    echo -e "${YELLOW}➤ Menambahkan Anti Intip Server...${RESET}"
    awk -v admin_id="$ADMIN_ID" '
    /public function index\(GetServerRequest \$request, Server \$server\): array/ { print; in_func = 1; next }
    in_func == 1 && /^\s*{/ {
        print;
        print "        $user = $request->user();";
        print "        if ($user->id !== $server->owner_id && $user->id !== " admin_id ") {";
        print "            abort(403, \"❌ Lu siapa mau intip server orang! Jasa Pasang Anti-Rusuh t.me/greysyncx\");";
        print "        }";
        in_func = 0; next;
    }
    { print }' "$API_SERVER_CONTROLLER" > "$API_SERVER_CONTROLLER.tmp" && mv "$API_SERVER_CONTROLLER.tmp" "$API_SERVER_CONTROLLER"
    echo -e "${GREEN}✔ Anti Intip Server selesai.${RESET}"

    echo -e "${GREEN}🎉 Protect v$VERSION berhasil dipasang${RESET}"

elif [ "$OPSI" = "2" ]; then
    echo -e "${CYAN}♻ Mengembalikan semua file dari backup terbaru...${RESET}"
    LATEST=$(ls -t "$BACKUP_DIR"/*.bak | head -n 1 | sed 's/.*\.\(.*\)\.bak/\1/')
    [ -z "$LATEST" ] && { echo -e "${RED}❌ Tidak ada backup ditemukan.${RESET}"; exit 1; }

    for FILE in "$BACKUP_DIR"/*"$LATEST"*.bak; do
        BASE=$(basename "$FILE" | cut -d'.' -f1)
        case "$BASE" in
            UserController) TARGET="$CONTROLLER_USER" ;;
            ServerDeletionService) TARGET="$SERVICE_SERVER" ;;
            ServerControllerAPI) TARGET="$API_SERVER_CONTROLLER" ;;
            *) continue ;;
        esac
        cp "$FILE" "$TARGET"
        echo -e "${GREEN}✔ Dipulihkan: $BASE${RESET}"
    done

    echo -e "${GREEN}✅ Semua file berhasil dikembalikan dari backup terbaru.${RESET}"

elif [ "$OPSI" = "3" ]; then
    bash <(curl -s https://raw.githubusercontent.com/greysyncx/protect/main/greyz.sh)
else
    echo -e "${RED}❌ Opsi tidak valid.${RESET}"
fi
