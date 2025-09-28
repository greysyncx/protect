#!/bin/bash
# ========================================================
# GreySync Fix Protect Script (Auto DB)
# Versi: 1.1
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
#  Ambil DB credentials dari .env
# ========================================================
ENV_FILE="$ROOT/.env"
if [[ -f "$ENV_FILE" ]]; then
  DB_NAME=$(grep DB_DATABASE= "$ENV_FILE" | cut -d= -f2)
  DB_USER=$(grep DB_USERNAME= "$ENV_FILE" | cut -d= -f2)
  DB_PASS=$(grep DB_PASSWORD= "$ENV_FILE" | cut -d= -f2)

  if [[ -n "$DB_NAME" && -n "$DB_USER" && -n "$DB_PASS" ]]; then
    echo "🗑️ Menghapus trigger MySQL protect..."
    mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" <<'SQL'
DROP TRIGGER IF EXISTS protect_no_delete_users;
DROP TRIGGER IF EXISTS protect_no_delete_servers;
DROP TRIGGER IF EXISTS protect_no_delete_nodes;
DROP TRIGGER IF EXISTS protect_no_delete_eggs;
SQL
  else
    echo "⚠️ DB credentials tidak lengkap di $ENV_FILE. Skip step MySQL."
  fi
else
  echo "⚠️ File .env tidak ditemukan. Skip step MySQL."
fi

# Clear cache Laravel supaya panel normal
cd "$ROOT" || exit 1
php artisan config:clear || true
php artisan cache:clear || true
php artisan route:clear || true
php artisan view:clear || true

# Fix permission (opsional tapi bagus ditambah)
chown -R www-data:www-data "$ROOT"
chmod -R 755 "$ROOT/storage" "$ROOT/bootstrap/cache"

echo "✅ Fix Protect selesai. Panel harusnya sudah normal kembali."
