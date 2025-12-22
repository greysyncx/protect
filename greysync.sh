#!/bin/bash

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

# Clear only if interactive
[[ -t 1 ]] && clear

# ===== HEADER (interactive only) =====
if [[ -z "$1" ]]; then
  echo -e "${CYAN}${BOLD}"
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║                                                      ║"
  echo "║          GreySync Protect + Panel Grey              ║"
  echo "║                 Version $VERSION                     ║"
  echo "║                                                      ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo -e "${RESET}"
fi

# ===== BOT MODE =====
OPSI="$1"
ADMIN_ID="$2"

if [ -z "$OPSI" ]; then
  echo -e "${RED}❌ Mode tidak diberikan. Gunakan: $0 <1|2> [adminId]${RESET}"
  exit 1
fi

# ================== MODE 1 : INSTALL ====================
if [ "$OPSI" = "1" ]; then

    if [ -z "$ADMIN_ID" ]; then
      echo -e "${RED}❌ ADMIN_ID wajib untuk mode install (mode 1).${RESET}"
      exit 1
    fi

    echo -e "${CYAN}➤ Mode Install Protect | Admin ID: ${ADMIN_ID}${RESET}"

    echo -e "${YELLOW}➤ Membuat backup sebelum patch...${RESET}"
    DATE_TAG=$(date +%F-%H%M%S)
    [ -f "$CONTROLLER_USER" ] && cp "$CONTROLLER_USER" "$BACKUP_DIR/UserController.$DATE_TAG.bak"
    [ -f "$SERVICE_SERVER" ] && cp "$SERVICE_SERVER" "$BACKUP_DIR/ServerDeletionService.$DATE_TAG.bak"
    [ -f "$API_SERVER_CONTROLLER" ] && cp "$API_SERVER_CONTROLLER" "$BACKUP_DIR/ServerControllerAPI.$DATE_TAG.bak"

    # ===== Protect Delete User =====
    if [ -f "$CONTROLLER_USER" ]; then
        echo -e "${YELLOW}➤ Menambahkan Protect Delete User...${RESET}"
        awk -v admin_id="$ADMIN_ID" '
        /public function delete\(Request \$request, User \$user\): RedirectResponse/ { print; in_func = 1; next }
        in_func == 1 && /^\s*{/ {
            print
            print "        if (\\$request->user()->id !== " admin_id ") {"
            print "            throw new DisplayException(\"Unauthorized delete user\");"
            print "        }"
            in_func = 0
            next
        }
        { print }' "$CONTROLLER_USER" > "$CONTROLLER_USER.tmp" && mv "$CONTROLLER_USER.tmp" "$CONTROLLER_USER"
        echo -e "${GREEN}✔ Protect Delete User selesai.${RESET}"
    fi

    # ===== Protect Delete Server =====
    if [ -f "$SERVICE_SERVER" ]; then
        echo -e "${YELLOW}➤ Menambahkan Protect Delete Server...${RESET}"
        if ! grep -q "use Illuminate\\Support\\Facades\\Auth;" "$SERVICE_SERVER"; then
            sed -i '/^namespace Pterodactyl\\Services\\Servers;/a use Illuminate\\Support\\Facades\\Auth;\nuse Pterodactyl\\Exceptions\\DisplayException;' "$SERVICE_SERVER"
        fi
        awk -v admin_id="$ADMIN_ID" '
        /public function handle\(Server \$server\): void/ { print; in_func = 1; next }
        in_func == 1 && /^\s*{/ {
            print
            print "        \\$user = Auth::user();"
            print "        if (\\$user && \\$user->id !== " admin_id ") {"
            print "            throw new DisplayException(\"Unauthorized delete server\");"
            print "        }"
            in_func = 0
            next
        }
        { print }' "$SERVICE_SERVER" > "$SERVICE_SERVER.tmp" && mv "$SERVICE_SERVER.tmp" "$SERVICE_SERVER"
        echo -e "${GREEN}✔ Protect Delete Server selesai.${RESET}"
    fi

    # ===== Anti Intip Server API =====
    if [ -f "$API_SERVER_CONTROLLER" ]; then
        echo -e "${YELLOW}➤ Menambahkan Anti Intip Server API...${RESET}"
        awk -v admin_id="$ADMIN_ID" '
        /public function index\(GetServerRequest \$request, Server \$server\): array/ { print; in_func = 1; next }
        in_func == 1 && /^\s*{/ {
            print
            print "        \\$user = \\$request->user();"
            print "        if (\\$user->id !== \\$server->owner_id && \\$user->id !== " admin_id ") {"
            print "            abort(403, \"Unauthorized access\");"
            print "        }"
            in_func = 0
            next
        }
        { print }' "$API_SERVER_CONTROLLER" > "$API_SERVER_CONTROLLER.tmp" && mv "$API_SERVER_CONTROLLER.tmp" "$API_SERVER_CONTROLLER"
        echo -e "${GREEN}✔ Anti Intip Server selesai.${RESET}"
    fi

    # ===== Proteksi Blade View =====
    VIEW_FILE="$VIEW_DIR/servers/view/index.blade.php"
    if [ -f "$VIEW_FILE" ]; then
        echo -e "${YELLOW}➤ Menambahkan Proteksi View Detail Server...${RESET}"
        cp "$VIEW_FILE" "$BACKUP_DIR/view_index_$(date +%F-%H%M%S).bak"

        awk -v admin_id="$ADMIN_ID" '
        NR==1 {
            print "@php"
            print "    \\$user = auth()->user();"
            print "    \\$ownerId = \\$server->owner_id ?? null;"
            print "    if (!isset(\\$user) || (\\$user->id !== \\$ownerId && \\$user->id !== " admin_id ")) {"
            print "        abort(403, \"Unauthorized access\");"
            print "    }"
            print "@endphp"
        }
        { print }' "$VIEW_FILE" > "$VIEW_FILE.tmp" && mv "$VIEW_FILE.tmp" "$VIEW_FILE"
        echo -e "${GREEN}✔ Proteksi Blade View selesai.${RESET}"
    fi

    echo -e "${GREEN}🎉 Protect v$VERSION berhasil dipasang.${RESET}"

    # ===== CHAIN TO GREYZ =====
    echo -e "${CYAN}➡ Menjalankan GreyZ Admin Protect...${RESET}"
    if [[ -f "./greyz.sh" ]]; then
      bash ./greyz.sh 1 "$ADMIN_ID"
    else
      echo -e "${YELLOW}⚠ greyz.sh tidak ditemukan, lewati Admin Protect.${RESET}"
    fi

    exit 0

# ================= MODE 2 : RESTORE ======================
elif [ "$OPSI" = "2" ]; then

    echo -e "${CYAN}♻ Mengembalikan semua file dari backup terbaru...${RESET}"
    LATEST=$(ls -t "$BACKUP_DIR"/*.bak 2>/dev/null | head -n 1 | sed 's/.*\.\(.*\)\.bak/\1/')
    [ -z "$LATEST" ] && { echo -e "${RED}❌ Tidak ada backup ditemukan.${RESET}"; exit 1; }

    for FILE in "$BACKUP_DIR"/*"$LATEST"*.bak; do
        BASE=$(basename "$FILE" | cut -d'.' -f1)
        case "$BASE" in
            UserController) TARGET="$CONTROLLER_USER" ;;
            ServerDeletionService) TARGET="$SERVICE_SERVER" ;;
            ServerControllerAPI) TARGET="$API_SERVER_CONTROLLER" ;;
            view_index_*) TARGET="$VIEW_DIR/servers/view/index.blade.php" ;;
            *) continue ;;
        esac
        [ -n "$TARGET" ] && [ -f "$TARGET" ] && cp "$FILE" "$TARGET" \
          && echo -e "${GREEN}✔ Dipulihkan: $TARGET${RESET}"
    done

    echo -e "${GREEN}✅ Semua file berhasil dikembalikan dari backup terbaru.${RESET}"
    exit 0

else
    echo -e "${RED}❌ Opsi tidak valid: $OPSI (gunakan 1 atau 2)${RESET}"
    exit 1
fi
