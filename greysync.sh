#!/bin/bash
# GreySync Protect - All-in-one (middleware + controller/service patches)
# Versi: 1.2 (safe, backup, restore, auto php-fpm detect)
#
# Usage:
#   greysync.sh           # default = install
#   greysync.sh install
#   greysync.sh uninstall
#   greysync.sh restore
#   greysync.sh adminpatch <ADMIN_ID>   # apply admin ID to patched controllers (optional)
#   greysync.sh adminrestore            # restore controller backups

ROOT="/var/www/pterodactyl"
MIDDLEWARE="$ROOT/app/Http/Middleware/GreySyncProtect.php"
KERNEL="$ROOT/app/Http/Kernel.php"
STORAGE="$ROOT/storage/app/greysync_protect.json"
IDPROTECT="$ROOT/storage/app/idprotect.json"
VIEW="$ROOT/resources/views/errors/protect.blade.php"
ENV="$ROOT/.env"
LOG="/var/log/greysync_protect.log"
BACKUP_DIR="$ROOT/greysync_backups_$(date +%s)"

# Controller / service targets to patch
USER_CONTROLLER="$ROOT/app/Http/Controllers/Admin/UserController.php"
SERVER_SERVICE="$ROOT/app/Services/Servers/ServerDeletionService.php"
ADMIN_CONTROLLERS=(
  "$ROOT/app/Http/Controllers/Admin/Nodes/NodeController.php"
  "$ROOT/app/Http/Controllers/Admin/Nests/NestController.php"
  "$ROOT/app/Http/Controllers/Admin/Settings/IndexController.php"
)

# Colors
RED="\033[1;31m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; CYAN="\033[1;36m"; RESET="\033[0m"

log() { echo -e "$1"; echo -e "$(date '+%F %T') $1" >> "$LOG"; }

# detect running php-fpm service name
detect_php_fpm() {
  local svc
  svc=$(systemctl list-units --type=service --all | grep -oE 'php[0-9]+(\.[0-9]+)?-fpm' | head -n1)
  echo "${svc:-php8.3-fpm}"
}

# safe php lint check for a file
php_check() {
  php -l "$1" >/dev/null 2>&1
  return $?
}

# backup a file (preserve dir structure under BACKUP_DIR)
backup_file() {
  local src="$1"
  if [[ -f "$src" ]]; then
    mkdir -p "$BACKUP_DIR/$(dirname "${src#$ROOT/}")"
    cp -f "$src" "$BACKUP_DIR/${src#$ROOT/}.bak"
    log "${YELLOW}backup: $src -> $BACKUP_DIR/${src#$ROOT/}.bak${RESET}"
  fi
}

# restore backups (used for adminrestore or uninstall)
restore_backups() {
  if [[ ! -d "$BACKUP_DIR" ]]; then
    log "${YELLOW}No backup dir: $BACKUP_DIR (nothing to restore)${RESET}"
    return 1
  fi
  log "${CYAN}Restoring backups from $BACKUP_DIR...${RESET}"
  find "$BACKUP_DIR" -type f -name "*.bak" | while read -r f; do
    target="$ROOT/${f#$BACKUP_DIR/}"
    target="${target%.bak}"
    mkdir -p "$(dirname "$target")"
    cp -f "$f" "$target"
    log "${GREEN}restored $target${RESET}"
  done
  fix_laravel
  return 0
}

# insert Kernel middleware safely (with leading backslash)
insert_kernel_middleware() {
  if [[ ! -f "$KERNEL" ]]; then log "${RED}Kernel.php not found: $KERNEL${RESET}"; return 1; fi
  if grep -q "\\\\App\\\\Http\\\\Middleware\\\\GreySyncProtect" "$KERNEL" 2>/dev/null || grep -q "GreySyncProtect" "$KERNEL" 2>/dev/null; then
    log "${YELLOW}Middleware already present in Kernel.php (skip)${RESET}"; return 0
  fi
  backup_file "$KERNEL"
  cp "$KERNEL" "$KERNEL.tmp"
  LINE=$(grep -Fn "'web' => [" "$KERNEL" 2>/dev/null | cut -d: -f1 | head -n1)
  if [[ -z "$LINE" ]]; then
    log "${YELLOW}Couldn't find 'web' middleware array; skipping kernel injection${RESET}"
    return 0
  fi
  awk -v n=$((LINE+1)) 'NR==n{print "        \\App\\Http\\Middleware\\GreySyncProtect::class,"}1' "$KERNEL" > "$KERNEL.tmp" && mv "$KERNEL.tmp" "$KERNEL"
  # validate php syntax
  if ! php_check "$KERNEL"; then
    log "${RED}Kernel.php syntax error after injection, restoring backup${RESET}"
    cp -f "$BACKUP_DIR/${KERNEL#$ROOT/}.bak" "$KERNEL" 2>/dev/null || true
    return 1
  fi
  log "${GREEN}Injected middleware into Kernel.php${RESET}"
  return 0
}

# remove injected middleware (pattern)
remove_kernel_middleware() {
  if [[ ! -f "$KERNEL" ]]; then return 0; fi
  sed -i '/GreySyncProtect::class/d' "$KERNEL" 2>/dev/null || true
  log "${GREEN}Removed GreySyncProtect entries from Kernel.php (if any)${RESET}"
}

# write middleware php file
write_middleware_file() {
  mkdir -p "$(dirname "$MIDDLEWARE")"
  backup_file "$MIDDLEWARE"
  cat > "$MIDDLEWARE" <<'PHP'
<?php
namespace App\Http\Middleware;
use Closure;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Facades\Auth;
class GreySyncProtect {
    protected function getSuperAdminId() {
        $path = storage_path('app/idprotect.json');
        if (file_exists($path)) {
            $data = json_decode(file_get_contents($path), true);
            return intval($data['superAdminId'] ?? 1);
        }
        return 1;
    }
    protected function isProtectOn() {
        if (Storage::exists('greysync_protect.json')) {
            $data = json_decode(Storage::get('greysync_protect.json'), true);
            return ($data['status'] ?? 'off') === 'on';
        }
        return false;
    }
    protected function deny($request, $superAdminId) {
        if ($request->ajax() || $request->wantsJson()) {
            return response()->json(['error'=>'❌ Akses ditolak','powered'=>'GreySync Protect'],403);
        }
        return response()->view('errors.protect',['superAdminId'=>$superAdminId],403);
    }
    public function handle($request, Closure $next) {
        $user = Auth::user();
        $superAdminId = $this->getSuperAdminId();
        if ($this->isProtectOn() && (!$user || $user->id !== $superAdminId)) {
            $blocked=['admin/backups','downloads','storage','server/*/files','api/client/servers/*/files'];
            foreach ($blocked as $p) {
                if ($request->is("$p*")) return $this->deny($request,$superAdminId);
            }
        }
        return $next($request);
    }
}
PHP
  # quick syntax check
  if ! php_check "$MIDDLEWARE"; then
    log "${RED}Middleware file syntax error; restoring backup${RESET}"
    cp -f "$BACKUP_DIR/${MIDDLEWARE#$ROOT/}.bak" "$MIDDLEWARE" 2>/dev/null || true
    return 1
  fi
  log "${GREEN}Middleware file written${RESET}"
}

write_error_view() {
  mkdir -p "$(dirname "$VIEW")"
  backup_file "$VIEW"
  cat > "$VIEW" <<'BLADE'
<!doctype html><html><head><meta charset="utf-8">
<title>GreySync Protect</title>
<style>body{background:#bf1f2b;color:#fff;display:flex;align-items:center;justify-content:center;height:100vh;font-family:Arial;text-align:center}</style></head><body>
<div><h1>❌ Akses dibatasi (GreySync Protect)</h1>
<p>Jika ini panelmu, hubungi super admin.</p>
<small>⿻ GreySync Protect</small></div>
</body></html>
BLADE
  log "${GREEN}Error view written${RESET}"
}

fix_laravel() {
  cd "$ROOT" || return 1
  php artisan config:clear >/dev/null 2>&1 || true
  php artisan cache:clear >/dev/null 2>&1 || true
  php artisan route:clear >/dev/null 2>&1 || true
  php artisan view:clear >/dev/null 2>&1 || true
  chown -R www-data:www-data "$ROOT"
  chmod -R 755 "$ROOT/storage" "$ROOT/bootstrap/cache"
  local fpm
  fpm=$(detect_php_fpm)
  systemctl restart nginx >/dev/null 2>&1 || true
  systemctl restart "$fpm" >/dev/null 2>&1 || true
  log "${GREEN}Laravel cache/perm fixed and services restarted ($fpm)${RESET}"
}

# ---------- PATCH: UserController (anti delete user) ----------
patch_user_controller() {
  if [[ ! -f "$USER_CONTROLLER" ]]; then
    log "${YELLOW}UserController not found: $USER_CONTROLLER (skip)${RESET}"
    return 1
  fi
  # backup
  backup_file "$USER_CONTROLLER"
  # if already patched, skip
  if grep -q "GREYSYNC_PROTECT_USER" "$USER_CONTROLLER"; then
    log "${YELLOW}UserController already patched (skip)${RESET}"; return 0
  fi

  # insert check inside delete method (look for public function delete( ... ) pattern)
  awk 'BEGIN{patched=0}
/public function delete\(/ {
  print; infunc=1; next
}
infunc==1 && /^[[:space:]]*{/ && patched==0 {
  print;
  print "        // GREYSYNC_PROTECT_USER: block delete for non-superadmin";
  print "        $user = \\Illuminate\\Support\\Facades\\Auth::user();";
  print "        if (!$user || $user->id !== (int)\\json_decode(file_get_contents(storage_path(\"app/idprotect.json\")), true)[\"superAdminId\"]) {";
  print "            throw new \\Pterodactyl\\Exceptions\\DisplayException(\"⛔ Akses ditolak (GreySync Protect)\");";
  print "        }";
  patched=1;
  next
}
{ print } END{ if(patched==0) exit 0 }' "$USER_CONTROLLER" > "$USER_CONTROLLER.tmp" && mv "$USER_CONTROLLER.tmp" "$USER_CONTROLLER"

  # check syntax
  if ! php_check "$USER_CONTROLLER"; then
    log "${RED}Patch UserController caused syntax error, restoring backup${RESET}"
    cp -f "$BACKUP_DIR/${USER_CONTROLLER#$ROOT/}.bak" "$USER_CONTROLLER" 2>/dev/null || true
    return 2
  fi
  log "${GREEN}Patched UserController (anti delete)${RESET}"
}

# ---------- PATCH: ServerDeletionService (anti delete server) ----------
patch_server_service() {
  if [[ ! -f "$SERVER_SERVICE" ]]; then
    log "${YELLOW}ServerDeletionService not found: $SERVER_SERVICE (skip)${RESET}"
    return 1
  fi
  backup_file "$SERVER_SERVICE"
  if grep -q "GREYSYNC_PROTECT_SERVER" "$SERVER_SERVICE"; then
    log "${YELLOW}ServerDeletionService already patched (skip)${RESET}"; return 0
  fi

  # insert user check at start of handle function
  awk 'BEGIN{patched=0}
/public function handle\(/ {
  print; infunc=1; next
}
infunc==1 && /^[[:space:]]*{/ && patched==0 {
  print;
  print "        // GREYSYNC_PROTECT_SERVER: block server delete for non-superadmin";
  print "        $user = \\Illuminate\\Support\\Facades\\Auth::user();";
  print "        if ($user && $user->id !== (int)\\json_decode(file_get_contents(storage_path(\"app/idprotect.json\")), true)[\"superAdminId\"]) {";
  print "            throw new \\Pterodactyl\\Exceptions\\DisplayException(\"⛔ Akses ditolak (GreySync Protect)\");";
  print "        }";
  patched=1;
  next
}
{ print } END{ if(patched==0) exit 0 }' "$SERVER_SERVICE" > "$SERVER_SERVICE.tmp" && mv "$SERVER_SERVICE.tmp" "$SERVER_SERVICE"

  if ! php_check "$SERVER_SERVICE"; then
    log "${RED}Patch ServerDeletionService caused syntax error, restoring backup${RESET}"
    cp -f "$BACKUP_DIR/${SERVER_SERVICE#$ROOT/}.bak" "$SERVER_SERVICE" 2>/dev/null || true
    return 2
  fi
  log "${GREEN}Patched ServerDeletionService (anti delete)${RESET}"
}

# ---------- PATCH: Admin Controllers (Node, Nest, Settings) ----------
patch_admin_controllers() {
  local admin_id="${1:-1}"
  mkdir -p "$BACKUP_DIR"
  for ctrl in "${ADMIN_CONTROLLERS[@]}"; do
    if [[ ! -f "$ctrl" ]]; then
      log "${YELLOW}Controller not found (skip): $ctrl${RESET}"
      continue
    fi
    backup_file "$ctrl"
    # skip if already patched
    if grep -q "GREYSYNC_PROTECT_ADMIN" "$ctrl"; then
      log "${YELLOW}Already patched: $ctrl${RESET}"
      continue
    fi

    # Add use Auth; ensure it exists and insert check in public function index()
    awk -v admin_id="$admin_id" '
    BEGIN{in_namespace=0; inserted_use=0; in_func=0; patched=0}
    /^namespace / { print; next }
    /^use / && !inserted_use {
      print
      next
    }
    # print file but capture namespace header to insert uses
    { print }
    ' "$ctrl" > "$ctrl.tmp" # baseline copy; we'll do safer approach below

    # safer approach: insert use Illuminate\Support\Facades\Auth; after namespace line if not present
    perl -0777 -pe '
      BEGIN{$admin=shift @ARGV}
      if (/namespace\s+[^\r\n]+;\s*/s) {
        $ns=$&;
        if ($_ !~ /use\s+Illuminate\\\Support\\\Facades\\\Auth;/) {
          s/namespace\s+[^\r\n]+;\s*/$&\nuse Illuminate\\\Support\\\Facades\\\Auth;\n/;
        }
      }
      # insert check inside public function index
      s/(public function index\([^\)]*\)\s*\{\s*)/$1\n        // GREYSYNC_PROTECT_ADMIN: block for non-superadmin\n        \$user = Auth::user();\n        if (!\$user || \$user->id != '$admin') { abort(403, "⛔ Akses ditolak (GreySync Protect)"); }\n/eg;
    ' "$admin_id" "$ctrl.tmp" > "$ctrl.patched" && mv "$ctrl.patched" "$ctrl"

    rm -f "$ctrl.tmp"

    if ! php_check "$ctrl"; then
      log "${RED}Patch $ctrl caused syntax error, restoring backup${RESET}"
      cp -f "$BACKUP_DIR/${ctrl#$ROOT/}.bak" "$ctrl" 2>/dev/null || true
      continue
    fi
    # mark file
    sed -i '1i// GREYSYNC_PROTECT_ADMIN' "$ctrl"
    log "${GREEN}Patched admin controller: $ctrl${RESET}"
  done
}

# ---------- RESTORE individual patched controllers from backups ----------
restore_patched_controllers() {
  for ctrl in "${ADMIN_CONTROLLERS[@]}" "$USER_CONTROLLER" "$SERVER_SERVICE"; do
    if [[ -f "$BACKUP_DIR/${ctrl#$ROOT/}.bak" ]]; then
      cp -f "$BACKUP_DIR/${ctrl#$ROOT/}.bak" "$ctrl"
      log "${GREEN}Restored $ctrl from backup${RESET}"
    fi
  done
  fix_laravel
}

# ---------- Main install / uninstall / restore ----------
install_all() {
  mkdir -p "$BACKUP_DIR"
  insert_kernel_middleware || log "${YELLOW}Kernel injection failed, but continuing (backup kept)${RESET}"
  write_middleware_file || log "${YELLOW}Middleware write failed${RESET}"
  write_error_view
  echo '{ "status": "on" }' > "$STORAGE"
  echo '{ "superAdminId": 1 }' > "$IDPROTECT"
  # patch controllers/services
  patch_user_controller || log "${YELLOW}UserController patch skipped/failed${RESET}"
  patch_server_service || log "${YELLOW}ServerDeletionService patch skipped/failed${RESET}"
  patch_admin_controllers 1 || log "${YELLOW}Admin controllers patch skipped/failed${RESET}"
  fix_laravel
  log "${GREEN}Full install finished (protect active).${RESET}"
}

uninstall_all() {
  # remove middleware & status files
  rm -f "$MIDDLEWARE" "$VIEW" "$STORAGE" "$IDPROTECT"
  remove_kernel_middleware
  # restore patched controllers from this run's backup dir if present
  restore_patched_controllers || log "${YELLOW}Controller restore attempted${RESET}"
  fix_laravel
  log "${GREEN}Uninstall finished.${RESET}"
}

# CLI handlers
case "$1" in
  install|"") install_all ;;
  uninstall) uninstall_all ;;
  restore) restore_backups ;;        # restore any backups made earlier (from BACKUP_DIR)
  adminpatch)
    if [[ -z "$2" ]]; then echo "Usage: $0 adminpatch <ADMIN_ID>"; exit 1; fi
    mkdir -p "$BACKUP_DIR"
    patch_admin_controllers "$2"
    fix_laravel
    ;;
  adminrestore) restore_patched_controllers ;;
  *) echo -e "${CYAN}GreySync Protect v1.2${RESET}"; echo "Usage: $0 {install|uninstall|restore|adminpatch <id>|adminrestore}"; exit 1 ;;
esac
