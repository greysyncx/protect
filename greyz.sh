#!/bin/bash
# GreySync Protector + Anti-Intip v2.2 (Final Fix + Location)

RED="\033[1;31m"
GREEN="\033[1;32m"
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
RESET="\033[0m"
BOLD="\033[1m"

VERSION="2.2"
BACKUP_DIR="backup_greysync_protect"

# === Controller yang diproteksi
declare -A CONTROLLERS=(
  ["NodeController.php"]="/var/www/pterodactyl/app/Http/Controllers/Admin/Nodes/NodeController.php"
  ["NestController.php"]="/var/www/pterodactyl/app/Http/Controllers/Admin/Nests/NestController.php"
  ["SettingsController.php"]="/var/www/pterodactyl/app/Http/Controllers/Admin/SettingsController.php"
  ["LocationController.php"]="/var/www/pterodactyl/app/Http/Controllers/Admin/Locations/LocationController.php"
)

SERVER_CONTROLLER="/var/www/pterodactyl/app/Http/Controllers/Admin/Servers/ServerController.php"

clear
echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║ GreySync Protector + Anti-Intip v${VERSION}                    ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"

echo "1) 🔐 Install Protect + Anti-Intip"
echo "2) ♻ Restore Backup"
read -p "Pilih (1/2): " MODE

if [[ "$MODE" == "1" ]]; then
    read -p "👤 Masukkan ID Admin Utama: " ADMIN_ID
    [[ -z "$ADMIN_ID" ]] && { echo -e "${RED}❌ Admin ID kosong.${RESET}"; exit 1; }

    mkdir -p "$BACKUP_DIR"
    for name in "${!CONTROLLERS[@]}"; do cp "${CONTROLLERS[$name]}" "$BACKUP_DIR/$name.bak"; done
    cp "$SERVER_CONTROLLER" "$BACKUP_DIR/ServerController.php.bak"

    echo -e "${GREEN}🔧 Patch ke Admin ID: $ADMIN_ID${RESET}"

    # Protect semua controller admin (Node, Nest, Settings, Location)
    for name in "${!CONTROLLERS[@]}"; do
        path="${CONTROLLERS[$name]}"
        awk -v admin_id="$ADMIN_ID" '
        BEGIN{use=0; func=0}
        /^namespace / {
            print;
            if(!use){print "use Illuminate\\Support\\Facades\\Auth;"; use=1}
            next
        }
        /public function index\(.*\)/ {print; func=1; next}
        func==1 && /^\s*{/ {
            print;
            print "        $user = Auth::user();";
            print "        if (!$user || $user->id != " admin_id ") abort(403);";
            func=0; next
        }
        {print}
        ' "$path" > "$path.tmp" && mv "$path.tmp" "$path"
        echo -e "${GREEN}✅ $name terproteksi${RESET}"
    done

    # Anti intip server (show)
    awk -v admin_id="$ADMIN_ID" '
    BEGIN{use=0; func=0}
    /^namespace / {
        print;
        if(!use){print "use Illuminate\\Support\\Facades\\Auth;"; use=1}
        next
    }
    /public function show\(.*\)/ {print; func=1; next}
    func==1 && /^\s*{/ {
        print;
        print "        $user = Auth::user();";
        print "        if (!$user || ($user->id !== $server->owner_id && $user->id != " admin_id ")) abort(403);";
        func=0; next
    }
    {print}
    ' "$BACKUP_DIR/ServerController.php.bak" > "$SERVER_CONTROLLER"
    echo -e "${GREEN}✅ Anti-Intip Server aktif${RESET}"

    cd /var/www/pterodactyl || exit 1
    php artisan route:clear && php artisan view:clear && php artisan config:clear
    yarn build:production --progress

    echo -e "${CYAN}🎉 Protect + Anti-Intip selesai${RESET}"

elif [[ "$MODE" == "2" ]]; then
    for name in "${!CONTROLLERS[@]}"; do [[ -f "$BACKUP_DIR/$name.bak" ]] && cp "$BACKUP_DIR/$name.bak" "${CONTROLLERS[$name]}"; done
    [[ -f "$BACKUP_DIR/ServerController.php.bak" ]] && cp "$BACKUP_DIR/ServerController.php.bak" "$SERVER_CONTROLLER"
    cd /var/www/pterodactyl || exit 1
    yarn build:production --progress
    echo -e "${CYAN}✅ Restore selesai${RESET}"
else
    echo -e "${RED}❌ Pilihan tidak valid${RESET}"
fi
