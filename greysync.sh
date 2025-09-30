#!/usr/bin/env bash
# GreySync Protect v1.6.2

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
VERSION="1.6.2"
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

ensure_backup_parent() {
  mkdir -p "$BACKUP_PARENT"
}

backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  mkdir -p "$BACKUP_DIR/$(dirname "${f#$ROOT/}")"
  cp -af "$f" "$BACKUP_DIR/${f#$ROOT/}.bak"
  log "Backup: $f -> $BACKUP_DIR/${f#$ROOT/}.bak"
}

save_latest_symlink() {
  mkdir -p "$BACKUP_PARENT"
  ln -sfn "$(basename "$BACKUP_DIR")" "$BACKUP_LATEST_LINK"
}

restore_from_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || { err "Backup dir not found: $dir"; return 1; }
  log "Restoring from $dir"
  find "$dir" -type f -name "*.bak" | while read -r f; do
    rel="${f#$dir/}"
    target="$ROOT/${rel%.bak}"
    mkdir -p "$(dirname "$target")"
    cp -af "$f" "$target"
    log "Restored: $target"
  done
  return 0
}

restore_from_latest_backup() {
  local latest
  if [[ -L "$BACKUP_LATEST_LINK" ]]; then
    latest="$(readlink -f "$BACKUP_LATEST_LINK")"
  else
    latest="$(ls -td "$BACKUP_PARENT"/greysync_* 2>/dev/null | head -n1 || true)"
  fi
  if [[ -z "$latest" || ! -d "$latest" ]]; then
    err "No greysync backups found in $BACKUP_PARENT"
    return 1
  fi
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
      ins=1
      next
    }
    { print }
    ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    log "Inserted Auth use into $file"
  fi
}

insert_guard_into_first_method() {
  local file="$1"; local tag="$2"; local admin_id="$3"; local methods_csv="$4"
  [[ -f "$file" ]] || { log "Skip (not found): $file"; return 0; }
  if grep -q "GREYSYNC_PROTECT_${tag}" "$file" 2>/dev/null; then log "Already patched ($tag): $file"; return 0; fi
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
            patched=1; in_sig=0; next
          } else {
            print line; in_sig=1; next
          }
        }
      }
    }
    print line
  }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  if ! php_check_file "$file"; then
    err "Syntax error detected after patching $file"
    cp -af "$BACKUP_DIR/${file#$ROOT/}.bak" "$file" 2>/dev/null || true
    return 2
  fi
  ok "Patched: $file"
  return 0
}

patch_user_delete() {
  local file="${TARGETS[USER]}"
  local admin_id="$1"
  [[ -f "$file" ]] || { log "Skip (UserController not found)"; return 0; }
  if grep -q "GREYSYNC_PROTECT_USER" "$file" 2>/dev/null; then log "Already patched: UserController"; return 0; fi
  backup_file "$file"
  awk -v admin="$admin_id" '
  BEGIN{in_sig=0; patched=0}
  {
    line=$0
    if (patched==0 && match(line,/public[[:space:]]+function[[:space:]]+delete[[:space:]]*\([^\)]*\)[[:space:]]*\{?/i)) {
      if (index(line,"{")>0) {
        before = substr(line,1,index(line,"{"))
        print before
        print "        // GREYSYNC_PROTECT_USER"
        print "        if (isset($request) && $request->user()->id != " admin ") { throw new Pterodactyl\\\\Exceptions\\\\DisplayException(\"❌ GreySync Protect: Tidak boleh hapus user\"); }"
        rem = substr(line,index(line,"{")+1)
        if (length(rem)>0) print rem
        patched=1; next
      } else {
        print line; in_sig=1; next
      }
    } else if (in_sig==1 && match(line,/^\s*{/)) {
      print line
      print "        // GREYSYNC_PROTECT_USER"
      print "        if (isset($request) && $request->user()->id != " admin ") { throw new Pterodactyl\\\\Exceptions\\\\DisplayException(\"❌ GreySync Protect: Tidak boleh hapus user\"); }"
      in_sig=0; patched=1; next
    }
    print line
  }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  if ! php_check_file "$file"; then
    err "UserController syntax error after patch, restoring backup"
    cp -af "$BACKUP_DIR/${file#$ROOT/}.bak" "$file" 2>/dev/null || true
    return 2
  fi
  ok "Patched: UserController (delete)"
}

patch_server_delete_service() {
  local file="${TARGETS[SERVER]}"
  local admin_id="$1"
  [[ -f "$file" ]] || { log "Skip (ServerDeletionService not found)"; return 0; }
  if grep -q "GREYSYNC_PROTECT_SERVER" "$file" 2>/dev/null; then log "Already patched: ServerDeletionService"; return 0; fi
  backup_file "$file"
  ensure_auth_use "$file"
  awk -v admin="$admin_id" '
  BEGIN{in_sig=0; patched=0}
  {
    line=$0
    if (patched==0 && match(line,/public[[:space:]]+function[[:space:]]+handle[[:space:]]*\([^\)]*\)[[:space:]]*\{?/i)) {
      if (index(line,"{")>0) {
        before = substr(line,1,index(line,"{"))
        print before
        print "        // GREYSYNC_PROTECT_SERVER"
        print "        $user = Auth::user();"
        print "        if ($user && $user->id != " admin ") { throw new Pterodactyl\\\\Exceptions\\\\DisplayException(\"❌ GreySync Protect: Tidak boleh hapus server\"); }"
        rem = substr(line,index(line,"{")+1)
        if (length(rem)>0) print rem
        patched=1; next
      } else {
        print line; in_sig=1; next
      }
    } else if (in_sig==1 && match(line,/^\s*{/)) {
      print line
      print "        // GREYSYNC_PROTECT_SERVER"
      print "        $user = Auth::user();"
      print "        if ($user && $user->id != " admin ") { throw new Pterodactyl\\\\Exceptions\\\\DisplayException(\"❌ GreySync Protect: Tidak boleh hapus server\"); }"
      in_sig=0; patched=1; next
    }
    print line
  }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  if ! php_check_file "$file"; then
    err "ServerDeletionService syntax error after patch, restoring backup"
    cp -af "$BACKUP_DIR/${file#$ROOT/}.bak" "$file" 2>/dev/null || true
    return 2
  fi
  ok "Patched: ServerDeletionService (handle)"
}

fix_laravel() {
  cd "$ROOT" || return 1
  if command -v composer >/dev/null 2>&1; then
    composer dump-autoload -o --no-dev >/dev/null 2>&1 || true
  fi
  if [[ -n "$PHP" ]]; then
    $PHP artisan config:clear >/dev/null 2>&1 || true
    $PHP artisan cache:clear  >/dev/null 2>&1 || true
    $PHP artisan route:clear  >/dev/null 2>&1 || true
    $PHP artisan view:clear   >/dev/null 2>&1 || true
  fi
  chown -R www-data:www-data "$ROOT" >/dev/null 2>&1 || true
  chmod -R 755 "$ROOT/storage" "$ROOT/bootstrap/cache" >/dev/null 2>&1 || true
  if systemctl list-unit-files | grep -q nginx.service; then
    systemctl restart nginx >/dev/null 2>&1 || true
  fi
  php_fpm="$(systemctl list-units --type=service --all | grep -oE 'php[0-9]+(\.[0-9]+)?-fpm' | head -n1 || true)"
  [[ -n "$php_fpm" ]] && systemctl restart "$php_fpm" >/dev/null 2>&1 || true
  ok "Laravel caches cleared & services restarted"
}

run_yarn_build() {
  if [[ "$YARN_BUILD" = true && -f "$ROOT/package.json" ]]; then
    log "Running yarn build (may take a while)..."

    # detect node and version
    if ! command -v node >/dev/null 2>&1; then
      log "Node.js not found, attempting to install Node.js 16 and yarn..."
      apt-get update -y >/dev/null 2>&1 || true
      apt-get remove -y nodejs >/dev/null 2>&1 || true
      curl -fsSL https://deb.nodesource.com/setup_16.x | bash - >/dev/null 2>&1 || true
      apt-get install -y nodejs >/dev/null 2>&1 || true
      npm i -g yarn >/dev/null 2>&1 || true
    fi

    NODE_BIN="$(command -v node || true)"
    NODE_VERSION=0
    if [[ -n "$NODE_BIN" ]]; then
      NODE_VERSION_RAW="$($NODE_BIN -v 2>/dev/null || echo v0)"
      NODE_VERSION="$(echo "$NODE_VERSION_RAW" | sed 's/^v\([0-9]*\).*/\1/')"
      log "Detected Node.js version: $NODE_VERSION_RAW"
    fi

    # For Node >= 17, apply OpenSSL legacy provider fix to avoid webpack errors
    if [[ "$NODE_VERSION" -ge 17 ]]; then
      export NODE_OPTIONS=--openssl-legacy-provider
      log "${YELLOW}Applying NODE_OPTIONS=--openssl-legacy-provider for Node >= 17${RESET}"
    fi

    pushd "$ROOT" >/dev/null 2>&1
    # ensure cross-env present (some panel builds require)
    yarn add --silent cross-env >/dev/null 2>&1 || true

    # prefer script if exists
    if yarn run | grep -q "build:production"; then
      if ! NODE_OPTIONS="${NODE_OPTIONS:-}" yarn build:production --silent --progress; then
        err "yarn build failed (check logs). Continuing but panel front may be broken."
      else
        ok "Frontend build finished"
      fi
    else
      # fallback to generic webpack if available
      if [[ -f node_modules/.bin/webpack ]]; then
        if ! NODE_OPTIONS="${NODE_OPTIONS:-}" yarn run clean >/dev/null 2>&1 || true
        if ! NODE_OPTIONS="${NODE_OPTIONS:-}" ./node_modules/.bin/webpack --mode production --silent --progress; then
          err "webpack build failed (check logs). Continuing but panel front may be broken."
        else
          ok "Frontend webpack build finished"
        fi
      else
        log "No build script or webpack found, skipping frontend build."
      fi
    fi
    popd >/dev/null 2>&1
  else
    log "Skipping yarn build (no package.json or build disabled)."
  fi
}

install_all() {
  IN_INSTALL=true
  ensure_backup_parent
  mkdir -p "$BACKUP_DIR"
  save_latest_symlink

  local admin_id="${1:-$ADMIN_ID_DEFAULT}"
  log "Installing GreySync Protect v$VERSION (admin_id=$admin_id)"
  echo '{ "status": "on" }' > "$STORAGE" 2>/dev/null || true
  echo '{ "superAdminId": '"$admin_id"' }' > "$IDPROTECT" 2>/dev/null || true

  # Specific patches (safe)
  patch_user_delete "$admin_id" || { err "Failed patching user"; return 2; }
  patch_server_delete_service "$admin_id" || { err "Failed patching server service"; return 2; }

  # Flexible targets
  for tag in NODE NEST SETTINGS DATABASES LOCATIONS; do
    path="${TARGETS[$tag]}"
    insert_guard_into_first_method "$path" "$tag" "$admin_id" "index view show edit update create" || { err "Failed patching $tag"; return 2; }
  done

  # build & laravel fixes
  run_yarn_build || true
  fix_laravel || true

  ok "✅ GreySync Protect installed. Backups stored in: $BACKUP_DIR"
  IN_INSTALL=false
}

uninstall_all() {
  log "Uninstalling GreySync Protect: will attempt to restore latest backup"
  rm -f "$STORAGE" "$IDPROTECT" 2>/dev/null || true
  if ! restore_from_latest_backup; then
    err "No backups to restore"
    return 1
  fi
  fix_laravel || true
  ok "✅ Uninstalled & restored from latest backup"
}

admin_patch() {
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
  fix_laravel || true
}

# auto-rollback on error during install
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
      admin_patch_result="$(admin_patch "$nid" 2>&1)" || true
      ;;
    5) exit 0 ;;
    *)
      echo "Pilihan tidak valid"; exit 1 ;;
  esac
}

# CLI dispatch
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
