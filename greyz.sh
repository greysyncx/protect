#!/bin/bash
# GreySync Protector System v1.5

RED="\033[1;31m"
GREEN="\033[1;32m"
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
RESET="\033[0m"
BOLD="\033[1m"

VERSION="1.5"
BACKUP_DIR="backup_greysync_protect"

# === Target controller untuk halaman admin ===
declare -A CONTROLLERS=(
  ["NodeController.php"]="/var/www/pterodactyl/app/Http/Controllers/Admin/Nodes/NodeController.php"
  ["NestController.php"]="/var/www/pterodactyl/app/Http/Controllers/Admin/Nests/NestController.php"
  ["IndexController.php"]="/var/www/pterodactyl/app/Http/Controllers/Admin/Settings/IndexController.php"
)

# === Target controller untuk Anti-Intip halaman server ===
SERVER_CONTROLLER="/var/www/pterodactyl/app/Http/Controllers/Server/ServerController.php"

clear
echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║          GreySync Protector + Anti-Intip             ║"
echo "║                 Version $VERSION                      ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"

echo -e "${YELLOW}Pilih mode:${RESET}"
echo -e "1) 🔐 Install Protect + Anti-Intip"
echo -e "2) ♻️  Restore Backup"
read -p "Masukkan pilihan (1/2): " MODE

# ================== MODE 1 =========================
if [[ "$MODE" == "1" ]]; then
    read -p "👤 Masukkan ID Admin Utama (contoh: 1): " ADMIN_ID
    if [[ -z "$ADMIN_ID" ]]; then
        echo -e "${RED}❌ Admin ID tidak boleh kosong.${RESET}"
        exit 1
    fi

    mkdir -p "$BACKUP_DIR"

    echo -e "${YELLOW}📦 Membackup file-file asli...${RESET}"
    for name in "${!CONTROLLERS[@]}"; do
        cp "${CONTROLLERS[$name]}" "$BACKUP_DIR/$name.bak"
    done
    cp "$SERVER_CONTROLLER" "$BACKUP_DIR/ServerController.php.bak"

    echo -e "${GREEN}🔧 Menerapkan Protect untuk Admin ID: $ADMIN_ID${RESET}"

    # === Patch halaman Nodes/Nests/Settings ===
    for name in "${!CONTROLLERS[@]}"; do
        path="${CONTROLLERS[$name]}"

        if ! grep -q "public function index" "$path"; then
            echo -e "${RED}⚠️  Lewat: $name tidak memiliki 'public function index()'.${RESET}"
            continue
        fi

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
        /public function index\(.*\)/ {
            print; in_func=1; next;
        }
        in_func==1 && /^\s*{/ {
            print;
            print "        $user = Auth::user();";
            print "        if (!$user || $user->id != " admin_id ") {";
            print "            abort(403, \\\"Akses ditolak! Hanya Admin ID " admin_id " yang dapat mengakses halaman ini. ©GreySync v'"$VERSION"'\\\");";
            print "        }";
            in_func=0; next;
        }
        { print; }
        ' "$path" > "$path.patched" && mv "$path.patched" "$path"

        echo -e "${GREEN}✅ Protect diterapkan ke: $name${RESET}"
    done

    # === Patch Anti-Intip di halaman Server ===
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
    /public function show\(.*Server.*\)/ {
        print; in_func=1; next;
    }
    in_func==1 && /^\s*{/ {
        print;
        print "        $user = Auth::user();";
        print "        if (!$user || ($user->id !== $server->owner_id && $user->id != " admin_id ")) {";
        print "            abort(403, \\\"❌ Kenalin Syah Anti-Intip v"'"$VERSION"'"\\\");";
        print "        }";
        in_func=0; next;
    }
    { print; }
    ' "$BACKUP_DIR/ServerController.php.bak" > "$SERVER_CONTROLLER"

    echo -e "${GREEN}✅ Anti-Intip diterapkan ke ServerController${RESET}"


    echo -e "${YELLOW}➤ Build ulang panel...${RESET}"
    cd /var/www/pterodactyl || { echo -e "${RED}❌ Gagal ke direktori panel.${RESET}"; exit 1; }
    yarn build:production --progress

    echo -e "\n${BLUE}🎉 Install selesai!"
    echo -e "📁 Backup ada di: $BACKUP_DIR${RESET}"


# ================= MODE 2 =======================
elif [[ "$MODE" == "2" ]]; then
    if [[ ! -d "$BACKUP_DIR" ]]; then
        echo -e "${RED}❌ Folder backup tidak ditemukan: $BACKUP_DIR${RESET}"
        exit 1
    fi

    echo -e "${CYAN}♻️  Memulihkan file-file asli...${RESET}"
    for name in "${!CONTROLLERS[@]}"; do
        if [[ -f "$BACKUP_DIR/$name.bak" ]]; then
            cp "$BACKUP_DIR/$name.bak" "${CONTROLLERS[$name]}"
            echo -e "${GREEN}🔄 Dipulihkan: $name${RESET}"
        else
            echo -e "${RED}⚠️  Backup tidak ditemukan untuk $name.${RESET}"
        fi
    done

    if [[ -f "$BACKUP_DIR/ServerController.php.bak" ]]; then
        cp "$BACKUP_DIR/ServerController.php.bak" "$SERVER_CONTROLLER"
        echo -e "${GREEN}🔄 Dipulihkan: ServerController${RESET}"
    else
        echo -e "${RED}⚠️  Backup tidak ditemukan untuk ServerController.${RESET}"
    fi

    cd /var/www/pterodactyl || { echo -e "${RED}❌ Gagal ke direktori panel.${RESET}"; exit 1; }
    yarn build:production --progress

    echo -e "\n${BLUE}✅ Restore selesai. Semua file kembali ke versi asli.${RESET}"


# ==================== MODE INVALID ==================
else
    echo -e "${RED}❌ Pilihan tidak valid. Masukkan 1 atau 2.${RESET}"
    exit 1
fi
