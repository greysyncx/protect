#!/usr/bin/env bash
# GreySync Protect v1.6.5 (Clean & Safe)

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
VERSION="1.6.5"
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

RED="\033[1;31m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; CYAN="\033[1;36m"; RESET="\033[0m"

log(){ echo -e "$(date -u +'%Y-%m-%dT%H:%M:%SZ') - $*" | tee -a "$LOGFILE"; }
err(){ echo -e "${RED}$*${RESET}" | tee -a "$LOGFILE" >&2; EXIT_CODE=1; }
ok(){ echo -e "${GREEN}$*${RESET}" | tee -a "$LOGFILE"; }

php_bin() {
  if command -v php >/dev/null 2>&1; then echo "php"; return 0; fi
  for v in 8.3 8.2 8.1 8.0 7.4; do
    if command -v "php$v" >/dev/null 2>&1; then echo "php$v"; return 0; fi
  done
  return 1
}
PHP="$(php_bin || true)"

php_check_file() {
  local f="$1"
  if [[ -n "$PHP" && -f "$f" ]]; then
    if ! "$PHP" -l "$f" >/dev/null 2>&1; then return 1; fi
  fi
  return 0
}

ensure_backup_parent(){ mkdir -p "$BACKUP_PARENT"; }
backup_file(){ local f="$1"; [[ -f "$f" ]] || return 0; mkdir -p "$BACKUP_DIR/$(dirname "${f#$ROOT/}")"; cp -af "$f" "$BACKUP_DIR/${f#$ROOT/}.bak"; log "Backup: $f -> $BACKUP_DIR/${f#$ROOT/}.bak"; }
save_latest_symlink(){ mkdir -p "$BACKUP_PARENT"; ln -sfn "$BACKUP_DIR" "$BACKUP_LATEST_LINK"; }

restore_from_dir(){
  local dir="$1"
  [[ -d "$dir" ]] || { err "Backup dir not found: $dir"; return 1; }
  log "Restoring from $dir"
  find "$dir" -type f -name "*.bak" -print0 | while IFS= read -r -d '' f; do
    rel="${f#$dir/}"; target="$ROOT/${rel%.bak}"
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

ensure_auth_use() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  if ! grep -Fq "Illuminate\\Support\\Facades\\Auth" "$file"; then
    ns_line="$(grep -n '^namespace ' "$file" 2>/dev/null | head -n1 | cut -d: -f1 || true)"
    if [[ -n "$ns_line" ]]; then
      sed -i "$ns_line a\\
use Illuminate\\Support\\Facades\\Auth;
" "$file"
      log "Inserted Auth use into $file"
    else
      sed -i '1 i\\
use Illuminate\\Support\\Facades\\Auth;
' "$file" || true
      log "Inserted Auth use (fallback) into $file"
    fi
  fi
}

insert_guard_after_open_brace_multiline() {
  local file="$1"; local func_regex="$2"; local guard="$3"; local marker="$4"
  [[ -f "$file" ]] || return 0
  if grep -Fq "$marker" "$file" 2>/dev/null; then
    log "Already contains marker $marker in $file, skipping"
    return 0
  fi
  local tmp
  tmp="$(mktemp "${file}.XXXXXX")" || tmp="$file.tmp"
  perl -0777 -pe '
    my $f = $ENV{"FUNC_RE"};
    my $g = $ENV{"GUARD"};
    $g =~ s/\$/\\\$/g;
    if ( $_ =~ /$f/si ) {
      s/($f)/$1\n$g/si;
    }
  ' FUNC_RE="$func_regex" GUARD="$guard" < "$file" > "$tmp"
  mv "$tmp" "$file"
}

patch_file_manager(){
  local file="${TARGETS[FILE]}"
  local admin_id="${1:-$ADMIN_ID_DEFAULT}"
  [[ -f "$file" ]] || { log "Skip (FileController not found): $file"; return 0; }
  if grep -q "GREYSYNC_PROTECT_FILE" "$file" 2>/dev/null; then log "Already patched: FileController"; return 0; fi

  backup_file "$file"
  ensure_auth_use "$file"

  read -r -d '' guard <<'EOF' || true
        // GREYSYNC_PROTECT_FILE
        $user = Auth::user();
        $server = (isset($request) ? $request->attributes->get("server") : null);
        if (!$user) { abort(403, "❌ GreySync Protect: akses ditolak"); }
        if ($user->id != __ADMIN_ID__ && (!$server || $server->owner_id != $user->id)) {
            abort(403, "❌ GreySync Protect: Mau ngapain wok? ini server orang, bukan server mu");
        }
EOF

  guard="${guard//__ADMIN_ID__/$admin_id}"
  func_re='public\s+function\s+(index|download|contents|store|rename|delete)\s*\([^\)]*\)\s*\{'
  marker='GREYSYNC_PROTECT_FILE'
  insert_guard_after_open_brace_multiline "$file" "$func_re" "$guard" "$marker"

  if ! php_check_file "$file"; then
    err "FileController syntax error after patch. Restoring backup"
    cp -af "$BACKUP_DIR/${file#$ROOT/}.bak" "$file" 2>/dev/null || true
    return 2
  fi

  ok "Patched: FileController (file access longgar)"
  return 0
}

patch_user_delete() {
  local file="${TARGETS[USER]}"
  local admin_id="${1:-$ADMIN_ID_DEFAULT}"
  [[ -f "$file" ]] || { log "Skip (UserController not found)"; return 0; }
  if grep -q "GREYSYNC_PROTECT_USER" "$file" 2>/dev/null; then log "Already patched: UserController"; return 0; fi

  backup_file "$file"
  ensure_auth_use "$file"

  read -r -d '' guard <<'EOF' || true
        // GREYSYNC_PROTECT_USER
        $user = Auth::user();
        if (!$user || $user->id != __ADMIN_ID__) { throw new Pterodactyl\\Exceptions\\DisplayException("❌ GreySync Protect: Tidak boleh hapus user"); }
EOF

  guard="${guard//__ADMIN_ID__/$admin_id}"
  func_re='public\s+function\s+delete\s*\([^\)]*\)\s*\{'
  marker='GREYSYNC_PROTECT_USER'
  insert_guard_after_open_brace_multiline "$file" "$func_re" "$guard" "$marker"

  if ! php_check_file "$file"; then
    err "UserController syntax error after patch. Restoring backup"
    cp -af "$BACKUP_DIR/${file#$ROOT/}.bak" "$file" 2>/dev/null || true
    return 2
  fi

  ok "Patched: UserController (delete)"
  return 0
}

patch_server_delete_service(){
  local file="${TARGETS[SERVER]}"
  local admin_id="${1:-$ADMIN_ID_DEFAULT}"
  [[ -f "$file" ]] || { log "Skip (ServerDeletionService not found)"; return 0; }
  if grep -q "GREYSYNC_PROTECT_SERVER" "$file" 2>/dev/null; then log "Already patched: ServerDeletionService"; return 0; fi

  backup_file "$file"
  ensure_auth_use "$file"

  read -r -d '' guard <<'EOF' || true
        // GREYSYNC_PROTECT_SERVER
        $user = Auth::user();
        if ($user && $user->id != __ADMIN_ID__) { throw new Pterodactyl\\Exceptions\\DisplayException("❌ GreySync Protect: Tidak boleh hapus server"); }
EOF

  guard="${guard//__ADMIN_ID__/$admin_id}"
  func_re='public\s+function\s+handle\s*\([^\)]*\)\s*\{'
  marker='GREYSYNC_PROTECT_SERVER'
  insert_guard_after_open_brace_multiline "$file" "$func_re" "$guard" "$marker"

  if ! php_check_file "$file"; then
    err "ServerDeletionService syntax error after patch. Restoring backup"
    cp -af "$BACKUP_DIR/${file#$ROOT/}.bak" "$file" 2>/dev/null || true
    return 2
  fi

  ok "Patched: ServerDeletionService (handle)"
  return 0
}

insert_guard_into_first_method(){
  local file="$1"; local tag="$2"; local admin_id="$3"; local methods_csv="$4"
  [[ -f "$file" ]] || { log "Skip (not found): $file"; return 0; }
  if grep -q "GREYSYNC_PROTECT_${tag}" "$file" 2>/dev/null; then log "Already patched ($tag): $file"; return 0; fi
  backup_file "$file"
  ensure_auth_use "$file"

  # build regex from methods_csv
  methods_regex="$(echo "$methods_csv" | sed 's/ /|/g')"
  func_re="public\\s+function\\s+($methods_regex)\\s*\\([^\\)]*\\)\\s*\\{"
  read -r -d '' guard <<'EOF' || true
        // GREYSYNC_PROTECT__TAG__
        $user = Auth::user();
        if (!$user || $user->id != __ADMIN_ID__) { abort(403, "❌ GreySync Protect: Akses ditolak"); }
EOF
  guard="${guard//__ADMIN_ID__/$admin_id}"
  guard="${guard//__TAG__/$tag}"
  marker="GREYSYNC_PROTECT_${tag}"
  insert_guard_after_open_brace_multiline "$file" "$func_re" "$guard" "$marker"

  if ! php_check_file "$file"; then
    err "Syntax error after patching $file"
    cp -af "$BACKUP_DIR/${file#$ROOT/}.bak" "$file" 2>/dev/null || true
    return 2
  fi
  ok "Patched: $file"
  return 0
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
  if systemctl list-unit-files | grep -q nginx.service; then systemctl restart nginx >/dev/null 2>&1 || true; fi
  php_fpm="$(systemctl list-units --type=service --all | grep -oE 'php[0-9]+(\.[0-9]+)?-fpm' | head -n1 || true)"
  [[ -n "$php_fpm" ]] && systemctl restart "$php_fpm" >/dev/null 2>&1 || true
  ok "Laravel caches cleared & services restarted"
}

run_yarn_build(){
  [[ "$YARN_BUILD" = true && -f "$ROOT/package.json" ]] || return 0
  log "Running yarn build..."
  if ! command -v node >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y nodejs npm >/dev/null 2>&1 || true
    npm i -g yarn >/dev/null 2>&1 || true
  fi
  pushd "$ROOT" >/dev/null 2>&1
  yarn install --silent >/dev/null 2>&1 || true
  if yarn run | grep -q "build:production"; then
    NODE_OPTIONS="${NODE_OPTIONS:-}" yarn build:production --silent --progress || err "yarn build failed"
  elif [[ -f node_modules/.bin/webpack ]]; then
    NODE_OPTIONS="${NODE_OPTIONS:-}" ./node_modules/.bin/webpack --mode production --silent --progress || err "webpack build failed"
  else
    log "No build script found, skipping"
  fi
  popd >/dev/null 2>&1
  ok "Frontend build finished"
}

install_all(){
  IN_INSTALL=true
  ensure_backup_parent
  mkdir -p "$BACKUP_DIR"
  save_latest_symlink

  local admin_id="${1:-$ADMIN_ID_DEFAULT}"
  log "Installing GreySync Protect v$VERSION (admin_id=$admin_id)"
  echo '{ "status":"on" }' > "$STORAGE" 2>/dev/null || true
  echo '{ "superAdminId": '"$admin_id"' }' > "$IDPROTECT" 2>/dev/null || true

  patch_user_delete "$admin_id" || { err "Failed patching user"; return 2; }
  patch_server_delete_service "$admin_id" || { err "Failed patching server service"; return 2; }

  # Flexible targets
  for tag in NODE NEST SETTINGS DATABASES LOCATIONS; do
    path="${TARGETS[$tag]}"
    insert_guard_into_first_method "$path" "$tag" "$admin_id" "index view show edit update create" || { err "Failed patching $tag"; return 2; }
  done

  # File manager (longgar)
  patch_file_manager "$admin_id" || { err "Failed patching FileController"; return 2; }

  run_yarn_build || true
  fix_laravel || true

  ok "✅ GreySync Protect installed. Backups stored in: $BACKUP_DIR"
  IN_INSTALL=false
}

uninstall_all(){
  log "Uninstalling GreySync Protect: will attempt to restore latest backup"
  rm -f "$STORAGE" "$IDPROTECT" 2>/dev/null || true
  if ! restore_from_latest_backup; then
    err "No backups to restore"
    return 1
  fi
  fix_laravel || true
  ok "✅ Uninstalled & restored from latest backup"
}

admin_patch(){
  local newid="${1:-}"
  if [[ -z "$newid" || ! "$newid" =~ ^[0-9]+$ ]]; then
    err "Usage: $0 adminpatch <numeric id>"
    return 1
  fi
  echo '{ "superAdminId": '"$newid"' }' > "$IDPROTECT"
  ok "SuperAdmin ID set -> $newid"
  # re-run patches with new id
  patch_user_delete "$newid" || true
  patch_server_delete_service "$newid" || true
  for tag in NODE NEST SETTINGS DATABASES LOCATIONS; do
    path="${TARGETS[$tag]}"
    insert_guard_into_first_method "$path" "$tag" "$newid" "index view show edit update create" || true
  done
  patch_file_manager "$newid" || true
  fix_laravel || true
}

_on_error_trap() {
  local rc=$?
  if [[ "$IN_INSTALL" = true ]]; then
    err "Error occurred during install. Attempting rollback from $BACKUP_DIR"
    restore_from_dir "$BACKUP_DIR" || err "Rollback failed or incomplete"
    fix_laravel || true
  fi
  exit $rc
}
trap _on_error_trap ERR

print_menu() {
  clear
  echo -e "${CYAN}====================================${RESET}"
  echo -e "${CYAN}  GreySync Protect v$VERSION (Safe)${RESET}"
  echo -e "${CYAN}====================================${RESET}"
  echo "1) Install Protect (apply patches & build)"
  echo "2) Uninstall Protect (restore latest backup)"
  echo "3) Restore from latest backup"
  echo "4) Set SuperAdmin ID & apply (adminpatch)"
  echo "5) Exit"
  read -p "Pilih opsi [1-5]: " opt
  case "$opt" in
    1)
      read -p "Masukkan admin ID (default $ADMIN_ID_DEFAULT): " aid
      aid="${aid:-$ADMIN_ID_DEFAULT}"
      install_all "$aid"
      ;;
    2) uninstall_all ;;
    3) restore_from_latest_backup && fix_laravel ;;
    4)
      read -p "Masukkan SuperAdmin ID baru: " nid
      if [[ -z "$nid" ]] || ! [[ "$nid" =~ ^[0-9]+$ ]]; then
        err "SuperAdmin ID harus numerik"
      else
        admin_patch "$nid"
      fi
      ;;
    5) exit 0 ;;
    *) echo "Pilihan tidak valid"; exit 1 ;;
  esac
}

if [[ "${1:-}" == "" ]]; then
  print_menu
  exit 0
fi

case "$1" in
  install) install_all "${2:-$ADMIN_ID_DEFAULT}" ;;
  uninstall) uninstall_all ;;
  restore) restore_from_latest_backup ;;
  adminpatch) admin_patch "$2" ;;
  *) err "Usage: $0 {install|uninstall|restore|adminpatch <id>}"; exit 1 ;;
esac

exit $EXIT_CODE
