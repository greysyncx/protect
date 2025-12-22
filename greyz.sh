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

MODE="${1:-}"
ADMIN_ID="${2:-}"

AUTO_MODE=0
[[ "$MODE" =~ ^[12]$ ]] && AUTO_MODE=1

if [[ "$AUTO_MODE" -eq 0 ]]; then
  clear
  echo -e "${CYAN}GreySync Admin Protect v$VERSION${RESET}"
fi

if [[ -z "$MODE" || ! "$MODE" =~ ^[12]$ ]]; then
  echo -e "${RED}❌ Mode tidak valid${RESET}"
  exit 1
fi

if [[ "$MODE" == "1" && ! "$ADMIN_ID" =~ ^[0-9]+$ ]]; then
  echo -e "${RED}❌ Admin ID wajib${RESET}"
  exit 1
fi

backup() {
  [[ -f "$1" ]] && cp "$1" "$BACKUP_DIR/$(basename "$1").$(date +%F-%H%M%S).bak"
}

patch_api() {
  backup "$1"
  grep -q "Facades\\Auth" "$1" || sed -i '/^namespace/a use Illuminate\\Support\\Facades\\Auth;' "$1"
  awk -v admin="$ADMIN_ID" '
  /public function update/ {print;f=1;next}
  f&&/\{/{
    print
    print "        $a=$request->user()??Auth::user();"
    print "        if(!$a||($a->id!=$user->id&&$a->id!=" admin ")) return response()->json([],403);"
    f=0;next
  }{print}' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

patch_admin() {
  backup "$1"
  grep -q "Facades\\Auth" "$1" || sed -i '/^namespace/a use Illuminate\\Support\\Facades\\Auth;' "$1"
  awk -v admin="$ADMIN_ID" '
  /public function update/ {print;f=1;next}
  f&&/\{/{
    print
    print "        $a=$request->user()??Auth::user();"
    print "        if(!$a||($a->id!=$user->id&&$a->id!=" admin ")) return back()->withErrors([\"error\"=>\"Unauthorized\"]);"
    f=0;next
  }{print}' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

if [[ "$MODE" == "1" ]]; then
  for p in \
    /var/www/pterodactyl/app/Http/Controllers/Api/Application/Users/UserController.php \
    /var/www/pterodactyl/app/Http/Controllers/Api/Users/UserController.php; do
    [[ -f "$p" ]] && patch_api "$p" && break
  done

  for p in \
    /var/www/pterodactyl/app/Http/Controllers/Admin/UserController.php \
    /var/www/pterodactyl/app/Http/Controllers/Admin/Users/UserController.php; do
    [[ -f "$p" ]] && patch_admin "$p" && break
  done

  echo -e "${GREEN}✅ Admin Protect terpasang${RESET}"
  exit 0
fi

if [[ "$MODE" == "2" ]]; then
  shopt -s nullglob
  for b in "$BACKUP_DIR"/*.bak; do
    n=$(basename "$b" | sed 's/\.[0-9-]*\.bak$//')
    find /var/www/pterodactyl/app/Http/Controllers -name "$n" -exec cp "$b" {} \; 2>/dev/null || true
  done
  echo -e "${GREEN}✅ Restore Admin Protect selesai${RESET}"
fi
