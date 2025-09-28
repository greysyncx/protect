#!/bin/bash
# ========================================================
# GreySync Admin Protect (non-interactive + interactive)
# Versi: 1.1
# ========================================================

RED="\033[1;31m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; CYAN="\033[1;36m"; RESET="\033[0m"
BACKUP_DIR="/var/www/pterodactyl/backup_greysync_admin"

declare -A CONTROLLERS
CONTROLLERS["NodeController.php"]="/var/www/pterodactyl/app/Http/Controllers/Admin/Nodes/NodeController.php"
CONTROLLERS["NestController.php"]="/var/www/pterodactyl/app/Http/Controllers/Admin/Nests/NestController.php"
CONTROLLERS["IndexController.php"]="/var/www/pterodactyl/app/Http/Controllers/Admin/Settings/IndexController.php"

apply_protect() {
    ADMIN_ID="$1"
    mkdir -p "$BACKUP_DIR"

    echo -e "${YELLOW}📦 Membackup file original...${RESET}"
    for name in "${!CONTROLLERS[@]}"; do
        cp "${CONTROLLERS[$name]}" "$BACKUP_DIR/$name.bak" 2>/dev/null || true
    done

    echo -e "${YELLOW}➤ Terapkan proteksi hanya untuk ID $ADMIN_ID...${RESET}"
    for name in "${!CONTROLLERS[@]}"; do
        path="${CONTROLLERS[$name]}"
        if [[ -f "$path" ]]; then
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
                print "        $user = Auth::user();";
                print "        if (!$user || $user->id !== " admin_id ") {";
                print "            abort(403, \"⛔ Tidak boleh akses halaman ini!\");";
                print "        }";
                in_func = 0; next;
            }
            { print; }
            ' "$path" > "$path.patched" && mv "$path.patched" "$path"
            echo -e "${GREEN}✅ Protect diterapkan ke: $name${RESET}"
        else
            echo -e "${RED}⚠ File tidak ditemukan: $path${RESET}"
        fi
    done
}

restore_protect() {
    echo -e "${YELLOW}♻ Mengembalikan backup...${RESET}"
    for name in "${!CONTROLLERS[@]}"; do
        if [[ -f "$BACKUP_DIR/$name.bak" ]]; then
            cp "$BACKUP_DIR/$name.bak" "${CONTROLLERS[$name]}"
            echo -e "${GREEN}✔ Dipulihkan: $name${RESET}"
        else
            echo -e "${RED}⚠ Backup $name tidak ditemukan${RESET}"
        fi
    done
}

# Mode non-interaktif
if [[ "$1" == "install" && -n "$2" ]]; then
    apply_protect "$2"
    exit 0
elif [[ "$1" == "restore" ]]; then
    restore_protect
    exit 0
fi

# Mode interaktif (jika tanpa argumen)
clear
echo -e "${CYAN}═══════════════════════════════════════${RESET}"
echo -e "   GreySync Admin Protect v1.1"
echo -e "═══════════════════════════════════════${RESET}"
echo -e "${YELLOW}[1] Install Admin Protect${RESET}"
echo -e "${YELLOW}[2] Restore dari Backup${RESET}"
read -p "Pilih opsi [1/2]: " OPSI

if [[ "$OPSI" == "1" ]]; then
    read -p "Masukkan ID Admin Utama (contoh: 1): " ADMIN_ID
    apply_protect "$ADMIN_ID"
elif [[ "$OPSI" == "2" ]]; then
    restore_protect
else
    echo -e "${RED}❌ Opsi tidak valid.${RESET}"
fi
