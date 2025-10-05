#!/usr/bin/env bash
# GreySync Protect v1.5 Detect (Multi-version)
# Author: greysync (adapted)

set -euo pipefail
IFS=$'\n\t'

RED="\033[1;31m"
GREEN="\033[1;32m"
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
RESET="\033[0m"

VERSION="1.5-detect"

echo -e "${CYAN}GreySync Protect — auto-detect version & inject protections (v${VERSION})${RESET}"
echo

read -p "👤 Masukkan ID Admin Utama (contoh: 1): " ADMIN_ID
if [[ -z "$ADMIN_ID" ]]; then
  echo -e "${RED}❌ Admin ID tidak boleh kosong.${RESET}"
  exit 1
fi

BACKUP_DIR="/root/greysync_backups"
mkdir -p "$BACKUP_DIR"

API_CANDIDATES=(
  "/var/www/pterodactyl/app/Http/Controllers/Api/Application/Users/UserController.php"
  "/var/www/pterodactyl/app/Http/Controllers/Api/Users/UserController.php"
  "/var/www/pterodactyl/app/Http/Controllers/Api/Application/UserController.php"
)

ADMIN_CANDIDATES=(
  "/var/www/pterodactyl/app/Http/Controllers/Admin/UserController.php"
  "/var/www/pterodactyl/app/Http/Controllers/Admin/Users/UserController.php"
  "/var/www/pterodactyl/app/Http/Controllers/Admin/UsersController.php"
  "/var/www/pterodactyl/app/Http/Controllers/Admin/UserManagementController.php"
)

PATCHED=()

backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    cp "$f" "$BACKUP_DIR/$(basename "$f").$(date +%F-%H%M%S).bak"
  fi
}

inject_api_protect() {
  local path="$1"
  echo -e "${YELLOW}➤ Inject API anti-edit -> $path${RESET}"
  backup_file "$path"

  # ensure Auth is imported
  if ! grep -q "use Illuminate\\Support\\Facades\\Auth;" "$path"; then
    sed -i '/^namespace /a use Illuminate\\Support\\Facades\\Auth;' "$path"
  fi

  # robust awk: find 'public function update' then insert on first '{' after it
  awk -v admin_id="$ADMIN_ID" '
    BEGIN { in_func=0; inserted=0 }
    /public function update[[:space:]]*\(.*\)/ {
      print; in_func=1; next
    }
    in_func==1 {
      if (/\{/ && inserted==0) {
        print
        print "        // === GreySync Anti Edit Protect (API) ==="
        print "        $auth = $request->user() ?? Auth::user();"
        print "        if (!\$auth || (\$auth->id !== \$user->id && \$auth->id != " admin_id ")) {"
        print "            return response()->json([\"error\" => \"❌ Lu bukan pemilik atau admin utama, dilarang edit user lain!\"], 403);"
        print "        }"
        inserted=1
        in_func=0
        next
      }
    }
    { print }
  ' "$path" > "$path.tmp" && mv "$path.tmp" "$path"

  PATCHED+=("$path")
}

inject_admin_protect() {
  local path="$1"
  echo -e "${YELLOW}➤ Inject Admin-web anti-edit -> $path${RESET}"
  backup_file "$path"

  # ensure Auth is imported
  if ! grep -q "use Illuminate\\Support\\Facades\\Auth;" "$path"; then
    sed -i '/^namespace /a use Illuminate\\Support\\Facades\\Auth;' "$path"
  fi

  # inject protection in admin update() — redirect back with error
  awk -v admin_id="$ADMIN_ID" '
    BEGIN { in_func=0; inserted=0 }
    /public function update[[:space:]]*\(.*\)/ {
      print; in_func=1; next
    }
    in_func==1 {
      if (/\{/ && inserted==0) {
        print
        print "        // === GreySync Anti Edit Protect (Admin) ==="
        print "        $auth = \$request->user() ?? Auth::user();"
        print "        if (!\$auth || (\$auth->id !== \$user->id && \$auth->id != " admin_id ")) {"
        print "            return redirect()->back()->withErrors([\"error\" => \"❌ Lu bukan pemilik atau admin utama, dilarang edit user lain!\"]);"
        print "        }"
        inserted=1
        in_func=0
        next
      }
    }
    { print }
  ' "$path" > "$path.tmp" && mv "$path.tmp" "$path"

  PATCHED+=("$path")
}

found_any=0

echo -e "${CYAN}Scanning for controller files...${RESET}"

# detect API controller
for p in "${API_CANDIDATES[@]}"; do
  if [[ -f "$p" ]]; then
    echo -e "${GREEN}Found API UserController: $p${RESET}"
    inject_api_protect "$p"
    found_any=1
    break
  fi
done

# detect Admin controller(s)
for p in "${ADMIN_CANDIDATES[@]}"; do
  if [[ -f "$p" ]]; then
    echo -e "${GREEN}Found Admin UserController: $p${RESET}"
    inject_admin_protect "$p"
    found_any=1
    break
  fi
done

# additionally, scan admin controllers folder for possible index() protection (Nodes/Nests/Settings/Location)
ADMIN_PANEL_DIR="/var/www/pterodactyl/app/Http/Controllers/Admin"
panel_targets=("Nodes/NodeController.php" "Nests/NestController.php" "Settings/IndexController.php" "LocationController.php")
for t in "${panel_targets[@]}"; do
  full="$ADMIN_PANEL_DIR/$t"
  if [[ -f "$full" ]]; then
    echo -e "${GREEN}Found panel controller: $full${RESET}"
    # backup + add Auth use if needed + inject index() guard (same pattern)
    backup_file "$full"
    if ! grep -q "use Illuminate\\Support\\Facades\\Auth;" "$full"; then
      sed -i '/^namespace /a use Illuminate\\Support\\Facades\\Auth;' "$full"
    fi

    awk -v admin_id="$ADMIN_ID" '
      BEGIN { found=0 }
      /public function index[[:space:]]*\(.*\)/ { print; found=1; next }
      found==1 && /^\s*{/ {
        print;
        print "        // === GreySync Anti Intip Protect ===";
        print "        $user = Auth::user();";
        print "        if (!$user || $user->id != " admin_id ") {";
        print "            abort(403, \"❌ Bocah tolol ngapain lu?\");";
        print "        }";
        found=0; next;
      }
      { print }
    ' "$full" > "$full.tmp" && mv "$full.tmp" "$full"

    PATCHED+=("$full")
  fi
done

if [[ ${#PATCHED[@]} -eq 0 ]]; then
  echo -e "${YELLOW}⚠ Tidak ditemukan file target untuk dipatch. Pastikan path Pterodactyl benar.${RESET}"
  echo -e "${YELLOW}Paths tested:${RESET}"
  for p in "${API_CANDIDATES[@]}"; do echo " - $p"; done
  for p in "${ADMIN_CANDIDATES[@]}"; do echo " - $p"; done
  exit 0
fi

echo
echo -e "${GREEN}✔ Selesai. File yang berhasil dipatch:${RESET}"
for f in "${PATCHED[@]}"; do
  echo -e "  - ${CYAN}$f${RESET}"
done

echo
echo -e "${CYAN}📌 Saran: jika kamu restore manual sebelumnya, jalankan juga:" 
echo -e "  cd /var/www/pterodactyl && php artisan optimize:clear"
echo -e "${CYAN}Tapi untuk modifikasi controller biasanya tidak wajib.${RESET}"

echo -e "${GREEN}🎯 Protect aktif (owner OR admin utama dapat edit).${RESET}"
