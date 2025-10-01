#!/usr/bin/env bash
# GreySync Protect v1.6.4 (clean, safe)

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
ok(){ echo -e "${GREEN}$*${RESET}" | tee -a "$LOGFILE"; }

php_bin() {
  if command -v php >/dev/null 2>&1; then echo php; return 0; fi
  for v in 8.3 8.2 8.1 8.0 7.4; do
    if command -v "php$v" >/dev/null 2>&1; then echo "php$v"; return 0; fi
  done
  return 1
}
PHP="$(php_bin || true)"

php_check_file(){
  local f="$1"
  if [[ -n "$PHP" && -f "$f" ]]; then
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
save_latest_symlink(){ mkdir -p "$BACKUP_PARENT"; ln -sfn "$(basename "$BACKUP_DIR")" "$BACKUP_LATEST_LINK"; }

restore_from_dir(){
  local dir="$1"
  [[ -d "$dir" ]] || { err "Backup dir not found: $dir"; return 1; }
  log "Restoring from $dir"
  find "$dir" -type f -name "*.bak" | while read -r f; do
    rel="${f#$dir/}"; target="$ROOT/${rel%.bak}"
    mkdir -p "$(dirname "$target")"
    cp -af "$f" "$target"
    log "Restored: $target"
  done
}
restore_from_latest_backup(){
  local latest
  if [[ -L "$BACKUP_LATEST_LINK" ]]; then latest="$(readlink -f "$BACKUP_LATEST_LINK")"
  else latest="$(ls -td "$BACKUP_PARENT"/greysync_* 2>/dev/null | head -n1 || true)"; fi
  [[ -z "$latest" || ! -d "$latest" ]] && { err "No backups found"; return 1; }
  restore_from_dir "$latest"
}

ensure_auth_use(){
  local file="$1"
  [[ -f "$file" ]] || return 0
  if ! grep -q "Illuminate\\Support\\Facades\\Auth" "$file"; then
    awk 'BEGIN{ins=0}
      /^namespace[[:space:]]/ && ins==0 { print; print "use Illuminate\\\\Support\\\\Facades\\\\Auth;"; ins=1; next }
      { print }
    ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    log "Inserted Auth use into $file"
  fi
}

insert_guard_awklike(){
  local file="$1"; local methods="$2"; local guard="$3"; local marker="$4"
  [[ -f "$file" ]] || { log "Skip (not found): $file"; return 0; }
  if grep -q "$marker" "$file" 2>/dev/null; then log "Already patched ($marker): $file"; return 0; fi

  backup_file "$file"
  ensure_auth_use "$file"

  # build awk pattern to match any method from list
  local pat=""
  for m in $methods; do
    if [[ -n "$pat" ]]; then pat="$pat|$m"; else pat="$m"; fi
  done

  awk -v PAT="$pat" -v GUARD="$guard" -v MK="$marker" '
    BEGIN{ins=0; re="public[[:space:]]+function[[:space:]]+("PAT")[[:space:]]*\\([^)]*\\)[[:space:]]*\\{?";}
    {
      line=$0
      if (ins==0) {
        if (match(line, re)) {
          # if "{" on same line: split and insert guard after brace
          idx = index(line, "{")
          if (idx > 0) {
            before = substr(line, 1, idx)
            after = substr(line, idx+1)
            print before
            # print guard lines with indentation preserved (4 spaces)
            n=split(GUARD, garr, "\n")
            for (i=1;i<=n;i++) if (garr[i] != "") print garr[i]
            if (length(after) > 0) print after
            ins=1; next
          } else {
            print line
            # next non-empty line that is just "{" -> insert guard
            getline l2
            print l2
            if (match(l2,/^\s*\{/)) {
              n=split(GUARD, garr2, "\n")
              for (i=1;i<=n;i++) if (garr2[i] != "") print garr2[i]
              ins=1; next
            } else {
              # if not a brace line, continue printing rest normally
              # continue processing (but we already printed l2)
              next
            }
          }
        }
      }
      print line
    }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"

  # verify PHP syntax
  if ! php_check_file "$file"; then
    err "Syntax error after patching $file — restoring backup"
    cp -af "$BACKUP_DIR/${file#$ROOT/}.bak" "$file" 2>/dev/null || true
    return 2
  fi

  ok "Patched: $file"
  return 0
}

patch_file_manager(){
  local file="${TARGETS[FILE]}"; local admin_id="${1:-$ADMIN_ID_DEFAULT}"
  [[ -f "$file" ]] || { log "Skip FileController not found"; return 0; }
  local guard='        // GREYSYNC_PROTECT_FILE
        $user = Auth::user();
        $server = (isset($request) ? $request->attributes->get("server") : null);
        if (!$user) { abort(403, "❌ GreySync Protect: akses ditolak"); }
        if ($user->id != '"$admin_id"' && (!$server || $server->owner_id != $user->id)) {
            abort(403, "❌ GreySync Protect: Mau ngapain wok? ini server orang, bukan server mu");
        }'
  insert_guard_awklike "$file" "index download contents store rename delete" "$guard" "GREYSYNC_PROTECT_FILE"
}

patch_user_delete(){
  local file="${TARGETS[USER]}"; local admin_id="${1:-$ADMIN_ID_DEFAULT}"
  [[ -f "$file" ]] || { log "Skip UserController not found"; return 0; }
  local guard='        // GREYSYNC_PROTECT_USER
        $user = Auth::user();
        if (!$user || $user->id != '"$admin_id"') { throw new Pterodactyl\\Exceptions\\DisplayException("❌ GreySync Protect: Tidak boleh hapus user"); }'
  insert_guard_awklike "$file" "delete" "$guard" "GREYSYNC_PROTECT_USER"
}

patch_server_delete_service(){
  local file="${TARGETS[SERVER]}"; local admin_id="${1:-$ADMIN_ID_DEFAULT}"
  [[ -f "$file" ]] || { log "Skip ServerDeletionService not found"; return 0; }
  local guard='        // GREYSYNC_PROTECT_SERVER
        $user = Auth::user();
        if ($user && $user->id != '"$admin_id"') { throw new Pterodactyl\\Exceptions\\DisplayException("❌ GreySync Protect: Tidak boleh hapus server"); }'
  insert_guard_awklike "$file" "handle" "$guard" "GREYSYNC_PROTECT_SERVER"
}

insert_guard_into_first_method(){
  local file="$1"; local tag="$2"; local admin_id="$3"; local methods_csv="$4"
  [[ -f "$file" ]] || { log "Skip (not found): $file"; return 0; }
  local guard='        // GREYSYNC_PROTECT__TAG__
        $user = Auth::user();
        if (!$user || $user->id != __ADMIN_ID__) { abort(403, "❌ GreySync Protect: Akses ditolak"); }'
  guard="${guard//__ADMIN_ID__/$admin_id}"
  guard="${guard//__TAG__/$tag}"
  insert_guard_awklike "$file" "$methods_csv" "$guard" "GREYSYNC_PROTECT_${tag}"
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

  for tag in NODE NEST SETTINGS DATABASES LOCATIONS; do
    path="${TARGETS[$tag]}"
    insert_guard_into_first_method "$path" "$tag" "$admin_id" "index view show edit update create" || { err "Failed patching $tag"; return 2; }
  done

  patch_file_manager "$admin_id" || { err "Failed patching FileController"; return 2; }

  run_yarn_build || true
  fix_laravel || true

  ok "✅ GreySync Protect installed. Backups: $BACKUP_DIR"
  IN_INSTALL=false
}

uninstall_all(){
  log "Uninstalling GreySync Protect: restoring latest backup"
  rm -f "$STORAGE" "$IDPROTECT" 2>/dev/null || true
  if ! restore_from_latest_backup; then
    err "No backups to restore"
    return 1
  fi
  fix_laravel || true
  ok "✅ Uninstalled & restored"
}

admin_patch(){
  local newid="${1:-}"
  if [[ -z "$newid" || ! "$newid" =~ ^[0-9]+$ ]]; then err "Usage: $0 adminpatch <numeric id>"; return 1; fi
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

_on_error_trap(){
  local rc=$?
  if [[ "$IN_INSTALL" = true ]]; then
    err "Error during install. Rolling back from $BACKUP_DIR"
    restore_from_dir "$BACKUP_DIR" || err "Rollback failed"
    fix_laravel || true
  fi
  exit $rc
}
trap _on_error_trap ERR

print_menu(){
  clear
  echo "GreySync Protect v$VERSION"
  echo "1) Install"
  echo "2) Uninstall"
  echo "3) Restore"
  echo "4) Set SuperAdmin ID (adminpatch)"
  echo "5) Exit"
  read -p "Choice [1-5]: " opt
  case "$opt" in
    1) read -p "Admin ID (default $ADMIN_ID_DEFAULT): " aid; aid="${aid:-$ADMIN_ID_DEFAULT}"; install_all "$aid" ;;
    2) uninstall_all ;;
    3) restore_from_latest_backup && fix_laravel ;;
    4) read -p "New SuperAdmin ID: " nid; admin_patch "$nid" ;;
    5) exit 0 ;;
    *) echo "Invalid"; exit 1 ;;
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
