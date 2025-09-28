#!/bin/bash
# ========================================================
# GreySync Protect - Super Protect Script
# Versi: 1.0
# ========================================================

ROOT="/var/www/pterodactyl"
MIDDLEWARE="$ROOT/app/Http/Middleware/GreySyncProtect.php"
KERNEL="$ROOT/app/Http/Kernel.php"
STORAGE="$ROOT/storage/app/greysync_protect.json"
IDPROTECT="$ROOT/storage/app/idprotect.json"
VIEW="$ROOT/resources/views/errors/protect.blade.php"
ENV="$ROOT/.env"

# Warna
RED="\033[1;31m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; CYAN="\033[1;36m"; RESET="\033[0m"

clear
echo -e "${CYAN}═══════════════════════════════════════${RESET}"
echo -e "   GreySync Protect - Super Shield"
echo -e "═══════════════════════════════════════${RESET}"
echo -e "${YELLOW}[1] Install Protect & Build Panel${RESET}"
echo -e "${YELLOW}[2] Uninstall Protect${RESET}"
echo -e "${YELLOW}[3] Restore Kernel.php dari Backup${RESET}"
read -p "Pilih opsi [1/2/3]: " OPSI

# Ambil credential MySQL
DB_HOST=$(grep DB_HOST $ENV | cut -d '=' -f2)
DB_NAME=$(grep DB_DATABASE $ENV | cut -d '=' -f2)
DB_USER=$(grep DB_USERNAME $ENV | cut -d '=' -f2)
DB_PASS=$(grep DB_PASSWORD $ENV | cut -d '=' -f2)

if [[ "$OPSI" == "1" ]]; then
    echo -e "${YELLOW}➤ Backup Kernel.php...${RESET}"
    [ -f "$KERNEL" ] && cp "$KERNEL" "$KERNEL.bak.$(date +%Y%m%d%H%M%S)"

    echo -e "${YELLOW}➤ Tambahkan middleware...${RESET}"
    if [[ -f "$KERNEL" ]] && ! grep -q "GreySyncProtect" "$KERNEL"; then
        LINE=$(grep -Fn "'web' => [" "$KERNEL" | cut -d: -f1 | head -n1)
        [ -n "$LINE" ] && awk -v n=$((LINE+1)) 'NR==n{print "        App\\\\Http\\\\Middleware\\\\GreySyncProtect::class,"}1' "$KERNEL" > "$KERNEL.tmp" && mv "$KERNEL.tmp" "$KERNEL"
    fi

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
            $blocked=['admin/backups','downloads','storage',
                      'server/*/files','api/client/servers/*/files'];
            foreach ($blocked as $p) {
                if ($request->is("$p*")) return $this->deny($request,$superAdminId);
            }
        }
        return $next($request);
    }
}
PHP

    echo '{ "status": "on" }' > "$STORAGE"
    echo '{ "superAdminId": 1 }' > "$IDPROTECT"

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

    echo -e "${YELLOW}➤ Tambahkan MySQL triggers...${RESET}"
    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" <<'SQL'
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

    echo -e "${YELLOW}➤ Build frontend panel...${RESET}"
    sudo apt-get update -y >/dev/null
    sudo apt-get remove nodejs -y >/dev/null
    curl -fsSL https://deb.nodesource.com/setup_16.x | sudo -E bash - >/dev/null
    sudo apt-get install nodejs -y >/dev/null
    cd "$ROOT" || exit 1
    npm i -g yarn >/dev/null
    yarn add cross-env >/dev/null
    yarn build:production --progress

    echo -e "${GREEN}✅ Install Protect selesai.${RESET}"

elif [[ "$OPSI" == "2" ]]; then
    echo -e "${YELLOW}➤ Uninstall Protect...${RESET}"
    rm -f "$MIDDLEWARE" "$STORAGE" "$IDPROTECT" "$VIEW"
    sed -i '/GreySyncProtect::class/d' "$KERNEL" || true
    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" <<'SQL'
DROP TRIGGER IF EXISTS protect_no_delete_users;
DROP TRIGGER IF EXISTS protect_no_delete_servers;
DROP TRIGGER IF EXISTS protect_no_delete_nodes;
DROP TRIGGER IF EXISTS protect_no_delete_eggs;
SQL
    cd "$ROOT" && php artisan config:clear && php artisan cache:clear && php artisan route:clear
    echo -e "${GREEN}🗑️ Protect dihapus.${RESET}"

elif [[ "$OPSI" == "3" ]]; then
    LATEST_BACKUP=$(ls -t "$KERNEL.bak."* 2>/dev/null | head -n 1 || true)
    if [[ -z "$LATEST_BACKUP" ]]; then
        echo -e "${RED}❌ Tidak ada backup Kernel.php ditemukan.${RESET}"
        exit 1
    fi
    cp -f "$LATEST_BACKUP" "$KERNEL"
    cd "$ROOT" && php artisan config:clear && php artisan cache:clear && php artisan route:clear
    echo -e "${GREEN}✅ Kernel.php dipulihkan dari backup.${RESET}"
else
    echo -e "${RED}❌ Opsi tidak valid.${RESET}"
fi
