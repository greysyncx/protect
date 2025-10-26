#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

RED="\033[1;31m"
GREEN="\033[1;32m"
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
RESET="\033[0m"
VERSION="1.6"

BACKUP_DIR="/root/greysync_backupsx"
mkdir -p "$BACKUP_DIR"

MODE_ARG="${1:-}"
ADMIN_ID_ARG="${2:-}"
AUTO_MODE=0
MENU=""
ADMIN_ID=""
# ====== Mode Otomatis Deteksi ======
if [[ "$MODE_ARG" =~ ^[12]$ ]]; then
  AUTO_MODE=1
  MENU="$MODE_ARG"

  if [[ "$MENU" == "1" ]]; then
    if [[ "$ADMIN_ID_ARG" =~ ^[0-9]+$ ]]; then
      ADMIN_ID="$ADMIN_ID_ARG"
    else
      echo -e "${RED}❌ Mode otomatis install butuh Admin ID (contoh: bash greyz.sh 1 12345).${RESET}"
      exit 1
    fi
  fi
else
  clear
  echo -e "${CYAN}"
  echo "╔════════════════════════════════════════════════════════╗"
  echo "║             GreySync Admin Protect v${VERSION}               ║"
  echo "╚════════════════════════════════════════════════════════╝"
  echo -e "${RESET}"

  echo -e "${YELLOW}[1]${RESET} Pasang Protect GreyZ"
  echo -e "${YELLOW}[2]${RESET} Restore dari Backup Terakhir"
  read -p "$(echo -e "${CYAN}Pilih opsi [1/2]: ${RESET}")" MENU

  if [[ "$MENU" == "1" ]]; then
    read -p "$(echo -e "${CYAN}👤 Masukkan ID Admin Utama (contoh: 1): ${RESET}")" ADMIN_ID
  fi
fi
# ====== Validasi ======
if [[ -z "$MENU" || ! "$MENU" =~ ^[12]$ ]]; then
  echo -e "${RED}❌ Pilihan tidak valid.${RESET}"
  exit 1
fi

if [[ "$MENU" == "1" && -z "$ADMIN_ID" ]]; then
  echo -e "${RED}❌ Admin ID wajib diisi untuk mode install.${RESET}"
  exit 1
fi
# ========== Helper Backup ==========
backup_file() {
  local f="$1"
  [[ -f "$f" ]] && cp "$f" "$BACKUP_DIR/$(basename "$f").$(date +%F-%H%M%S).bak"
}
# ========== Inject Protect API ==========
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
        print "            return response()->json([\"error\" => \"😹 Lu Siapa Mau Edit User Lain? Jasa Pasang Anti-Rusuh t.me/greysyncx\"], 403);"
        print "        }"
        inserted=1
        in_func=0; next;
      }
    }
    { print }
  ' "$path" > "$path.tmp" && mv "$path.tmp" "$path"
}
# ========== Inject Protect Admin ==========
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
        print "            return redirect()->back()->withErrors([\"error\" => \"😹 Lu Siapa Mau Edit User Lain? Jasa Pasang Anti-Rusuh t.me/greysyncx\"]);"
        print "        }"
        inserted=1
        in_func=0; next;
      }
    }
    { print }
  ' "$path" > "$path.tmp" && mv "$path.tmp" "$path"
}
# ========== MODE 1: Pasang Protect ==========
if [[ "$MENU" == "1" ]]; then
  echo -e "${YELLOW}➡ Menjalankan GreySync Admin Protect...${RESET}"

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

  for p in "${API_CANDIDATES[@]}"; do
    [[ -f "$p" ]] && inject_api_protect "$p" && PATCHED+=("$p")
  done
  for p in "${ADMIN_CANDIDATES[@]}"; do
    [[ -f "$p" ]] && inject_admin_protect "$p" && PATCHED+=("$p")
  done

  if [[ ${#PATCHED[@]} -eq 0 ]]; then
    echo -e "${YELLOW}⚠ Tidak ditemukan file target untuk dipatch.${RESET}"
  else
    echo -e "${GREEN}✅ Proteksi berhasil diterapkan ke file:${RESET}"
    for f in "${PATCHED[@]}"; do
      echo -e "  • ${YELLOW}$f${RESET}"
    done
    echo -e "${CYAN}🛡 Sistem kini terlindungi dari edit & intip tidak sah.${RESET}"
  fi
# ========== MODE 2: Restore ==========
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
