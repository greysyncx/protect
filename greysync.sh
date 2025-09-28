#!/bin/bash
# GreySync Protect - All-in-one (middleware + controller/service patches)
# Versi: 1.3 (fix middleware check, clean patch functions)
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

# backup a file
backup_file() {
  local src="$1"
  if [[ -f "$src" ]]; then
    mkdir -p "$BACKUP_DIR/$(dirname "${src#$ROOT/}")"
    cp -f "$src" "$BACKUP_DIR/${src#$ROOT/}.bak"
    log "${YELLOW}backup: $src -> $BACKUP_DIR/${src#$ROOT/}.bak${RESET}"
  fi
}

# restore backups
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

# insert Kernel middleware
insert_kernel_middleware() {
  if [[ ! -f "$KERNEL" ]]; then log "${RED}Kernel.php not found: $KERNEL${RESET}"; return 1; fi
  if grep -q "\\\\App\\\\Http\\\\Middleware\\\\GreySyncProtect" "$KERNEL" 2>/dev/null; then
    log "${YELLOW}Middleware already present in Kernel.php (skip)${RESET}"; return 0
  fi
  backup_file "$KERNEL"
  LINE=$(grep -Fn "'web' => [" "$KERNEL" | cut -d: -f1 | head -n1)
  if [[ -z "$LINE" ]]; then
    log "${YELLOW}Couldn't find 'web' middleware array; skipping kernel injection${RESET}"
    return 0
  fi
  awk -v n=$((LINE+1)) 'NR==n{print "        \\App\\Http\\Middleware\\GreySyncProtect::class,"}1' "$KERNEL" > "$KERNEL.tmp" && mv "$KERNEL.tmp" "$KERNEL"
  php_check "$KERNEL" || { log "${RED}Kernel.php syntax error, restoring backup${RESET}"; cp -f "$BACKUP_DIR/${KERNEL#$ROOT/}.bak" "$KERNEL"; return 1; }
  log "${GREEN}Injected middleware into Kernel.php${RESET}"
}

# remove Kernel middleware
remove_kernel_middleware() {
  [[ -f "$KERNEL" ]] && sed -i '/GreySyncProtect::class/d' "$KERNEL"
  log "${GREEN}Removed GreySyncProtect entries from Kernel.php (if any)${RESET}"
}

# write middleware file
write_middleware_file() {
  mkdir -p "$(dirname "$MIDDLEWARE")"
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
  php_check "$MIDDLEWARE" || { log "${RED}Middleware file syntax error${RESET}"; return 1; }
  log "${GREEN}Middleware file written${RESET}"
}

# write error view
write_error_view() {
  mkdir -p "$(dirname "$VIEW")"
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

# clear cache & restart
fix_laravel() {
  cd "$ROOT" || return 1
  php artisan config:clear >/dev/null 2>&1
  php artisan cache:clear >/dev/null 2>&1
  php artisan route:clear >/dev/null 2>&1
  php artisan view:clear >/dev/null 2>&1
  chown -R www-data:www-data "$ROOT"
  chmod -R 755 "$ROOT/storage" "$ROOT/bootstrap/cache"
  systemctl restart nginx >/dev/null 2>&1
  systemctl restart "$(detect_php_fpm)" >/dev/null 2>&1
  log "${GREEN}Laravel cache/perm fixed and services restarted${RESET}"
}

# ---------- PATCH: UserController ----------
patch_user_controller() {
  if [[ ! -f "$USER_CONTROLLER" ]]; then log "${YELLOW}UserController not found (skip)${RESET}"; return 1; fi
  backup_file "$USER_CONTROLLER"
  grep -q "GREYSYNC_PROTECT_USER" "$USER_CONTROLLER" && { log "${YELLOW}UserController already patched${RESET}"; return 0; }
  awk 'BEGIN{patched=0}
/public function delete\(/ {print; infunc=1; next}
infunc==1 && /^[[:space:]]*{/ && patched==0 {
  print;
  print "        // GREYSYNC_PROTECT_USER";
  print "        $user = \\Illuminate\\Support\\Facades\\Auth::user();";
  print "        if (!$user || $user->id !== (int)\\json_decode(file_get_contents(storage_path(\"app/idprotect.json\")), true)[\"superAdminId\"]) {";
  print "            throw new \\Pterodactyl\\Exceptions\\DisplayException(\"⛔ Akses ditolak (GreySync Protect)\");";
  print "        }"; patched=1; next }
{print}' "$USER_CONTROLLER" > "$USER_CONTROLLER.tmp" && mv "$USER_CONTROLLER.tmp" "$USER_CONTROLLER"
  php_check "$USER_CONTROLLER" || { cp -f "$BACKUP_DIR/${USER_CONTROLLER#$ROOT/}.bak" "$USER_CONTROLLER"; return 2; }
  log "${GREEN}Patched UserController${RESET}"
}

# ---------- PATCH: ServerDeletionService ----------
patch_server_service() {
  if [[ ! -f "$SERVER_SERVICE" ]]; then log "${YELLOW}ServerDeletionService not found (skip)${RESET}"; return 1; fi
  backup_file "$SERVER_SERVICE"
  grep -q "GREYSYNC_PROTECT_SERVER" "$SERVER_SERVICE" && { log "${YELLOW}ServerDeletionService already patched${RESET}"; return 0; }
  awk 'BEGIN{patched=0}
/public function handle\(/ {print; infunc=1; next}
infunc==1 && /^[[:space:]]*{/ && patched==0 {
  print;
  print "        // GREYSYNC_PROTECT_SERVER";
  print "        $user = \\Illuminate\\Support\\Facades\\Auth::user();";
  print "        if ($user && $user->id !== (int)\\json_decode(file_get_contents(storage_path(\"app/idprotect.json\")), true)[\"superAdminId\"]) {";
  print "            throw new \\Pterodactyl\\Exceptions\\DisplayException(\"⛔ Akses ditolak (GreySync Protect)\");";
  print "        }"; patched=1; next }
{print}' "$SERVER_SERVICE" > "$SERVER_SERVICE.tmp" && mv "$SERVER_SERVICE.tmp" "$SERVER_SERVICE"
  php_check "$SERVER_SERVICE" || { cp -f "$BACKUP_DIR/${SERVER_SERVICE#$ROOT/}.bak" "$SERVER_SERVICE"; return 2; }
  log "${GREEN}Patched ServerDeletionService${RESET}"
}

# ---------- PATCH: Admin Controllers ----------
patch_admin_controllers() {
  local admin_id="${1:-1}"
  for ctrl in "${ADMIN_CONTROLLERS[@]}"; do
    [[ ! -f "$ctrl" ]] && { log "${YELLOW}Not found: $ctrl${RESET}"; continue; }
    backup_file "$ctrl"
    grep -q "GREYSYNC_PROTECT_ADMIN" "$ctrl" && { log "${YELLOW}Already patched: $ctrl${RESET}"; continue; }
    perl -0777 -pe "
      my \$admin = $admin_id;
      if (/namespace\s+[^\r\n]+;\s*/s) {
        if (!/use\s+Illuminate\\\\Support\\\\Facades\\\\Auth;/) {
          s/namespace\s+[^\r\n]+;\s*/\$&\nuse Illuminate\\\\Support\\\\Facades\\\\Auth;\n/;
        }
      }
      s/(public function index\([^\)]*\)\s*\{\s*)/\$1\n        \/\/ GREYSYNC_PROTECT_ADMIN\n        \$user = Auth::user();\n        if (!\$user || \$user->id != \$admin) { abort(403, \"⛔ Akses ditolak (GreySync Protect)\"); }\n/eg;
    " "$ctrl" > "$ctrl.tmp" && mv "$ctrl.tmp" "$ctrl"
    php_check "$ctrl" || { cp -f "$BACKUP_DIR/${ctrl#$ROOT/}.bak" "$ctrl"; continue; }
    sed -i '1i// GREYSYNC_PROTECT_ADMIN' "$ctrl"
    log "${GREEN}Patched admin controller: $ctrl${RESET}"
  done
}

# ---------- Restore controllers ----------
restore_patched_controllers() {
  for ctrl in "${ADMIN_CONTROLLERS[@]}" "$USER_CONTROLLER" "$SERVER_SERVICE"; do
    [[ -f "$BACKUP_DIR/${ctrl#$ROOT/}.bak" ]] && cp -f "$BACKUP_DIR/${ctrl#$ROOT/}.bak" "$ctrl"
  done
  fix_laravel
}

# ---------- Main ops ----------
install_all() {
  mkdir -p "$BACKUP_DIR"
  insert_kernel_middleware
  write_middleware_file
  [[ ! -f "$MIDDLEWARE" ]] && { log "${RED}Middleware missing after write${RESET}"; return 1; }
  write_error_view
  echo '{ "status": "on" }' > "$STORAGE"
  echo '{ "superAdminId": 1 }' > "$IDPROTECT"
  patch_user_controller
  patch_server_service
  patch_admin_controllers 1
  fix_laravel
  log "${GREEN}Full install finished (protect active).${RESET}"
}

uninstall_all() {
  rm -f "$MIDDLEWARE" "$VIEW" "$STORAGE" "$IDPROTECT"
  remove_kernel_middleware
  restore_patched_controllers
  fix_laravel
  log "${GREEN}Uninstall finished.${RESET}"
}

# CLI
case "$1" in
  install|"") install_all ;;
  uninstall) uninstall_all ;;
  restore) restore_backups ;;
  adminpatch) [[ -z "$2" ]] && { echo "Usage: $0 adminpatch <ADMIN_ID>"; exit 1; }; patch_admin_controllers "$2"; fix_laravel ;;
  adminrestore) restore_patched_controllers ;;
  *) echo -e "${CYAN}GreySync Protect v1.3${RESET}"; echo "Usage: $0 {install|uninstall|restore|adminpatch <id>|adminrestore}"; exit 1 ;;
esac
