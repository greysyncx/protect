#!/usr/bin/env bash
# GreySync Protect v1.6.4-clean

set -euo pipefail
IFS=$'\n\t'

ROOT="${ROOT:-/var/www/pterodactyl}"
BACKUP_PARENT="$ROOT/greysync_backups"
TIMESTAMP="$(date +%s)"
BACKUP_DIR="$BACKUP_PARENT/greysync_$TIMESTAMP"
BACKUP_LATEST_LINK="$BACKUP_PARENT/latest"
STORAGE="$ROOT/storage/app/greysync_protect.json"
IDPROTECT="$ROOT/storage/app/idprotect.json"
ADMIN_ID_DEFAULT="${ADMIN_ID_DEFAULT:-1}"
LOGFILE="/var/log/greysync_protect.log"

VERSION="1.6.4"
IN_INSTALL=false
EXIT_CODE=0

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

RED="\033[1;31m"; GREEN="\033[1;32m"; CYAN="\033[1;36m"; RESET="\033[0m"

log(){ echo -e "$(date -u +'%Y-%m-%dT%H:%M:%SZ') - $*" | tee -a "$LOGFILE"; }
err(){ echo -e "${RED}$*${RESET}" | tee -a "$LOGFILE" >&2; EXIT_CODE=1; }
ok(){  echo -e "${GREEN}$*${RESET}" | tee -a "$LOGFILE"; }

php_bin(){ command -v php >/dev/null 2>&1 && echo "php" || for v in 8.3 8.2 8.1 8.0 7.4; do command -v php$v >/dev/null 2>&1 && echo "php$v" && return; done; }
PHP="$(php_bin || true)"

backup_file(){ [[ -f "$1" ]] && mkdir -p "$BACKUP_DIR/$(dirname "${1#$ROOT/}")" && cp -af "$1" "$BACKUP_DIR/${1#$ROOT/}.bak" && log "Backup: $1"; }
restore_from_dir(){ [[ -d "$1" ]] || return 1; find "$1" -type f -name "*.bak" | while read -r f; do rel="${f#$1/}"; cp -af "$f" "$ROOT/${rel%.bak}"; done; }
restore_from_latest_backup(){ latest="$(ls -td "$BACKUP_PARENT"/greysync_* 2>/dev/null | head -n1 || true)"; [[ -n "$latest" ]] && restore_from_dir "$latest"; }

ensure_auth_use(){ grep -q "Illuminate\\\\Support\\\\Facades\\\\Auth" "$1" || awk '/namespace/{print;print "use Illuminate\\Support\\Facades\\Auth;";next}1' "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }

insert_guard(){
  local file="$1" tag="$2" admin="$3"
  [[ -f "$file" ]] || return
  grep -q "GREYSYNC_PROTECT_${tag}" "$file" && return
  backup_file "$file"
  awk -v admin="$admin" -v tag="$tag" '
  BEGIN{patched=0}
  /public[[:space:]]+function/ && patched==0{
    print $0
    print "        // GREYSYNC_PROTECT_"tag
    print "        $user = Auth::user() ?: Auth::guard(\"client\")->user();"
    print "        if (!$user || $user->id != "admin") { abort(403, \"❌ GreySync Protect: Akses ditolak\"); }"
    patched=1; next
  }{print}
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  ok "Patched: $file ($tag)"
}

patch_file_manager(){
  local file="${TARGETS[FILE]}" admin="$1"
  [[ -f "$file" ]] || return
  grep -q "GREYSYNC_PROTECT_FILE" "$file" && return
  backup_file "$file"; ensure_auth_use "$file"
  awk -v admin="$admin" '
  BEGIN{patched=0}
  /public[[:space:]]+function[[:space:]]+(index|download|contents|store|rename|delete)/ && patched==0{
    print $0
    print "        // GREYSYNC_PROTECT_FILE"
    print "        $user = Auth::user() ?: Auth::guard(\"client\")->user();"
    print "        if (!isset($request) && method_exists($this, \"getRequest\")) { $request = $this->getRequest(); }"
    print "        $server = (isset($request)?$request->attributes->get(\"server\"):null);"
    print "        if (!$user) { abort(403, \"❌ GreySync Protect: akses ditolak\"); }"
    print "        if ($user->id != " admin " && (!$server || $server->owner_id != $user->id)) {"
    print "            $placeholder = storage_path(\"app/greysync_protect_placeholder.png\");"
    print "            if (file_exists($placeholder)) { return response()->file($placeholder); }"
    print "            abort(403, \"❌ GreySync Protect: Mau ngapain wok? ini server orang, bukan server mu\");"
    print "        }"
    patched=1; next
  }{print}
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  ok "Patched: FileController"
}

patch_user_delete(){
  local file="${TARGETS[USER]}" admin="$1"
  [[ -f "$file" ]] || return
  grep -q "GREYSYNC_PROTECT_USER" "$file" && return
  backup_file "$file"
  awk -v admin="$admin" '
  /public[[:space:]]+function[[:space:]]+delete/ {
    print $0
    print "        // GREYSYNC_PROTECT_USER"
    print "        if ($request->user()->id != "admin") { throw new Pterodactyl\\Exceptions\\DisplayException(\"❌ GreySync Protect: Tidak boleh hapus user\"); }"
    next
  }{print}
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  ok "Patched: UserController"
}

patch_server_delete(){
  local file="${TARGETS[SERVER]}" admin="$1"
  [[ -f "$file" ]] || return
  grep -q "GREYSYNC_PROTECT_SERVER" "$file" && return
  backup_file "$file"; ensure_auth_use "$file"
  awk -v admin="$admin" '
  /public[[:space:]]+function[[:space:]]+handle/ {
    print $0
    print "        // GREYSYNC_PROTECT_SERVER"
    print "        $user = Auth::user() ?: Auth::guard(\"client\")->user();"
    print "        if ($user && $user->id != "admin") { throw new Pterodactyl\\Exceptions\\DisplayException(\"❌ GreySync Protect: Tidak boleh hapus server\"); }"
    next
  }{print}
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  ok "Patched: ServerDeletionService"
}

fix_laravel(){
  cd "$ROOT" || return
  [[ -n "$PHP" ]] && { $PHP artisan config:clear || true; $PHP artisan cache:clear || true; }
  chown -R www-data:www-data "$ROOT" || true
  chmod -R 755 "$ROOT/storage" "$ROOT/bootstrap/cache" || true
  systemctl restart nginx || true
  fpm=$(systemctl list-units --type=service --all | grep -oE 'php[0-9]+(\.[0-9]+)?-fpm' | head -n1 || true)
  [[ -n "$fpm" ]] && systemctl restart "$fpm"
  ok "Laravel caches cleared"
}

install_all(){
  IN_INSTALL=true
  mkdir -p "$BACKUP_DIR"; ln -sfn "$(basename "$BACKUP_DIR")" "$BACKUP_LATEST_LINK"
  local admin="${1:-$ADMIN_ID_DEFAULT}"
  log "Installing GreySync Protect v$VERSION (admin_id=$admin)"
  echo '{ "status":"on" }' > "$STORAGE"
  echo '{ "superAdminId": '"$admin"' }' > "$IDPROTECT"
  patch_user_delete "$admin"
  patch_server_delete "$admin"
  for tag in NODE NEST SETTINGS DATABASES LOCATIONS; do insert_guard "${TARGETS[$tag]}" "$tag" "$admin"; done
  patch_file_manager "$admin"
  fix_laravel
  ok "✅ Installed Protect. Backup in $BACKUP_DIR"
  IN_INSTALL=false
}

uninstall_all(){ rm -f "$STORAGE" "$IDPROTECT"; restore_from_latest_backup; fix_laravel; ok "✅ Uninstalled & restored"; }
admin_patch(){ echo '{ "superAdminId": '"$1"' }' > "$IDPROTECT"; install_all "$1"; }

trap '_on_err' ERR
_on_err(){ [[ "$IN_INSTALL" = true ]] && { err "Error during install, rollback..."; restore_from_dir "$BACKUP_DIR"; fix_laravel; }; exit 1; }

case "${1:-}" in
  install) install_all "${2:-$ADMIN_ID_DEFAULT}" ;;
  uninstall) uninstall_all ;;
  restore) restore_from_latest_backup && fix_laravel ;;
  adminpatch) admin_patch "$2" ;;
  *) echo -e "${CYAN}GreySync Protect v$VERSION${RESET}
Usage:
  $0 install [admin_id]
  $0 uninstall
  $0 restore
  $0 adminpatch <id>" ;;
esac

exit $EXIT_CODE
