#!/bin/bash

# ===== WARNA =====
RED="\033[1;31m"
GREEN="\033[1;32m"
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
RESET="\033[0m"

# ===== INFO =====
VERSION="1.5 Ultimate"
ROOT="/var/www/pterodactyl"
BACKUP_DIR="backup_greyz"
POLICY_PATH="$ROOT/app/Policies/ServerPolicy.php"

declare -A CONTROLLERS=(
  ["NodeController.php"]="$ROOT/app/Http/Controllers/Admin/Nodes/NodeController.php"
  ["NestController.php"]="$ROOT/app/Http/Controllers/Admin/Nests/NestController.php"
  ["IndexController.php"]="$ROOT/app/Http/Controllers/Admin/Settings/IndexController.php"
  ["LocationController.php"]="$ROOT/app/Http/Controllers/Admin/LocationController.php"
)

# ===== SETUP =====
clear
rm -f /var/log/greyz_intip.log 2>/dev/null
mkdir -p "$BACKUP_DIR"

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║              GreyZ Protect v${VERSION}               ║"
echo "║         (Admin + Anti-Intip via ServerPolicy)        ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"

echo -e "${YELLOW}1) Pasang Protect"
echo -e "2) Restore Protect Terakhir${RESET}"
read -p "Pilih [1/2]: " MODE

# ===== PASANG PROTECT =====
if [[ "$MODE" == "1" ]]; then
  read -p "👤 Masukkan ID Admin Utama (contoh: 1): " ADMIN_ID
  [[ -z "$ADMIN_ID" ]] && echo -e "${RED}❌ Admin ID kosong.${RESET}" && exit 1

  echo -e "${YELLOW}📦 Membackup semua file asli ke: $BACKUP_DIR${RESET}"
  for name in "${!CONTROLLERS[@]}"; do
    path="${CONTROLLERS[$name]}"
    if [[ -f "$path" ]]; then
      cp "$path" "$BACKUP_DIR/$name.$(date +%F-%H%M%S).bak"
      echo -e "${GREEN}✔ Backup: $path${RESET}"
    else
      echo -e "${YELLOW}⚠ Lewat (tidak ada): $path${RESET}"
    fi
  done

  if [[ -f "$POLICY_PATH" ]]; then
    cp "$POLICY_PATH" "$BACKUP_DIR/ServerPolicy.php.$(date +%F-%H%M%S).bak"
    echo -e "${GREEN}✔ Backup: $POLICY_PATH${RESET}"
  else
    echo -e "${YELLOW}⚠ ServerPolicy.php tidak ditemukan.${RESET}"
  fi

  echo -e "${CYAN}🛡 Memasang proteksi Admin Controllers...${RESET}"
  for name in "${!CONTROLLERS[@]}"; do
    path="${CONTROLLERS[$name]}"
    [[ ! -f "$path" ]] && echo -e "${YELLOW}⚠ Lewat: $name hilang${RESET}" && continue

    awk -v admin_id="$ADMIN_ID" '
      BEGIN { in_func=0 }
      /^namespace / {
        print; print "use Illuminate\\Support\\Facades\\Auth;"; next
      }
      /public function index\(.*\)/ { print; in_func=1; next }
      in_func==1 && /^\s*{/ {
        print
        print "        $user = Auth::user();"
        print "        if (!$user || $user->id != " admin_id ") {"
        print "            abort(403, \"❌ bocah tolol ngapain lu?\");"
        print "        }"
        in_func=0; next
      }
      { print }
    ' "$path" > "$path.tmp" && mv "$path.tmp" "$path"

    echo -e "${GREEN}✔ Protect: $name${RESET}"
  done

  # ===== PASANG ANTI-INTIP =====
  if [[ -f "$POLICY_PATH" ]]; then
    echo -e "${CYAN}🧩 Memasang Anti-Intip di ServerPolicy...${RESET}"

    awk '
      BEGIN { in_view=0; brace_count=0 }
      {
        if (in_view==0) {
          if ($0 ~ /public[[:space:]]+function[[:space:]]+view[[:space:]]*\(/) {
            in_view=1
            open = gsub(/\{/, "{")
            close = gsub(/\}/, "}")
            brace_count += open - close
            next
          } else print
        } else {
          open = gsub(/\{/, "{")
          close = gsub(/\}/, "}")
          brace_count += open - close
          if (brace_count <= 0) in_view=0
          next
        }
      }
    ' "$POLICY_PATH" > "$POLICY_PATH.tmp"

    mv "$POLICY_PATH.tmp" "$POLICY_PATH"

    TOTAL_LINES=$(wc -l < "$POLICY_PATH")
    [[ "$TOTAL_LINES" -lt 3 ]] && echo -e "${RED}❌ ServerPolicy.php terlalu pendek.${RESET}" && exit 1

    head -n $((TOTAL_LINES - 1)) "$POLICY_PATH" > "$POLICY_PATH.tmp"
    cat >> "$POLICY_PATH.tmp" <<EOF

    /**
     * Anti-Intip: Blokir akses selain owner & admin utama.
     */
    public function view(User \$user, Server \$server): bool
    {
        if (\$user->id === \$server->owner_id || \$user->root_admin || \$user->id === $ADMIN_ID) {
            return true;
        }
        abort(403, "⚠️ Anti-Intip GreySync. Anak Yatim Mau Ngintip nih😹");
    }

EOF
    tail -n 1 "$POLICY_PATH" >> "$POLICY_PATH.tmp"
    mv "$POLICY_PATH.tmp" "$POLICY_PATH"

    echo -e "${GREEN}✔ Anti-Intip ditambahkan ke ServerPolicy.php${RESET}"
  else
    echo -e "${YELLOW}⚠ ServerPolicy.php tidak ditemukan, skip.${RESET}"
  fi

  # ===== CLEAR CACHE =====
  if command -v php >/dev/null 2>&1; then
    echo -e "${CYAN}🔄 Membersihkan cache Laravel...${RESET}"
    php artisan cache:clear 2>/dev/null || true
    php artisan config:clear 2>/dev/null || true
    php artisan route:clear 2>/dev/null || true
  fi

  echo -e "${GREEN}✅ Proteksi berhasil dipasang (Admin ID: $ADMIN_ID)${RESET}"
  echo -e "${YELLOW}📁 Backup tersimpan di: $BACKUP_DIR${RESET}"

# ===== RESTORE MODE =====
elif [[ "$MODE" == "2" ]]; then
  echo -e "${CYAN}♻ Memulihkan file backup terakhir...${RESET}"
  for name in "${!CONTROLLERS[@]}"; do
    latest=$(ls -t "$BACKUP_DIR" | grep "$name" | head -n 1)
    if [[ -n "$latest" ]]; then
      cp "$BACKUP_DIR/$latest" "${CONTROLLERS[$name]}"
      echo -e "${GREEN}✔ Pulih: $latest${RESET}"
    else
      echo -e "${YELLOW}⚠ Tidak ada backup untuk $name${RESET}"
    fi
  done

  latest_policy=$(ls -t "$BACKUP_DIR" | grep "ServerPolicy.php" | head -n 1)
  if [[ -n "$latest_policy" ]]; then
    cp "$BACKUP_DIR/$latest_policy" "$POLICY_PATH"
    echo -e "${GREEN}✔ Pulih Policy: $latest_policy${RESET}"
  else
    echo -e "${YELLOW}⚠ Tidak ada backup untuk ServerPolicy.php${RESET}"
  fi

  if command -v php >/dev/null 2>&1; then
    php artisan cache:clear 2>/dev/null || true
    php artisan config:clear 2>/dev/null || true
    php artisan route:clear 2>/dev/null || true
  fi

  echo -e "${GREEN}🔁 Restore selesai.${RESET}"
else
  echo -e "${RED}❌ Pilihan tidak valid.${RESET}"
fi
