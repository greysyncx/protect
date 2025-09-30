#!/usr/bin/env bash
# GreySync Protect (Safe) v1.6.4
# Adds multi-server & subuser protection (longgar mode).
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
YARN_BUILD=true

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

php_check_file(){ local f="$1"; [[ -n "$PHP" && -f "$f" ]] && ! "$PHP" -l "$f" >/dev/null 2>&1 && return 1 || return 0; }

ensure_backup_parent(){ mkdir -p "$BACKUP_PARENT"; }
backup_file(){ local f="$1"; [[ -f "$f" ]] || return 0; mkdir -p "$BACKUP_DIR/$(dirname "${f#$ROOT/}")"; cp -af "$f" "$BACKUP_DIR/${f#$ROOT/}.bak"; log "Backup: $f"; }
save_latest_symlink(){ mkdir -p "$BACKUP_PARENT"; ln -sfn "$(basename "$BACKUP_DIR")" "$BACKUP_LATEST_LINK"; }

restore_from_dir(){
  local dir="$1"; [[ -d "$dir" ]] || { err "Backup dir not found: $dir"; return 1; }
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

ensure_auth_use(){ local file="$1"; [[ -f "$file" ]] || return 0
  if ! grep -q "Illuminate\\\\Support\\\\Facades\\\\Auth" "$file"; then
    awk '/namespace[[:space:]]+[A-Za-z0-9_\\\]+;/ {print;print "use Illuminate\\Support\\Facades\\Auth;";next}1' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    log "Inserted Auth use into $file"
  fi
}

# --- File Manager (multi-server, subuser, superadmin) ---
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
        print "        if (!$user) { abort(403, \"❌ GreySync Protect: tidak ada sesi login\"); }"
        print "        if ($user->id != " admin ") {"
        print "            if (!$server || $server->owner_id != $user->id) {"
        print "                if (!$server || !$server->subusers->contains(\"user_id\", $user->id)) {"
        print "                    abort(403, \"❌ GreySync Protect: kamu tidak punya akses ke server ini\");"
        print "                }"
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
      print "        if (!$user) { abort(403, \"❌ GreySync Protect: tidak ada sesi login\"); }"
      print "        if ($user->id != " admin ") {"
      print "            if (!$server || $server->owner_id != $user->id) {"
      print "                if (!$server || !$server->subusers->contains(\"user_id\", $user->id)) {"
      print "                    abort(403, \"❌ GreySync Protect: kamu tidak punya akses ke server ini\");"
      print "                }"
      print "            }"
      print "        }"
      in_sig=0; patched=1; next
    }
    print line
  }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  php_check_file "$file" || { err "FileController syntax error"; cp -af "$BACKUP_DIR/${file#$ROOT/}.bak" "$file" || true; return 2; }
  ok "Patched: FileController (multi-server support)"
}

# TODO: User delete, Server delete, Node/Nest/Settings patch sama seperti versi lama
install_all(){
  IN_INSTALL=true; ensure_backup_parent; mkdir -p "$BACKUP_DIR"; save_latest_symlink
  local admin_id="${1:-$ADMIN_ID_DEFAULT}"
  log "Installing GreySync Protect v$VERSION (admin_id=$admin_id)"
  echo '{ "status":"on" }' > "$STORAGE"
  echo '{ "superAdminId": '"$admin_id"' }' > "$IDPROTECT"
  patch_file_manager "$admin_id"
  # panggil patch_user_delete, patch_server_delete_service, insert_guard_into_first_method sesuai versi lama
  ok "✅ GreySync Protect installed. Backup in $BACKUP_DIR"
  IN_INSTALL=false
}

uninstall_all(){ log "Uninstalling GreySync Protect"; rm -f "$STORAGE" "$IDPROTECT"; restore_from_latest_backup || err "No backups"; ok "✅ Uninstalled & restored"; }

admin_patch(){ local newid="${1:-}"; [[ -z "$newid" || ! "$newid" =~ ^[0-9]+$ ]] && { err "Usage: $0 adminpatch <id>"; return 1; }
  echo '{ "superAdminId": '"$newid"' }' > "$IDPROTECT"; ok "SuperAdmin ID set -> $newid"; patch_file_manager "$newid"; }

trap '_on_error_trap' ERR
_on_error_trap(){ local rc=$?; [[ "$IN_INSTALL" = true ]] && { err "Error during install, rollback..."; restore_from_dir "$BACKUP_DIR" || true; }; exit $rc; }

print_menu(){ clear; echo -e "${CYAN}GreySync Protect v$VERSION${RESET}"
  echo "1) Install Protect"; echo "2) Uninstall Protect"; echo "3) Restore Backup"; echo "4) Set SuperAdmin ID"; echo "5) Exit"
  read -p "Pilih opsi [1-5]: " opt
  case "$opt" in
    1) read -p "Admin ID (default $ADMIN_ID_DEFAULT): " aid; install_all "${aid:-$ADMIN_ID_DEFAULT}" ;;
    2) uninstall_all ;;
    3) restore_from_latest_backup ;;
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
