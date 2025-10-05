#!/bin/bash
# GreySync Protect v1.5 (Final Auto-Detect + Restore)
# by greysync

RED="\033[1;31m"
GREEN="\033[1;32m"
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
RESET="\033[0m"
VERSION="1.5"

clear
echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║        GreySync Protect (Anti Edit & Anti Intip)     ║"
echo "║                   Version $VERSION                   ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"

echo -e "${YELLOW}1) Pasang Protect"
echo -e "2) Restore Protect${RESET}"
read -p "Pilih [1/2]: " MODE

BACKUP_DIR="/root/greysync_backups"
mkdir -p "$BACKUP_DIR"

API_PATHS=(
  "/var/www/pterodactyl/app/Http/Controllers/Api/Application/Users/UserController.php"
  "/var/www/pterodactyl/app/Http/Controllers/Api/Users/UserController.php"
  "/var/www/pterodactyl/app/Http/Controllers/Api/Application/UserController.php"
)
ADMIN_PATHS=(
  "/var/www/pterodactyl/app/Http/Controllers/Admin/UserController.php"
  "/var/www/pterodactyl/app/Http/Controllers/Admin/Users/UserController.php"
  "/var/www/pterodactyl/app/Http/Controllers/Admin/UsersController.php"
)
PANEL_PATHS=(
  "/var/www/pterodactyl/app/Http/Controllers/Admin/Nodes/NodeController.php"
  "/var/www/pterodactyl/app/Http/Controllers/Admin/Nests/NestController.php"
  "/var/www/pterodactyl/app/Http/Controllers/Admin/Settings/IndexController.php"
  "/var/www/pterodactyl/app/Http/Controllers/Admin/LocationController.php"
)

if [[ "$MODE" == "1" ]]; then
    read -p "👤 Masukkan ID Admin Utama (contoh: 1): " ADMIN_ID
    [[ -z "$ADMIN_ID" ]] && echo -e "${RED}❌ Admin ID kosong.${RESET}" && exit 1

    echo -e "${YELLOW}📦 Membackup file asli ke: $BACKUP_DIR${RESET}"

    # === Cari dan patch API UserController ===
    for path in "${API_PATHS[@]}"; do
        if [[ -f "$path" ]]; then
            cp "$path" "$BACKUP_DIR/$(basename "$path").$(date +%F-%H%M%S).bak"
            echo -e "${YELLOW}➤ Menemukan API Controller: $path${RESET}"

            if ! grep -q "use Illuminate\\Support\\Facades\\Auth;" "$path"; then
                sed -i '/^namespace /a use Illuminate\\Support\\Facades\\Auth;' "$path"
            fi

            awk -v admin_id="$ADMIN_ID" '
                BEGIN { in_func=0 }
                /public function update\(.*\)/ { print; in_func=1; next }
                in_func==1 && /^\s*{/ {
                    print;
                    print "        // === GreySync Anti Edit Protect ===";
                    print "        $auth = $request->user() ?? Auth::user();";
                    print "        if (!$auth || ($auth->id !== $user->id && $auth->id != " admin_id ")) {";
                    print "            return response()->json([\"error\" => \"❌ Lu siapa mau edit user lain tolol!\"], 403);";
                    print "        }";
                    in_func=0; next;
                }
                { print }
            ' "$path" > "$path.tmp" && mv "$path.tmp" "$path"

            echo -e "${GREEN}✔ Protect (Anti Edit User API) selesai.${RESET}"
            break
        fi
    done

    # === Patch Panel Controller ===
    for path in "${PANEL_PATHS[@]}"; do
        if [[ -f "$path" ]]; then
            cp "$path" "$BACKUP_DIR/$(basename "$path").$(date +%F-%H%M%S).bak"
            awk -v admin_id="$ADMIN_ID" '
                BEGIN { done=0 }
                /public function index\(.*\)/ { print; in_func=1; next }
                in_func==1 && /^\s*{/ {
                    print;
                    print "        // === GreySync Anti Intip Protect ===";
                    print "        $user = Auth::user();";
                    print "        if (!$user || $user->id != " admin_id ") abort(403, \"❌ Bocah tolol ngapain lu?\");";
                    in_func=0; next;
                }
                { print }
            ' "$path" > "$path.tmp" && mv "$path.tmp" "$path"

            echo -e "${GREEN}✔ Protect (Anti Intip Panel): $(basename "$path")${RESET}"
        fi
    done

    echo -e "${GREEN}🛡 Protect aktif untuk Admin ID $ADMIN_ID tanpa rebuild panel.${RESET}"

elif [[ "$MODE" == "2" ]]; then
    echo -e "${CYAN}♻ Mengembalikan file dari backup...${RESET}"
    for file in "${API_PATHS[@]}" "${PANEL_PATHS[@]}"; do
        name=$(basename "$file")
        latest=$(ls -1t "$BACKUP_DIR" | grep "^$name" | head -n 1)
        if [[ -n "$latest" ]]; then
            cp "$BACKUP_DIR/$latest" "$file"
            echo -e "${GREEN}✔ Dipulihkan: $name${RESET}"
        else
            echo -e "${YELLOW}⚠ Tidak ditemukan backup untuk $name${RESET}"
        fi
    done
    echo -e "${GREEN}✅ Semua file telah dipulihkan.${RESET}"

else
    echo -e "${RED}❌ Pilihan tidak valid.${RESET}"
fi
