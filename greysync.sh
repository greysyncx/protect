#!/usr/bin/env bash
# GreySync Protect v1.6.3 (Final Fix)
set -euo pipefail
IFS=$'\n\t'

ROOT="${ROOT:-/var/www/pterodactyl}"
BACKUP_PARENT="${BACKUP_PARENT:-$ROOT/greysync_backups}"
TIMESTAMP="$(date +%s)"
BACKUP_DIR="$BACKUP_PARENT/greysync_$TIMESTAMP"
BACKUP_LATEST_LINK="$BACKUP_PARENT/latest"
STORAGE="$ROOT/storage/app/greysync_protect.json"
IDPROTECT="$ROOT/storage/app/idprotect.json"
ADMIN_ID_DEFAULT=1
LOGFILE="/var/log/greysync_protect.log"
VERSION="1.6.3"

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
err(){ echo -e "${RED}ERROR:${RESET} $*" | tee -a "$LOGFILE" >&2; }
ok(){ echo -e "${GREEN}$*${RESET}" | tee -a "$LOGFILE"; }

php_bin(){ command -v php >/dev/null && echo php && return; for v in 8.3 8.2 8.1 8.0 7.4; do command -v php$v >/dev/null && echo php$v && return; done; }
PHP="$(php_bin || true)"
php_check_file(){ [[ -n "$PHP" && -f "$1" ]] && ! "$PHP" -l "$1" >/dev/null && return 1 || return 0; }

backup_file(){ [[ -f "$1" ]] || return 0; mkdir -p "$BACKUP_DIR/$(dirname "${1#$ROOT/}")"; cp -af "$1" "$BACKUP_DIR/${1#$ROOT/}.bak"; log "Backup: $1"; }
save_latest_symlink(){ mkdir -p "$BACKUP_PARENT"; ln -sfn "$(basename "$BACKUP_DIR")" "$BACKUP_LATEST_LINK"; }

restore_from_dir(){ [[ -d "$1" ]] || { err "No backup dir $1"; return 1; }; log "Restoring from $1"; find "$1" -type f -name "*.bak" | while read -r f; do rel="${f#$1/}"; tgt="$ROOT/${rel%.bak}"; mkdir -p "$(dirname "$tgt")"; cp -af "$f" "$tgt"; done; }

restore_from_latest_backup(){ local latest; latest="$(ls -td "$BACKUP_PARENT"/greysync_* 2>/dev/null | head -n1 || true)"; [[ -z "$latest" ]] && { err "No backups"; return 1; }; restore_from_dir "$latest"; }

ensure_auth_use(){ [[ -f "$1" ]] || return 0; grep -q "Illuminate\\Support\\Facades\\Auth" "$1" || sed -i '/^namespace/a use Illuminate\\Support\\Facades\\Auth;' "$1"; }

# --- PATCH FUNCTIONS ---
patch_user_delete(){
  local f="${TARGETS[USER]}"; local admin_id="$1"
  [[ -f "$f" ]] || { log "Skip UserController"; return 0; }
  grep -q "GREYSYNC_PROTECT_USER" "$f" && { log "Already patched USER"; return 0; }
  backup_file "$f"; ensure_auth_use "$f"
  awk -v admin="$admin_id" '
  BEGIN{in_sig=0;patched=0}
  {
    l=$0
    if(patched==0 && match(l,/public[[:space:]]+function[[:space:]]+delete/)){
      if(index(l,"{")>0){
        pre=substr(l,1,index(l,"{")); rem=substr(l,index(l,"{")+1)
        print pre
        print "        // GREYSYNC_PROTECT_USER"
        print "        $user = \Illuminate\Support\Facades\Auth::user();"
        print "        if (!$user || $user->id != " admin ") {"
        print "            throw new \Pterodactyl\Exceptions\DisplayException(\"❌ GreySync Protect: Tidak boleh hapus user\");"
        print "        }"
        if(length(rem)>0) print rem; patched=1; next
      } else {print l; in_sig=1; next}
    } else if(in_sig==1 && match(l,/^\s*{/)){
      print l
      print "        // GREYSYNC_PROTECT_USER"
      print "        $user = \Illuminate\Support\Facades\Auth::user();"
      print "        if (!$user || $user->id != " admin ") {"
      print "            throw new \Pterodactyl\Exceptions\DisplayException(\"❌ GreySync Protect: Tidak boleh hapus user\");"
      print "        }"
      in_sig=0; patched=1; next
    }
    print l
  }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  php_check_file "$f" || { err "UserController syntax error"; return 2; }
  ok "Patched: UserController"
}

patch_server_delete_service(){
  local f="${TARGETS[SERVER]}"; local admin_id="$1"
  [[ -f "$f" ]] || { log "Skip ServerDeletionService"; return 0; }
  grep -q "GREYSYNC_PROTECT_SERVER" "$f" && { log "Already patched SERVER"; return 0; }
  backup_file "$f"; ensure_auth_use "$f"
  awk -v admin="$admin_id" '
  BEGIN{in_sig=0;patched=0}
  {
    l=$0
    if(patched==0 && match(l,/public[[:space:]]+function[[:space:]]+handle/)){
      if(index(l,"{")>0){
        pre=substr(l,1,index(l,"{")); rem=substr(l,index(l,"{")+1)
        print pre
        print "        // GREYSYNC_PROTECT_SERVER"
        print "        $user = \Illuminate\Support\Facades\Auth::user();"
        print "        if ($user && $user->id != " admin ") {"
        print "            throw new \Pterodactyl\Exceptions\DisplayException(\"❌ GreySync Protect: Tidak boleh hapus server\");"
        print "        }"
        if(length(rem)>0) print rem; patched=1; next
      } else {print l; in_sig=1; next}
    } else if(in_sig==1 && match(l,/^\s*{/)){
      print l
      print "        // GREYSYNC_PROTECT_SERVER"
      print "        $user = \Illuminate\Support\Facades\Auth::user();"
      print "        if ($user && $user->id != " admin ") {"
      print "            throw new \Pterodactyl\Exceptions\DisplayException(\"❌ GreySync Protect: Tidak boleh hapus server\");"
      print "        }"
      in_sig=0; patched=1; next
    }
    print l
  }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  php_check_file "$f" || { err "ServerDeletionService syntax error"; return 2; }
  ok "Patched: ServerDeletionService"
}

# --- Laravel cleanup ---
fix_laravel(){
  cd "$ROOT" || return
  [[ -n "$PHP" ]] && { $PHP artisan config:clear || true; $PHP artisan cache:clear || true; $PHP artisan route:clear || true; $PHP artisan view:clear || true; }
  chown -R www-data:www-data "$ROOT" || true
  chmod -R 755 "$ROOT/storage" "$ROOT/bootstrap/cache" || true
  systemctl restart nginx || true
  php_fpm="$(systemctl list-units --type=service --all | grep -oE 'php[0-9.]*-fpm' | head -n1 || true)"
  [[ -n "$php_fpm" ]] && systemctl restart "$php_fpm" || true
  ok "Laravel caches cleared & services restarted"
}

# --- MAIN ---
install_all(){
  local admin_id="${1:-$ADMIN_ID_DEFAULT}"
  mkdir -p "$BACKUP_DIR"; save_latest_symlink
  log "Installing GreySync Protect v$VERSION (admin_id=$admin_id)"
  echo '{ "status":"on" }' > "$STORAGE"
  echo '{ "superAdminId": '"$admin_id"' }' > "$IDPROTECT"
  patch_user_delete "$admin_id"
  patch_server_delete_service "$admin_id"
  fix_laravel
  ok "✅ GreySync Protect installed. Backup in $BACKUP_DIR"
}

uninstall_all(){ rm -f "$STORAGE" "$IDPROTECT"; restore_from_latest_backup; fix_laravel; ok "✅ Uninstalled"; }
admin_patch(){ echo '{ "superAdminId": '"$1"' }' > "$IDPROTECT"; patch_user_delete "$1"; patch_server_delete_service "$1"; fix_laravel; ok "Admin ID updated → $1"; }

case "${1:-}" in
  install) install_all "${2:-$ADMIN_ID_DEFAULT}" ;;
  uninstall) uninstall_all ;;
  restore) restore_from_latest_backup ;;
  adminpatch) admin_patch "$2" ;;
  *) echo "Usage: $0 {install|uninstall|restore|adminpatch <id>}";;
esac
