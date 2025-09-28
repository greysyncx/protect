#!/bin/bash
# GreySync Protect - Safe Auto Protect Script
# Versi: 2.2 (fix: safe DB, cache, perms, restart)
# Usage:
#   greysync.sh install
#   greysync.sh uninstall
#   greysync.sh restore
#   greysync.sh admininstall <id>
#   greysync.sh adminrestore

ROOT="/var/www/pterodactyl"
MIDDLEWARE="$ROOT/app/Http/Middleware/GreySyncProtect.php"
KERNEL="$ROOT/app/Http/Kernel.php"
STORAGE="$ROOT/storage/app/greysync_protect.json"
IDPROTECT="$ROOT/storage/app/idprotect.json"
VIEW="$ROOT/resources/views/errors/protect.blade.php"
ENV="$ROOT/.env"
LOG="/var/log/greysync_protect.log"
BACKUP_DIR="$ROOT/backup_greysync_admin"

# Colors
RED="\033[1;31m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; CYAN="\033[1;36m"; RESET="\033[0m"

log() { echo -e "$1"; echo -e "$(date '+%F %T') $1" >> "$LOG"; }

env_get() {
  key="$1"
  awk -F= -v k="$key" '$1==k { $1=""; sub(/^=/,""); print substr($0,2); exit }' "$ENV" 2>/dev/null
}

DB_HOST=$(env_get "DB_HOST"); [ -z "$DB_HOST" ] && DB_HOST="127.0.0.1"
DB_DATABASE=$(env_get "DB_DATABASE")
DB_USERNAME=$(env_get "DB_USERNAME")
DB_PASSWORD=$(env_get "DB_PASSWORD")

check_mysql_conn() {
  if [[ -z "$DB_DATABASE" || -z "$DB_USERNAME" ]]; then
    log "${YELLOW}⚠ DB credentials incomplete in $ENV — skip DB steps.${RESET}"
    return 1
  fi
  if [[ -z "$DB_PASSWORD" ]]; then
    mysql -h "$DB_HOST" -u "$DB_USERNAME" --connect-timeout=5 -e "SELECT 1" "$DB_DATABASE" >/dev/null 2>&1
  else
    mysql -h "$DB_HOST" -u "$DB_USERNAME" -p"$DB_PASSWORD" --connect-timeout=5 -e "SELECT 1" "$DB_DATABASE" >/dev/null 2>&1
  fi
  return $?
}

insert_kernel_middleware() {
  if [[ ! -f "$KERNEL" ]]; then log "${RED}❌ Kernel.php not found${RESET}"; return 1; fi
  if grep -q "GreySyncProtect" "$KERNEL"; then
    log "${YELLOW}ℹ GreySyncProtect already in Kernel.php${RESET}"; return 0; fi
  cp "$KERNEL" "$KERNEL.bak.$(date +%s)" || { log "${RED}❌ Backup Kernel.php failed${RESET}"; return 1; }
  LINE=$(grep -Fn "'web' => [" "$KERNEL" | cut -d: -f1 | head -n1)
  if [[ -n "$LINE" ]]; then
    awk -v n=$((LINE+1)) 'NR==n{print "        App\\Http\\Middleware\\GreySyncProtect::class,"}1' "$KERNEL" > "$KERNEL.tmp" && mv "$KERNEL.tmp" "$KERNEL"
    log "${GREEN}✔ Middleware injected${RESET}"
  else
    log "${YELLOW}⚠ 'web' middleware not found, skip injection${RESET}"
  fi
}

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
  log "${GREEN}✔ Middleware file written${RESET}"
}

write_error_view() {
  mkdir -p "$(dirname "$VIEW")"
  cat > "$VIEW" <<'BLADE'
<!doctype html><html><head><meta charset="utf-8">
<title>GreySync Protect</title>
<style>body{background:#bf1f2b;color:#fff;display:flex;align-items:center;justify-content:center;height:100vh;font-family:Arial;text-align:center}</style></head><body>
<div><h1>❌ Mau maling? Gak bisa boss😹</h1>
<p>GreySync Protect aktif.</p>
<small>⿻ Powered by GreySync</small></div>
</body></html>
BLADE
  log "${GREEN}✔ Error view written${RESET}"
}

install_triggers() {
  if ! check_mysql_conn; then log "${YELLOW}⚠ Skip DB triggers.${RESET}"; return 1; fi
  log "${YELLOW}➤ Installing MySQL triggers...${RESET}"
  local CMD
  if [[ -z "$DB_PASSWORD" ]]; then CMD="mysql -h $DB_HOST -u $DB_USERNAME $DB_DATABASE"; else CMD="mysql -h $DB_HOST -u $DB_USERNAME -p$DB_PASSWORD $DB_DATABASE"; fi
  $CMD <<'SQL' || { log "${YELLOW}⚠ Trigger install failed (skip).${RESET}"; return 1; }
DROP TRIGGER IF EXISTS protect_no_delete_users;
CREATE TRIGGER protect_no_delete_users BEFORE DELETE ON users FOR EACH ROW BEGIN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '❌ Dilarang hapus user (GreySync Protect)';
END;
DROP TRIGGER IF EXISTS protect_no_delete_servers;
CREATE TRIGGER protect_no_delete_servers BEFORE DELETE ON servers FOR EACH ROW BEGIN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '❌ Dilarang hapus server (GreySync Protect)';
END;
DROP TRIGGER IF EXISTS protect_no_delete_nodes;
CREATE TRIGGER protect_no_delete_nodes BEFORE DELETE ON nodes FOR EACH ROW BEGIN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '❌ Dilarang hapus node (GreySync Protect)';
END;
DROP TRIGGER IF EXISTS protect_no_delete_eggs;
CREATE TRIGGER protect_no_delete_eggs BEFORE DELETE ON eggs FOR EACH ROW BEGIN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '❌ Dilarang hapus egg (GreySync Protect)';
END;
SQL
  log "${GREEN}✔ Triggers installed (if permitted).${RESET}"
}

safe_build_frontend() {
  log "${YELLOW}➤ Try build frontend...${RESET}"
  cd "$ROOT" || return 1
  command -v yarn >/dev/null 2>&1 || { log "${YELLOW}⚠ yarn missing, skip build.${RESET}"; return 1; }
  yarn install --ignore-engines || { log "${YELLOW}⚠ yarn install failed, skip build.${RESET}"; return 1; }
  yarn build:production --progress || { log "${YELLOW}⚠ yarn build failed, skip.${RESET}"; return 1; }
  log "${GREEN}✔ Frontend build done.${RESET}"
}

fix_laravel() {
  cd "$ROOT" || return 1
  php artisan config:clear || true
  php artisan cache:clear || true
  php artisan route:clear || true
  php artisan view:clear || true
  chown -R www-data:www-data "$ROOT"
  chmod -R 755 "$ROOT/storage" "$ROOT/bootstrap/cache"
  systemctl restart nginx
  systemctl restart php8.3-fpm
}

install_panel() {
  log "${YELLOW}➤ Installing Protect...${RESET}"
  insert_kernel_middleware
  write_middleware_file
  write_error_view
  echo '{ "status": "on" }' > "$STORAGE"
  echo '{ "superAdminId": 1 }' > "$IDPROTECT"
  install_triggers || true
  fix_laravel
  safe_build_frontend || true
  log "${GREEN}✅ Install finished.${RESET}"
}

uninstall_panel() {
  log "${YELLOW}➤ Uninstalling Protect...${RESET}"
  rm -f "$MIDDLEWARE" "$STORAGE" "$IDPROTECT" "$VIEW" || true
  sed -i '/GreySyncProtect::class/d' "$KERNEL" 2>/dev/null || true
  if check_mysql_conn; then
    local CMD
    if [[ -z "$DB_PASSWORD" ]]; then CMD="mysql -h $DB_HOST -u $DB_USERNAME $DB_DATABASE"; else CMD="mysql -h $DB_HOST -u $DB_USERNAME -p$DB_PASSWORD $DB_DATABASE"; fi
    $CMD <<'SQL' || true
DROP TRIGGER IF EXISTS protect_no_delete_users;
DROP TRIGGER IF EXISTS protect_no_delete_servers;
DROP TRIGGER IF EXISTS protect_no_delete_nodes;
DROP TRIGGER IF EXISTS protect_no_delete_eggs;
SQL
    log "${GREEN}✔ Trigger removal attempted.${RESET}"
  fi
  fix_laravel
  log "${GREEN}✅ Uninstall finished.${RESET}"
}

restore_kernel() {
  LATEST_BACKUP=$(ls -t "$KERNEL.bak."* 2>/dev/null | head -n 1 || true)
  [[ -z "$LATEST_BACKUP" ]] && { log "${RED}❌ No Kernel backup.${RESET}"; return 1; }
  cp -f "$LATEST_BACKUP" "$KERNEL"
  fix_laravel
  log "${GREEN}✅ Kernel restored from $LATEST_BACKUP${RESET}"
}

case "$1" in
  install) install_panel ;;
  uninstall) uninstall_panel ;;
  restore) restore_kernel ;;
  *) echo -e "${CYAN}GreySync Protect v2.2${RESET}"; echo "Usage: $0 {install|uninstall|restore}"; exit 1 ;;
esac
