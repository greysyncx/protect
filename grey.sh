#!/bin/bash
# ========================================================
# GreySync Fix Protect Script (Final PHP 8.3)
# ========================================================

ROOT="/var/www/pterodactyl"
KERNEL="$ROOT/app/Http/Kernel.php"

echo "♻️ Menjalankan perbaikan GreySync Protect..."

# Hapus middleware GreySyncProtect
sed -i '/GreySyncProtect::class/d' "$KERNEL" 2>/dev/null

# Hapus file middleware & view error jika masih ada
rm -f "$ROOT/app/Http/Middleware/GreySyncProtect.php"
rm -f "$ROOT/resources/views/errors/protect.blade.php"

# Hapus file status protect
rm -f "$ROOT/storage/app/greysync_protect.json"
rm -f "$ROOT/storage/app/idprotect.json"

# ========================================================
#  Fix MySQL (kasih full akses ke user pterodactyl)
# ========================================================
echo "🗑️ Menghapus trigger MySQL protect..."
mysql -u root -e "GRANT ALL PRIVILEGES ON pterodactyl.* TO 'pterodactyl'@'localhost'; FLUSH PRIVILEGES;"

# Coba drop trigger (kalau ada)
mysql -u pterodactyl -p$(grep DB_PASSWORD= "$ROOT/.env" | cut -d= -f2) pterodactyl <<'SQL'
DROP TRIGGER IF EXISTS protect_no_delete_users;
DROP TRIGGER IF EXISTS protect_no_delete_servers;
DROP TRIGGER IF EXISTS protect_no_delete_nodes;
DROP TRIGGER IF EXISTS protect_no_delete_eggs;
SQL

# ========================================================
# Clear cache Laravel supaya panel normal
# ========================================================
cd "$ROOT" || exit 1
php artisan config:clear || true
php artisan cache:clear || true
php artisan route:clear || true
php artisan view:clear || true

# ========================================================
# Fix permission
# ========================================================
chown -R www-data:www-data "$ROOT"
chmod -R 755 "$ROOT/storage" "$ROOT/bootstrap/cache"

# ========================================================
# Restart service web (PHP 8.3)
# ========================================================
systemctl restart nginx
systemctl restart php8.3-fpm

echo "✅ Fix Protect selesai. Panel harusnya sudah normal kembali."
