#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ===== COLOR =====
RED="\033[1;31m"
GREEN="\033[1;32m"
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
WHITE="\033[1;37m"
RESET="\033[0m"

# ===== CONFIG =====
VERSION="1.6"
BACKUP_DIR="/root/greysync_backupsx"
mkdir -p "$BACKUP_DIR"

# Clear only if interactive
[[ -t 1 ]] && clear

# ===== HEADER (interactive only) =====
if [[ -z "${1:-}" ]]; then
echo -e "${CYAN}"
echo "╔════════════════════════════════════════════════════════════╗"
echo "║        GreyZ Admin Protect • Auto Mode                     ║"
echo "║        Version : v${VERSION}                                ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo -e "${RESET}"
fi

# ===== BOT MODE =====
MODE="${1:-}"
ADMIN_ID="${2:-}"

if [[ -z "$MODE" ]]; then
  echo -e "${RED}❌ Mode tidak diberikan. Gunakan: $0 <1|2> [adminId]${RESET}"
  exit 1
fi

# ================= MODE 1 : INSTALL =================
if [[ "$MODE" == "1" ]]; then

  if [[ -z "$ADMIN_ID" ]]; then
    echo -e "${RED}❌ Admin ID wajib untuk mode install.${RESET}"
    exit 1
  fi

  echo -e "${CYAN}➤ GreyZ Admin Protect | Admin ID: ${ADMIN_ID}${RESET}"
  echo -e "${CYAN}⏳ Memulai patch admin controller...${RESET}"
  echo

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
    echo -e "${YELLOW}⚙ Patch API → ${WHITE}$path${RESET}"
    backup_file "$path"

    if ! grep -q "use Illuminate\\Support\\Facades\\Auth;" "$path"; then
      sed -i '/^namespace /a use Illuminate\\Support\\Facades\\Auth;' "$path"
    fi

    awk -v admin_id="$ADMIN_ID" '
      BEGIN { in_func=0; inserted=0 }
      /public function update[[:space:]]*\(.*\)/ { print; in_func=1; next }
      in_func==1 && /\{/ && inserted==0 {
        print
        print "        // === GreyZ Anti Edit Protect (API) ==="
        print "        $auth = $request->user() ?? Auth::user();"
        print "        if (!\\$auth || (\\$auth->id !== \\$user->id && \\$auth->id != " admin_id ")) {"
        print "            return response()->json([\"error\" => \"Unauthorized modification\"], 403);"
        print "        }"
        inserted=1
        in_func=0
        next
      }
      { print }
    ' "$path" > "$path.tmp" && mv "$path.tmp" "$path"

    PATCHED+=("$path")
  }

  inject_admin_protect() {
    local path="$1"
    echo -e "${YELLOW}⚙ Patch Admin → ${WHITE}$path${RESET}"
    backup_file "$path"

    if ! grep -q "use Illuminate\\Support\\Facades\\Auth;" "$path"; then
      sed -i '/^namespace /a use Illuminate\\Support\\Facades\\Auth;' "$path"
    fi

    awk -v admin_id="$ADMIN_ID" '
      BEGIN { in_func=0; inserted=0 }
      /public function update[[:space:]]*\(.*\)/ { print; in_func=1; next }
      in_func==1 && /\{/ && inserted==0 {
        print
        print "        // === GreyZ Anti Edit Protect (Admin) ==="
        print "        $auth = \\$request->user() ?? Auth::user();"
        print "        if (!\\$auth || (\\$auth->id !== \\$user->id && \\$auth->id != " admin_id ")) {"
        print "            return redirect()->back()->withErrors([\"error\" => \"Unauthorized access\" ]);"
        print "        }"
        inserted=1
        in_func=0
        next
      }
      { print }
    ' "$path" > "$path.tmp" && mv "$path.tmp" "$path"

    PATCHED+=("$path")
  }

  for p in "${API_CANDIDATES[@]}"; do
    [[ -f "$p" ]] && inject_api_protect "$p" && break
  done

  for p in "${ADMIN_CANDIDATES[@]}"; do
    [[ -f "$p" ]] && inject_admin_protect "$p" && break
  done

  echo
  if [[ ${#PATCHED[@]} -eq 0 ]]; then
    echo -e "${YELLOW}⚠ Tidak ada file yang berhasil dipatch.${RESET}"
  else
    echo -e "${GREEN}✅ GreyZ Admin Protect berhasil:${RESET}"
    for f in "${PATCHED[@]}"; do
      echo -e "   • ${WHITE}$f${RESET}"
    done
  fi
  exit 0

# ================= MODE 2 : RESTORE =================
elif [[ "$MODE" == "2" ]]; then

  echo -e "${CYAN}🔄 Restore dari backup GreyZ...${RESET}"
  shopt -s nullglob
  LATEST_FILES=$(ls -1t "$BACKUP_DIR"/*.bak 2>/dev/null || true)

  if [[ -z "$LATEST_FILES" ]]; then
    echo -e "${RED}❌ Backup tidak ditemukan.${RESET}"
    exit 1
  fi

  for bak in $LATEST_FILES; do
    fname=$(basename "$bak" | sed 's/\.[0-9-]*\.bak$//')
    find /var/www/pterodactyl/app/Http/Controllers -type f -name "$fname" \
      -exec cp "$bak" {} \; 2>/dev/null || true
  done

  echo -e "${GREEN}✅ Restore GreyZ selesai.${RESET}"
  echo -e "${WHITE}📁 Backup:${RESET} $BACKUP_DIR"
  exit 0

else
  echo -e "${RED}❌ Mode tidak valid: $MODE (gunakan 1 atau 2)${RESET}"
  exit 1
fi
