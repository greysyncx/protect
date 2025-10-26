#!/bin/bash

RED="\033[1;31m"
GREEN="\033[1;32m"
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
RESET="\033[0m"
BOLD="\033[1m"
VERSION="1.5"

MODE_ARG="$1"
ADMIN_ID_ARG="$2"
AUTO_MODE=0
OPSI=""
ADMIN_ID=""

if [[ "$MODE_ARG" =~ ^[123]$ ]]; then
    AUTO_MODE=1
    OPSI="$MODE_ARG"
    if [[ "$OPSI" == "1" || "$OPSI" == "3" ]]; then
        if [[ "$ADMIN_ID_ARG" =~ ^[0-9]+$ ]]; then
            ADMIN_ID="$ADMIN_ID_ARG"
        else
            echo -e "${RED}❌ Mode otomatis membutuhkan Admin ID (contoh: bash greysync.sh 1 12345).${RESET}"
            exit 1
        fi
    fi
else
    clear
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║         GreySync Protect + Panel Grey                ║"
    echo "║                    Version $VERSION                  ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
    echo -e "${YELLOW}[1]${RESET} Pasang Protect & Build Panel"
    echo -e "${YELLOW}[2]${RESET} Restore dari Backup Terakhir"
    echo -e "${YELLOW}[3]${RESET} Pasang Protect Admin"
    read -p "$(echo -e "${CYAN}Pilih opsi [1/2/3]: ${RESET}")" OPSI

    if [[ "$OPSI" == "1" || "$OPSI" == "3" ]]; then
        read -p "$(echo -e "${CYAN}👤 Masukkan User ID Admin Utama (contoh: 1): ${RESET}")" ADMIN_ID
    fi
fi
# Validate opsi
if [[ -z "$OPSI" || ! "$OPSI" =~ ^[123]$ ]]; then
    echo -e "${RED}❌ Opsi tidak valid.${RESET}"
    exit 1
fi
# For interactive mode
if [[ ( "$OPSI" == "1" || "$OPSI" == "3" ) && -z "$ADMIN_ID" ]]; then
    echo -e "${RED}❌ Admin ID tidak boleh kosong untuk opsi ini.${RESET}"
    exit 1
fi
# ========== FILE PENTING ==========
CONTROLLER_USER="/var/www/pterodactyl/app/Http/Controllers/Admin/UserController.php"
SERVICE_SERVER="/var/www/pterodactyl/app/Services/Servers/ServerDeletionService.php"
API_SERVER_CONTROLLER="/var/www/pterodactyl/app/Http/Controllers/Api/Client/Servers/ServerController.php"
BACKUP_DIR="backup_greysyncx"
mkdir -p "$BACKUP_DIR"
# Create a timestamped backup function for safety
backup_file_if_exists() {
    local file="$1"
    if [ -f "$file" ]; then
        DATE_TAG=$(date +%F-%H%M%S)
        cp "$file" "$BACKUP_DIR/$(basename "$file").$DATE_TAG.bak" 2>/dev/null || true
    fi
}

if [ "$OPSI" = "1" ]; then
    echo -e "${YELLOW}➤ Membuat backup sebelum patch...${RESET}"
    backup_file_if_exists "$CONTROLLER_USER"
    backup_file_if_exists "$SERVICE_SERVER"
    backup_file_if_exists "$API_SERVER_CONTROLLER"

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
    LATEST=$(ls -t "$BACKUP_DIR"/*.bak 2>/dev/null | head -n 1)
    if [ -z "$LATEST" ]; then
        echo -e "${RED}❌ Tidak ada backup ditemukan.${RESET}"
        exit 1
    fi
    for FILE in "$BACKUP_DIR"/*.bak; do
        BASENAME=$(basename "$FILE")
        # match original base by prefix before first dot
        BASE=$(echo "$BASENAME" | cut -d'.' -f1)
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
    echo -e "${YELLOW}➡ Menjalankan GreyZ Admin Protect...${RESET}"
    bash <(curl -s https://raw.githubusercontent.com/greysyncx/protect/main/greyz.sh) "$ADMIN_ID"
else
    echo -e "${RED}❌ Opsi tidak valid.${RESET}"
    exit 1
fi
