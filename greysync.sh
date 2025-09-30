#!/bin/bash
# GreySync Protect (No-Middleware) v1.5.2-nomw (fixed)
ROOT="/var/www/pterodactyl"
BACKUP_DIR="$ROOT/greysync_backups_$(date +%s)"

USER_CONTROLLER="$ROOT/app/Http/Controllers/Admin/UserController.php"
SERVER_SERVICE="$ROOT/app/Services/Servers/ServerDeletionService.php"
NODE_CONTROLLER="$ROOT/app/Http/Controllers/Admin/Nodes/NodeController.php"
NEST_CONTROLLER="$ROOT/app/Http/Controllers/Admin/Nests/NestController.php"
SETTINGS_CONTROLLER="$ROOT/app/Http/Controllers/Admin/Settings/IndexController.php"

STORAGE="$ROOT/storage/app/greysync_protect.json"
IDPROTECT="$ROOT/storage/app/idprotect.json"
ADMIN_ID_DEFAULT=1

RED="\033[1;31m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RESET="\033[0m"

log() { echo -e "$1"; }
err() { echo -e "${RED}$1${RESET}"; }
ok()  { echo -e "${GREEN}$1${RESET}"; }

php_check() {
  # Check PHP syntax; return 0 if ok, nonzero otherwise
  php -l "$1" >/dev/null 2>&1
  return $?
}

backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  mkdir -p "$BACKUP_DIR/$(dirname "${f#$ROOT/}")"
  cp -f "$f" "$BACKUP_DIR/${f#$ROOT/}.bak"
  log "${YELLOW}Backup: $f -> $BACKUP_DIR/${f#$ROOT/}.bak${RESET}"
}

restore_from_latest_backup() {
  local latest
  latest=$(ls -td "$ROOT"/greysync_backups_* 2>/dev/null | head -n1)
  [[ -z "$latest" ]] && { err "❌ No greysync backups found"; return 1; }
  find "$latest" -type f -name "*.bak" | while read -r f; do
    rel="${f#$latest/}"
    target="$ROOT/${rel%.bak}"
    mkdir -p "$(dirname "$target")"
    cp -f "$f" "$target"
    log "${GREEN}Restored: $target${RESET}"
  done
  return 0
}

# insert "use Illuminate\\Support\\Facades\\Auth;" after namespace if missing
ensure_auth_use() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  if ! grep -q "Illuminate\\\\Support\\\\Facades\\\\Auth" "$file"; then
    # insert after first namespace declaration
    awk '
    BEGIN { inserted=0 }
    /namespace[ ]+[A-Za-z0-9_\\\]+;/ && inserted==0 {
      print $0
      print "use Illuminate\\Support\\Facades\\Auth;"
      inserted=1
      next
    }
    { print }
    ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    log "${YELLOW}Inserted Auth use into $file${RESET}"
  fi
}

# Generic function: insert guard into first matching public function among list
patch_admin_controller_flexible() {
  local ctrl="$1"
  local tag="$2"
  local admin_id="${3:-$ADMIN_ID_DEFAULT}"

  [[ -f "$ctrl" ]] || { log "${YELLOW}Skip (not found): $ctrl${RESET}"; return 0; }
  backup_file "$ctrl"

  if grep -q "GREYSYNC_PROTECT_${tag}" "$ctrl" 2>/dev/null; then
    log "${YELLOW}Already patched: $ctrl${RESET}"
    return 0
  fi

  # Ensure Auth facade is present
  ensure_auth_use "$ctrl"

  # Try to find one of the target methods and insert guard right after opening brace.
  awk -v admin="$admin_id" -v tag="$tag" '
  BEGIN {
    in_sig=0; patched=0;
    # methods to try in order
    split("index view show edit update create", methods);
  }
  {
    line=$0
    if (patched==0) {
      # if we are currently within a matched signature and see the opening brace,
      # insert guard after it.
      if (in_sig==1) {
        if (match(line,/^\s*{/)) {
          print line
          print "        // GREYSYNC_PROTECT_"tag
          print "        $user = Auth::user();"
          print "        if (!$user || $user->id != " admin ") { abort(403, \"❌ GreySync Protect: Akses ditolak\"); }"
          in_sig=0
          patched=1
          next
        }
        # if brace was on same line as signature (handled below), we won't be here.
      }
      # check if this line is a function signature of our targeted names
      for (i in methods) {
        pat = "public[[:space:]]+function[[:space:]]+"methods[i]"[[:space:]]*\\([^)]*\\)[[:space:]]*\\{?"
        if (match(line,pat)) {
          # if brace is on same line
          if (index(line,"{") > 0) {
            # insert guard after the brace on same line: print prefix then guard block
            # split at first "{"
            before = substr(line,1,index(line,"{"))
            print before
            print "        // GREYSYNC_PROTECT_"tag
            print "        $user = Auth::user();"
            print "        if (!$user || $user->id != " admin ") { abort(403, \"❌ GreySync Protect: Akses ditolak\"); }"
            # print the remainder of line after "{"
            rem = substr(line,index(line,"{")+1)
            if (length(rem)>0) {
              print rem
            }
            patched=1
            in_sig=0
            next
          } else {
            # signature line without brace; set flag so next brace line will get guard
            print line
            in_sig=1
            next
          }
        }
      }
    }
    print line
  }
  END {
    # fallback: if not patched, attempt to patch first public function
    if (patched==0) {
      # nothing here: we keep file unchanged; caller may choose fallback behavior
    }
  }
  ' "$ctrl" > "$ctrl.tmp" && mv "$ctrl.tmp" "$ctrl"

  # lint check
  if ! php_check "$ctrl"; then
    err "❌ Syntax error after patching $ctrl — restoring backup"
    cp -f "$BACKUP_DIR/${ctrl#$ROOT/}.bak" "$ctrl" 2>/dev/null || true
    return 2
  fi

  ok "Patched: $ctrl"
  return 0
}

patch_user_delete() {
  local admin_id="${1:-$ADMIN_ID_DEFAULT}"
  [[ -f "$USER_CONTROLLER" ]] || { log "${YELLOW}Skip (not found): UserController${RESET}"; return 0; }
  backup_file "$USER_CONTROLLER"
  if grep -q "GREYSYNC_PROTECT_USER" "$USER_CONTROLLER" 2>/dev/null; then
    log "${YELLOW}Already patched: UserController${RESET}"; return 0
  fi

  # Insert guard into delete method (robust awk)
  awk -v admin="$admin_id" '
  BEGIN { in_sig=0; patched=0 }
  {
    line=$0
    # match delete method signature (flexible)
    if (patched==0 && match(line,/public[[:space:]]+function[[:space:]]+delete[[:space:]]*\([^\)]*\)[[:space:]]*\{?/i)) {
      # if brace on same line
      if (index(line,"{")>0) {
        before = substr(line,1,index(line,"{"))
        print before
        print "        // GREYSYNC_PROTECT_USER"
        print "        if (isset($request) && $request->user()->id != " admin ") { throw new Pterodactyl\\Exceptions\\DisplayException(\"❌ GreySync Protect: Tidak boleh hapus user\"); }"
        rem = substr(line,index(line,"{")+1)
        if (length(rem)>0) print rem
        patched=1
        next
      } else {
        print line
        in_sig=1
        next
      }
    } else if (in_sig==1 && match(line,/^\s*{/)) {
      print line
      print "        // GREYSYNC_PROTECT_USER"
      print "        if (isset($request) && $request->user()->id != " admin ") { throw new Pterodactyl\\Exceptions\\DisplayException(\"❌ GreySync Protect: Tidak boleh hapus user\"); }"
      in_sig=0
      patched=1
      next
    }
    print line
  }
  ' "$USER_CONTROLLER" > "$USER_CONTROLLER.tmp" && mv "$USER_CONTROLLER.tmp" "$USER_CONTROLLER"

  if ! php_check "$USER_CONTROLLER"; then
    err "❌ UserController error — restoring backup"
    cp -f "$BACKUP_DIR/${USER_CONTROLLER#$ROOT/}.bak" "$USER_CONTROLLER" 2>/dev/null || true
    return 2
  fi
  ok "Patched: UserController (delete)"
}

patch_server_delete_service() {
  local admin_id="${1:-$ADMIN_ID_DEFAULT}"
  [[ -f "$SERVER_SERVICE" ]] || { log "${YELLOW}Skip (not found): ServerDeletionService${RESET}"; return 0; }
  backup_file "$SERVER_SERVICE"
  if grep -q "GREYSYNC_PROTECT_SERVER" "$SERVER_SERVICE" 2>/dev/null; then
    log "${YELLOW}Already patched: ServerDeletionService${RESET}"; return 0
  fi

  # Ensure Auth facade exists
  ensure_auth_use "$SERVER_SERVICE"

  # Insert guard into handle(...) method
  awk -v admin="$admin_id" '
  BEGIN { in_sig=0; patched=0 }
  {
    line=$0
    if (patched==0 && match(line,/public[[:space:]]+function[[:space:]]+handle[[:space:]]*\([^\)]*\)[[:space:]]*\{?/i)) {
      if (index(line,"{")>0) {
        before = substr(line,1,index(line,"{"))
        print before
        print "        // GREYSYNC_PROTECT_SERVER"
        print "        $user = Auth::user();"
        print "        if ($user && $user->id != " admin ") { throw new Pterodactyl\\Exceptions\\DisplayException(\"❌ GreySync Protect: Tidak boleh hapus server\"); }"
        rem = substr(line,index(line,"{")+1)
        if (length(rem)>0) print rem
        patched=1
        next
      } else {
        print line
        in_sig=1
        next
      }
    } else if (in_sig==1 && match(line,/^\s*{/)) {
      print line
      print "        // GREYSYNC_PROTECT_SERVER"
      print "        $user = Auth::user();"
      print "        if ($user && $user->id != " admin ") { throw new Pterodactyl\\Exceptions\\DisplayException(\"❌ GreySync Protect: Tidak boleh hapus server\"); }"
      in_sig=0
      patched=1
      next
    }
    print line
  }
  ' "$SERVER_SERVICE" > "$SERVER_SERVICE.tmp" && mv "$SERVER_SERVICE.tmp" "$SERVER_SERVICE"

  if ! php_check "$SERVER_SERVICE"; then
    err "❌ ServerDeletionService error — restoring backup"
    cp -f "$BACKUP_DIR/${SERVER_SERVICE#$ROOT/}.bak" "$SERVER_SERVICE" 2>/dev/null || true
    return 2
  fi
  ok "Patched: ServerDeletionService (handle)"
}

fix_laravel() {
  cd "$ROOT" || return 1
  command -v composer >/dev/null 2>&1 && composer dump-autoload -o --no-dev >/dev/null 2>&1 || true
  php artisan config:clear >/dev/null 2>&1 || true
  php artisan cache:clear  >/dev/null 2>&1 || true
  php artisan route:clear  >/dev/null 2>&1 || true
  php artisan view:clear   >/dev/null 2>&1 || true
  chown -R www-data:www-data "$ROOT" >/dev/null 2>&1 || true
  chmod -R 755 "$ROOT/storage" "$ROOT/bootstrap/cache" >/dev/null 2>&1 || true
  systemctl restart nginx >/dev/null 2>&1 || true
  php_fpm=$(systemctl list-units --type=service --all | grep -oE 'php[0-9]+(\.[0-9]+)?-fpm' | head -n1 || true)
  [[ -n "$php_fpm" ]] && systemctl restart "$php_fpm" >/dev/null 2>&1 || true
  ok "Laravel caches cleared & services restarted"
}

install_all() {
  mkdir -p "$BACKUP_DIR"
  echo '{ "status": "on" }' > "$STORAGE" 2>/dev/null || true
  echo '{ "superAdminId": '"$ADMIN_ID_DEFAULT"' }' > "$IDPROTECT" 2>/dev/null || true

  patch_user_delete "$ADMIN_ID_DEFAULT"
  patch_server_delete_service "$ADMIN_ID_DEFAULT"
  patch_admin_controller_flexible "$NODE_CONTROLLER" "NODE" "$ADMIN_ID_DEFAULT"
  patch_admin_controller_flexible "$NEST_CONTROLLER" "NEST" "$ADMIN_ID_DEFAULT"
  patch_admin_controller_flexible "$SETTINGS_CONTROLLER" "SETTINGS" "$ADMIN_ID_DEFAULT"

  fix_laravel || true
  ok "✅ GreySync Protect (no-middleware) installed."
}

uninstall_all() {
  rm -f "$STORAGE" "$IDPROTECT" 2>/dev/null || true
  restore_from_latest_backup || log "${YELLOW}No backups restored${RESET}"
  fix_laravel || true
  ok "✅ GreySync Protect uninstalled/restored."
}

admin_patch() {
  local newid="$1"
  if [[ -z "$newid" || ! "$newid" =~ ^[0-9]+$ ]]; then
    err "Usage: $0 adminpatch <numeric id>"
    return 1
  fi
  echo '{ "superAdminId": '"$newid"' }' > "$IDPROTECT"
  ok "SuperAdmin ID set -> $newid"
  patch_user_delete "$newid"
  patch_server_delete_service "$newid"
  patch_admin_controller_flexible "$NODE_CONTROLLER" "NODE" "$newid"
  patch_admin_controller_flexible "$NEST_CONTROLLER" "NEST" "$newid"
  patch_admin_controller_flexible "$SETTINGS_CONTROLLER" "SETTINGS" "$newid"
  fix_laravel || true
}

restore_backups() {
  restore_from_latest_backup || { err "❌ No backups found"; return 1; }
  fix_laravel || true
  ok "✅ Restored controllers from latest backup"
}

case "$1" in
  install|"") install_all ;;
  uninstall)   uninstall_all ;;
  restore)     restore_backups ;;
  adminpatch)  admin_patch "$2" ;;
  *) err "Usage: $0 {install|uninstall|restore|adminpatch <id>}"; exit 1 ;;
esac
