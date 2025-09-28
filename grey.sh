#!/bin/bash
# ========================================================
# GreySync Fix Protect Script
# Versi: 1.0
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

# Hapus trigger MySQL yang bikin error
mysql -u root -p"${MYSQL_ROOT_PASSWORD}" "$DB_NAME" <<'SQL'
DROP TRIGGER IF EXISTS protect_no_delete_users;
DROP TRIGGER IF EXISTS protect_no_delete_servers;
DROP TRIGGER IF EXISTS protect_no_delete_nodes;
DROP TRIGGER IF EXISTS protect_no_delete_eggs;
SQL

# Clear cache Laravel supaya panel normal
cd "$ROOT" || exit 1
php artisan config:clear || true
php artisan cache:clear || true
php artisan route:clear || true

echo "✅ Fix Protect selesai. Panel harusnya sudah normal kembali."
