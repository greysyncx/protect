#!/usr/bin/env bash
# GreySync Protect v1.6.9 (Auto-Fix Final)
# SuperAdmin = full access, RootAdmin = full access, ServerOwner = kelola file sendiri

set -euo pipefail
IFS=$'\n\t'

ROOT="${ROOT:-/var/www/pterodactyl}"
BACKUP_PARENT="${BACKUP_PARENT:-$ROOT/greysync_backups}"
TIMESTAMP="$(date +%s)"
BACKUP_DIR="$BACKUP_PARENT/greysync_$TIMESTAMP"
BACKUP_LATEST_LINK="$BACKUP_PARENT/latest"
STORAGE="$ROOT/storage/app/greysync_protect.json"
IDPROTECT="$ROOT/storage/app/idprotect.json"
ADMIN_ID_DEFAULT="${ADMIN_ID_DEFAULT:-1}"
LOGFILE="${LOGFILE:-/var/log/greysync_protect.log}"

VERSION="1.6.9"
IN_INSTALL=false
EXIT_CODE=0

mkdir -p "$BACKUP_PARENT" "$(dirname "$STORAGE")" "$(dirname "$IDPROTECT")" "$(dirname "$LOGFILE")" 2>/dev/null || true

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

RED="\033[1;31m"; GREEN="\033[1;32m"; CYAN="\033[1;36m"; YELLOW="\033[1;33m"; RESET="\033[0m"

log(){ echo -e "$(date -u +'%Y-%m-%dT%H:%M:%SZ') - $*" | tee -a "$LOGFILE"; }
err(){ echo -e "${RED}$*${RESET}" | tee -a "$LOGFILE" >&2; EXIT_CODE=1; }
ok(){ echo -e "${GREEN}$*${RESET}" | tee -a "$LOGFILE"; }
warn(){ echo -e "${YELLOW}$*${RESET}" | tee -a "$LOGFILE"; }

php_bin(){
  if command -v php >/dev/null 2>&1; then echo "php"; return; fi
  for v in 8.3 8.2 8.1 8.0 7.4; do
    if command -v "php$v" >/dev/null 2>&1; then echo "php$v"; return; fi
  done
}
PHP="$(php_bin || true)"

php_check_file(){ [[ -n "$PHP" && -f "$1" ]] || return 1; "$PHP" -l "$1" >/dev/null 2>&1; }

check_target_file(){
  local f="$1"; local tag="$2"
  if [[ ! -f "$f" ]]; then
    warn "❌ Target $tag tidak ditemukan: $f (skip patch)"
    return 1
  fi
}

backup_file(){
  local f="$1"; check_target_file "$f" "$(basename "$f")" || return 1
  mkdir -p "$BACKUP_DIR/$(dirname "${f#$ROOT/}")"
  cp -af "$f" "$BACKUP_DIR/${f#$ROOT/}.bak"
  log "📦 Backup: $f"
}

restore_from_dir(){
  [[ -d "$1" ]] || { err "Backup dir not found: $1"; return 1; }
  find "$1" -type f -name "*.bak" -print0 | while IFS= read -r -d '' f; do
    rel="${f#$1/}"; target="$ROOT/${rel%.bak}"
    mkdir -p "$(dirname "$target")"; cp -af "$f" "$target"
    log "♻️ Restored: $target"
  done
}

restore_from_latest_backup(){
  local latest="$(readlink -f "$BACKUP_LATEST_LINK" 2>/dev/null || ls -td "$BACKUP_PARENT"/greysync_* 2>/dev/null | head -n1 || true)"
  [[ -z "$latest" ]] && { err "❌ No backups available"; return 1; }
  restore_from_dir "$latest"
}

ensure_auth_use(){
  local f="$1"; [[ -f "$f" ]] || return
  grep -Fq "Illuminate\\Support\\Facades\\Auth" "$f" || \
    sed -i "$(grep -n '^namespace ' "$f" | head -n1 | cut -d: -f1)a use Illuminate\\Support\\Facades\\Auth;" "$f"
}

insert_guard_after_open_brace_multiline(){
  local f="$1"; local func="$2"; local guard="$3"; local marker="$4"
  grep -Fq "$marker" "$f" && { log "⚠️ Skip ($marker already)"; return; }
  perl -0777 -pe "s/($func)/\$1\n$guard/si" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# ========== PATCHES ==========
patch_file_manager(){
  local f="${TARGETS[FILE]}"; local aid="$1"; check_target_file "$f" "FILE" || return
  grep -Fq "GREYSYNC_PROTECT_FILE_SAFE" "$f" && return
  backup_file "$f"; ensure_auth_use "$f"
  local guard="
        // GREYSYNC_PROTECT_FILE_SAFE
        \$user = Auth::user();
        \$server = (isset(\$request) ? \$request->attributes->get('server') : null);
        if (!\$user) { abort(403, '❌ GreySync Protect: akses ditolak'); }
        if (\$user->id != $aid && empty(\$user->root_admin) && (!\$server || \$server->owner_id != \$user->id)) {
            abort(403, '❌ GreySync Protect: File bukan milikmu!');
        }"
  insert_guard_after_open_brace_multiline "$f" 'public\s+function\s+(store|rename|delete|compress|decompress|replace|move|copy)\s*\([^)]*\)\s*\{' "$guard" "GREYSYNC_PROTECT_FILE_SAFE"
  php_check_file "$f" || cp -af "$BACKUP_DIR/${f#$ROOT/}.bak" "$f"
  ok "✅ Patched FileController"
}

patch_user_delete(){
  local f="${TARGETS[USER]}"; local aid="$1"; check_target_file "$f" "USER" || return
  grep -Fq "GREYSYNC_PROTECT_USER" "$f" && return
  backup_file "$f"; ensure_auth_use "$f"
  local g="
        // GREYSYNC_PROTECT_USER
        \$user = Auth::user();
        if (!\$user || (\$user->id != $aid && empty(\$user->root_admin))) {
            throw new Pterodactyl\\Exceptions\\DisplayException('❌ GreySync Protect: Tidak boleh hapus user');
        }"
  insert_guard_after_open_brace_multiline "$f" 'public\s+function\s+delete\s*\([^)]*\)\s*\{' "$g" "GREYSYNC_PROTECT_USER"
  ok "✅ Patched UserController"
}

patch_server_delete_service(){
  local f="${TARGETS[SERVER]}"; local aid="$1"; check_target_file "$f" "SERVER" || return
  grep -Fq "GREYSYNC_PROTECT_SERVER" "$f" && return
  backup_file "$f"; ensure_auth_use "$f"
  local g="
        // GREYSYNC_PROTECT_SERVER
        \$user = Auth::user();
        if (\$user && (\$user->id != $aid && empty(\$user->root_admin))) {
            throw new Pterodactyl\\Exceptions\\DisplayException('❌ GreySync Protect: Tidak boleh hapus server');
        }"
  insert_guard_after_open_brace_multiline "$f" 'public\s+function\s+handle\s*\([^)]*\)\s*\{' "$g" "GREYSYNC_PROTECT_SERVER"
  ok "✅ Patched ServerDeletionService"
}

insert_guard_into_first_method(){
  local f="$1"; local tag="$2"; local aid="$3"; local m="$(echo "$4" | sed 's/ /|/g')"
  check_target_file "$f" "$tag" || return
  grep -Fq "GREYSYNC_PROTECT_${tag}" "$f" && return
  backup_file "$f"; ensure_auth_use "$f"
  local g="
        // GREYSYNC_PROTECT_$tag
        \$user = Auth::user();
        if (!\$user || (\$user->id != $aid && empty(\$user->root_admin))) {
            abort(403, '❌ GreySync Protect: Akses ditolak');
        }"
  insert_guard_after_open_brace_multiline "$f" "public\s+function\s+($m)\s*\([^)]*\)\s*\{" "$g" "GREYSYNC_PROTECT_${tag}"
  ok "✅ Patched $tag"
}

# ========== SYSTEM ==========
fix_laravel(){
  cd "$ROOT"
  [[ -n "$PHP" ]] && { $PHP artisan config:clear; $PHP artisan cache:clear; $PHP artisan route:clear; $PHP artisan view:clear; }
  chown -R www-data:www-data "$ROOT" >/dev/null 2>&1 || true
  chmod -R 755 "$ROOT/storage" "$ROOT/bootstrap/cache" >/dev/null 2>&1 || true
  systemctl restart nginx >/dev/null 2>&1 || true
  local php_fpm="$(systemctl list-units --type=service --all | grep -oE 'php[0-9]+(\.[0-9]+)?-fpm' | head -n1 || true)"
  [[ -n "$php_fpm" ]] && systemctl restart "$php_fpm"
  ok "♻️ Laravel cache cleared & services restarted"
}

install_all(){
  IN_INSTALL=true
  mkdir -p "$BACKUP_DIR"; ln -sfn "$BACKUP_DIR" "$BACKUP_LATEST_LINK"
  local aid="${1:-$ADMIN_ID_DEFAULT}"
  log "🚀 Installing v$VERSION (SuperAdmin=$aid)"
  echo '{ "status":"on" }' > "$STORAGE"
  echo "{ \"superAdminId\": $aid }" > "$IDPROTECT"
  patch_user_delete "$aid"
  patch_server_delete_service "$aid"
  for t in NODE NEST SETTINGS DATABASES LOCATIONS; do
    insert_guard_into_first_method "${TARGETS[$t]}" "$t" "$aid" "index view show edit update create"
  done
  patch_file_manager "$aid"
  fix_laravel
  ok "✅ GreySync Protect installed"
  IN_INSTALL=false
}

uninstall_all(){
  log "🗑️ Uninstalling GreySync Protect"
  rm -f "$STORAGE" "$IDPROTECT"
  restore_from_latest_backup
  fix_laravel
  ok "✅ Uninstalled"
}

admin_patch(){
  local nid="$1"
  [[ "$nid" =~ ^[0-9]+$ ]] || { err "❌ SuperAdmin ID harus numerik"; return 1; }
  echo "{ \"superAdminId\": $nid }" > "$IDPROTECT"
  patch_user_delete "$nid"
  patch_server_delete_service "$nid"
  for t in NODE NEST SETTINGS DATABASES LOCATIONS; do
    insert_guard_into_first_method "${TARGETS[$t]}" "$t" "$nid" "index view show edit update create"
  done
  patch_file_manager "$nid"
  fix_laravel
  ok "🔑 SuperAdmin ID updated"
}

trap '[[ "$IN_INSTALL" = true ]] && { err "Install failed, rollback"; restore_from_dir "$BACKUP_DIR"; fix_laravel; }; exit $?' ERR

# Menu
print_menu(){
  clear
  echo -e "${CYAN}GreySync Protect v$VERSION${RESET}"
  echo "1) Install"
  echo "2) Uninstall"
  echo "3) Restore backup"
  echo "4) Set SuperAdmin ID"
  echo "5) Exit"
  read -p "Pilih [1-5]: " o
  case "$o" in
    1) read -p "Admin ID (default $ADMIN_ID_DEFAULT): " aid; install_all "${aid:-$ADMIN_ID_DEFAULT}";;
    2) uninstall_all;;
    3) restore_from_latest_backup && fix_laravel;;
    4) read -p "SuperAdmin ID baru: " nid; admin_patch "$nid";;
    5) exit 0;;
    *) echo "Invalid";;
  esac
}

# CLI args
case "${1:-}" in
  install) install_all "${2:-$ADMIN_ID_DEFAULT}";;
  uninstall) uninstall_all;;
  restore) restore_from_latest_backup;;
  adminpatch) admin_patch "$2";;
  *) print_menu;;
esac
