#!/bin/bash
# GreySync Protect - v1.5 Final (No Backup Protect)
# Full Protect: User, Server, Node, Nest, Settings

ROOT="/var/www/pterodactyl"
BACKUP_DIR="$ROOT/greysync_backups_$(date +%s)"

# Controller & Service Paths
USER_CONTROLLER="$ROOT/app/Http/Controllers/Admin/UserController.php"
SERVER_SERVICE="$ROOT/app/Services/Servers/ServerDeletionService.php"
NODE_CONTROLLER="$ROOT/app/Http/Controllers/Admin/Nodes/NodeController.php"
NEST_CONTROLLER="$ROOT/app/Http/Controllers/Admin/Nests/NestController.php"
SETTINGS_CONTROLLER="$ROOT/app/Http/Controllers/Admin/Settings/IndexController.php"

ADMIN_ID=1  # Default super admin ID

log() { echo -e "$1"; }

backup_file() {
  [[ -f "$1" ]] || return
  mkdir -p "$BACKUP_DIR/$(dirname "${1#$ROOT/}")"
  cp -f "$1" "$BACKUP_DIR/${1#$ROOT/}.bak"
}

# --- Protect User Delete ---
patch_user_controller() {
  backup_file "$USER_CONTROLLER"
  grep -q "GREYSYNC_PROTECT_USER" "$USER_CONTROLLER" && return
  awk -v admin_id="$ADMIN_ID" '
  /public function delete/ {print; in_func=1; next}
  in_func==1 && /^\s*{/ {
    print;
    print "        // GREYSYNC_PROTECT_USER";
    print "        if ($request->user()->id !== " admin_id ") {";
    print "            throw new \\Pterodactyl\\Exceptions\\DisplayException(\"❌ GreySync Protect: Tidak boleh hapus user\");";
    print "        }";
    in_func=0; next
  }
  {print}' "$USER_CONTROLLER" > "$USER_CONTROLLER.tmp" && mv "$USER_CONTROLLER.tmp" "$USER_CONTROLLER"
}

# --- Protect Server Delete ---
patch_server_service() {
  backup_file "$SERVER_SERVICE"
  grep -q "GREYSYNC_PROTECT_SERVER" "$SERVER_SERVICE" && return
  awk -v admin_id="$ADMIN_ID" '
  /public function handle/ {print; in_func=1; next}
  in_func==1 && /^\s*{/ {
    print;
    print "        // GREYSYNC_PROTECT_SERVER";
    print "        $user = \\Illuminate\\Support\\Facades\\Auth::user();";
    print "        if ($user && $user->id !== " admin_id ") {";
    print "            throw new \\Pterodactyl\\Exceptions\\DisplayException(\"❌ GreySync Protect: Tidak boleh hapus server\");";
    print "        }";
    in_func=0; next
  }
  {print}' "$SERVER_SERVICE" > "$SERVER_SERVICE.tmp" && mv "$SERVER_SERVICE.tmp" "$SERVER_SERVICE"
}

# --- Protect Admin Index in Controllers ---
patch_admin_controller() {
  local ctrl="$1"
  local tag="$2"
  backup_file "$ctrl"
  grep -q "GREYSYNC_PROTECT_${tag}" "$ctrl" && return
  perl -0777 -pe "
    if (/namespace\s+[^\r\n]+;/s && !/Illuminate\\\\Support\\\\Facades\\\\Auth/) {
      s/(namespace\s+[^\r\n]+;)/\$1\nuse Illuminate\\\\Support\\\\Facades\\\\Auth;/;
    }
    s/(public function index\([^\)]*\)\s*\{)/\$1\n        \/\/ GREYSYNC_PROTECT_${tag}\n        \$user = Auth::user();\n        if (!\$user || \$user->id != $ADMIN_ID) { abort(403, \"❌ GreySync Protect: Akses ditolak\"); }/s;
  " "$ctrl" > "$ctrl.tmp" && mv "$ctrl.tmp" "$ctrl"
}

install_all() {
  mkdir -p "$BACKUP_DIR"
  patch_user_controller
  patch_server_service
  patch_admin_controller "$NODE_CONTROLLER" "NODE"
  patch_admin_controller "$NEST_CONTROLLER" "NEST"
  patch_admin_controller "$SETTINGS_CONTROLLER" "SETTINGS"

  cd "$ROOT" && composer dump-autoload -o
  php artisan config:clear && php artisan cache:clear
  php artisan route:clear && php artisan view:clear

  log "✅ GreySync Protect v1.5 Installed (User, Server, Node, Nest, Settings)"
}

uninstall_all() {
  [[ -d "$BACKUP_DIR" ]] || { log "⚠️ Tidak ada backup"; return; }
  find "$BACKUP_DIR" -name "*.bak" | while read f; do
    orig="$ROOT/${f#$BACKUP_DIR/}"
    cp -f "$f" "$orig"
  done
  cd "$ROOT" && composer dump-autoload -o
  php artisan config:clear && php artisan cache:clear
  php artisan route:clear && php artisan view:clear
  log "✅ GreySync Protect v1.5 Uninstalled & Restored"
}

case "$1" in
  install|"") install_all ;;
  uninstall) uninstall_all ;;
  *) echo "Usage: $0 {install|uninstall}";;
esac
