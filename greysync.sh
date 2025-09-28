# simpan script
sudo tee /root/greysync_fixed.sh > /dev/null <<'SH'
#!/bin/bash
# GreySync Protect - robust fix (no perl escaping issues)
# Versi: 1.4-fixed
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

# colors
RED="\033[1;31m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; CYAN="\033[1;36m"; RESET="\033[0m"

log() { echo -e "$1"; echo -e "$(date '+%F %T') $1" >> "$LOG"; }

detect_php_fpm() {
  local svc
  svc=$(systemctl list-units --type=service --all | grep -oE 'php[0-9]+(\.[0-9]+)?-fpm' | head -n1)
  echo "${svc:-php8.3-fpm}"
}

php_check() {
  php -l "$1" >/dev/null 2>&1
  return $?
}

backup_file() {
  local src="$1"
  if [[ -f "$src" ]]; then
    mkdir -p "$BACKUP_DIR/$(dirname "${src#$ROOT/}")"
    cp -f "$src" "$BACKUP_DIR/${src#$ROOT/}.bak"
    log "${YELLOW}backup: $src -> $BACKUP_DIR/${src#$ROOT/}.bak${RESET}"
  fi
}

restore_file_from_backup() {
  local src="$1"
  if [[ -f "$BACKUP_DIR/${src#$ROOT/}.bak" ]]; then
    cp -f "$BACKUP_DIR/${src#$ROOT/}.bak" "$src"
    log "${GREEN}restored $src from backup${RESET}"
  fi
}

insert_kernel_middleware() {
  if [[ ! -f "$KERNEL" ]]; then log "${RED}Kernel.php not found: $KERNEL${RESET}"; return 1; fi
  # only insert once
  if grep -q "\\\\App\\\\Http\\\\Middleware\\\\GreySyncProtect::class" "$KERNEL" 2>/dev/null || grep -q "GreySyncProtect::class" "$KERNEL" 2>/dev/null; then
    log "${YELLOW}Kernel already contains GreySyncProtect${RESET}"
    return 0
  fi
  backup_file "$KERNEL"
  # find 'web' middleware array line and insert next line
  LINE=$(grep -Fn "'web' => [" "$KERNEL" 2>/dev/null | cut -d: -f1 | head -n1)
  if [[ -z "$LINE" ]]; then
    # fallback: try to find middlewareGroups array start
    LINE=$(grep -Fn "protected \\$middlewareGroups" "$KERNEL" 2>/dev/null | cut -d: -f1 | head -n1)
  fi
  if [[ -z "$LINE" ]]; then
    log "${YELLOW}Couldn't find web middleware array; skipping kernel injection${RESET}"
    return 0
  fi
  awk -v n=$((LINE+1)) 'NR==n{print "        \\App\\Http\\Middleware\\GreySyncProtect::class,"}1' "$KERNEL" > "$KERNEL.tmp" && mv "$KERNEL.tmp" "$KERNEL"
  if ! php_check "$KERNEL"; then
    log "${RED}Kernel syntax error after injection, restoring backup${RESET}"
    restore_file_from_backup "$KERNEL"
    return 1
  fi
  log "${GREEN}Injected middleware into Kernel.php${RESET}"
  return 0
}

remove_kernel_middleware() {
  [[ -f "$KERNEL" ]] && sed -i '/GreySyncProtect::class/d' "$KERNEL"
  log "${GREEN}Removed GreySyncProtect entries from Kernel.php (if any)${RESET}"
}

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
  chown --no-dereference www-data:www-data "$MIDDLEWARE" 2>/dev/null || true
  chmod 644 "$MIDDLEWARE" 2>/dev/null || true
  if ! php_check "$MIDDLEWARE"; then
    log "${RED}Middleware file syntax error after write${RESET}"
    restore_file_from_backup "$MIDDLEWARE"
    return 1
  fi
  log "${GREEN}Middleware file written${RESET}"
  return 0
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
  chown --no-dereference www-data:www-data "$VIEW" 2>/dev/null || true
  chmod 644 "$VIEW" 2>/dev/null || true
  log "${GREEN}Error view written${RESET}"
}

fix_laravel() {
  cd "$ROOT" || return 1
  php artisan config:clear >/dev/null 2>&1 || true
  php artisan cache:clear >/dev/null 2>&1 || true
  php artisan route:clear >/dev/null 2>&1 || true
  php artisan view:clear >/dev/null 2>&1 || true
  composer dump-autoload --no-dev -o >/dev/null 2>&1 || true
  chown -R www-data:www-data "$ROOT"
  chmod -R 755 "$ROOT/storage" "$ROOT/bootstrap/cache"
  systemctl restart nginx >/dev/null 2>&1 || true
  systemctl restart "$(detect_php_fpm)" >/dev/null 2>&1 || true
  log "${GREEN}Laravel cache/perm fixed and services restarted${RESET}"
}

# patch user controller (insert inside delete method)
patch_user_controller() {
  [[ -f "$USER_CONTROLLER" ]] || { log "${YELLOW}UserController not found (skip)${RESET}"; return 1; }
  backup_file "$USER_CONTROLLER"
  if grep -q "GREYSYNC_PROTECT_USER" "$USER_CONTROLLER"; then
    log "${YELLOW}UserController already patched (skip)${RESET}"; return 0
  fi
  awk 'BEGIN{patched=0}
/public function delete\(/ {print; infunc=1; next}
infunc==1 && /^[[:space:]]*{/ && patched==0 {
  print;
  print "        // GREYSYNC_PROTECT_USER";
  print "        $user = \\Illuminate\\Support\\Facades\\Auth::user();";
  print "        if (!$user || $user->id !== (int)\\json_decode(file_get_contents(storage_path(\"app/idprotect.json\")), true)[\"superAdminId\"]) {";
  print "            throw new \\Pterodactyl\\Exceptions\\DisplayException(\"⛔ Akses ditolak (GreySync Protect)\");";
  print "        }";
  patched=1; next
}
{print}' "$USER_CONTROLLER" > "$USER_CONTROLLER.tmp" && mv "$USER_CONTROLLER.tmp" "$USER_CONTROLLER"
  if ! php_check "$USER_CONTROLLER"; then
    log "${RED}UserController syntax error after patch, restoring backup${RESET}"
    restore_file_from_backup "$USER_CONTROLLER"
    return 2
  fi
  log "${GREEN}Patched UserController${RESET}"
}

# patch server deletion service
patch_server_service() {
  [[ -f "$SERVER_SERVICE" ]] || { log "${YELLOW}ServerDeletionService not found (skip)${RESET}"; return 1; }
  backup_file "$SERVER_SERVICE"
  if grep -q "GREYSYNC_PROTECT_SERVER" "$SERVER_SERVICE"; then
    log "${YELLOW}ServerDeletionService already patched (skip)${RESET}"; return 0
  fi
  awk 'BEGIN{patched=0}
/public function handle\(/ {print; infunc=1; next}
infunc==1 && /^[[:space:]]*{/ && patched==0 {
  print;
  print "        // GREYSYNC_PROTECT_SERVER";
  print "        $user = \\Illuminate\\Support\\Facades\\Auth::user();";
  print "        if ($user && $user->id !== (int)\\json_decode(file_get_contents(storage_path(\"app/idprotect.json\")), true)[\"superAdminId\"]) {";
  print "            throw new \\Pterodactyl\\Exceptions\\DisplayException(\"⛔ Akses ditolak (GreySync Protect)\");";
  print "        }";
  patched=1; next
}
{print}' "$SERVER_SERVICE" > "$SERVER_SERVICE.tmp" && mv "$SERVER_SERVICE.tmp" "$SERVER_SERVICE"
  if ! php_check "$SERVER_SERVICE"; then
    log "${RED}ServerDeletionService syntax error after patch, restoring backup${RESET}"
    restore_file_from_backup "$SERVER_SERVICE"
    return 2
  fi
  log "${GREEN}Patched ServerDeletionService${RESET}"
}

# patch admin controllers using a safe PHP helper to avoid escaping problems
patch_admin_controllers() {
  local admin_id="${1:-1}"
  # create temp php helper
  helper="/tmp/greysync_admin_patch_$$.php"
  cat > "$helper" <<'PHPH'
<?php
// args: file adminId
if ($argc < 3) {
    fwrite(STDERR,"need args\n");
    exit(1);
}
$file = $argv[1];
$admin = intval($argv[2]);
if (!is_file($file)) { echo "NOFILE\n"; exit(2); }
$orig = file_get_contents($file);
if (strpos($orig, "GREYSYNC_PROTECT_ADMIN") !== false) { echo "SKIP\n"; exit(0); }
// ensure use Auth line exists after namespace
if (strpos($orig, "Illuminate\\Support\\Facades\\Auth") === false) {
    $orig = preg_replace('/(namespace\\s+[^{;]+;\\s*)/m', "$1\nuse Illuminate\\Support\\Facades\\Auth;\n", $orig, 1);
}
// insert protection inside first public function index(...)
$pattern = '/public\\s+function\\s+index\\s*\\([^\\)]*\\)\\s*\\{/m';
if (preg_match($pattern, $orig, $m, PREG_OFFSET_CAPTURE)) {
    $pos = $m[0][1] + strlen($m[0][0]);
    $injection = "\n        // GREYSYNC_PROTECT_ADMIN: block for non-superadmin\n        \$user = Auth::user();\n        if (!\$user || \$user->id != $admin) { abort(403, \"⛔ Akses ditolak (GreySync Protect)\"); }\n";
    $new = substr($orig,0,$pos) . $injection . substr($orig,$pos);
    file_put_contents($file, $new);
    echo "PATCHED\n";
    exit(0);
} else {
    echo "NOINDEX\n";
    exit(3);
}
PHPH

  # run helper for each admin controller
  for ctrl in "${ADMIN_CONTROLLERS[@]}"; do
    if [[ ! -f "$ctrl" ]]; then
      log "${YELLOW}Admin controller not found (skip): $ctrl${RESET}"
      continue
    fi
    backup_file "$ctrl"
    php "$helper" "$ctrl" "$admin_id" >/tmp/greysync_admin_patch_out 2>&1 || true
    out=$(cat /tmp/greysync_admin_patch_out || true)
    if echo "$out" | grep -q "PATCHED"; then
      if ! php_check "$ctrl"; then
        log "${RED}Syntax error in $ctrl after patch, restoring backup${RESET}"
        restore_file_from_backup "$ctrl"
        continue
      fi
      # mark file
      sed -i '1i// GREYSYNC_PROTECT_ADMIN' "$ctrl"
      log "${GREEN}Patched admin controller: $ctrl${RESET}"
    else
      log "${YELLOW}Admin patch helper result for $ctrl: $out${RESET}"
    fi
  done
  rm -f "$helper" /tmp/greysync_admin_patch_out
}

restore_patched_controllers() {
  for ctrl in "${ADMIN_CONTROLLERS[@]}" "$USER_CONTROLLER" "$SERVER_SERVICE"; do
    restore_file_from_backup "$ctrl"
  done
  fix_laravel
}

install_all() {
  mkdir -p "$BACKUP_DIR"
  insert_kernel_middleware
  write_middleware_file || { log "${RED}Failed to write middleware, aborting install${RESET}"; return 1; }
  # sanity: if middleware missing abort
  [[ -f "$MIDDLEWARE" ]] || { log "${RED}Middleware missing after write, aborting${RESET}"; return 1; }
  write_error_view
  echo '{ "status": "on" }' > "$STORAGE"
  echo '{ "superAdminId": 1 }' > "$IDPROTECT"
  patch_user_controller || log "${YELLOW}UserController patch skipped/failed${RESET}"
  patch_server_service || log "${YELLOW}ServerDeletionService patch skipped/failed${RESET}"
  patch_admin_controllers 1 || log "${YELLOW}Admin controllers patch skipped/failed${RESET}"
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

case "$1" in
  install|"") install_all ;;
  uninstall) uninstall_all ;;
  restore) restore_patched_controllers ;;
  adminpatch) [[ -z "$2" ]] && { echo "Usage: $0 adminpatch <ADMIN_ID>"; exit 1; }; patch_admin_controllers "$2"; fix_laravel ;;
  adminrestore) restore_patched_controllers ;;
  *) echo "Usage: $0 {install|uninstall|restore|adminpatch <id>|adminrestore}"; exit 1 ;;
esac
SH
