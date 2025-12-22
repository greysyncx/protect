#!/bin/bash

# ===== AUTO MODE =====
OPSI_ARG="${1:-}"
ADMIN_ARG="${2:-}"
AUTO_MODE=0
OPSI=""
ADMIN_ID=""

if [[ "$OPSI_ARG" =~ ^[1-3]$ ]]; then
  AUTO_MODE=1
  OPSI="$OPSI_ARG"
  ADMIN_ID="$ADMIN_ARG"
fi

# ===== COLOR =====
RED="\033[1;31m"
GREEN="\033[1;32m"
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
RESET="\033[0m"
BOLD="\033[1m"

# ===== CONFIG =====
VERSION="1.6"
BACKUP_DIR="backup_greysyncx"
CONTROLLER_USER="/var/www/pterodactyl/app/Http/Controllers/Admin/UserController.php"
SERVICE_SERVER="/var/www/pterodactyl/app/Services/Servers/ServerDeletionService.php"
API_SERVER_CONTROLLER="/var/www/pterodactyl/app/Http/Controllers/Api/Client/Servers/ServerController.php"
VIEW_DIR="/var/www/pterodactyl/resources/views/admin"

mkdir -p "$BACKUP_DIR"

clear

# ===== HEADER =====
echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║                                                      ║"
echo "║          GreySync Protect + Panel Grey              ║"
echo "║                 Version $VERSION                     ║"
echo "║                                                      ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"

# ===== MENU =====
echo
echo -e "${YELLOW}[1]${RESET} Pasang Protect & Build Panel"
echo -e "${YELLOW}[2]${RESET} Restore dari Backup Terakhir"
echo -e "${YELLOW}[3]${RESET} Pasang Protect Admin"
echo

if [[ "$AUTO_MODE" -eq 0 ]]; then
  read -p "$(echo -e "${CYAN}➤ Pilih opsi [1/2/3]: ${RESET}")" OPSI
fi
echo

# ================== MODE 1 ====================
if [ "$OPSI" = "1" ]; then

    if [[ -z "$ADMIN_ID" ]]; then
      read -p "$(echo -e "${CYAN}👤 Masukkan User ID Admin Utama (contoh: 1): ${RESET}")" ADMIN_ID
    fi

    [ -z "$ADMIN_ID" ] && { echo -e "${RED}❌ ADMIN ID kosong.${RESET}"; exit 1; }

    echo -e "${YELLOW}➤ Membuat backup sebelum patch...${RESET}"
    DATE_TAG=$(date +%F-%H%M%S)
    [ -f "$CONTROLLER_USER" ] && cp "$CONTROLLER_USER" "$BACKUP_DIR/UserController.$DATE_TAG.bak"
    [ -f "$SERVICE_SERVER" ] && cp "$SERVICE_SERVER" "$BACKUP_DIR/ServerDeletionService.$DATE_TAG.bak"
    [ -f "$API_SERVER_CONTROLLER" ] && cp "$API_SERVER_CONTROLLER" "$BACKUP_DIR/ServerControllerAPI.$DATE_TAG.bak"

    # ===== Protect Delete User =====
    if [ -f "$CONTROLLER_USER" ]; then
        awk -v admin_id="$ADMIN_ID" '
        /public function delete\(Request \$request, User \$user\): RedirectResponse/ { print; in_func = 1; next }
        in_func == 1 && /^\s*{/ {
            print
            print "        if (\$request->user()->id !== " admin_id ") {"
            print "            throw new DisplayException(\"🤬 Lu siapa mau hapus user lain?\\nJasa Pasang Anti-Rusuh t.me/greysyncx\");"
            print "        }"
            in_func = 0
            next
        }
        { print }' "$CONTROLLER_USER" > "$CONTROLLER_USER.tmp" && mv "$CONTROLLER_USER.tmp" "$CONTROLLER_USER"
    fi

    # ===== Protect Delete Server =====
    if [ -f "$SERVICE_SERVER" ]; then
        if ! grep -q "use Illuminate\\Support\\Facades\\Auth;" "$SERVICE_SERVER"; then
            sed -i '/^namespace Pterodactyl\\Services\\Servers;/a use Illuminate\\Support\\Facades\\Auth;\nuse Pterodactyl\\Exceptions\\DisplayException;' "$SERVICE_SERVER"
        fi
        awk -v admin_id="$ADMIN_ID" '
        /public function handle\(Server \$server\): void/ { print; in_func = 1; next }
        in_func == 1 && /^\s*{/ {
            print
            print "        \$user = Auth::user();"
            print "        if (\$user && \$user->id !== " admin_id ") {"
            print "            throw new DisplayException(\"🤬 Lu siapa mau hapus server orang?\\nJasa Pasang Anti-Rusuh t.me/greysyncx\");"
            print "        }"
            in_func = 0
            next
        }
        { print }' "$SERVICE_SERVER" > "$SERVICE_SERVER.tmp" && mv "$SERVICE_SERVER.tmp" "$SERVICE_SERVER"
    fi

    # ===== Anti Intip Server (API) =====
    if [ -f "$API_SERVER_CONTROLLER" ]; then
        awk -v admin_id="$ADMIN_ID" '
        /public function index\(GetServerRequest \$request, Server \$server\): array/ { print; in_func = 1; next }
        in_func == 1 && /^\s*{/ {
            print
            print "        \$user = \$request->user();"
            print "        if (\$user->id !== \$server->owner_id && \$user->id !== " admin_id ") {"
            print "            abort(403, \"❌ Lu siapa mau intip server orang! Jasa Pasang Anti-Rusuh t.me/greysyncx\");"
            print "        }"
            in_func = 0
            next
        }
        { print }' "$API_SERVER_CONTROLLER" > "$API_SERVER_CONTROLLER.tmp" && mv "$API_SERVER_CONTROLLER.tmp" "$API_SERVER_CONTROLLER"
    fi

    # ===== Proteksi Blade View =====
    VIEW_FILE="$VIEW_DIR/servers/view/index.blade.php"
    if [ -f "$VIEW_FILE" ]; then
        cp "$VIEW_FILE" "$BACKUP_DIR/view_index_$(date +%F-%H%M%S).bak"
        sed -i '/Lu siapa mau intip detail server orang/d' "$VIEW_FILE" 2>/dev/null || true
        sed -i '/auth()->user();/d' "$VIEW_FILE" 2>/dev/null || true
        sed -i '/abort(403/d' "$VIEW_FILE" 2>/dev/null || true

        awk -v admin_id="$ADMIN_ID" '
        NR==1 {
            print "@php"
            print "    \$user = auth()->user();"
            print "    \$ownerId = \$server->owner_id ?? null;"
            print "    if (!isset(\$user) || (\$user->id !== \$ownerId && \$user->id !== " admin_id ")) {"
            print "        abort(403, \"❌ Lu siapa mau intip detail server orang! Jasa Pasang Anti-Rusuh t.me/greysyncx\");"
            print "    }"
            print "@endphp"
        }
        { print }' "$VIEW_FILE" > "$VIEW_FILE.tmp" && mv "$VIEW_FILE.tmp" "$VIEW_FILE"
    fi

# ================= MODE 2 ======================
elif [ "$OPSI" = "2" ]; then
    LATEST=$(ls -t "$BACKUP_DIR"/*.bak 2>/dev/null | head -n 1 | sed 's/.*\.\(.*\)\.bak/\1/')
    [ -z "$LATEST" ] && exit 1

    for FILE in "$BACKUP_DIR"/*"$LATEST"*.bak; do
        BASE=$(basename "$FILE" | cut -d'.' -f1)
        case "$BASE" in
            UserController) TARGET="$CONTROLLER_USER" ;;
            ServerDeletionService) TARGET="$SERVICE_SERVER" ;;
            ServerControllerAPI) TARGET="$API_SERVER_CONTROLLER" ;;
            view_index_*) TARGET="$VIEW_DIR/servers/view/index.blade.php" ;;
            *) continue ;;
        esac
        [ -n "$TARGET" ] && [ -f "$TARGET" ] && cp "$FILE" "$TARGET"
    done

# ================== MODE 3 ======================
elif [ "$OPSI" = "3" ]; then
    bash <(curl -s https://raw.githubusercontent.com/greysyncx/protect/main/greyz.sh)
else
    echo -e "${RED}❌ Opsi tidak valid.${RESET}"
fi
