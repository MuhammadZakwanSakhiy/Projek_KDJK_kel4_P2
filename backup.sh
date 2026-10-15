#!/usr/bin/env bash
# ==============================================================================
# Projek KDJK - Kelompok 4 Paralel 2
# Skrip Pemeliharaan & Pencadangan Otomatis (Backup & Maintenance)
# Mencadangkan Basis Data Coolify, WordPress MySQL, dan Volume Data
# ==============================================================================

set -euo pipefail

readonly C_RESET='\033[0m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[1;33m'
readonly C_RED='\033[0;31m'
readonly C_BLUE='\033[0;34m'
readonly C_BOLD='\033[1m'

log_info()    { echo -e "${C_BLUE}[INFO]${C_RESET} $*"; }
log_success() { echo -e "${C_GREEN}[SUCCESS]${C_RESET} $*"; }
log_warn()    { echo -e "${C_YELLOW}[WARNING]${C_RESET} $*"; }
log_error()   { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

# Validasi akses root
if [[ $EUID -ne 0 ]]; then
    log_error "Skrip ini harus dijalankan sebagai root (gunakan 'sudo bash backup.sh')."
    exit 1
fi

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_DIR="/backup/kdjk_kel4_${TIMESTAMP}"
RETENTION_DAYS=7

mkdir -p "$BACKUP_DIR"
log_info "Memulai pencadangan sistem ke direktori: $BACKUP_DIR"

# 1. Backup Basis Data Internal Coolify
log_info "1/4: Mencadangkan basis data internal Coolify..."
if docker ps --format '{{.Names}}' | grep -q "^coolify-db$"; then
    docker exec -t coolify-db pg_dump -U coolify coolify > "$BACKUP_DIR/coolify_db.sql" 2>/dev/null || true
    log_success "Database Coolify berhasil dicadangkan."
else
    log_warn "Kontainer coolify-db tidak ditemukan atau tidak sedang berjalan."
fi

# 2. Backup Konfigurasi & Lingkungan Coolify (/data/coolify)
log_info "2/4: Mencadangkan file konfigurasi /data/coolify..."
if [[ -d "/data/coolify" ]]; then
    tar -czf "$BACKUP_DIR/coolify_config_data.tar.gz" -C /data coolify 2>/dev/null || true
    log_success "Direktori konfigurasi /data/coolify berhasil diarsipkan."
else
    log_warn "Direktori /data/coolify belum terbentuk."
fi

# 3. Backup Basis Data Demo WordPress MySQL
log_info "3/4: Mencadangkan basis data demo WordPress MySQL..."
if docker ps --format '{{.Names}}' | grep -q "demo_wordpress_db"; then
    docker exec -t demo_wordpress_db mysqldump -u root -prootsecret123 --all-databases > "$BACKUP_DIR/wordpress_all_databases.sql" 2>/dev/null || true
    log_success "Database WordPress berhasil dicadangkan."
else
    log_info "Kontainer demo_wordpress_db tidak aktif (dilewati)."
fi

# 4. Ringkasan Ukuran Arsip Cadangan
log_info "4/4: Membuat arsip kompresi tunggal dan ringkasan..."
FINAL_ARCHIVE="/backup/backup_kdjk_kel4_${TIMESTAMP}.tar.gz"
tar -czf "$FINAL_ARCHIVE" -C /backup "kdjk_kel4_${TIMESTAMP}"
rm -rf "$BACKUP_DIR"

ARCHIVE_SIZE=$(du -sh "$FINAL_ARCHIVE" | awk '{print $1}')
log_success "Pencadangan selesai! Berkas: $FINAL_ARCHIVE ($ARCHIVE_SIZE)"

# 5. Rotasi Pembersihan Cadangan Lama (> 7 hari)
log_info "Memeriksa dan menghapus arsip cadangan yang berumur lebih dari $RETENTION_DAYS hari..."
find /backup -type f -name "backup_kdjk_kel4_*.tar.gz" -mtime +"$RETENTION_DAYS" -exec rm -f {} \; || true

log_success "Prosedur maintenance & backup berhasil diselesaikan."
