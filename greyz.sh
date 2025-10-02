#!/bin/bash
# GreySync Protector + Anti-Intip v2.1 (Final Fix)
# Tested with Pterodactyl >= v1.11

RED="\033[1;31m"
GREEN="\033[1;32m"
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
RESET="\033[0m"
BOLD="\033[1m"

VERSION="2.1"
BACKUP_DIR="backup_greysync_protect"

declare -A CONTROLLERS=(
  ["NodeController.php"]="/var/www/pterodactyl/app/Http/Controllers/Admin/Nodes/NodeController.php"
  ["NestController.php"]="/var/www/pterodactyl/app/Http/Controllers/Admin/Nests/NestController.php"
  ["IndexController.php"]="/var/www/pterodactyl/app/Http/Controllers/Admin/Settings/IndexController.php"
  ["LocationController.php"]="/var/www/pterodactyl/app/Http/Controllers/Admin/Locations/LocationController.php"
)

SERVER_CONTROLLER="/var/www/pterodactyl/app/Http/Controllers/Admin/Servers/ServerController.php"

clear
echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║       GreySync Protector + Anti-Intip v$VERSION       ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"

echo -e "${YELLOW}Pilih mode:${RESET}"
echo "1) 🔐 Install Protect + Anti-Intip"
echo "2) ♻ Restore Backup"
read -p "Masukkan pilihan (1/2): " MODE

if [[ "$MODE" == "1" ]]; then
    read -p "👤 Masukkan ID Admin Utama (contoh: 1): " ADMIN_ID
    [ -z "$ADMIN_ID" ] && echo -e "${RED}❌ Admin ID tidak boleh kosong.${RESET}" && exit 1

    mkdir -p "$BACKUP_DIR"
    echo -e "${YELLOW}📦 Membackup file asli...${RESET}"
    for name in "${!CONTROLLERS[@]}"; do
        cp "${CONTROLLERS[$name]}" "$BACKUP_DIR/$name.bak"
    done
    cp "$SERVER_CONTROLLER" "$BACKUP_DIR/ServerController.php.bak"

    echo -e "${GREEN}🔧 Menerapkan Protect ke Controllers...${RESET}"
    for name in "${!CONTROLLERS[@]}"; do
        path="${CONTROLLERS[$name]}"
        awk -v admin_id="$ADMIN_ID" '
        BEGIN { inserted_use=0; in_func=0; }
        /^namespace / {
            print;
            if (!inserted_use) {
                print "use Illuminate\\Support\\Facades\\Auth;";
                inserted_use=1;
            }
            next;
        }
        /public function index\(.*\)/ { print; in_func=1; next }
        in_func==1 && /^\s*{/ {
            print;
            print "        $user = Auth::user();";
            print "        if (!$user || ($user->id != " admin_id " && !$user->root_admin)) abort(403);";
            in_func=0; next;
        }
        { print }
        ' "$path" > "$path.tmp" && mv "$path.tmp" "$path"
        echo -e "${GREEN}✅ Protect diterapkan ke: $name${RESET}"
    done

    echo -e "${GREEN}🔧 Menerapkan Anti-Intip ke ServerController...${RESET}"
    awk -v admin_id="$ADMIN_ID" '
    BEGIN { inserted_use=0; in_func=0; }
    /^namespace / {
        print;
        if (!inserted_use) {
            print "use Illuminate\\Support\\Facades\\Auth;";
            inserted_use=1;
        }
        next;
    }
    /public function show\(.*\)/ { print; in_func=1; next }
    in_func==1 && /^\s*{/ {
        print;
        print "        $user = Auth::user();";
        print "        if (!$user || ($user->id !== $server->owner_id && $user->id != " admin_id ")) abort(403);";
        in_func=0; next;
    }
    { print }
    ' "$BACKUP_DIR/ServerController.php.bak" > "$SERVER_CONTROLLER"
    echo -e "${GREEN}✅ Anti-Intip diterapkan ke ServerController${RESET}"

    echo -e "${YELLOW}🚀 Clear cache & rebuild panel...${RESET}"
    cd /var/www/pterodactyl || exit 1
    php artisan route:clear
    php artisan view:clear
    php artisan config:clear
    yarn build:production --progress

    echo -e "\n${BLUE}🎉 Install selesai. Backup ada di: $BACKUP_DIR${RESET}"

elif [[ "$MODE" == "2" ]]; then
    echo -e "${CYAN}♻ Memulihkan file...${RESET}"
    for name in "${!CONTROLLERS[@]}"; do
        [[ -f "$BACKUP_DIR/$name.bak" ]] && cp "$BACKUP_DIR/$name.bak" "${CONTROLLERS[$name]}"
    done
    [[ -f "$BACKUP_DIR/ServerController.php.bak" ]] && cp "$BACKUP_DIR/ServerController.php.bak" "$SERVER_CONTROLLER"

    cd /var/www/pterodactyl || exit 1
    php artisan route:clear
    php artisan view:clear
    php artisan config:clear
    yarn build:production --progress

    echo -e "\n${BLUE}✅ Restore selesai.${RESET}"
else
    echo -e "${RED}❌ Pilihan tidak valid.${RESET}"
fi
