#!/bin/bash

# ===== COLOR =====
RED="\033[1;31m"
GREEN="\033[1;32m"
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
RESET="\033[0m"
BOLD="\033[1m"

# ===== CONFIG =====
VERSION="1.6"
BACKUP_DIR="backup_greysyncx"

CONTROLLER_USER="/var/www/pterodactyl/app/Http/Controllers/Admin/UserController.php"
SERVICE_SERVER="/var/www/pterodactyl/app/Services/Servers/ServerDeletionService.php"
API_SERVER_CONTROLLER="/var/www/pterodactyl/app/Http/Controllers/Api/Client/Servers/ServerController.php"
VIEW_DIR="/var/www/pterodactyl/resources/views/admin"

mkdir -p "$BACKUP_DIR"

# ===== BOT MODE =====
MODE="$1"
ADMIN_ID="$2"

AUTO_MODE=0
[[ "$MODE" =~ ^[12]$ ]] && AUTO_MODE=1

# ===== MANUAL HEADER =====
if [[ "$AUTO_MODE" -eq 0 ]]; then
  clear
  echo -e "${CYAN}${BOLD}"
  echo "GreySync Protect v$VERSION"
  echo -e "${RESET}"
fi

# ===== VALIDASI =====
if [[ -z "$MODE" || ! "$MODE" =~ ^[12]$ ]]; then
  echo -e "${RED}❌ Mode tidak valid (1=install, 2=restore)${RESET}"
  exit 1
fi

if [[ "$MODE" == "1" && ! "$ADMIN_ID" =~ ^[0-9]+$ ]]; then
  echo -e "${RED}❌ ADMIN_ID wajib untuk mode install${RESET}"
  exit 1
fi

# ================= MODE 1 =================
if [[ "$MODE" == "1" ]]; then
  echo -e "${CYAN}➤ Install GreySync Protect | Admin ID: $ADMIN_ID${RESET}"

  ts=$(date +%F-%H%M%S)
  [[ -f "$CONTROLLER_USER" ]] && cp "$CONTROLLER_USER" "$BACKUP_DIR/UserController.$ts.bak"
  [[ -f "$SERVICE_SERVER" ]] && cp "$SERVICE_SERVER" "$BACKUP_DIR/ServerDeletionService.$ts.bak"
  [[ -f "$API_SERVER_CONTROLLER" ]] && cp "$API_SERVER_CONTROLLER" "$BACKUP_DIR/ServerControllerAPI.$ts.bak"

  # === Protect Delete User ===
  if [[ -f "$CONTROLLER_USER" ]]; then
    awk -v admin="$ADMIN_ID" '
    /public function delete/ {print;f=1;next}
    f&&/\{/{
      print
      print "        if ($request->user()->id !== " admin ") {"
      print "            throw new DisplayException(\"Unauthorized delete\");"
      print "        }"
      f=0;next
    }{print}' "$CONTROLLER_USER" > "$CONTROLLER_USER.tmp" && mv "$CONTROLLER_USER.tmp" "$CONTROLLER_USER"
  fi

  # === Protect Delete Server ===
  if [[ -f "$SERVICE_SERVER" ]]; then
    grep -q "Facades\\Auth" "$SERVICE_SERVER" || \
      sed -i '/^namespace/a use Illuminate\\Support\\Facades\\Auth;\nuse Pterodactyl\\Exceptions\\DisplayException;' "$SERVICE_SERVER"

    awk -v admin="$ADMIN_ID" '
    /public function handle/ {print;f=1;next}
    f&&/\{/{
      print
      print "        $u = Auth::user();"
      print "        if ($u && $u->id !== " admin ") {"
      print "            throw new DisplayException(\"Unauthorized delete\");"
      print "        }"
      f=0;next
    }{print}' "$SERVICE_SERVER" > "$SERVICE_SERVER.tmp" && mv "$SERVICE_SERVER.tmp" "$SERVICE_SERVER"
  fi

  # === Anti Intip API ===
  if [[ -f "$API_SERVER_CONTROLLER" ]]; then
    awk -v admin="$ADMIN_ID" '
    /public function index/ {print;f=1;next}
    f&&/\{/{
      print
      print "        $u = $request->user();"
      print "        if ($u->id !== $server->owner_id && $u->id !== " admin ") {"
      print "            abort(403);"
      print "        }"
      f=0;next
    }{print}' "$API_SERVER_CONTROLLER" > "$API_SERVER_CONTROLLER.tmp" && mv "$API_SERVER_CONTROLLER.tmp" "$API_SERVER_CONTROLLER"
  fi

  # === Blade Protect ===
  VIEW_FILE="$VIEW_DIR/servers/view/index.blade.php"
  if [[ -f "$VIEW_FILE" ]]; then
    cp "$VIEW_FILE" "$BACKUP_DIR/view_index.$ts.bak"
    awk -v admin="$ADMIN_ID" '
    NR==1{
      print "@php"
      print "$u=auth()->user();"
      print "if(!$u||($u->id!=$server->owner_id&&$u->id!=" admin ")) abort(403);"
      print "@endphp"
    }{print}' "$VIEW_FILE" > "$VIEW_FILE.tmp" && mv "$VIEW_FILE.tmp" "$VIEW_FILE"
  fi

  echo -e "${GREEN}✅ GreySync Protect terpasang${RESET}"
  exit 0
fi

# ================= MODE 2 =================
if [[ "$MODE" == "2" ]]; then
  echo -e "${CYAN}♻ Restore GreySync Protect${RESET}"
  shopt -s nullglob
  for b in "$BACKUP_DIR"/*.bak; do
    base=$(basename "$b" | cut -d. -f1)
    case "$base" in
      UserController) cp "$b" "$CONTROLLER_USER" ;;
      ServerDeletionService) cp "$b" "$SERVICE_SERVER" ;;
      ServerControllerAPI) cp "$b" "$API_SERVER_CONTROLLER" ;;
      view_index*) cp "$b" "$VIEW_DIR/servers/view/index.blade.php" ;;
    esac
  done
  echo -e "${GREEN}✅ Restore selesai${RESET}"
fi
