#!/bin/bash

RED="\033[1;31m"
GREEN="\033[1;32m"
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
RESET="\033[0m"
VERSION="1.5 Ultimate"

clear
echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║              GreyZ Protect v1.5 Ultimate             ║"
echo "║         (Admin + Anti-Intip Client Server)           ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"

echo -e "${YELLOW}1) Pasang Protect"
echo -e "2) Restore Protect Terakhir${RESET}"
read -p "Pilih [1/2]: " MODE

declare -A CONTROLLERS=(
    ["NodeController.php"]="/var/www/pterodactyl/app/Http/Controllers/Admin/Nodes/NodeController.php"
    ["NestController.php"]="/var/www/pterodactyl/app/Http/Controllers/Admin/Nests/NestController.php"
    ["IndexController.php"]="/var/www/pterodactyl/app/Http/Controllers/Admin/Settings/IndexController.php"
    ["LocationController.php"]="/var/www/pterodactyl/app/Http/Controllers/Admin/LocationController.php"
    ["ClientServerController.php"]="/var/www/pterodactyl/app/Http/Controllers/Api/Client/Servers/ServerController.php"
)

BACKUP_DIR="backup_greyz"
mkdir -p "$BACKUP_DIR"

if [[ "$MODE" == "1" ]]; then
    read -p "👤 Masukkan ID Admin Utama (contoh: 1): " ADMIN_ID
    if [[ -z "$ADMIN_ID" ]]; then
        echo -e "${RED}❌ Admin ID kosong.${RESET}"
        exit 1
    fi

    echo -e "${YELLOW}📦 Membackup semua file asli ke: $BACKUP_DIR${RESET}"
    for name in "${!CONTROLLERS[@]}"; do
        path="${CONTROLLERS[$name]}"
        [[ -f "$path" ]] && cp "$path" "$BACKUP_DIR/$name.$(date +%F-%H%M%S).bak"
    done

    echo -e "${CYAN}🛡 Memasang proteksi Admin Controllers...${RESET}"
    for name in NodeController.php NestController.php IndexController.php LocationController.php; do
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
            print "            abort(403, \"❌ bocah tolol ngapain lu?\");";
            print "        }";
            in_func=0; next;
        }
        { print }
        ' "$path" > "$path.tmp" && mv "$path.tmp" "$path"

        echo -e "${GREEN}✔ Protect: $name${RESET}"
    done

    echo -e "${CYAN}🧩 Menambahkan Anti-Intip ke Client ServerController...${RESET}"
    CLIENT_PATH="${CONTROLLERS["ClientServerController.php"]}"

    if [[ -f "$CLIENT_PATH" ]]; then
        awk '
        /public function index\(.*GetServerRequest/ {
            print;
            getline;
            if ($0 ~ /{/) {
                print "{";
                print "        \$user = \$request->user();";
                print "        if (!\$user->root_admin && \$user->id !== \$server->owner_id) {";
                print "            abort(403, \"⚠️ Anti-Intip GreyZ: Kamu tidak memiliki izin melihat server ini.\");";
                print "        }";
                next;
            }
        }
        { print }
        ' "$CLIENT_PATH" > "$CLIENT_PATH.tmp" && mv "$CLIENT_PATH.tmp" "$CLIENT_PATH"
        echo -e "${GREEN}✔ Anti-Intip aktif di Client ServerController${RESET}"
    else
        echo -e "${YELLOW}⚠ Lewat: Client ServerController tidak ditemukan${RESET}"
    fi

    echo -e "${GREEN}✅ Semua proteksi berhasil dipasang untuk Admin ID $ADMIN_ID${RESET}"

elif [[ "$MODE" == "2" ]]; then
    echo -e "${CYAN}♻ Restore file backup terakhir...${RESET}"
    for name in "${!CONTROLLERS[@]}"; do
        latest=$(ls -t "$BACKUP_DIR" | grep "$name" | head -n 1)
        if [[ -n "$latest" ]]; then
            cp "$BACKUP_DIR/$latest" "${CONTROLLERS[$name]}" && \
            echo -e "${GREEN}✔ Pulih: $latest${RESET}"
        else
            echo -e "${YELLOW}⚠ Tidak ada backup untuk $name${RESET}"
        fi
    done
    echo -e "${GREEN}🔁 Restore selesai.${RESET}"
else
    echo -e "${RED}❌ Pilihan tidak valid.${RESET}"
fi
