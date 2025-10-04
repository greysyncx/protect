#!/bin/bash

RED="\033[1;31m"
GREEN="\033[1;32m"
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
RESET="\033[0m"
VERSION="1.4"

clear
echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║      GreyZ Protect (Nodes/Nests/Settings/loc)        ║"
echo "║                    Version $VERSION                  ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"

echo -e "${YELLOW}1) Pasang Protect"
echo -e "2) Restore Protect${RESET}"
read -p "Pilih [1/2]: " MODE

declare -A CONTROLLERS=(
    ["NodeController.php"]="/var/www/pterodactyl/app/Http/Controllers/Admin/Nodes/NodeController.php"
    ["NestController.php"]="/var/www/pterodactyl/app/Http/Controllers/Admin/Nests/NestController.php"
    ["IndexController.php"]="/var/www/pterodactyl/app/Http/Controllers/Admin/Settings/IndexController.php"
    ["LocationController.php"]="/var/www/pterodactyl/app/Http/Controllers/Admin/LocationController.php"
)

BACKUP_DIR="backup_greyz"
mkdir -p "$BACKUP_DIR"

if [[ "$MODE" == "1" ]]; then
    read -p "👤 Masukkan ID Admin Utama (contoh: 1): " ADMIN_ID
    if [[ -z "$ADMIN_ID" ]]; then
        echo -e "${RED}❌ Admin ID kosong.${RESET}"
        exit 1
    fi

    echo -e "${YELLOW}📦 Membackup file asli ke: $BACKUP_DIR${RESET}"
    for name in "${!CONTROLLERS[@]}"; do
        cp "${CONTROLLERS[$name]}" "$BACKUP_DIR/$name.$(date +%F-%H%M%S).bak" 2>/dev/null
    done

    for name in "${!CONTROLLERS[@]}"; do
        path="${CONTROLLERS[$name]}"
        [[ ! -f "$path" ]] && echo -e "${YELLOW}⚠ Lewat: $name hilang${RESET}" && continue

        awk -v admin_id="$ADMIN_ID" '
        BEGIN { in_func=0 }
        /^namespace / {
            print;
            print "use Illuminate\\Support\\Facades\\Auth;";
            next;
        }
        /public function index\(.*\)/ { print; in_func=1; next }
        in_func==1 && /^\s*{/ {
            print;
            print "        \$user = Auth::user();";
            print "        if (!\$user || \$user->id !== " admin_id ") {";
            print "            abort(403, \"bocah tolol ngapain lu?\");";
            print "        }";
            in_func=0; next;
        }
        { print }
        ' "$path" > "$path.tmp" && mv "$path.tmp" "$path"

        echo -e "${GREEN}✔ Protect: $name${RESET}"
    done

    echo -e "${GREEN}🛡 Protect selesai untuk Admin ID $ADMIN_ID (tanpa rebuild panel).${RESET}"

elif [[ "$MODE" == "2" ]]; then
    echo -e "${CYAN}♻ Restore file backup...${RESET}"
    for name in "${!CONTROLLERS[@]}"; do
        latest_file=$(ls -1t "$BACKUP_DIR" | grep "^$name" | head -n 1)
        if [[ -n "$latest_file" ]]; then
            cp "$BACKUP_DIR/$latest_file" "${CONTROLLERS[$name]}"
            echo -e "${GREEN}✔ Pulih otomatis: $latest_file${RESET}"
        else
            echo -e "${YELLOW}⚠ Tidak ditemukan backup untuk $name${RESET}"
        fi
    done

    echo -e "${GREEN}✅ Semua file telah dipulihkan ke versi backup terbaru.${RESET}"
else
    echo -e "${RED}❌ Pilihan tidak valid.${RESET}"
fi
