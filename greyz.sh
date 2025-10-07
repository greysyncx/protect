#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

RED="\033[1;31m"
GREEN="\033[1;32m"
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
RESET="\033[0m"

VERSION="1.5"
BACKUP_DIR="/root/greysync_backupsx"
mkdir -p "$BACKUP_DIR"

clear
echo -e "${CYAN}"
echo "╔════════════════════════════════════════════════════════╗"
echo "║              GreySync Protect — Auto Mode v${VERSION}         ║"
echo "╚════════════════════════════════════════════════════════╝"
echo -e "${RESET}"

echo -e "${YELLOW}[1]${RESET} Pasang Protect GreyZ"
echo -e "${YELLOW}[2]${RESET} Restore dari Backup Terakhir"
read -p "$(echo -e "${CYAN}Pilih opsi [1/2]: ${RESET}")" MENU

if [[ "$MENU" == "1" ]]; then
  read -p "👤 Masukkan ID Admin Utama (contoh: 1): " ADMIN_ID
  if [[ -z "$ADMIN_ID" ]]; then
    echo -e "${RED}❌ Admin ID tidak boleh kosong.${RESET}"
    exit 1
  fi

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
    [[ -f "$f" ]] && cp "$f" "$BACKUP_DIR/$(basename "$f").$(date +%F-%H%M%S).bak"
  }

  inject_api_protect() {
    local path="$1"
    echo -e "${YELLOW}⚙ Inject API anti-edit → ${path}${RESET}"
    backup_file "$path"

    if ! grep -q "use Illuminate\\Support\\Facades\\Auth;" "$path"; then
      sed -i '/^namespace /a use Illuminate\\Support\\Facades\\Auth;' "$path"
    fi

    awk -v admin_id="$ADMIN_ID" '
      BEGIN { in_func=0; inserted=0 }
      /public function update[[:space:]]*\(.*\)/ { print; in_func=1; next }
      in_func==1 {
        if (/\{/ && inserted==0) {
          print
          print "        // === GreySync Anti Edit Protect (API) ==="
          print "        $auth = $request->user() ?? Auth::user();"
          print "        if (!\$auth || (\$auth->id !== \$user->id && \$auth->id != " admin_id ")) {"
          print "            return response()->json([\"error\" => \"❌ Lu Siapa Mau Edit User Lain? Jasa Pasang Anti-Rusuh t.me/greysyncx\"], 403);"
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
    echo -e "${YELLOW}⚙ Inject Admin-web anti-edit → ${path}${RESET}"
    backup_file "$path"

    if ! grep -q "use Illuminate\\Support\\Facades\\Auth;" "$path"; then
      sed -i '/^namespace /a use Illuminate\\Support\\Facades\\Auth;' "$path"
    fi

    awk -v admin_id="$ADMIN_ID" '
      BEGIN { in_func=0; inserted=0 }
      /public function update[[:space:]]*\(.*\)/ { print; in_func=1; next }
      in_func==1 {
        if (/\{/ && inserted==0) {
          print
          print "        // === GreySync Anti Edit Protect (Admin) ==="
          print "        $auth = \$request->user() ?? Auth::user();"
          print "        if (!\$auth || (\$auth->id !== \$user->id && \$auth->id != " admin_id ")) {"
          print "            return redirect()->back()->withErrors([\"error\" => \"❌ Lu Siapa Mau Edit User Lain? Jasa Pasang Anti-Rusuh t.me/greysyncx\"]);"
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

  # Detect API UserController
  for p in "${API_CANDIDATES[@]}"; do
    if [[ -f "$p" ]]; then
      echo -e "${GREEN}✔ Found API UserController:${RESET} $p"
      inject_api_protect "$p"
      break
    fi
  done

  # Detect Admin UserController
  for p in "${ADMIN_CANDIDATES[@]}"; do
    if [[ -f "$p" ]]; then
      echo -e "${GREEN}✔ Found Admin UserController:${RESET} $p"
      inject_admin_protect "$p"
      break
    fi
  done

  # Protect Panel (Nodes, Nests, Settings, Location)
  ADMIN_PANEL_DIR="/var/www/pterodactyl/app/Http/Controllers/Admin"
  panel_targets=("Nodes/NodeController.php" "Nests/NestController.php" "Settings/IndexController.php" "LocationController.php")
  for t in "${panel_targets[@]}"; do
    full="$ADMIN_PANEL_DIR/$t"
    if [[ -f "$full" ]]; then
      echo -e "${GREEN}✔ Found Panel Controller:${RESET} $full"
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
          print "            abort(403, \"❌ GreySync Protect: Mau Ngapain Bang? Jasa Pasang Anti-Rusuh t.me/greysyncx\");";
          print "        }";
          found=0; next;
        }
        { print }
      ' "$full" > "$full.tmp" && mv "$full.tmp" "$full"

      PATCHED+=("$full")
    fi
  done

  echo
  if [[ ${#PATCHED[@]} -eq 0 ]]; then
    echo -e "${YELLOW}⚠ Tidak ditemukan file target untuk dipatch.${RESET}"
  else
    echo -e "${GREEN}✅ Proteksi berhasil diterapkan ke file:${RESET}"
    for f in "${PATCHED[@]}"; do
      echo -e "  • ${YELLOW}$f${RESET}"
    done
    echo
    echo -e "${CYAN}🛡  Sistem kini terlindungi dari edit & intip tidak sah.${RESET}"
  fi

elif [[ "$MENU" == "2" ]]; then
  echo -e "${CYAN}🔄 Memulihkan file dari backup terbaru...${RESET}"
  shopt -s nullglob
  LATEST_FILES=$(ls -1t "$BACKUP_DIR"/*.bak 2>/dev/null || true)

  if [[ -z "$LATEST_FILES" ]]; then
    echo -e "${RED}❌ Tidak ada file backup ditemukan.${RESET}"
    exit 1
  fi

  for bak in $LATEST_FILES; do
    fname=$(basename "$bak" | sed 's/\.[0-9-]*\.bak$//')
    find /var/www/pterodactyl/app/Http/Controllers -type f -name "$fname" -exec cp "$bak" {} \; 2>/dev/null || true
  done

  echo -e "${GREEN}✅ Semua file berhasil dikembalikan dari backup terbaru.${RESET}"
  echo -e "${CYAN}📁 Lokasi backup: ${YELLOW}$BACKUP_DIR${RESET}"

else
  echo -e "${RED}❌ Pilihan tidak valid.${RESET}"
  exit 1
fi
