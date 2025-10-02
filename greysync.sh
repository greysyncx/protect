#!/usr/bin/env bash
# GreySync Protect v1.6.4 (Final Clean)

set -euo pipefail
IFS=$'\n\t'

# === CONFIG ===
ROOT="${ROOT:-/var/www/pterodactyl}"
BACKUP_PARENT="${BACKUP_PARENT:-$ROOT/greysync_backups}"
TIMESTAMP="$(date +%s)"
BACKUP_DIR="${BACKUP_PARENT}/greysync_$TIMESTAMP"
BACKUP_LATEST_LINK="$BACKUP_PARENT/latest"
STORAGE="$ROOT/storage/app/greysync_protect.json"
IDPROTECT="$ROOT/storage/app/idprotect.json"
ADMIN_ID_DEFAULT="${ADMIN_ID_DEFAULT:-1}"
LOGFILE="/var/log/greysync_protect.log"
VERSION="1.6.4"

# === STATE ===
IN_INSTALL=false
EXIT_CODE=0

# === FILE TARGETS ===
declare -A TARGETS=(
  ["USER"]="$ROOT/app/Http/Controllers/Admin/UserController.php"
  ["SERVER"]="$ROOT/app/Services/Servers/ServerDeletionService.php"
  ["NODE"]="$ROOT/app/Http/Controllers/Admin/Nodes/NodeController.php"
  ["NEST"]="$ROOT/app/Http/Controllers/Admin/Nests/NestController.php"
  ["SETTINGS"]="$ROOT/app/Http/Controllers/Admin/Settings/IndexController.php"
  ["DATABASES"]="$ROOT/app/Http/Controllers/Admin/Databases/DatabaseController.php"
  ["LOCATIONS"]="$ROOT/app/Http/Controllers/Admin/Locations/LocationController.php"
  ["FILE"]="$ROOT/app/Http/Controllers/Api/Client/Servers/FileController.php"
)

# === LOGGING ===
log(){ echo -e "[OK] $*" | tee -a "$LOGFILE"; }
err(){ echo -e "[ERR] $*" | tee -a "$LOGFILE" >&2; EXIT_CODE=1; }

# === PHP BINARY ===
php_bin(){
  for bin in php php8.3 php8.2 php8.1 php8.0 php7.4; do
    if command -v "$bin" >/dev/null 2>&1; then echo "$bin"; return 0; fi
  done
  return 1
}
PHP="$(php_bin || true)"
if [[ -z "$PHP" ]]; then
  err "PHP binary tidak ditemukan. Install php-cli terlebih dahulu."
  exit 1
fi

php_check(){
  [[ -n "$PHP" && -f "$1" ]] && ! "$PHP" -l "$1" >/dev/null 2>&1 && return 1 || return 0
}

# === BACKUP ===
backup_file(){
  [[ -f "$1" ]] && mkdir -p "$BACKUP_DIR/$(dirname "${1#$ROOT/}")" && cp -af "$1" "$BACKUP_DIR/${1#$ROOT/}.bak"
}
restore_from_latest_backup(){
  [[ -L "$BACKUP_LATEST_LINK" ]] && dir="$(readlink -f "$BACKUP_LATEST_LINK")" \
    || dir="$(ls -td $BACKUP_PARENT/greysync_* 2>/dev/null | head -n1 || true)"
  [[ -d "$dir" ]] || return 0
  find "$dir" -name "*.bak" | while read -r f; do
    cp -af "$f" "$ROOT/${f#$dir/%.bak}"
  done
}

# === HELPER: AUTH USE ===
ensure_auth_use(){ grep -q "Illuminate\\\\Support\\\\Facades\\\\Auth" "$1" || sed -i "1i use Illuminate\\Support\\Facades\\Auth;" "$1"; }

insert_guard(){
  local file="$1" regex="$2" guard="$3" marker="$4"
  grep -q "$marker" "$file" && return 0
  perl -0777 -pe "s/($regex)/\$1\n$guard/si" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

# === PATCH: File Manager ===
patch_file_manager(){
  local file="${TARGETS[FILE]}" aid="${1:-$ADMIN_ID_DEFAULT}"
  [[ -f "$file" ]] || return 0
  grep -q "GREYSYNC_PROTECT_FILE" "$file" && return 0
  backup_file "$file"; ensure_auth_use "$file"
  guard='        // GREYSYNC_PROTECT_FILE
        $u = Auth::user(); $s = ($request?->attributes->get("server"));
        if(!$u){abort(403,"Access denied");}
        if($u->id!='"$aid"' && (!$s || $s->owner_id!=$u->id)){abort(403,"Access denied");}'
  insert_guard "$file" 'public\s+function\s+(index|download|contents|store|rename|delete)\s*\{' "$guard" "GREYSYNC_PROTECT_FILE"
  php_check "$file" || cp -af "$BACKUP_DIR/${file#$ROOT/}.bak" "$file"
  log "FileController patched"
}

# === PATCH: User Delete ===
patch_user_delete(){
  local file="${TARGETS[USER]}" aid="${1:-$ADMIN_ID_DEFAULT}"
  [[ -f "$file" ]] || return 0
  grep -q "GREYSYNC_PROTECT_USER" "$file" && return 0
  backup_file "$file"; ensure_auth_use "$file"
  guard='        // GREYSYNC_PROTECT_USER
        $u = Auth::user(); if(!$u || $u->id!='"$aid"'){throw new Pterodactyl\Exceptions\DisplayException("Access denied");}'
  insert_guard "$file" 'public\s+function\s+delete\s*\([^)]*\)\s*\{' "$guard" "GREYSYNC_PROTECT_USER"
  log "UserController patched"
}

# === PATCH: Server Delete ===
patch_server_delete(){
  local file="${TARGETS[SERVER]}" aid="${1:-$ADMIN_ID_DEFAULT}"
  [[ -f "$file" ]] || return 0
  grep -q "GREYSYNC_PROTECT_SERVER" "$file" && return 0
  backup_file "$file"; ensure_auth_use "$file"
  guard='        // GREYSYNC_PROTECT_SERVER
        $u = Auth::user(); if($u && $u->id!='"$aid"'){throw new Pterodactyl\Exceptions\DisplayException("Access denied");}'
  insert_guard "$file" 'public\s+function\s+handle\s*\([^)]*\)\s*\{' "$guard" "GREYSYNC_PROTECT_SERVER"
  log "ServerDeletionService patched"
}

# === PATCH: Generic ===
insert_guard_generic(){
  local file="$1" tag="$2" aid="$3"
  [[ -f "$file" ]] || return 0
  grep -q "GREYSYNC_PROTECT_${tag}" "$file" && return 0
  backup_file "$file"; ensure_auth_use "$file"
  guard='        // GREYSYNC_PROTECT_'$tag'
        $u = Auth::user(); if(!$u || $u->id!='"$aid"'){abort(403,"Access denied");}'
  insert_guard "$file" 'public\s+function\s+(index|view|show|edit|update|create)\s*\{' "$guard" "GREYSYNC_PROTECT_${tag}"
  log "$tag patched"
}

# === FIX LARAVEL ===
fix_laravel(){
  cd "$ROOT" || return 1
  [[ -n "$PHP" ]] && { $PHP artisan config:clear; $PHP artisan cache:clear; $PHP artisan route:clear; $PHP artisan view:clear; }
  chown -R www-data:www-data "$ROOT" || true
  chmod -R 755 "$ROOT/storage" "$ROOT/bootstrap/cache" || true
  systemctl restart nginx >/dev/null 2>&1 || true
  php_fpm="$(systemctl list-units --type=service --all | grep -oE 'php[0-9]*\(\.[0-9]*\)?-fpm' | head -n1 || true)"
  [[ -n "$php_fpm" ]] && systemctl restart "$php_fpm" || true
}

# === INSTALL ALL ===
install_all(){
  IN_INSTALL=true
  mkdir -p "$BACKUP_DIR"; ln -sfn "$BACKUP_DIR" "$BACKUP_LATEST_LINK"
  local aid="${1:-$ADMIN_ID_DEFAULT}"
  echo '{ "status":"on" }' > "$STORAGE"
  echo '{ "superAdminId": '"$aid"' }' > "$IDPROTECT"
  patch_user_delete "$aid"; patch_server_delete "$aid"
  for tag in NODE NEST SETTINGS DATABASES LOCATIONS; do insert_guard_generic "${TARGETS[$tag]}" "$tag" "$aid"; done
  patch_file_manager "$aid"
  fix_laravel
  log "Protect installed (admin=$aid)"
  IN_INSTALL=false
}

# === UNINSTALL ===
uninstall_all(){
  rm -f "$STORAGE" "$IDPROTECT"
  restore_from_latest_backup
  fix_laravel
  log "Protect uninstalled"
}

# === ADMIN PATCH ===
admin_patch(){
  echo '{ "superAdminId": '"$1"' }' > "$IDPROTECT"
  install_all "$1"
}

# === MAIN ===
case "${1:-}" in
  install) install_all "${2:-$ADMIN_ID_DEFAULT}" ;;
  uninstall) uninstall_all ;;
  restore) restore_from_latest_backup ;;
  adminpatch) admin_patch "$2" ;;
  *) echo "Usage: $0 {install|uninstall|restore|adminpatch <id>}";;
esac

exit $EXIT_CODE
