#!/bin/bash
# ========================================================
# GreySync Fix Protect Script (Final)
# ========================================================

ROOT="/var/www/pterodactyl"
BACKUP="/var/www/pterodactyl_backup"

echo "♻️ Menjalankan perbaikan GreySync Protect..."

# 1. Backup folder lama (untuk jaga-jaga)
if [ -d "$ROOT" ]; then
  mv "$ROOT" "$BACKUP-$(date +%s)" || true
fi
mkdir -p "$ROOT"
cd "$ROOT" || exit 1

# 2. Download file panel terbaru
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz
chmod -R 755 storage/* bootstrap/cache

# 3. Copy .env lama
if [ -f "$BACKUP/.env" ]; then
  cp "$BACKUP/.env" "$ROOT/.env"
fi

# 4. Install dependency Laravel
composer install --no-dev --optimize-autoloader

# 5. Jalankan migrate DB (tidak hapus data)
php artisan migrate --force

# 6. Bersihkan cache Laravel
php artisan config:clear
php artisan cache:clear
php artisan route:clear
php artisan view:clear

# 7. Fix permission
chown -R www-data:www-data "$ROOT"
chmod -R 755 "$ROOT/storage" "$ROOT/bootstrap/cache"

# 8. Restart service (PHP 8.3 + nginx)
systemctl restart nginx
systemctl restart php8.3-fpm

echo "✅ Fix Protect selesai. Panel harusnya sudah normal kembali."
