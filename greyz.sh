#!/bin/bash

RED="\033[1;31m"
GREEN="\033[1;32m"
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
RESET="\033[0m"
BOLD="\033[1m"
VERSION="1.3"

clear
echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║          Protect + Panel Builder                     ║"
echo "║                    Version $VERSION                  ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"

echo -e "${YELLOW}Pilih mode yang ingin dijalankan:${RESET}"
echo -e "1) 🔐 Install Protect (Add Protect)"
echo -e "2) ♻️ Restore Backup (Restore)"
read -p "Masukkan pilihan (1/2): " MODE

declare -A CONTROLLERS
CONTROLLERS["NodeController.php"]="/var/www/pterodactyl/app/Http/Controllers/Admin/Nodes/NodeController.php"
CONTROLLERS["NestController.php"]="/var/www/pterodactyl/app/Http/Controllers/Admin/Nests/NestController.php"
CONTROLLERS["IndexController.php"]="/var/www/pterodactyl/app/Http/Controllers/Admin/Settings/IndexController.php"
CONTROLLERS["LocationController.php"]="/var/www/pterodactyl/app/Http/Controllers/Admin/Locations/LocationController.php"

BACKUP_DIR="backup_greysync_protect"

if [[ "$MODE" == "1" ]]; then
    read -p "👤 Masukkan ID Admin Utama (contoh: 1): " ADMIN_ID
    if [[ -z "$ADMIN_ID" ]]; then
        echo -e "${RED}❌ Admin ID tidak boleh kosong.${RESET}"
        exit 1
    fi

    mkdir -p "$BACKUP_DIR"

    echo -e "${YELLOW}📦 Membackup file asli sebelum di protect ke: ${BLUE}$BACKUP_DIR${RESET}"
    for name in "${!CONTROLLERS[@]}"; do
        if [[ -f "${CONTROLLERS[$name]}" ]]; then
            cp "${CONTROLLERS[$name]}" "$BACKUP_DIR/$name.bak"
        fi
    done

    echo -e "${GREEN}🔧 Menerapkan Protect hanya untuk ID $ADMIN_ID...${RESET}"

    for name in "${!CONTROLLERS[@]}"; do
        path="${CONTROLLERS[$name]}"
        if [[ ! -f "$path" ]]; then
            echo -e "${YELLOW}⚠️ Lewat: $name tidak ditemukan.${RESET}"
            continue
        fi
        if ! grep -q "public function index" "$path"; then
            echo -e "${RED}⚠️ Gagal: $name tidak memiliki 'public function index()'! Lewat.${RESET}"
            continue
        fi

        awk -v admin_id="$ADMIN_ID" '
        BEGIN { inserted_use=0; in_func=0; }
        /^namespace / {
            print;
            if (!inserted_use) {
                print "use Illuminate\\Support\\Facades\\Auth;";
                inserted_use = 1;
            }
            next;
        }
        /public function index\(.*\)/ {
            print; in_func = 1; next;
        }
        in_func == 1 && /^\s*{/ {
            print;
            print "        \$user = Auth::user();";
            print "        if (\$user || \$user->id !== " admin_id ") {";
            print "            abort(403, \"bocah tolol ngapain lu?");";
            print "        }";
            in_func = 0; next;
        }
        { print; }
        ' "$path" > "$path.patched" && mv "$path.patched" "$path"
        echo -e "${GREEN}✅ Protect diterapkan ke: $name${RESET}"
    done

    echo -e "${YELLOW}➤ Build ulang panel...${RESET}"
    cd /var/www/pterodactyl || exit 1
    yarn build:production --progress

    echo -e "\n${BLUE}🎉 Protect selesai!"
    echo -e "📁 Backup file tersimpan di: $BACKUP_DIR"
    echo -e "🛡️ Sekarang hanya ID $ADMIN_ID yang bisa buka halaman Nodes/Nests/Settings/Locations (jika ada)"
    echo -e "${RESET}"

elif [[ "$MODE" == "2" ]]; then
    if [[ ! -d "$BACKUP_DIR" ]]; then
        echo -e "${RED}❌ Folder backup tidak ditemukan: $BACKUP_DIR${RESET}"
        exit 1
    fi

    echo -e "${CYAN}♻️ Mengembalikan file ke versi sebelum Protect...${RESET}"
    for name in "${!CONTROLLERS[@]}"; do
        if [[ -f "$BACKUP_DIR/$name.bak" ]]; then
            cp "$BACKUP_DIR/$name.bak" "${CONTROLLERS[$name]}"
            echo -e "${GREEN}🔄 Dipulihkan: $name${RESET}"
        fi
    done

    echo -e "${YELLOW}➤ Build ulang panel...${RESET}"
    cd /var/www/pterodactyl || exit 1
    yarn build:production --progress

    echo -e "\n${BLUE}✅ Restore selesai. Semua file dikembalikan ke versi asli.${RESET}"

else
    echo -e "${RED}❌ Pilihan tidak valid. Masukkan 1 atau 2.${RESET}"
    exit 1
fi
