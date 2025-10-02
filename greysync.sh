#!/usr/bin/env bash
# GreySync Protect (Safe) v1.6.4 - Versi Ramping

set -euo pipefail
IFS=$'\n\t'

# --- Konfigurasi Default & Variabel ---
ROOT="${ROOT:-/var/www/pterodactyl}"
BACKUP_PARENT="${BACKUP_PARENT:-$ROOT/greysync_backups}"
TIMESTAMP="$(date +%Y%m%d%H%M%S)"
BACKUP_DIR="${BACKUP_DIR:-$BACKUP_PARENT/greysync_backup_$TIMESTAMP}"
BACKUP_LATEST_LINK="$BACKUP_PARENT/latest"
STORAGE="${STORAGE:-$ROOT/storage/app/greysync_protect.json}"
IDPROTECT="${IDPROTECT:-$ROOT/storage/app/idprotect.json}"
ADMIN_ID_DEFAULT="${ADMIN_ID_DEFAULT:-1}"
LOGFILE="${LOGFILE:-/var/log/greysync_protect.log}"

# Global Flags
YARN_BUILD=true
VERSION="1.6.4"
IN_INSTALL=false
EXIT_CODE=0
ADMIN_ID="$ADMIN_ID_DEFAULT"

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

# --- Warna & Logging ---
RED="\033[1;31m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; CYAN="\033[1;36m"; RESET="\033[0m"

log(){ echo -e "$(date -u +'%Y-%m-%dT%H:%M:%SZ') - ${CYAN}[INFO]${RESET} $*" | tee -a "$LOGFILE"; }
err(){ echo -e "$(date -u +'%Y-%m-%dT%H:%M:%SZ') - ${RED}[ERROR]${RESET} $*" | tee -a "$LOGFILE" >&2; EXIT_CODE=1; }
ok(){ echo -e "$(date -u +'%Y-%m-%dT%H:%M:%SZ') - ${GREEN}[OK]${RESET} $*" | tee -a "$LOGFILE"; }
warn(){ echo -e "$(date -u +'%Y-%m-%dT%H:%M:%SZ') - ${YELLOW}[WARN]${RESET} $*" | tee -a "$LOGFILE"; }

# --- Fungsi Pengecekan Sistem ---
php_bin() {
  local php_cmd=""
  if command -v php >/dev/null 2>&1; then php_cmd="php"; fi
  if [[ -z "$php_cmd" ]]; then
    for v in 8.3 8.2 8.1 8.0 7.4; do
      if command -v "php$v" >/dev/null 2>&1; then php_cmd="php$v"; break; fi
    done
  fi
  if [[ -n "$php_cmd" ]]; then echo "$php_cmd"; return 0; else err "PHP binary tidak ditemukan."; return 1; fi
}
PHP="$(php_bin || true)"

php_check_file() {
  local f="$1"
  if [[ -n "$PHP" && -f "$f" ]]; then
    if ! "$PHP" -l "$f" >/dev/null 2>&1; then return 1; fi
  fi
  return 0
}

check_dependencies() {
    if [[ -z "$PHP" ]]; then err "Aplikasi membutuhkan PHP."; return 1; fi
    if ! command -v composer >/dev/null 2>&1; then warn "Composer tidak ditemukan. 'dump-autoload' dilewati."; fi
    if [[ ! -d "$ROOT/app" ]]; then err "Direktori Pterodactyl Panel tidak ditemukan di: $ROOT"; return 1; fi
    mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
    touch "$LOGFILE" 2>/dev/null || true
    return 0
}


# --- Fungsi Backup & Restore ---
ensure_backup_parent() { mkdir -p "$BACKUP_PARENT"; }

backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  if [[ -f "$BACKUP_DIR/${f#$ROOT/}.bak" ]]; then log "File sudah di-backup, lewati: $f"; return 0; fi
  mkdir -p "$BACKUP_DIR/$(dirname "${f#$ROOT/}")"
  cp -af "$f" "$BACKUP_DIR/${f#$ROOT/}.bak"
  log "Backup: $f -> ${BACKUP_DIR}/${f#$ROOT/}.bak"
}

save_latest_symlink() {
  mkdir -p "$BACKUP_PARENT"
  ln -sfn "$(basename "$BACKUP_DIR")" "$BACKUP_LATEST_LINK"
}

restore_from_dir() {
  local dir="$1"
  local abs_dir
  abs_dir="$(readlink -f "$dir" 2>/dev/null || echo "$dir")"
  
  [[ -d "$abs_dir" ]] || { err "Direktori backup tidak ditemukan: $dir"; return 1; }
  log "Memulihkan dari $abs_dir"
  
  local restore_count=0
  find "$abs_dir" -type f -name "*.bak" -print0 | while IFS= read -r -d $'\0' f; do
    rel="${f#$abs_dir/}"
    target="$ROOT/${rel%.bak}"
    mkdir -p "$(dirname "$target")"
    cp -af "$f" "$target"
    log "Dipulihkan: $target"
    restore_count=$((restore_count + 1))
  done
  
  if [[ "$restore_count" -eq 0 ]]; then warn "Tidak ada file .bak yang ditemukan di $abs_dir."; fi
  return 0
}

restore_from_latest_backup() {
  local latest
  if [[ -L "$BACKUP_LATEST_LINK" ]]; then
    latest="$(readlink -f "$BACKUP_LATEST_LINK")"
  else
    latest="$(ls -td "$BACKUP_PARENT"/greysync_backup_* 2>/dev/null | head -n1 || true)"
  fi
  
  if [[ -z "$latest" || ! -d "$latest" ]]; then
    err "Tidak ada backup GreySync yang ditemukan di $BACKUP_PARENT"
    return 1
  fi
  
  log "Memulihkan dari backup terbaru: $latest"
  restore_from_dir "$latest"
}

# --- Fungsi Patching PHP ---
ensure_auth_use() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  
  sed -i -r '/use[[:space:]]+Illuminate([^;]*Support[^;]*Facades[^;]*Auth|Support\\\Facades\\\Auth)[^;]*;?/Id' "$file" || true
  if ! grep -q '^<?php' "$file"; then sed -i '1s/^/<?php\n/' "$file" || true; fi
  
  if ! grep -q "^use Illuminate\\\\Support\\\\Facades\\\\Auth;" "$file"; then
    if grep -q '^namespace ' "$file"; then
      sed -i '/^namespace[[:space:]]\+[A-Za-z0-9_\\]\+;/a use Illuminate\\Support\\Facades\\Auth;' "$file" || true
      log "Inserted Auth use into $file"
    else
      warn "Tidak ada namespace di $file. Melewatkan penyisipan 'use Auth'."
    fi
  fi
}

insert_guard_into_first_method() {
  local file="$1"; local tag="$2"; local admin_id="$3"; local methods_csv="$4"
  [[ -f "$file" ]] || { log "Skip (not found): $file"; return 0; }
  if grep -q "GREYSYNC_PROTECT_${tag}" "$file" 2>/dev/null; then log "Sudah di-patch ($tag): $file"; return 0; fi
  backup_file "$file"

  local method_group
  method_group="$(echo "$methods_csv" | sed 's/ /|/g; s/^/(/; s/$/)/')"

  awk -v admin="$admin_id" -v tag="$tag" -v group="$method_group" '
  BEGIN{
    in_sig=0; patched=0;
    pat = "public[[:space:]]+function[[:space:]]+" group "[[:space:]]*\\([^)]*\\)[[:space:]]*\\{?"
  }
  {
    line=$0
    if (patched==0) {
      if (in_sig==1 && match(line,/^\s*{/)) {
        print line; print "        // GREYSYNC_PROTECT_"tag
        print "        $user = Auth::user();"
        print "        if (!$user || $user->id != " admin ") { abort(403, \"❌ GreySync Protect: Akses ditolak\"); }"
        in_sig=0; patched=1; next
      }
      if (match(line, pat)) {
        if (index(line,"{")>0) {
          before = substr(line,1,index(line,"{"))
          rem = substr(line,index(line,"{")+1)
          print before; print "        // GREYSYNC_PROTECT_"tag
          print "        $user = Auth::user();"
          print "        if (!$user || $user->id != " admin ") { abort(403, \"❌ GreySync Protect: Akses ditolak\"); }"
          if (length(rem)>0) print rem
          patched=1; in_sig=0; next
        } else {
          print line; in_sig=1; next
        }
      }
    }
    print line
  }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"

  if ! php_check_file "$file"; then
    err "Error sintaks di $file. Memulihkan backup..."
    cp -af "$BACKUP_DIR/${file#$ROOT/}.bak" "$file" 2>/dev/null || true
    return 2
  fi
  ok "Di-patch: $file"
  return 0
}

patch_user_delete() {
  local file="${TARGETS[USER]}"
  local admin_id="$1"
  [[ -f "$file" ]] || { log "Skip (UserController not found)"; return 0; }
  if grep -q "GREYSYNC_PROTECT_USER" "$file" 2>/dev/null; then log "Sudah di-patch: UserController"; return 0; fi
  backup_file "$file"

  if ! grep -Ei "public[[:space:]]+function[[:space:]]+(delete|destroy)" "$file"; then
    warn "Pola 'delete/destroy' tidak ditemukan. Melewati patch UserController."
    return 0
  fi
  
  awk -v admin="$admin_id" '
  BEGIN{in_sig=0; patched=0}
  {
    line=$0
    if (patched==0 && match(line,/public[[:space:]]+function[[:space:]]+(delete|destroy)[[:space:]]*\([^\)]*\)[[:space:]]*\{?/i)) {
      if (index(line,"{")>0) {
        before = substr(line,1,index(line,"{"))
        print before; print "        // GREYSYNC_PROTECT_USER"
        print "        if (isset($request) && $request->user()->id != " admin ") { throw new Pterodactyl\\\\Exceptions\\\\DisplayException(\"❌ GreySync Protect: Tidak boleh hapus user\"); }"
        rem = substr(line,index(line,"{")+1)
        if (length(rem)>0) print rem
        patched=1; next
      } else {
        print line; in_sig=1; next
      }
    } else if (in_sig==1 && match(line,/^\s*{/)) {
      print line; print "        // GREYSYNC_PROTECT_USER"
      print "        if (isset($request) && $request->user()->id != " admin ") { throw new Pterodactyl\\\\Exceptions\\\\DisplayException(\"❌ GreySync Protect: Tidak boleh hapus user\"); }"
      in_sig=0; patched=1; next
    }
    print line
  }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"

  if ! php_check_file "$file"; then
    err "UserController syntax error. Restoring backup."
    cp -af "$BACKUP_DIR/${file#$ROOT/}.bak" "$file" 2>/dev/null || true
    return 2
  fi
  ok "Di-patch: UserController (delete)"
}

patch_server_delete_service() {
  local file="${TARGETS[SERVER]}"
  local admin_id="$1"
  [[ -f "$file" ]] || { log "Skip (ServerDeletionService not found)"; return 0; }
  if grep -q "GREYSYNC_PROTECT_SERVER" "$file" 2>/dev/null; then log "Sudah di-patch: ServerDeletionService"; return 0; fi
  backup_file "$file"
  ensure_auth_use "$file"
  
  awk -v admin="$admin_id" '
  BEGIN{in_sig=0; patched=0}
  {
    line=$0
    if (patched==0 && match(line,/public[[:space:]]+function[[:space:]]+handle[[:space:]]*\([^\)]*\)[[:space:]]*\{?/i)) {
      if (index(line,"{")>0) {
        before = substr(line,1,index(line,"{"))
        print before; print "        // GREYSYNC_PROTECT_SERVER"
        print "        $user = Auth::user();"
        print "        if ($user && $user->id != " admin ") { throw new Pterodactyl\\\\Exceptions\\\\DisplayException(\"❌ GreySync Protect: Tidak boleh hapus server\"); }"
        rem = substr(line,index(line,"{")+1)
        if (length(rem)>0) print rem
        patched=1; next
      } else {
        print line; in_sig=1; next
      }
    } else if (in_sig==1 && match(line,/^\s*{/)) {
      print line; print "        // GREYSYNC_PROTECT_SERVER"
      print "        $user = Auth::user();"
      print "        if ($user && $user->id != " admin ") { throw new Pterodactyl\\\\Exceptions\\\\DisplayException(\"❌ GreySync Protect: Tidak boleh hapus server\"); }"
      in_sig=0; patched=1; next
    }
    print line
  }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  
  if ! php_check_file "$file"; then
    err "ServerDeletionService syntax error. Restoring backup."
    cp -af "$BACKUP_DIR/${file#$ROOT/}.bak" "$file" 2>/dev/null || true
    return 2
  fi
  ok "Di-patch: ServerDeletionService (handle)"
}

# --- Fungsi Post-Patching (Clear Cache & Build) ---
fix_laravel() {
  log "Membersihkan cache Laravel dan me-restart service..."
  cd "$ROOT" || return 1
  
  if command -v composer >/dev/null 2>&1; then composer dump-autoload -o --no-dev >/dev/null 2>&1 || true; fi
  
  if [[ -n "$PHP" ]]; then
    $PHP artisan config:clear >/dev/null 2>&1 || true
    $PHP artisan cache:clear  >/dev/null 2>&1 || true
    $PHP artisan route:clear  >/dev/null 2>&1 || true
    $PHP artisan view:clear   >/dev/null 2>&1 || true
  else
    warn "PHP binary tidak ditemukan, lewati artisan cache clear."
  fi
  
  chown -R www-data:www-data "$ROOT" >/dev/null 2>&1 || true
  chmod -R 755 "$ROOT/storage" "$ROOT/bootstrap/cache" >/dev/null 2>&1 || true
  
  if systemctl is-active --quiet nginx.service; then systemctl restart nginx >/dev/null 2>&1 || true; fi
  
  php_fpm="$(systemctl list-units --type=service --all | grep -oE 'php[0-9]+(\.[0-9]+)?-fpm' | head -n1 || true)"
  [[ -n "$php_fpm" ]] && systemctl restart "$php_fpm" >/dev/null 2>&1 || true
  
  ok "Cache Laravel dibersihkan & service di-restart."
}

run_yarn_build() {
  if [[ "$YARN_BUILD" = true && -f "$ROOT/package.json" ]]; then
    log "Menjalankan yarn build..."
    
    if ! command -v node >/dev/null 2>&1 || ! command -v yarn >/dev/null 2>&1; then
      warn "Node.js/Yarn tidak ditemukan. Mencoba instalasi..."
      apt-get update -y >/dev/null 2>&1 || true
      apt-get remove -y nodejs >/dev/null 2>&1 || true
      curl -fsSL https://deb.nodesource.com/setup_16.x | bash - >/dev/null 2>&1 || true
      apt-get install -y nodejs >/dev/null 2>&1 || true
      npm i -g yarn >/dev/null 2>&1 || true
    fi

    NODE_BIN="$(command -v node || true)"
    if [[ -n "$NODE_BIN" ]]; then
      NODE_VERSION="$( "$NODE_BIN" -v 2>/dev/null | sed 's/^v\([0-9]*\).*/\1/' || echo 0 )"
      if [[ "$NODE_VERSION" -ge 17 ]]; then
        export NODE_OPTIONS=--openssl-legacy-provider
        log "${YELLOW}Menerapkan NODE_OPTIONS=--openssl-legacy-provider${RESET}"
      fi
    fi

    pushd "$ROOT" >/dev/null 2>&1
    yarn add --silent cross-env >/dev/null 2>&1 || true

    if yarn run || true | grep -q "build:production"; then
      if ! NODE_OPTIONS="${NODE_OPTIONS:-}" yarn build:production --silent --progress; then
        err "yarn build gagal. Frontend Panel mungkin rusak."
      else
        ok "Frontend build selesai"
      fi
    elif [[ -f node_modules/.bin/webpack ]]; then
      if ! NODE_OPTIONS="${NODE_OPTIONS:-}" yarn run clean >/dev/null 2>&1; then warn "Clean step gagal."; fi
      if ! NODE_OPTIONS="${NODE_OPTIONS:-}" ./node_modules/.bin/webpack --mode production --silent --progress; then
        err "webpack build gagal. Frontend Panel mungkin rusak."
      else
        ok "Frontend webpack build selesai"
      fi
    else
      warn "Tidak ditemukan script build/webpack, lewati build frontend."
    fi

    popd >/dev/null 2>&1
  else
    log "Melewati yarn build."
  fi
}

# --- Fungsi Utama ---
install_all() {
  if ! check_dependencies; then return 1; fi
  
  IN_INSTALL=true
  ensure_backup_parent
  mkdir -p "$BACKUP_DIR"
  save_latest_symlink
  
  local admin_id="$1"
  log "Memulai instalasi GreySync Protect v$VERSION (admin_id=$admin_id)"
  
  echo '{ "status": "on" }' > "$STORAGE" 2>/dev/null || true
  echo '{ "superAdminId": '"$admin_id"' }' > "$IDPROTECT" 2>/dev/null || true
  ok "File konfigurasi diset (Admin ID: $admin_id)"

  patch_user_delete "$admin_id" || { err "Gagal patch user"; return 2; }
  patch_server_delete_service "$admin_id" || { err "Gagal patch server service"; return 2; }

  for tag in NODE NEST SETTINGS DATABASES LOCATIONS; do
    path="${TARGETS[$tag]}"
    ensure_auth_use "$path" || true
    insert_guard_into_first_method "$path" "$tag" "$admin_id" "index view show edit update create" || { err "Gagal patch $tag"; return 2; }
  done

  run_yarn_build || true
  fix_laravel || true

  ok "✅ GreySync Protect telah terinstall. Backup disimpan di: $BACKUP_DIR"
  IN_INSTALL=false
}

uninstall_all() {
  log "Memulai uninstalasi Protect: memulihkan backup terbaru"
  rm -f "$STORAGE" "$IDPROTECT" 2>/dev/null || true
  if ! restore_from_latest_backup; then
    err "Tidak ada backup ditemukan. Hanya file config yang dihapus."
  fi
  fix_laravel || true
  ok "✅ Uninstalled & dipulihkan."
}

admin_patch() {
  local newid="$1"
  if [[ ! "$newid" =~ ^[0-9]+$ ]]; then err "Penggunaan: $0 -a <numeric id>"; return 1; fi
  
  log "Mengubah SuperAdmin ID menjadi $newid dan menerapkan ulang patch."
  echo '{ "superAdminId": '"$newid"' }' > "$IDPROTECT"
  
  patch_user_delete "$newid" || true
  patch_server_delete_service "$newid" || true
  for tag in NODE NEST SETTINGS DATABASES LOCATIONS; do
    path="${TARGETS[$tag]}"
    ensure_auth_use "$path" || true
    insert_guard_into_first_method "$path" "$tag" "$newid" "index view show edit update create" || true
  done
  
  fix_laravel || true
  ok "SuperAdmin ID berhasil diset -> $newid"
}


# --- Error Handling & Menu ---
_on_error_trap() {
  local rc=$?
  if [[ "$IN_INSTALL" = true ]]; then
    err "Terjadi error selama instalasi. Mencoba rollback dari $BACKUP_DIR"
    restore_from_dir "$BACKUP_DIR" || err "Rollback gagal. Periksa file log!"
    fix_laravel || true
  fi
  exit $rc
}
trap _on_error_trap ERR

show_help() {
  echo -e "\n${CYAN}Penggunaan: $0 [perintah] [opsi]${RESET}"
  echo "Perintah:"
  echo "  -i <ID> (atau --install)    : Install Protect dengan Admin ID."
  echo "  -u (atau --uninstall)       : Uninstall Protect (pulihkan backup)."
  echo "  -r (atau --restore)         : Pulihkan dari backup terbaru saja."
  echo "  -a <ID> (atau --adminpatch) : Ubah ID SuperAdmin dan terapkan ulang patch."
  echo "  -b (atau --build)           : Sertakan build frontend (yarn/webpack) saat instalasi."
  echo "  -m (atau --menu)            : Tampilkan menu interaktif."
  echo "  -h (atau --help)            : Tampilkan bantuan ini."
}

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
      admin_patch "$nid"
      ;;
    5) exit 0 ;;
    *)
      err "Pilihan tidak valid"; exit 1 ;;
  esac
}

# --- Parsing Argumen dengan getopts (Final) ---

process_args() {
  local temp_args
  temp_args=$(getopt -o i:u::r::a:b::m::h:: --long install:,uninstall::,restore::,adminpatch:,build::,menu::,help:: -n 'script.sh' -- "$@")
  if [ $? != 0 ] ; then show_help >&2; exit 1 ; fi

  eval set -- "$temp_args"

  while true; do
    case "$1" in
      -i|--install)
        ADMIN_ID="$2"
        shift 2
        ;;
      -u|--uninstall)
        uninstall_all
        exit $EXIT_CODE
        ;;
      -r|--restore)
        restore_from_latest_backup && fix_laravel
        exit $EXIT_CODE
        ;;
      -a|--adminpatch)
        admin_patch "$2"
        exit $EXIT_CODE
        ;;
      -b|--build)
        YARN_BUILD=true
        shift
        ;;
      -m|--menu)
        print_menu
        exit $EXIT_CODE
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      --)
        shift
        break
        ;;
      *)
        err "Argument tidak valid: $1"
        show_help
        exit 1
        ;;
    esac
  done
}

# --- Eksekusi Awal ---
if [[ "$#" -gt 0 ]]; then
    process_args "$@"
    
    if [[ -n "${ADMIN_ID:-}" ]]; then
      if ! [[ "$ADMIN_ID" =~ ^[0-9]+$ ]]; then
        err "Admin ID harus berupa angka. Default: $ADMIN_ID_DEFAULT"
        exit 1
      fi
      install_all "$ADMIN_ID"
    fi
else
    print_menu
fi

exit $EXIT_CODE
