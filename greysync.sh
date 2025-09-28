#!/bin/bash
# GreySync Protect - v1.4 Final (Fix)
# Full protect: anti delete user/server + anti intip (files, storage, backups, settings)

ROOT="/var/www/pterodactyl"
MIDDLEWARE="$ROOT/app/Http/Middleware/GreySyncProtect.php"
KERNEL="$ROOT/app/Http/Kernel.php"
STORAGE="$ROOT/storage/app/greysync_protect.json"
IDPROTECT="$ROOT/storage/app/idprotect.json"
VIEW="$ROOT/resources/views/errors/protect.blade.php"
LOG="/var/log/greysync_protect.log"
BACKUP_DIR="$ROOT/greysync_backups_$(date +%s)"

USER_CONTROLLER="$ROOT/app/Http/Controllers/Admin/UserController.php"
SERVER_SERVICE="$ROOT/app/Services/Servers/ServerDeletionService.php"
ADMIN_CONTROLLERS=(
  "$ROOT/app/Http/Controllers/Admin/Nodes/NodeController.php"
  "$ROOT/app/Http/Controllers/Admin/Nests/NestController.php"
  "$ROOT/app/Http/Controllers/Admin/Settings/IndexController.php"
)

RED="\033[1;31m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; CYAN="\033[1;36m"; RESET="\033[0m"

log() { echo -e "$1"; echo -e "$(date '+%F %T') $1" >> "$LOG"; }
php_check() { php -l "$1" >/dev/null 2>&1; return $?; }
backup_file() { [[ -f "$1" ]] && mkdir -p "$BACKUP_DIR/$(dirname "${1#$ROOT/}")" && cp -f "$1" "$BACKUP_DIR/${1#$ROOT/}.bak"; }

# --- Kernel injection ---
insert_kernel_middleware() {
  grep -q "GreySyncProtect::class" "$KERNEL" 2>/dev/null && return
  backup_file "$KERNEL"
  LINE=$(grep -Fn "'web' => [" "$KERNEL" | cut -d: -f1 | head -n1)
  [[ -z "$LINE" ]] && return
  awk -v n=$((LINE+1)) 'NR==n{print "        \\App\\Http\\Middleware\\GreySyncProtect::class,"}1' "$KERNEL" > "$KERNEL.tmp" && mv "$KERNEL.tmp" "$KERNEL"
  php_check "$KERNEL" || cp -f "$BACKUP_DIR/${KERNEL#$ROOT/}.bak" "$KERNEL"
}
remove_kernel_middleware() { sed -i '/GreySyncProtect::class/d' "$KERNEL"; }

# --- Middleware file ---
write_middleware_file() {
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
    protected function deny($request,$superAdminId) {
        if ($request->ajax() || $request->wantsJson()) {
            return response()->json(['error'=>'❌ Akses ditolak','powered'=>'GreySync Protect'],403);
        }
        return response()->view('errors.protect',['superAdminId'=>$superAdminId],403);
    }
    public function handle($request, Closure $next) {
        $user = Auth::user();
        $superAdminId = $this->getSuperAdminId();
        if ($this->isProtectOn() && (!$user || $user->id !== $superAdminId)) {
            $blocked=['admin/backups','downloads','storage','server/*/files','api/client/servers/*/files','admin/settings*'];
            foreach ($blocked as $p) {
                if ($request->is("$p*")) return $this->deny($request,$superAdminId);
            }
        }
        return $next($request);
    }
}
PHP
}

# --- Error view ---
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
}

# --- Cache fix ---
fix_laravel() {
  cd "$ROOT" || return
  php artisan config:clear >/dev/null 2>&1
  php artisan cache:clear >/dev/null 2>&1
  php artisan route:clear >/dev/null 2>&1
  php artisan view:clear >/dev/null 2>&1
  chown -R www-data:www-data "$ROOT"
  chmod -R 755 "$ROOT/storage" "$ROOT/bootstrap/cache"
  systemctl restart nginx >/dev/null 2>&1
  systemctl restart php8.3-fpm >/dev/null 2>&1
}

# --- Patch controllers ---
patch_user_controller() {
  backup_file "$USER_CONTROLLER"
  grep -q "GREYSYNC_PROTECT_USER" "$USER_CONTROLLER" && return
  awk 'BEGIN{p=0}
/public function delete\(/ {print; inf=1; next}
inf==1 && /^[[:space:]]*{/ && p==0 {
  print;
  print "        // GREYSYNC_PROTECT_USER";
  print "        $user = \\Illuminate\\Support\\Facades\\Auth::user();";
  print "        if (!$user || $user->id !== (int)\\json_decode(file_get_contents(storage_path(\"app/idprotect.json\")), true)[\"superAdminId\"]) {";
  print "            throw new \\Pterodactyl\\Exceptions\\DisplayException(\"⛔ Akses ditolak (GreySync Protect)\");";
  print "        }"; p=1; next }
{print}' "$USER_CONTROLLER" > "$USER_CONTROLLER.tmp" && mv "$USER_CONTROLLER.tmp" "$USER_CONTROLLER"
}
patch_server_service() {
  backup_file "$SERVER_SERVICE"
  grep -q "GREYSYNC_PROTECT_SERVER" "$SERVER_SERVICE" && return
  awk 'BEGIN{p=0}
/public function handle\(/ {print; inf=1; next}
inf==1 && /^[[:space:]]*{/ && p==0 {
  print;
  print "        // GREYSYNC_PROTECT_SERVER";
  print "        $user = \\Illuminate\\Support\\Facades\\Auth::user();";
  print "        if ($user && $user->id !== (int)\\json_decode(file_get_contents(storage_path(\"app/idprotect.json\")), true)[\"superAdminId\"]) {";
  print "            throw new \\Pterodactyl\\Exceptions\\DisplayException(\"⛔ Akses ditolak (GreySync Protect)\");";
  print "        }"; p=1; next }
{print}' "$SERVER_SERVICE" > "$SERVER_SERVICE.tmp" && mv "$SERVER_SERVICE.tmp" "$SERVER_SERVICE"
}
patch_admin_controllers() {
  local admin_id="${1:-1}"
  for ctrl in "${ADMIN_CONTROLLERS[@]}"; do
    backup_file "$ctrl"
    grep -q "GREYSYNC_PROTECT_ADMIN" "$ctrl" && continue
    perl -0777 -pe "
      my \$a=$admin_id;
      if (/namespace\s+[^\r\n]+;/s && !/Illuminate\\\\Support\\\\Facades\\\\Auth/) {
        s/(namespace\s+[^\r\n]+;)/\$1\nuse Illuminate\\\\Support\\\\Facades\\\\Auth;/;
      }
      s/(public function index\([^\)]*\)\s*\{)/\$1\n        \/\/ GREYSYNC_PROTECT_ADMIN\n        \$user = Auth::user();\n        if (!\$user || \$user->id != \$a) { abort(403, \"⛔ Akses ditolak (GreySync Protect)\"); }/s;
    " "$ctrl" > "$ctrl.tmp" && mv "$ctrl.tmp" "$ctrl"
  done
}

# --- Restore ---
restore_patched_controllers() {
  LATEST_BACKUP=$(ls -td $ROOT/greysync_backups_* 2>/dev/null | head -n1)
  [[ -z "$LATEST_BACKUP" ]] && { log "${YELLOW}⚠️ Tidak ada backup untuk restore${RESET}"; return; }
  for ctrl in "${ADMIN_CONTROLLERS[@]}" "$USER_CONTROLLER" "$SERVER_SERVICE"; do
    [[ -f "$LATEST_BACKUP/${ctrl#$ROOT/}.bak" ]] && cp -f "$LATEST_BACKUP/${ctrl#$ROOT/}.bak" "$ctrl"
  done
  fix_laravel
}

# --- Ops ---
install_all() {
  mkdir -p "$BACKUP_DIR"
  insert_kernel_middleware
  write_middleware_file
  write_error_view
  echo '{ "status": "on" }' > "$STORAGE"
  echo '{ "superAdminId": 1 }' > "$IDPROTECT"
  patch_user_controller
  patch_server_service
  patch_admin_controllers 1
  cd "$ROOT" && composer dump-autoload -o
  fix_laravel
  log "${GREEN}✅ GreySync Protect installed.${RESET}"
}
uninstall_all() {
  rm -f "$MIDDLEWARE" "$VIEW" "$STORAGE" "$IDPROTECT"
  remove_kernel_middleware
  restore_patched_controllers
  fix_laravel
  log "${GREEN}✅ GreySync Protect uninstalled.${RESET}"
}

case "$1" in
  install|"") install_all ;;
  uninstall) uninstall_all ;;
  restore) restore_patched_controllers ;;
  adminpatch) [[ -z "$2" ]] && { echo "Usage: $0 adminpatch <ID>"; exit 1; }; patch_admin_controllers "$2"; fix_laravel ;;
  adminrestore) restore_patched_controllers ;;
  *) echo -e "${CYAN}GreySync Protect v1.4 Final${RESET}"; echo "Usage: $0 {install|uninstall|restore|adminpatch <id>|adminrestore}";;
esac
