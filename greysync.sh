#!/bin/bash
# GreySync Protect - Hybrid Mode (auto & manual)
# Versi: 1.0 (stabil fix namespace)

ROOT="/var/www/pterodactyl"
MIDDLEWARE="$ROOT/app/Http/Middleware/GreySyncProtect.php"
KERNEL="$ROOT/app/Http/Kernel.php"
STORAGE="$ROOT/storage/app/greysync_protect.json"
IDPROTECT="$ROOT/storage/app/idprotect.json"
VIEW="$ROOT/resources/views/errors/protect.blade.php"
ENV="$ROOT/.env"
LOG="/var/log/greysync_protect.log"

# Colors
RED="\033[1;31m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; CYAN="\033[1;36m"; RESET="\033[0m"

log() { echo -e "$1"; echo -e "$(date '+%F %T') $1" >> "$LOG"; }

insert_kernel_middleware() {
  if grep -q "GreySyncProtect" "$KERNEL" 2>/dev/null; then
    log "${YELLOW}ℹ Middleware sudah ada di Kernel.php${RESET}"; return 0
  fi
  cp "$KERNEL" "$KERNEL.bak.$(date +%s)"
  LINE=$(grep -Fn "'web' => [" "$KERNEL" | cut -d: -f1 | head -n1)
  [[ -z "$LINE" ]] && { log "${RED}❌ 'web' middleware array tidak ketemu${RESET}"; return 1; }
  awk -v n=$((LINE+1)) 'NR==n{print "        \\\\App\\\\Http\\\\Middleware\\\\GreySyncProtect::class,"}1' "$KERNEL" > "$KERNEL.tmp" && mv "$KERNEL.tmp" "$KERNEL"
  log "${GREEN}✔ Middleware ditambahkan ke Kernel.php${RESET}"
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
  log "${GREEN}✔ File middleware dibuat${RESET}"
}

write_error_view() {
  mkdir -p "$(dirname "$VIEW")"
  cat > "$VIEW" <<'BLADE'
<!doctype html><html><head><meta charset="utf-8">
<title>GreySync Protect</title>
<style>body{background:#bf1f2b;color:#fff;display:flex;align-items:center;justify-content:center;height:100vh;font-family:Arial;text-align:center}</style></head><body>
<div><h1>❌ Mau maling? Gak bisa boss 😹</h1>
<p>GreySync Protect aktif.</p>
<small>⿻ Powered by GreySync</small></div>
</body></html>
BLADE
  log "${GREEN}✔ Tampilan error dibuat${RESET}"
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
  log "${CYAN}➡ Memasang GreySync Protect...${RESET}"
  insert_kernel_middleware
  write_middleware_file
  write_error_view
  echo '{ "status": "on" }' > "$STORAGE"
  echo '{ "superAdminId": 1 }' > "$IDPROTECT"
  fix_laravel
  log "${GREEN}✅ Install selesai, protect aktif.${RESET}"
}

uninstall_panel() {
  log "${CYAN}➡ Uninstall GreySync Protect...${RESET}"
  rm -f "$MIDDLEWARE" "$STORAGE" "$IDPROTECT" "$VIEW"
  sed -i '/GreySyncProtect::class/d' "$KERNEL" 2>/dev/null
  fix_laravel
  log "${GREEN}✅ Uninstall selesai, protect dimatikan.${RESET}"
}

restore_kernel() {
  LATEST_BACKUP=$(ls -t "$KERNEL.bak."* 2>/dev/null | head -n 1 || true)
  [[ -z "$LATEST_BACKUP" ]] && { log "${RED}❌ Tidak ada backup Kernel.php${RESET}"; return 1; }
  cp -f "$LATEST_BACKUP" "$KERNEL"
  fix_laravel
  log "${GREEN}✅ Kernel.php dipulihkan dari backup${RESET}"
}

# --- AUTO MODE (default = install) ---
case "$1" in
  install|"") install_panel ;;
  uninstall) uninstall_panel ;;
  restore) restore_kernel ;;
  *) echo -e "${CYAN}GreySync Protect v1.0${RESET}"; echo "Usage: $0 {install|uninstall|restore}"; exit 1 ;;
esac
