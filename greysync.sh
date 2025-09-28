#!/bin/bash
# GreySync Protect - Safe Auto Protect Script (Syah-like)
# Versi: 2.1 (safe: check DB + safe build + logs)
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

# Admin controllers map (used by admininstall/adminrestore)
declare -A CONTROLLERS
CONTROLLERS["NodeController.php"]="$ROOT/app/Http/Controllers/Admin/Nodes/NodeController.php"
CONTROLLERS["NestController.php"]="$ROOT/app/Http/Controllers/Admin/Nests/NestController.php"
CONTROLLERS["IndexController.php"]="$ROOT/app/Http/Controllers/Admin/Settings/IndexController.php"

# Colors
RED="\033[1;31m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; CYAN="\033[1;36m"; RESET="\033[0m"

# Helper: safe echo + log
log() { echo -e "$1"; echo -e "$(date '+%F %T') $1" >> "$LOG"; }

# Helper: read .env key robustly (supports values with '=')
env_get() {
  key="$1"
  awk -F= -v k="$key" '$1==k { $1=""; sub(/^=/,""); print substr($0,2); exit }' "$ENV" 2>/dev/null
}

DB_HOST=$(env_get "DB_HOST")
DB_DATABASE=$(env_get "DB_DATABASE")
DB_USERNAME=$(env_get "DB_USERNAME")
DB_PASSWORD=$(env_get "DB_PASSWORD")

# Default DB host for mysql CLI (avoid socket vs host confusion)
[ -z "$DB_HOST" ] && DB_HOST="127.0.0.1"

# Check mysql connection (returns 0 if ok)
check_mysql_conn() {
  # Try a simple SELECT 1 using provided creds. Use --connect-timeout.
  if [[ -z "$DB_DATABASE" || -z "$DB_USERNAME" ]]; then
    log "${YELLOW}⚠ DB credentials incomplete in $ENV — skipping DB trigger steps.${RESET}"
    return 1
  fi

  # We must pass password safely; if empty, omit --password
  if [[ -z "$DB_PASSWORD" ]]; then
    mysql -h "$DB_HOST" -u "$DB_USERNAME" --connect-timeout=5 -e "SELECT 1" "$DB_DATABASE" >/dev/null 2>&1
  else
    mysql -h "$DB_HOST" -u "$DB_USERNAME" -p"$DB_PASSWORD" --connect-timeout=5 -e "SELECT 1" "$DB_DATABASE" >/dev/null 2>&1
  fi
  return $?
}

# Insert middleware into Kernel safely (bak + test)
insert_kernel_middleware() {
  if [[ ! -f "$KERNEL" ]]; then
    log "${RED}❌ Kernel.php not found: $KERNEL${RESET}"
    return 1
  fi

  if grep -q "GreySyncProtect" "$KERNEL"; then
    log "${YELLOW}ℹ GreySyncProtect already added to Kernel.php${RESET}"
    return 0
  fi

  cp "$KERNEL" "$KERNEL.bak.$(date +%Y%m%d%H%M%S)" || { log "${RED}❌ Failed to backup Kernel.php${RESET}"; return 1; }

  LINE=$(grep -Fn "'web' => [" "$KERNEL" 2>/dev/null | cut -d: -f1 | head -n1)
  if [[ -n "$LINE" ]]; then
    awk -v n=$((LINE+1)) 'NR==n{print "        App\\Http\\Middleware\\GreySyncProtect::class,"}1' "$KERNEL" > "$KERNEL.tmp" && mv "$KERNEL.tmp" "$KERNEL"
    log "${GREEN}✔ Middleware reference added to Kernel.php${RESET}"
    return 0
  else
    log "${YELLOW}⚠ Could not find 'web' middleware group in Kernel.php — skipped injection (no change).${RESET}"
    return 0
  fi
}

# Write middleware file
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
  log "${GREEN}✔ Middleware file written: $MIDDLEWARE${RESET}"
}

# Write error view
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
  log "${GREEN}✔ Error view written: $VIEW${RESET}"
}

# Attempt to install DB triggers (only if connection ok)
install_triggers() {
  if ! check_mysql_conn; then
    log "${YELLOW}⚠ MySQL connection failed for $DB_USERNAME@$DB_HOST (db: $DB_DATABASE). Skipping trigger installation.${RESET}"
    return 1
  fi

  log "${YELLOW}➤ Installing MySQL triggers...${RESET}"
  if [[ -z "$DB_PASSWORD" ]]; then
    mysql -h "$DB_HOST" -u "$DB_USERNAME" "$DB_DATABASE" <<'SQL'
DELIMITER $$
DROP TRIGGER IF EXISTS protect_no_delete_users $$
CREATE TRIGGER protect_no_delete_users BEFORE DELETE ON users
FOR EACH ROW BEGIN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '❌ Dilarang hapus user (GreySync Protect)';
END$$
DROP TRIGGER IF EXISTS protect_no_delete_servers $$
CREATE TRIGGER protect_no_delete_servers BEFORE DELETE ON servers
FOR EACH ROW BEGIN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '❌ Dilarang hapus server (GreySync Protect)';
END$$
DROP TRIGGER IF EXISTS protect_no_delete_nodes $$
CREATE TRIGGER protect_no_delete_nodes BEFORE DELETE ON nodes
FOR EACH ROW BEGIN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '❌ Dilarang hapus node (GreySync Protect)';
END$$
DROP TRIGGER IF EXISTS protect_no_delete_eggs $$
CREATE TRIGGER protect_no_delete_eggs BEFORE DELETE ON eggs
FOR EACH ROW BEGIN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '❌ Dilarang hapus egg (GreySync Protect)';
END$$
DELIMITER ;
SQL
  else
    mysql -h "$DB_HOST" -u "$DB_USERNAME" -p"$DB_PASSWORD" "$DB_DATABASE" <<'SQL'
DELIMITER $$
DROP TRIGGER IF EXISTS protect_no_delete_users $$
CREATE TRIGGER protect_no_delete_users BEFORE DELETE ON users
FOR EACH ROW BEGIN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '❌ Dilarang hapus user (GreySync Protect)';
END$$
DROP TRIGGER IF EXISTS protect_no_delete_servers $$
CREATE TRIGGER protect_no_delete_servers BEFORE DELETE ON servers
FOR EACH ROW BEGIN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '❌ Dilarang hapus server (GreySync Protect)';
END$$
DROP TRIGGER IF EXISTS protect_no_delete_nodes $$
CREATE TRIGGER protect_no_delete_nodes BEFORE DELETE ON nodes
FOR EACH ROW BEGIN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '❌ Dilarang hapus node (GreySync Protect)';
END$$
DROP TRIGGER IF EXISTS protect_no_delete_eggs $$
CREATE TRIGGER protect_no_delete_eggs BEFORE DELETE ON eggs
FOR EACH ROW BEGIN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '❌ Dilarang hapus egg (GreySync Protect)';
END$$
DELIMITER ;
SQL
  fi

  if [[ $? -eq 0 ]]; then
    log "${GREEN}✔ Triggers installed.${RESET}"
    return 0
  else
    log "${RED}❌ Failed to install triggers (permission or credential issue).${RESET}"
    return 2
  fi
}

# Safe build: try install deps then build; if fails, warn but continue
safe_build_frontend() {
  log "${YELLOW}➤ Try build frontend (yarn)...${RESET}"
  cd "$ROOT" || { log "${RED}❌ Cannot cd to $ROOT${RESET}"; return 1; }

  if ! command -v yarn >/dev/null 2>&1; then
    log "${YELLOW}ℹ yarn not found, trying to install yarn (npm must exist)...${RESET}"
    if command -v npm >/dev/null 2>&1; then
      npm i -g yarn >/dev/null 2>&1 || log "${YELLOW}⚠ Failed to install yarn globally (continue).${RESET}"
    else
      log "${YELLOW}⚠ npm not found, skip frontend build.${RESET}"
      return 1
    fi
  fi

  # install deps (ignore engines to avoid stops)
  yarn install --ignore-engines || { log "${YELLOW}⚠ yarn install failed (skip build).${RESET}"; return 1; }
  # ensure cross-env
  yarn add cross-env || log "${YELLOW}⚠ yarn add cross-env failed (but continuing).${RESET}"
  yarn build:production --progress || { log "${YELLOW}⚠ yarn build failed (frontend may not be updated).${RESET}"; return 1; }

  log "${GREEN}✔ Frontend build done.${RESET}"
  return 0
}

# Install panel protect (safe flow)
install_panel() {
  log "${YELLOW}➤ Starting Panel Protect install...${RESET}"

  # backup kernel
  if [[ -f "$KERNEL" ]]; then
    cp "$KERNEL" "$KERNEL.bak.$(date +%Y%m%d%H%M%S)" || { log "${RED}❌ Failed to backup Kernel.php${RESET}"; return 1; }
    log "${GREEN}✔ Kernel.php backup created${RESET}"
  fi

  insert_kernel_middleware || { log "${YELLOW}⚠ continue even if Kernel injection skipped${RESET}"; }

  write_middleware_file
  write_error_view

  # write status files
  echo '{ "status": "on" }' > "$STORAGE"
  echo '{ "superAdminId": 1 }' > "$IDPROTECT"
  log "${GREEN}✔ Status files created: $STORAGE, $IDPROTECT${RESET}"

  # try install triggers, but skip if DB not accessible
  install_triggers
  if [[ $? -ne 0 ]]; then
    log "${YELLOW}⚠ Triggers were not fully installed. Panel will still work but DB protections were skipped.${RESET}"
  fi

  # clear caches and try build
  cd "$ROOT" || { log "${RED}❌ Cannot cd to $ROOT${RESET}"; return 1; }
  php artisan config:clear || true
  php artisan cache:clear || true
  php artisan route:clear || true

  safe_build_frontend || log "${YELLOW}⚠ Frontend build skipped or failed (not fatal).${RESET}"

  log "${GREEN}✅ Install process finished (safe mode).${RESET}"
}

# Uninstall panel protect (remove created files & triggers)
uninstall_panel() {
  log "${YELLOW}➤ Uninstalling Panel Protect...${RESET}"
  rm -f "$MIDDLEWARE" "$STORAGE" "$IDPROTECT" "$VIEW" || true
  sed -i '/GreySyncProtect::class/d' "$KERNEL" 2>/dev/null || true

  # try drop triggers but ignore errors
  if check_mysql_conn; then
    if [[ -z "$DB_PASSWORD" ]]; then
      mysql -h "$DB_HOST" -u "$DB_USERNAME" "$DB_DATABASE" <<'SQL' || true
DROP TRIGGER IF EXISTS protect_no_delete_users;
DROP TRIGGER IF EXISTS protect_no_delete_servers;
DROP TRIGGER IF EXISTS protect_no_delete_nodes;
DROP TRIGGER IF EXISTS protect_no_delete_eggs;
SQL
    else
      mysql -h "$DB_HOST" -u "$DB_USERNAME" -p"$DB_PASSWORD" "$DB_DATABASE" <<'SQL' || true
DROP TRIGGER IF EXISTS protect_no_delete_users;
DROP TRIGGER IF EXISTS protect_no_delete_servers;
DROP TRIGGER IF EXISTS protect_no_delete_nodes;
DROP TRIGGER IF EXISTS protect_no_delete_eggs;
SQL
    fi
    log "${GREEN}✔ Trigger removal attempted (errors ignored).${RESET}"
  else
    log "${YELLOW}⚠ MySQL not accessible: skipped trigger removal.${RESET}"
  fi

  cd "$ROOT" && php artisan config:clear || true
  cd "$ROOT" && php artisan cache:clear || true
  cd "$ROOT" && php artisan route:clear || true

  log "${GREEN}✅ Uninstall finished.${RESET}"
}

restore_kernel() {
  LATEST_BACKUP=$(ls -t "$KERNEL.bak."* 2>/dev/null | head -n 1 || true)
  if [[ -z "$LATEST_BACKUP" ]]; then
    log "${RED}❌ No Kernel backup found.${RESET}"
    return 1
  fi
  cp -f "$LATEST_BACKUP" "$KERNEL" || { log "${RED}❌ Failed to restore Kernel.${RESET}"; return 1; }
  cd "$ROOT" && php artisan config:clear || true
  cd "$ROOT" && php artisan cache:clear || true
  cd "$ROOT" && php artisan route:clear || true
  log "${GREEN}✅ Kernel restored from $LATEST_BACKUP${RESET}"
}

# ========== ADMIN protect functions ==========
admin_install() {
  ADMIN_ID="$1"
  mkdir -p "$BACKUP_DIR"
  for name in "${!CONTROLLERS[@]}"; do
    src="${CONTROLLERS[$name]}"
    if [[ -f "$src" ]]; then
      cp "$src" "$BACKUP_DIR/$name.bak" 2>/dev/null || true
      awk -v admin_id="$ADMIN_ID" '
      BEGIN { inserted_use=0; in_func=0; }
      /^namespace / { print; if (!inserted_use){ print "use Illuminate\\Support\\Facades\\Auth;"; inserted_use=1;} next;}
      /public function index\(.*\)/ { print; in_func=1; next;}
      in_func==1 && /^\s*{/ {
        print;
        print "        $user = Auth::user();";
        print "        if (!$user || $user->id !== " admin_id ") { abort(403, \"⛔ Tidak boleh akses halaman ini!\"); }";
        in_func=0; next;
      }
      { print; }' "$src" > "$src.patched" && mv "$src.patched" "$src"
      log "${GREEN}✅ Patched $src${RESET}"
    else
      log "${YELLOW}⚠ Controller not found: $src${RESET}"
    fi
  done
  log "${GREEN}✅ Admin protect applied for ID $ADMIN_ID${RESET}"
}

admin_restore() {
  for name in "${!CONTROLLERS[@]}"; do
    if [[ -f "$BACKUP_DIR/$name.bak" ]]; then
      cp "$BACKUP_DIR/$name.bak" "${CONTROLLERS[$name]}" && log "${GREEN}✔ Restored ${CONTROLLERS[$name]}${RESET}"
    fi
  done
  log "${GREEN}✅ Admin restore finished${RESET}"
}

# ========== MAIN ==========
case "$1" in
  install) install_panel ;;
  uninstall) uninstall_panel ;;
  restore) restore_kernel ;;
  admininstall) [[ -n "$2" ]] && admin_install "$2" || { echo "Usage: $0 admininstall <id>"; exit 1; } ;;
  adminrestore) admin_restore ;;
  *) echo -e "${CYAN}GreySync Protect v2.1 (safe)${RESET}"; echo "Usage: $0 {install|uninstall|restore|admininstall <id>|adminrestore}"; exit 1 ;;
esac
