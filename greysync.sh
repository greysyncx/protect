#!/usr/bin/env bash
# GreySync Protect - Minimal & Safe (v1.0)
# Usage: greysync_protect.sh install|uninstall|restore|adminpatch <id>
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

log(){ echo -e "$(date -u +'%Y-%m-%dT%H:%M:%SZ') - $*"; }
err(){ echo -e "ERROR: $*" >&2; }
ok(){ echo -e "OK: $*"; }

php_bin(){
  if command -v php >/dev/null 2>&1; then echo "php"; return; fi
  for v in 8.3 8.2 8.1 8.0 7.4; do
    if command -v "php$v" >/dev/null 2>&1; then echo "php$v"; return; fi
  done
  echo ""
}
PHP="$(php_bin || true)"

php_check_file(){
  local f="$1"
  if [[ -z "$PHP" ]]; then
    return 0
  fi
  if [[ -f "$f" ]]; then
    if ! "$PHP" -l "$f" >/dev/null 2>&1; then
      return 1
    fi
  fi
  return 0
}

ensure_backup_parent(){ mkdir -p "$BACKUP_PARENT"; }
backup_file(){
  local f="$1"
  [[ -f "$f" ]] || return 0
  mkdir -p "$BACKUP_DIR/$(dirname "${f#$ROOT/}")"
  cp -af "$f" "$BACKUP_DIR/${f#$ROOT/}.bak"
  log "Backup: $f -> $BACKUP_DIR/${f#$ROOT/}.bak"
}

save_latest_symlink(){ mkdir -p "$BACKUP_PARENT"; ln -sfn "$BACKUP_DIR" "$BACKUP_LATEST_LINK"; }

restore_from_dir(){
  local dir="$1"
  [[ -d "$dir" ]] || { err "Backup dir not found: $dir"; return 1; }
  log "Restoring from $dir"
  find "$dir" -type f -name "*.bak" -print0 | while IFS= read -r -d '' f; do
    rel="${f#$dir/}"
    target="$ROOT/${rel%.bak}"
    mkdir -p "$(dirname "$target")"
    cp -af "$f" "$target"
    log "Restored: $target"
  done
}

restore_from_latest_backup(){
  local latest
  if [[ -L "$BACKUP_LATEST_LINK" ]]; then
    latest="$(readlink -f "$BACKUP_LATEST_LINK")"
  else
    latest="$(ls -td "$BACKUP_PARENT"/greysync_* 2>/dev/null | head -n1 || true)"
  fi
  [[ -z "$latest" || ! -d "$latest" ]] && { err "No backups found"; return 1; }
  restore_from_dir "$latest"
}

# Insert guard by matching function signature and adding guard after opening brace
# Uses perl; guard must be escaped for perl replacement (we'll escape $ and \)
insert_guard_after_open_brace_multiline(){
  local file="$1"; local func_regex="$2"; local guard_raw="$3"; local marker="$4"
  [[ -f "$file" ]] || { log "not found: $file"; return 0; }
  if grep -Fq "$marker" "$file" 2>/dev/null; then
    log "already patched ($marker): $file"
    return 0
  fi

  backup_file "$file"

  # Escape backslashes and dollar signs for safe perl replacement
  local guard="${guard_raw//\\/\\\\}"   # \ -> \\\\
  guard="${guard//\$/\\\$}"             # $ -> \$

  # Use perl to insert guard after the method opening brace
  perl -0777 -pe "s/($func_regex)/\$1\n$guard/si" "$file" > "$file.tmp" && mv "$file.tmp" "$file" || {
    err "perl insertion failed for $file"
    cp -af "$BACKUP_DIR/${file#$ROOT/}.bak" "$file" 2>/dev/null || true
    return 1
  }
  return 0
}

ensure_auth_use(){
  local file="$1"
  [[ -f "$file" ]] || return 0
  if ! grep -Fq "Illuminate\\Support\\Facades\\Auth" "$file"; then
    ns_line="$(grep -n '^namespace ' "$file" 2>/dev/null | head -n1 | cut -d: -f1 || true)"
    if [[ -n "$ns_line" ]]; then
      sed -i "${ns_line}a\\
use Illuminate\\Support\\Facades\\Auth;
" "$file"
    else
      sed -i '1i\
use Illuminate\\Support\\Facades\\Auth;
' "$file" || true
    fi
    log "Inserted Auth use into $file"
  fi
}

# Guards (use abort so panel shows red custom message, not 500)
# Guard for file operations (dangerous methods)
file_guard_template() {
  local aid="$1"
  cat <<'EOF'
        // GREYSYNC_PROTECT_FILE_SAFE
        $user = Auth::user();
        $server = (isset($request) ? $request->attributes->get('server') : null);
        if (!$user) { abort(403, "❌ GreySync Protect: akses ditolak"); }
        if ($user->id != __ADMIN_ID__ && empty($user->root_admin) && (!$server || $server->owner_id != $user->id)) {
            abort(403, "❌ GreySync Protect: Mau ngapain wok? ini server orang, bukan server mu");
        }
EOF
}

# Guard for admin controllers (nodes/nests/settings/..)
admin_guard_template(){
  local aid="$1"
  cat <<'EOF'
        // GREYSYNC_PROTECT_ADMIN
        $user = Auth::user();
        if (!$user || ($user->id != __ADMIN_ID__ && empty($user->root_admin))) { abort(403, "❌ GreySync Protect: Akses ditolak"); }
EOF
}

# Patchers
patch_file_manager(){
  local file="${TARGETS[FILE]}"
  local admin_id="${1:-$ADMIN_ID_DEFAULT}"
  [[ -f "$file" ]] || { log "skip filecontroller not found"; return 0; }
  if grep -Fq "GREYSYNC_PROTECT_FILE_SAFE" "$file" 2>/dev/null; then log "filecontroller already patched"; return 0; fi

  ensure_auth_use "$file"
  guard="$(file_guard_template "$admin_id")"
  guard="${guard//__ADMIN_ID__/$admin_id}"
  func_re='public\s+function\s+(store|rename|delete|compress|decompress|replace|move|copy)\s*\([^\)]*\)\s*\{'
  insert_guard_after_open_brace_multiline "$file" "$func_re" "$guard" "GREYSYNC_PROTECT_FILE_SAFE"

  if ! php_check_file "$file"; then
    err "syntax error after patching FileController, restoring backup"
    cp -af "$BACKUP_DIR/${file#$ROOT/}.bak" "$file" 2>/dev/null || true
    return 1
  fi
  ok "Patched FileController"
}

patch_admin_controllers(){
  local admin_id="${1:-$ADMIN_ID_DEFAULT}"
  for tag in NODE NEST SETTINGS DATABASES LOCATIONS; do
    local file="${TARGETS[$tag]}"
    [[ -f "$file" ]] || { log "skip $tag not found"; continue; }
    if grep -Fq "GREYSYNC_PROTECT_${tag}" "$file" 2>/dev/null; then log "$tag already patched"; continue; fi
    ensure_auth_use "$file"
    guard="$(admin_guard_template "$admin_id")"
    guard="${guard//__ADMIN_ID__/$admin_id}"
    methods="index view show edit update create"
    methods_regex="$(echo "$methods" | sed 's/ /|/g')"
    func_re="public\\s+function\\s+($methods_regex)\\s*\\([^\\)]*\\)\\s*\\{"
    insert_guard_after_open_brace_multiline "$file" "$func_re" "$guard" "GREYSYNC_PROTECT_${tag}"
    if ! php_check_file "$file"; then
      err "syntax error after patching $file, restoring backup"
      cp -af "$BACKUP_DIR/${file#$ROOT/}.bak" "$file" 2>/dev/null || true
    else
      ok "Patched $tag"
    fi
  done
}

# For user delete and server deletion we will use abort as well (keamanan + avoid backslash problems)
patch_user_delete(){
  local file="${TARGETS[USER]}"
  local admin_id="${1:-$ADMIN_ID_DEFAULT}"
  [[ -f "$file" ]] || { log "skip usercontroller not found"; return 0; }
  if grep -Fq "GREYSYNC_PROTECT_USER" "$file" 2>/dev/null; then log "usercontroller already patched"; return 0; fi

  backup_file "$file"
  ensure_auth_use "$file"
  read -r -d '' guard <<'EOF' || true
        // GREYSYNC_PROTECT_USER
        $user = Auth::user();
        if (!$user || ($user->id != __ADMIN_ID__ && empty($user->root_admin))) { abort(403, "❌ GreySync Protect: Tidak boleh hapus user"); }
EOF
  guard="${guard//__ADMIN_ID__/$admin_id}"
  func_re='public\s+function\s+delete\s*\([^\)]*\)\s*\{'
  insert_guard_after_open_brace_multiline "$file" "$func_re" "$guard" "GREYSYNC_PROTECT_USER"
  php_check_file "$file" || { err "syntax error after patching UserController"; cp -af "$BACKUP_DIR/${file#$ROOT/}.bak" "$file" 2>/dev/null || true; return 1; }
  ok "Patched UserController"
}

patch_server_delete_service(){
  local file="${TARGETS[SERVER]}"
  local admin_id="${1:-$ADMIN_ID_DEFAULT}"
  [[ -f "$file" ]] || { log "skip serverdeletion not found"; return 0; }
  if grep -Fq "GREYSYNC_PROTECT_SERVER" "$file" 2>/dev/null; then log "ServerDeletionService already patched"; return 0; fi

  backup_file "$file"
  ensure_auth_use "$file"
  read -r -d '' guard <<'EOF' || true
        // GREYSYNC_PROTECT_SERVER
        $user = Auth::user();
        if ($user && ($user->id != __ADMIN_ID__ && empty($user->root_admin))) { abort(403, "❌ GreySync Protect: Tidak boleh hapus server"); }
EOF
  guard="${guard//__ADMIN_ID__/$admin_id}"
  func_re='public\s+function\s+handle\s*\([^\)]*\)\s*\{'
  insert_guard_after_open_brace_multiline "$file" "$func_re" "$guard" "GREYSYNC_PROTECT_SERVER"
  php_check_file "$file" || { err "syntax error after patching ServerDeletionService"; cp -af "$BACKUP_DIR/${file#$ROOT/}.bak" "$file" 2>/dev/null || true; return 1; }
  ok "Patched ServerDeletionService"
}

fix_laravel(){
  cd "$ROOT" || return 1
  if command -v composer >/dev/null 2>&1; then composer dump-autoload -o --no-dev >/dev/null 2>&1 || true; fi
  if [[ -n "$PHP" ]]; then
    $PHP artisan config:clear >/dev/null 2>&1 || true
    $PHP artisan cache:clear  >/dev/null 2>&1 || true
    $PHP artisan route:clear  >/dev/null 2>&1 || true
    $PHP artisan view:clear   >/dev/null 2>&1 || true
  fi
  chown -R www-data:www-data "$ROOT" >/dev/null 2>&1 || true
  chmod -R 755 "$ROOT/storage" "$ROOT/bootstrap/cache" >/dev/null 2>&1 || true
  systemctl restart nginx >/dev/null 2>&1 || true
  local php_fpm="$(systemctl list-units --type=service --all | grep -oE 'php[0-9]+(\.[0-9]+)?-fpm' | head -n1 || true)"
  [[ -n "$php_fpm" ]] && systemctl restart "$php_fpm" >/dev/null 2>&1 || true
  ok "Laravel caches cleared & services restarted"
}

install_all(){
  IN_INSTALL=true
  ensure_backup_parent
  mkdir -p "$BACKUP_DIR"
  save_latest_symlink

  local admin_id="${1:-$ADMIN_ID_DEFAULT}"
  log "Installing GreySync Protect (SuperAdmin=$admin_id)"

  echo '{ "status":"on" }' > "$STORAGE" 2>/dev/null || true
  echo '{ "superAdminId": '"$admin_id"' }' > "$IDPROTECT" 2>/dev/null || true

  patch_user_delete "$admin_id" || true
  patch_server_delete_service "$admin_id" || true
  patch_admin_controllers "$admin_id" || true
  patch_file_manager "$admin_id" || true

  fix_laravel || true

  ok "Installed. Backups in: $BACKUP_DIR"
  IN_INSTALL=false
}

uninstall_all(){
  log "Uninstalling: restoring latest backup"
  rm -f "$STORAGE" "$IDPROTECT" 2>/dev/null || true
  restore_from_latest_backup || { err "No backups to restore"; return 1; }
  fix_laravel || true
  ok "Uninstalled & restored from backup"
}

admin_patch(){
  local newid="${1:-}"
  if [[ -z "$newid" || ! "$newid" =~ ^[0-9]+$ ]]; then
    err "Usage: $0 adminpatch <numeric id>"
    return 1
  fi
  echo '{ "superAdminId": '"$newid"' }' > "$IDPROTECT" 2>/dev/null || true
  ok "SuperAdmin ID set -> $newid"
  install_all "$newid"
}

_on_error_trap(){
  local rc=$?
  if [[ "$IN_INSTALL" = true ]]; then
    err "Error during install. Attempting rollback from $BACKUP_DIR"
    restore_from_dir "$BACKUP_DIR" || err "Rollback failed"
    fix_laravel || true
  fi
  exit $rc
}
trap _on_error_trap ERR

print_menu(){
  echo "GreySync Protect - minimal installer"
  echo "Usage: $0 {install|uninstall|restore|adminpatch <id>}"
}

case "${1:-}" in
  install) install_all "${2:-$ADMIN_ID_DEFAULT}" ;;
  uninstall) uninstall_all ;;
  restore) restore_from_latest_backup ;;
  adminpatch) admin_patch "$2" ;;
  *) print_menu ;;
esac

exit 0
