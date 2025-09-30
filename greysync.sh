#!/usr/bin/env bash
# GreySync Protect (Safe) v1.6.3
# Single-file installer/patcher for Pterodactyl controllers with safe rollback & build.
# Adds file-manager protection: users can access files only on their own servers (admin can access all).
# Usage:
#   sudo ./greysync.sh install [ADMIN_ID]
#   sudo ./greysync.sh uninstall
#   sudo ./greysync.sh restore
#   sudo ./greysync.sh adminpatch <id>
# Or run without args for interactive menu.

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
YARN_BUILD=true   # set to false to skip yarn build

VERSION="1.6.3"
IN_INSTALL=false
EXIT_CODE=0

# Targets (TAG -> path)
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

# Colors
RED="\033[1;31m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; CYAN="\033[1;36m"; RESET="\033[0m"

log(){ echo -e "$(date -u +'%Y-%m-%dT%H:%M:%SZ') - $*" | tee -a "$LOGFILE"; }
err(){ echo -e "${RED}$*${RESET}" | tee -a "$LOGFILE" >&2; EXIT_CODE=1; }
ok(){ echo -e "${GREEN}$*${RESET}" | tee -a "$LOGFILE"; }

# find php binary
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
    if ! "$PHP" -l "$f" >/dev/null 2>&1; then
      return 1
    fi
  fi
  return 0
}

ensure_backup_parent(){ mkdir -p "$BACKUP_PARENT"; }
backup_file(){ local f="$1"; [[ -f "$f" ]] || return 0; mkdir -p "$BACKUP_DIR/$(dirname "${f#$ROOT/}")"; cp -af "$f" "$BACKUP_DIR/${f#$ROOT/}.bak"; log "Backup: $f"; }
save_latest_symlink(){ mkdir -p "$BACKUP_PARENT"; ln -sfn "$(basename "$BACKUP_DIR")" "$BACKUP_LATEST_LINK"; }

restore_from_dir(){
  local dir="$1"
  [[ -d "$dir" ]] || { err "Backup dir not found: $dir"; return 1; }
  log "Restoring from $dir"
  find "$dir" -type f -name "*.bak" | while read -r f; do
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
  if ! grep -q "Illuminate\\\\Support\\\\Facades\\\\Auth" "$file"; then
    awk '
    BEGIN{ins=0}
    /namespace[[:space:]]+[A-Za-z0-9_\\\]+;/ && ins==0 {
      print $0
      print "use Illuminate\\Support\\Facades\\Auth;"
      ins=1; next
    }
    { print }
    ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    log "Inserted Auth use into $file"
  fi
}

insert_guard_into_first_method(){
  local file="$1"; local tag="$2"; local admin_id="$3"; local methods_csv="$4"
  [[ -f "$file" ]] || { log "Skip (not found): $file"; return 0; }
  if grep -q "GREYSYNC_PROTECT_${tag}" "$file"; then log "Already patched $tag"; return 0; fi
  backup_file "$file"
  awk -v admin="$admin_id" -v tag="$tag" -v methods_csv="$methods_csv" '
  BEGIN{ split(methods_csv, mlist, " "); in_sig=0; patched=0 }
  {
    line=$0
    if (patched==0) {
      if (in_sig==1 && match(line,/^\s*{/)) {
        print line
        print "        // GREYSYNC_PROTECT_"tag
        print "        $user = Auth::user();"
        print "        if (!$user || $user->id != " admin ") { abort(403, \"❌ GreySync Protect: Akses ditolak\"); }"
        in_sig=0; patched=1; next
      }
      for (i in mlist) {
        pat = "public[[:space:]]+function[[:space:]]+"mlist[i]"[[:space:]]*\\([^)]*\\)[[:space:]]*\\{?"
        if (match(line,pat)) {
          if (index(line,"{")>0) {
            before = substr(line,1,index(line,"{"))
            rem = substr(line,index(line,"{")+1)
            print before
            print "        // GREYSYNC_PROTECT_"tag
            print "        $user = Auth::user();"
            print "        if (!$user || $user->id != " admin ") { abort(403, \"❌ GreySync Protect: Akses ditolak\"); }"
            if (length(rem)>0) print rem
            patched=1; next
          } else { print line; in_sig=1; next }
        }
      }
    }
    print line
  }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  php_check_file "$file" || { err "Syntax error $file"; cp -af "$BACKUP_DIR/${file#$ROOT/}.bak" "$file" || true; return 2; }
  ok "Patched: $file"
}

# File manager patch (longgar)
patch_file_manager(){
  local file="${TARGETS[FILE]}"; local admin_id="${1:-$ADMIN_ID_DEFAULT}"
  [[ -f "$file" ]] || { log "Skip (FileController not found)"; return 0; }
  if grep -q "GREYSYNC_PROTECT_FILE" "$file"; then log "Already patched: FileController"; return 0; fi
  backup_file "$file"; ensure_auth_use "$file"
  awk -v admin="$admin_id" '
  BEGIN{ in_sig=0; patched=0 }
  {
    line=$0
    if (patched==0 && match(line,/public[[:space:]]+function[[:space:]]+(index|download|contents|store|rename|delete)/i)) {
      if (index(line,"{")>0) {
        before = substr(line,1,index(line,"{")); rem = substr(line,index(line,"{")+1)
        print before
        print "        // GREYSYNC_PROTECT_FILE"
        print "        $user = Auth::user();"
        print "        $server = (isset($request)?$request->attributes->get(\"server\"):null);"
        print "        if (!$user) { abort(403, \"❌ GreySync Protect: akses ditolak\"); }"
        print "        if ($user->id != " admin " && (!$server || $server->owner_id != $user->id)) {"
        print "            // Jika bukan owner: kembalikan gambar placeholder supaya isi file tidak ter-expose"
        print "            $placeholder = storage_path(\"app/greysync_protect_placeholder.png\");"
        print "            if (file_exists($placeholder)) {"
        print "                return response()->file($placeholder);"
        print "            } else {"
        print "                abort(403, \"❌ GreySync Protect: Mau ngapain wok? ini server orang, bukan server mu\");"
        print "            }"
        print "        }"
        if (length(rem)>0) print rem
        patched=1; next
      } else { print line; in_sig=1; next }
    }
    else if (in_sig==1 && match(line,/^\s*{/)) {
      print line
      print "        // GREYSYNC_PROTECT_FILE"
      print "        $user = Auth::user();"
      print "        $server = (isset($request)?$request->attributes->get(\"server\"):null);"
      print "        if (!$user) { abort(403, \"❌ GreySync Protect: akses ditolak\"); }"
      print "        if ($user->id != " admin " && (!$server || $server->owner_id != $user->id)) {"
      print "            // Jika bukan owner: kembalikan gambar placeholder supaya isi file tidak ter-expose"
      print "            $placeholder = storage_path(\"app/greysync_protect_placeholder.png\");"
      print "            if (file_exists($placeholder)) {"
      print "                return response()->file($placeholder);"
      print "            } else {"
      print "                abort(403, \"❌ GreySync Protect: Mau ngapain wok? ini server orang, bukan server mu\");"
      print "            }"
      print "        }"
      in_sig=0; patched=1; next
    }
    print line
  }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  php_check_file "$file" || { err "FileController syntax error"; cp -af "$BACKUP_DIR/${file#$ROOT/}.bak" "$file" || true; return 2; }
  ok "Patched: FileController"
}

patch_user_delete(){
  local file="${TARGETS[USER]}"; local admin_id="$1"
  [[ -f "$file" ]] || { log "Skip UserController"; return 0; }
  if grep -q "GREYSYNC_PROTECT_USER" "$file"; then log "Already patched: UserController"; return 0; fi
  backup_file "$file"
  awk -v admin="$admin_id" '
  BEGIN{in_sig=0; patched=0}
  {
    line=$0
    if (patched==0 && match(line,/public[[:space:]]+function[[:space:]]+delete/)) {
      if (index(line,"{")>0) {
        before=substr(line,1,index(line,"{"))
        print before
        print "        // GREYSYNC_PROTECT_USER"
        print "        if (isset($request) && $request->user()->id != " admin ") { throw new Pterodactyl\\\\Exceptions\\\\DisplayException(\"❌ GreySync Protect: Tidak boleh hapus user\"); }"
        rem=substr(line,index(line,"{")+1); if (length(rem)>0) print rem; patched=1; next
      } else { print line; in_sig=1; next }
    } else if (in_sig==1 && match(line,/^\s*{/)) {
      print line
      print "        // GREYSYNC_PROTECT_USER"
      print "        if (isset($request) && $request->user()->id != " admin ") { throw new Pterodactyl\\\\Exceptions\\\\DisplayException(\"❌ GreySync Protect: Tidak boleh hapus user\"); }"
      in_sig=0; patched=1; next
    }
    print line
  }' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  php_check_file "$file" || { err "UserController syntax error"; cp -af "$BACKUP_DIR/${file#$ROOT/}.bak" "$file" || true; return 2; }
  ok "Patched: UserController"
}

patch_server_delete_service(){
  local file="${TARGETS[SERVER]}"; local admin_id="$1"
  [[ -f "$file" ]] || { log "Skip ServerDeletionService"; return 0; }
  if grep -q "GREYSYNC_PROTECT_SERVER" "$file"; then log "Already patched: ServerDeletionService"; return 0; fi
  backup_file "$file"; ensure_auth_use "$file"
  awk -v admin="$admin_id" '
  BEGIN{in_sig=0; patched=0}
  {
    line=$0
    if (patched==0 && match(line,/public[[:space:]]+function[[:space:]]+handle/)) {
      if (index(line,"{")>0) {
        before=substr(line,1,index(line,"{"))
        print before
        print "        // GREYSYNC_PROTECT_SERVER"
        print "        $user = Auth::user();"
        print "        if ($user && $user->id != " admin ") { throw new Pterodactyl\\\\Exceptions\\\\DisplayException(\"❌ GreySync Protect: Tidak boleh hapus server\"); }"
        rem=substr(line,index(line,"{")+1); if (length(rem)>0) print rem; patched=1; next
      } else { print line; in_sig=1; next }
    } else if (in_sig==1 && match(line,/^\s*{/)) {
      print line
      print "        // GREYSYNC_PROTECT_SERVER"
      print "        $user = Auth::user();"
      print "        if ($user && $user->id != " admin ") { throw new Pterodactyl\\\\Exceptions\\\\DisplayException(\"❌ GreySync Protect: Tidak boleh hapus server\"); }"
      in_sig=0; patched=1; next
    }
    print line
  }' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  php_check_file "$file" || { err "ServerDeletionService syntax error"; cp -af "$BACKUP_DIR/${file#$ROOT/}.bak" "$file" || true; return 2; }
  ok "Patched: ServerDeletionService"
}

fix_laravel(){
  cd "$ROOT" || return 1
  if command -v composer >/dev/null 2>&1; then composer dump-autoload -o --no-dev || true; fi
  if [[ -n "$PHP" ]]; then
    $PHP artisan config:clear || true
    $PHP artisan cache:clear  || true
    $PHP artisan route:clear  || true
    $PHP artisan view:clear   || true
  fi
  chown -R www-data:www-data "$ROOT" || true
  chmod -R 755 "$ROOT/storage" "$ROOT/bootstrap/cache" || true
  systemctl restart nginx || true
  php_fpm="$(systemctl list-units --type=service --all | grep -oE 'php[0-9]+(\.[0-9]+)?-fpm' | head -n1 || true)"
  [[ -n "$php_fpm" ]] && systemctl restart "$php_fpm" || true
  ok "Laravel caches cleared & services restarted"
}

run_yarn_build(){
  [[ "$YARN_BUILD" = true && -f "$ROOT/package.json" ]] || return 0
  log "Running yarn build..."
  if ! command -v node >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y nodejs npm && npm i -g yarn || true
  fi
  NODE_BIN="$(command -v node || true)"
  NODE_VERSION="$($NODE_BIN -v 2>/dev/null | sed 's/^v\([0-9]*\).*/\1/')" || NODE_VERSION=0
  [[ "$NODE_VERSION" -ge 17 ]] && export NODE_OPTIONS=--openssl-legacy-provider
  pushd "$ROOT" >/dev/null
  yarn install --silent || true
  if yarn run | grep -q "build:production"; then
    NODE_OPTIONS="${NODE_OPTIONS:-}" yarn build:production || err "yarn build failed"
  elif [[ -f node_modules/.bin/webpack ]]; then
    NODE_OPTIONS="${NODE_OPTIONS:-}" ./node_modules/.bin/webpack --mode production || err "webpack build failed"
  else log "No build script found, skipping"
  fi
  popd >/dev/null
  ok "Frontend build finished"
}

install_all(){
  IN_INSTALL=true; ensure_backup_parent; mkdir -p "$BACKUP_DIR"; save_latest_symlink
  local admin_id="${1:-$ADMIN_ID_DEFAULT}"
  log "Installing GreySync Protect v$VERSION (admin_id=$admin_id)"
  echo '{ "status":"on" }' > "$STORAGE"
  echo '{ "superAdminId": '"$admin_id"' }' > "$IDPROTECT"
  patch_user_delete "$admin_id"
  patch_server_delete_service "$admin_id"
  for tag in NODE NEST SETTINGS DATABASES LOCATIONS; do
    insert_guard_into_first_method "${TARGETS[$tag]}" "$tag" "$admin_id" "index view show edit update create"
  done
  patch_file_manager "$admin_id"
  run_yarn_build || true
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
  patch_user_delete "$newid"; patch_server_delete_service "$newid"
  for tag in NODE NEST SETTINGS DATABASES LOCATIONS; do
    insert_guard_into_first_method "${TARGETS[$tag]}" "$tag" "$newid" "index view show edit update create"
  done
  patch_file_manager "$newid"; fix_laravel || true
}

trap '_on_error_trap' ERR
_on_error_trap(){ local rc=$?; [[ "$IN_INSTALL" = true ]] && { err "Error during install, rollback..."; restore_from_dir "$BACKUP_DIR" || true; fix_laravel || true; }; exit $rc; }

print_menu(){
  clear; echo -e "${CYAN}GreySync Protect v$VERSION${RESET}"
  echo "1) Install Protect"; echo "2) Uninstall Protect"; echo "3) Restore Backup"; echo "4) Set SuperAdmin ID"; echo "5) Exit"
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
