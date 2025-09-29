#!/bin/bash
# GreySync Protect (No-Middleware) v1.5.2-nomw (improved full-patch)
ROOT="/var/www/pterodactyl"
BACKUP_DIR="$ROOT/greysync_backups_$(date +%s)"

USER_CONTROLLER="$ROOT/app/Http/Controllers/Admin/UserController.php"
SERVER_SERVICE="$ROOT/app/Services/Servers/ServerDeletionService.php"
NODE_CONTROLLER="$ROOT/app/Http/Controllers/Admin/Nodes/NodeController.php"
NEST_CONTROLLER="$ROOT/app/Http/Controllers/Admin/Nests/NestController.php"
SETTINGS_CONTROLLER="$ROOT/app/Http/Controllers/Admin/Settings/IndexController.php"

STORAGE="$ROOT/storage/app/greysync_protect.json"
IDPROTECT="$ROOT/storage/app/idprotect.json"
ADMIN_ID_DEFAULT=1

RED="\033[1;31m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RESET="\033[0m"

log() { echo -e "$1"; }
err() { echo -e "${RED}$1${RESET}"; }
ok()  { echo -e "${GREEN}$1${RESET}"; }

php_check() {
  php -l "$1" >/dev/null 2>&1
  return $?
}

backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  mkdir -p "$BACKUP_DIR/$(dirname "${f#$ROOT/}")"
  cp -f "$f" "$BACKUP_DIR/${f#$ROOT/}.bak"
  log "${YELLOW}Backup: $f -> $BACKUP_DIR/${f#$ROOT/}.bak${RESET}"
}

restore_from_latest_backup() {
  local latest
  latest=$(ls -td "$ROOT"/greysync_backups_* 2>/dev/null | head -n1)
  [[ -z "$latest" ]] && { err "❌ No greysync backups found"; return 1; }
  find "$latest" -type f -name "*.bak" | while read -r f; do
    rel="${f#$latest/}"
    target="$ROOT/${rel%.bak}"
    mkdir -p "$(dirname "$target")"
    cp -f "$f" "$target"
    log "${GREEN}Restored: $target${RESET}"
  done
  return 0
}

# Improved patcher: safer insertion into specific controller methods
patch_admin_controller_flexible() {
  local ctrl="$1"
  local tag="$2"
  local admin_id="${3:-$ADMIN_ID_DEFAULT}"

  [[ -f "$ctrl" ]] || { log "${YELLOW}Skip (not found): $ctrl${RESET}"; return 0; }
  backup_file "$ctrl"

  if grep -q "GREYSYNC_PROTECT_${tag}" "$ctrl" 2>/dev/null; then
    log "${YELLOW}Already patched: $ctrl${RESET}"
    return 0
  fi

  # 1) ensure "use Illuminate\Support\Facades\Auth;" present after namespace
  perl -0777 -pe '
    if (/namespace\s+[^\r\n]+;/s && !/Illuminate\\\Support\\\Facades\\\Auth/) {
      s/(namespace\s+[^\r\n]+;)/$1\nuse Illuminate\\\Support\\\Facades\\\Auth;\n/;
    }
  ' "$ctrl" > "$ctrl.tmp.use" && mv "$ctrl.tmp.use" "$ctrl"

  # 2) Try to insert guard into specific common admin methods.
  # We'll attempt multiple method targets in order and insert guard inside the method body
  # right after the opening brace line. We will not replace parentheses lines, just insert after "{\n".
  perl -0777 -pe "
    my \$a = $admin_id;
    my \$patched = 0;
    # targets: index, view, show, edit, update, create
    if (/(public\\s+function\\s+(?:index|view|show|edit|update|create)\\s*\\([^\\)]*\\)\\s*\\{)/is) {
      s/(public\\s+function\\s+(?:index|view|show|edit|update|create)\\s*\\([^\\)]*\\)\\s*\\{)/\$1\n        \\/\\/ GREYSYNC_PROTECT_${tag}\\n        \$user = Auth::user();\\n        if (!\$user || \$user->id != \$a) { abort(403, \\\"❌ GreySync Protect: Akses ditolak\\\"); }\\n/si;
      \$patched = 1;
    }
    # fallback: find the first public function and insert (less preferred)
    if (!\$patched && /(public\\s+function\\s+[a-zA-Z0-9_]+\\s*\\([^\\)]*\\)\\s*\\{)/is) {
      s/(public\\s+function\\s+[a-zA-Z0-9_]+\\s*\\([^\\)]*\\)\\s*\\{)/\$1\n        \\/\\/ GREYSYNC_PROTECT_${tag}\\n        \$user = Auth::user();\\n        if (!\$user || \$user->id != \$a) { abort(403, \\\"❌ GreySync Protect: Akses ditolak\\\"); }\\n/si;
    }
  " "$ctrl" > "$ctrl.tmp.patch" && mv "$ctrl.tmp.patch" "$ctrl"

  # lint check
  if ! php_check "$ctrl"; then
    err "❌ Syntax error after patching $ctrl — restoring backup"
    cp -f "$BACKUP_DIR/${ctrl#$ROOT/}.bak" "$ctrl" 2>/dev/null || true
    return 2
  fi

  ok "Patched: $ctrl"
  return 0
}

patch_user_delete() {
  local admin_id="${1:-$ADMIN_ID_DEFAULT}"
  [[ -f "$USER_CONTROLLER" ]] || { log "${YELLOW}Skip (not found): UserController${RESET}"; return 0; }
  backup_file "$USER_CONTROLLER"
  if grep -q "GREYSYNC_PROTECT_USER" "$USER_CONTROLLER" 2>/dev/null; then
    log "${YELLOW}Already patched: UserController${RESET}"; return 0
  fi

  # insert guard right after method opening brace of delete method
  perl -0777 -pe '
    my $a = shift @ARGV;
    if (/(public\s+function\s+delete\s*\([^\)]*\)\s*\{)/i) {
      s/(public\s+function\s+delete\s*\([^\)]*\)\s*\{)/$1\n        \/\/ GREYSYNC_PROTECT_USER\n        if (isset($request) && $request->user()->id != $a) { throw new \\\\Pterodactyl\\\\Exceptions\\\\DisplayException(\"❌ GreySync Protect: Tidak boleh hapus user\"); }\n/;
    }
  ' "$admin_id" "$USER_CONTROLLER" > "$USER_CONTROLLER.tmp" && mv "$USER_CONTROLLER.tmp" "$USER_CONTROLLER"

  if ! php_check "$USER_CONTROLLER"; then
    err "❌ UserController error — restoring backup"
    cp -f "$BACKUP_DIR/${USER_CONTROLLER#$ROOT/}.bak" "$USER_CONTROLLER" 2>/dev/null || true
    return 2
  fi
  ok "Patched: UserController (delete)"
}

patch_server_delete_service() {
  local admin_id="${1:-$ADMIN_ID_DEFAULT}"
  [[ -f "$SERVER_SERVICE" ]] || { log "${YELLOW}Skip (not found): ServerDeletionService${RESET}"; return 0; }
  backup_file "$SERVER_SERVICE"
  if grep -q "GREYSYNC_PROTECT_SERVER" "$SERVER_SERVICE" 2>/dev/null; then
    log "${YELLOW}Already patched: ServerDeletionService${RESET}"; return 0
  fi

  # ensure Auth facade exists in file
  if ! grep -q "Illuminate\\\\Support\\\\Facades\\\\Auth" "$SERVER_SERVICE"; then
    perl -0777 -pe '
      if (/namespace\s+[^\r\n]+;/s) {
        s/(namespace\s+[^\r\n]+;)/$1\nuse Illuminate\\\Support\\\Facades\\\Auth;\n/;
      }
    ' "$SERVER_SERVICE" > "$SERVER_SERVICE.tmp.use" && mv "$SERVER_SERVICE.tmp.use" "$SERVER_SERVICE"
  fi

  perl -0777 -pe '
    my $a = shift @ARGV;
    if (/(public\s+function\s+handle\s*\([^\)]*\)\s*\{)/i) {
      s/(public\s+function\s+handle\s*\([^\)]*\)\s*\{)/$1\n        \/\/ GREYSYNC_PROTECT_SERVER\n        $user = Auth::user();\n        if ($user && $user->id != $a) { throw new \\\\Pterodactyl\\\\Exceptions\\\\DisplayException(\"❌ GreySync Protect: Tidak boleh hapus server\"); }\n/;
    }
  ' "$admin_id" "$SERVER_SERVICE" > "$SERVER_SERVICE.tmp" && mv "$SERVER_SERVICE.tmp" "$SERVER_SERVICE"

  if ! php_check "$SERVER_SERVICE"; then
    err "❌ ServerDeletionService error — restoring backup"
    cp -f "$BACKUP_DIR/${SERVER_SERVICE#$ROOT/}.bak" "$SERVER_SERVICE" 2>/dev/null || true
    return 2
  fi
  ok "Patched: ServerDeletionService (handle)"
}

fix_laravel() {
  cd "$ROOT" || return 1
  command -v composer >/dev/null 2>&1 && composer dump-autoload -o --no-dev >/dev/null 2>&1 || true
  php artisan config:clear >/dev/null 2>&1 || true
  php artisan cache:clear  >/dev/null 2>&1 || true
  php artisan route:clear  >/dev/null 2>&1 || true
  php artisan view:clear   >/dev/null 2>&1 || true
  chown -R www-data:www-data "$ROOT" >/dev/null 2>&1 || true
  chmod -R 755 "$ROOT/storage" "$ROOT/bootstrap/cache" >/dev/null 2>&1 || true
  systemctl restart nginx >/dev/null 2>&1 || true
  php_fpm=$(systemctl list-units --type=service --all | grep -oE 'php[0-9]+(\.[0-9]+)?-fpm' | head -n1 || true)
  [[ -n "$php_fpm" ]] && systemctl restart "$php_fpm" >/dev/null 2>&1 || true
  ok "Laravel caches cleared & services restarted"
}

install_all() {
  mkdir -p "$BACKUP_DIR"
  echo '{ "status": "on" }' > "$STORAGE" 2>/dev/null || true
  echo '{ "superAdminId": '"$ADMIN_ID_DEFAULT"' }' > "$IDPROTECT" 2>/dev/null || true

  patch_user_delete "$ADMIN_ID_DEFAULT"
  patch_server_delete_service "$ADMIN_ID_DEFAULT"
  patch_admin_controller_flexible "$NODE_CONTROLLER" "NODE" "$ADMIN_ID_DEFAULT"
  patch_admin_controller_flexible "$NEST_CONTROLLER" "NEST" "$ADMIN_ID_DEFAULT"
  patch_admin_controller_flexible "$SETTINGS_CONTROLLER" "SETTINGS" "$ADMIN_ID_DEFAULT"

  fix_laravel || true
  ok "✅ GreySync Protect (no-middleware) installed."
}

uninstall_all() {
  rm -f "$STORAGE" "$IDPROTECT" 2>/dev/null || true
  restore_from_latest_backup || log "${YELLOW}No backups restored${RESET}"
  fix_laravel || true
  ok "✅ GreySync Protect uninstalled/restored."
}

admin_patch() {
  local newid="$1"
  [[ -z "$newid" || ! "$newid" =~ ^[0-9]+$ ]] && { err "Usage: $0 adminpatch <numeric id>"; return 1; }
  echo '{ "superAdminId": '"$newid"' }' > "$IDPROTECT"
  ok "SuperAdmin ID set -> $newid"
  patch_user_delete "$newid"
  patch_server_delete_service "$newid"
  patch_admin_controller_flexible "$NODE_CONTROLLER" "NODE" "$newid"
  patch_admin_controller_flexible "$NEST_CONTROLLER" "NEST" "$newid"
  patch_admin_controller_flexible "$SETTINGS_CONTROLLER" "SETTINGS" "$newid"
  fix_laravel || true
}

restore_backups() {
  restore_from_latest_backup || { err "❌ No backups found"; return 1; }
  fix_laravel || true
  ok "✅ Restored controllers from latest backup"
}

case "$1" in
  install|"") install_all ;;
  uninstall)   uninstall_all ;;
  restore)     restore_backups ;;
  adminpatch)  admin_patch "$2" ;;
  *) err "Usage: $0 {install|uninstall|restore|adminpatch <id>}"; exit 1 ;;
esac
