#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

ROOT="${ROOT:-/var/www/pterodactyl}"
BACKUP_PARENT="${BACKUP_PARENT:-$ROOT/greysync_backups}"
TIMESTAMP="$(date +%s)"
BACKUP_DIR="${BACKUP_DIR:-$BACKUP_PARENT/greysync_$TIMESTAMP}"
BACKUP_LATEST_LINK="$BACKUP_PARENT/latest"
STORAGE="${STORAGE:-$ROOT/storage/app/greysync_protect.json}"
IDPROTECT="${IDPROTECT:-$ROOT/storage/app/idprotect.json}"
ADMIN_ID_DEFAULT="${ADMIN_ID_DEFAULT:-1}"
LOGFILE="${LOGFILE:-/var/log/greysync_protect.log}"

YARN_BUILD=false
VERSION="1.6.5-fix"
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

php_check_file(){ [[ -n "$PHP" && -f "$1" ]] && "$PHP" -l "$1" >/dev/null 2>&1; }

ensure_backup_parent(){ mkdir -p "$BACKUP_PARENT"; }
backup_file(){ [[ -f "$1" ]] && mkdir -p "$BACKUP_DIR/$(dirname "${1#$ROOT/}")" && cp -af "$1" "$BACKUP_DIR/${1#$ROOT/}.bak" && log "Backup: $1"; }
save_latest_symlink(){ mkdir -p "$BACKUP_PARENT" && ln -sfn "$(basename "$BACKUP_DIR")" "$BACKUP_LATEST_LINK"; }

restore_from_dir(){
  [[ -d "$1" ]] || { err "Backup dir not found: $1"; return 1; }
  log "Restoring from $1"
  find "$1" -type f -name "*.bak" | while read -r f; do
    rel="${f#$1/}"; target="$ROOT/${rel%.bak}"
    mkdir -p "$(dirname "$target")"; cp -af "$f" "$target"
    log "Restored: $target"
  done
}

restore_from_latest_backup(){
  local latest
  if [[ -L "$BACKUP_LATEST_LINK" ]]; then latest="$(readlink -f "$BACKUP_LATEST_LINK")"
  else latest="$(ls -td "$BACKUP_PARENT"/greysync_* 2>/dev/null | head -n1 || true)"
  fi
  [[ -z "$latest" || ! -d "$latest" ]] && { err "No backups found"; return 1; }
  restore_from_dir "$latest"
}

ensure_auth_use(){
  [[ -f "$1" ]] || return
  # insert Auth use only if not present
  grep -q "Illuminate\\\\Support\\\\Facades\\\\Auth" "$1" || \
  awk '/namespace/{print;print "use Illuminate\\Support\\Facades\\Auth;";next}1' "$1" > "$1.tmp" && mv "$1.tmp" "$1" && log "Inserted Auth use into $1"
}

# Insert guard into all public functions (admin-only guard).
insert_guard(){
  local file="$1" tag="$2" admin="$3"
  [[ -f "$file" ]] || { log "Skip (not found): $file"; return; }
  grep -q "GREYSYNC_PROTECT_${tag}" "$file" && { log "Already patched $tag"; return; }
  backup_file "$file"
  ensure_auth_use "$file"
  awk -v admin="$admin" -v tag="$tag" '
  BEGIN{patched=0}
  /public[[:space:]]+function/ && patched==0{
    print $0
    print "        // GREYSYNC_PROTECT_"tag
    print "        \\$user = Auth::user();"
    print "        if (!\\$user || \\$user->id != "admin") {"
    print "            abort(403, \"❌ GreySync Protect: Akses ditolak ("tag")\");"
    print "        }"
    patched=1; next
  }
  {print}
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  php_check_file "$file" || { err "Syntax error $file"; return 1; }
  ok "Patched: $file"
}

# FileController patch: owner OR admin allowed.
patch_file_manager(){
  local file="${TARGETS[FILE]}" admin="$1"
  [[ -f "$file" ]] || { log "Skip FileController (not found)"; return; }
  grep -q "GREYSYNC_PROTECT_FILE" "$file" && { log "Already patched FileController"; return; }

  backup_file "$file"
  ensure_auth_use "$file"

  # Insert snippet into every public function declaration
  awk -v admin="$admin" '
  {
    print $0
    if ($0 ~ /public[[:space:]]+function[[:space:]]+[A-Za-z0-9_]+\s*\([^)]*\)\s*\{/) {
      # inject owner/admin guard; escape $ with backslash for PHP output
      print "        // GREYSYNC_PROTECT_FILE"
      print "        \\$user = null;"
      print "        try { \\$user = Auth::user(); } catch (\\\\Throwable \\$e) {"
      print "            \\$user = (isset(\\$request) && method_exists(\\$request, \"user\")) ? \\$request->user() : null;"
      print "        }"
      print "        if (!\\$user) { abort(403, \"❌ GreySync Protect: Mau ngapain wok? ini server orang, bukan server mu\"); }"
      print ""
      print "        // try multiple ways to obtain server object"
      print "        \\$server = (isset(\\$server) && is_object(\\$server)) ? \\$server : null;"
      print "        if (!\\$server && isset(\\$request) && is_object(\\$request)) {"
      print "            \\$server = \\$request->attributes->get(\"server\") ?? (method_exists(\\$request, \"route\") ? \\$request->route(\"server\") : null);"
      print "        }"
      print "        if (!\\$server && isset(\\$request) && method_exists(\\$request, \"input\")) {"
      print "            \\$sid = \\$request->input(\"server_id\") ?? \\$request->input(\"id\") ?? null;"
      print "            if (\\$sid) {"
      print "                try { \\$server = \\\\Pterodactyl\\\\Models\\\\Server::find(\\$sid); } catch (\\\\Throwable \\$e) { \\$server = null; }"
      print "            }"
      print "        }"
      print "        \\$ownerId = (\\$server && is_object(\\$server)) ? (\\$server->owner_id ?? \\$server->user_id ?? null) : null;"
      print "        if (\\$user->id != " admin " && (!\\$ownerId || \\$ownerId != \\$user->id)) {"
      print "            // optional placeholder"
      print "            \\$placeholder = storage_path(\"app/greysync_protect_placeholder.png\");"
      print "            if (file_exists(\\$placeholder)) { return response()->file(\\$placeholder); }"
      print "            abort(403, \"❌ GreySync Protect: Mau ngapain wok? ini server orang, bukan server mu\");"
      print "        }"
    }
  }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"

  # validate
  if ! php_check_file "$file"; then
    err "FileController syntax error after patch; restoring backup"
    restore_from_dir "$BACKUP_DIR"
    return 1
  fi

  ok "Patched: FileController (owner or super-admin guard applied to public functions)."
}

# patch user delete safely (escape chars correctly)
patch_user_delete(){
  local file="${TARGETS[USER]}" admin="$1"
  [[ -f "$file" ]] || { log "Skip UserController"; return; }
  grep -q "GREYSYNC_PROTECT_USER" "$file" && { log "Already patched UserController"; return; }
  backup_file "$file"

  awk -v admin="$admin" '
  {
    print $0
    if ($0 ~ /public[[:space:]]+function[[:space:]]+delete\s*\([^)]*\)\s*\{/) {
      print "        // GREYSYNC_PROTECT_USER"
      print "        if (isset(\\$request) && \\$request->user()->id != " admin ") {"
      print "            throw new \\\\Pterodactyl\\\\Exceptions\\\\DisplayException(\"❌ GreySync Protect: Tidak boleh hapus user\");"
      print "        }"
    }
  }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"

  if ! php_check_file "$file"; then
    err "UserController syntax error after patch; restoring backup"
    restore_from_dir "$BACKUP_DIR"
    return 1
  fi

  ok "Patched: UserController"
}

# patch server deletion service safely
patch_server_delete_service(){
  local file="${TARGETS[SERVER]}" admin="$1"
  [[ -f "$file" ]] || { log "Skip ServerDeletionService"; return; }
  grep -q "GREYSYNC_PROTECT_SERVER" "$file" && { log "Already patched ServerDeletionService"; return; }
  backup_file "$file"
  ensure_auth_use "$file"

  awk -v admin="$admin" '
  {
    print $0
    if ($0 ~ /public[[:space:]]+function[[:space:]]+handle\s*\([^)]*\)\s*\{/) {
      print "        // GREYSYNC_PROTECT_SERVER"
      print "        \\$user = null;"
      print "        try { \\$user = Auth::user(); } catch (\\\\Throwable \\$e) {"
      print "            if (isset(\\$request) && method_exists(\\$request, \"user\")) { \\$user = \\$request->user(); }"
      print "        }"
      print "        if (\\$user && \\$user->id != " admin ") { throw new \\\\Pterodactyl\\\\Exceptions\\\\DisplayException(\"❌ GreySync Protect: Tidak boleh hapus server\"); }"
    }
  }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"

  if ! php_check_file "$file"; then
    err "ServerDeletionService syntax error after patch; restoring backup"
    restore_from_dir "$BACKUP_DIR"
    return 1
  fi

  ok "Patched: ServerDeletionService"
}

# helper to patch admin-only targets (USER, SERVER, NODE, NEST, SETTINGS, DATABASES, LOCATIONS)
patch_admin_targets(){
  local admin="$1"
  for tag in USER SERVER NODE NEST SETTINGS DATABASES LOCATIONS; do
    local f="${TARGETS[$tag]}"
    [[ -n "$f" ]] || continue
    insert_guard "$f" "$tag" "$admin"
  done
}

fix_laravel(){
  cd "$ROOT" || return 1
  command -v composer >/dev/null 2>&1 && composer dump-autoload -o --no-dev || true
  [[ -n "$PHP" ]] && { $PHP artisan config:clear || true; $PHP artisan cache:clear || true; }
  chown -R www-data:www-data "$ROOT" || true
  chmod -R 755 "$ROOT/storage" "$ROOT/bootstrap/cache" || true
  systemctl restart nginx || true
  fpm=$(systemctl list-units --type=service --all | grep -oE 'php[0-9]+(\.[0-9]+)?-fpm' | head -n1 || true)
  [[ -n "$fpm" ]] && systemctl restart "$fpm" || true
  ok "Laravel caches cleared & services restarted"
}

install_all(){
  IN_INSTALL=true
  ensure_backup_parent; mkdir -p "$BACKUP_DIR"; save_latest_symlink
  local admin="${1:-$ADMIN_ID_DEFAULT}"
  log "Installing GreySync Protect v$VERSION (admin_id=$admin)"
  mkdir -p "$(dirname "$STORAGE")"
  echo '{ "status":"on" }' > "$STORAGE"
  mkdir -p "$(dirname "$IDPROTECT")"
  echo '{ "superAdminId": '"$admin"' }' > "$IDPROTECT"

  # patch admin-only targets
  patch_admin_targets "$admin"
  # patch file manager (owner or admin)
  patch_file_manager "$admin"

  fix_laravel || true
  ok "✅ GreySync Protect installed. Backup in $BACKUP_DIR"
  IN_INSTALL=false
}

uninstall_all(){
  log "Uninstalling GreySync Protect"
  rm -f "$STORAGE" "$IDPROTECT"
  restore_from_latest_backup || err "No backups to restore"
  fix_laravel || true
  ok "✅ Uninstalled & restored"
}

admin_patch(){
  local newid="${1:-}"
  [[ -z "$newid" || ! "$newid" =~ ^[0-9]+$ ]] && { err "Usage: $0 adminpatch <id>"; return 1; }
  echo '{ "superAdminId": '"$newid"' }' > "$IDPROTECT"
  ok "SuperAdmin ID set -> $newid"
  patch_admin_targets "$newid"
  patch_file_manager "$newid"
  fix_laravel || true
}

trap '_on_err' ERR
_on_err(){ local rc=$?; [[ "$IN_INSTALL" = true ]] && { err "Error during install, rollback..."; restore_from_dir "$BACKUP_DIR" || true; fix_laravel || true; }; exit $rc; }

print_menu(){
  clear
  echo -e "${CYAN}GreySync Protect v$VERSION${RESET}"
  echo "1) Install Protect"
  echo "2) Uninstall Protect"
  echo "3) Restore Backup"
  echo "4) Set SuperAdmin ID"
  echo "5) Exit"
  read -p "Pilih opsi [1-5]: " opt
  case "$opt" in
    1) read -p "Admin ID (default $ADMIN_ID_DEFAULT): " aid; install_all "${aid:-$ADMIN_ID_DEFAULT}" ;;
    2) uninstall_all ;;
    3) restore_from_latest_backup && fix_laravel ;;
    4) read -p "SuperAdmin ID baru: " nid; admin_patch "$nid" ;;
    5) exit 0 ;;
    *) echo "Pilihan tidak valid"; exit 1 ;;
  esac
}

case "${1:-}" in
  "") print_menu ;;
  install) install_all "${2:-$ADMIN_ID_DEFAULT}" ;;
  uninstall) uninstall_all ;;
  restore) restore_from_latest_backup ;;
  adminpatch) admin_patch "$2" ;;
  *) err "Usage: $0 {install|uninstall|restore|adminpatch <id>}"; exit 1 ;;
esac

exit $EXIT_CODE
