#!/bin/bash
# GreySync Protect v1.4 (Final Anti Edit API)
# by greysync

RED="\033[1;31m"
GREEN="\033[1;32m"
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
RESET="\033[0m"

VERSION="1.4 aunt"

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

declare -A CONTROLLERS=(
    ["UserController.php"]="/var/www/pterodactyl/app/Http/Controllers/Api/Application/Users/UserController.php"
    ["NodeController.php"]="/var/www/pterodactyl/app/Http/Controllers/Admin/Nodes/NodeController.php"
    ["NestController.php"]="/var/www/pterodactyl/app/Http/Controllers/Admin/Nests/NestController.php"
    ["IndexController.php"]="/var/www/pterodactyl/app/Http/Controllers/Admin/Settings/IndexController.php"
    ["LocationController.php"]="/var/www/pterodactyl/app/Http/Controllers/Admin/LocationController.php"
)

BACKUP_DIR="backup_greyz"
mkdir -p "$BACKUP_DIR"

if [[ "$MODE" == "1" ]]; then
    read -p "👤 Masukkan ID Admin Utama (contoh: 1): " ADMIN_ID
    [[ -z "$ADMIN_ID" ]] && echo -e "${RED}❌ Admin ID kosong.${RESET}" && exit 1

    echo -e "${YELLOW}📦 Membackup file asli ke: $BACKUP_DIR${RESET}"
    for name in "${!CONTROLLERS[@]}"; do
        cp "${CONTROLLERS[$name]}" "$BACKUP_DIR/$name.$(date +%F-%H%M%S).bak" 2>/dev/null
    done

    for name in "${!CONTROLLERS[@]}"; do
        path="${CONTROLLERS[$name]}"
        [[ ! -f "$path" ]] && echo -e "${YELLOW}⚠ Lewat: $name tidak ditemukan${RESET}" && continue

        # === Anti Edit User (API Controller) ===
        if [[ "$name" == "UserController.php" ]]; then
            if ! grep -q "use Illuminate\\Support\\Facades\\Auth;" "$path"; then
                sed -i '/^namespace Pterodactyl\\Http\\Controllers\\Api\\Application\\Users;/a use Illuminate\\Support\\Facades\\Auth;' "$path"
            fi

            awk -v admin_id="$ADMIN_ID" '
                BEGIN { in_func=0 }
                /public function update\(.*\)/ { print; in_func=1; next }
                in_func==1 && /^\s*{/ {
                    print;
                    print "        // === GreySync Anti Edit Protect ===";
                    print "        $auth = $request->user() ?? Auth::user();";
                    print "        if (!$auth || $auth->id !== " admin_id ") {";
                    print "            return response()->json(["; 
                    print "                \"error\" => \"❌ Lu bukan admin utama, dilarang edit user lain!\"";
                    print "            ], 403);";
                    print "        }";
                    in_func=0; next;
                }
                { print }
            ' "$path" > "$path.tmp" && mv "$path.tmp" "$path"

            echo -e "${GREEN}✔ Protect (Anti Edit User API): $name${RESET}"
            continue
        fi

        # === Anti Intip Panel (Nodes/Nests/Settings/Loc) ===
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
                print "        $user = Auth::user();";
                print "        if (!$user || $user->id !== " admin_id ") {";
                print "            abort(403, \"❌ Bocah tolol ngapain lu?\");";
                print "        }";
                in_func=0; next;
            }
            { print }
        ' "$path" > "$path.tmp" && mv "$path.tmp" "$path"
        echo -e "${GREEN}✔ Protect Panel: $name${RESET}"
    done

    echo -e "${GREEN}🛡 Protect aktif untuk Admin ID $ADMIN_ID (tanpa rebuild panel).${RESET}"

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
    echo -e "${GREEN}✅ Semua file telah dipulihkan.${RESET}"

else
    echo -e "${RED}❌ Pilihan tidak valid.${RESET}"
fi
