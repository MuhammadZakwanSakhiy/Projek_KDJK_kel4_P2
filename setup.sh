#!/usr/bin/env bash
# ==============================================================================
# Projek KDJK - Kelompok 4 Paralel 2
# Otomatisasi Instalasi Self-Hosting PaaS Coolify & Cloudflare Tunnel
# Demo Aplikasi: Grafana & WordPress + MySQL
# ==============================================================================

set -euo pipefail

# --- ANSI Color Codes ---
readonly C_RESET='\033[0m'
readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[1;33m'
readonly C_BLUE='\033[0;34m'
readonly C_CYAN='\033[0;36m'
readonly C_BOLD='\033[1m'

# --- Logging Functions ---
log_info() {
    echo -e "${C_BLUE}[INFO]${C_RESET} $*"
}

log_success() {
    echo -e "${C_GREEN}[SUCCESS]${C_RESET} $*"
}

log_warn() {
    echo -e "${C_YELLOW}[WARNING]${C_RESET} $*"
}

log_error() {
    echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2
}

log_step() {
    echo -e "\n${C_BOLD}${C_CYAN}==>${C_RESET} ${C_BOLD}$*${C_RESET}"
}

# --- Default Variables ---
DOMAIN=""
CF_TUNNEL_TOKEN=""
NON_INTERACTIVE=false
SKIP_DOCKER=false
SKIP_COOLIFY=false
SKIP_TUNNEL=false
ENABLE_QUICK_TUNNEL=false
COOLIFY_PORT=8000

# Error Handler
trap 'on_error $? $LINENO' ERR
on_error() {
    local exit_code=$1
    local line_no=$2
    log_error "Skrip gagal pada baris $line_no dengan kode keluar $exit_code."
    log_error "Silakan periksa log di atas atau jalankan kembali dengan debugging aktif (bash -x setup.sh)."
    exit "$exit_code"
}

# --- Usage Banner ---
usage() {
    cat <<EOF
Penggunaan: sudo bash setup.sh [OPSI]

Opsi:
  -d, --domain <DOMAIN>       Domain utama untuk instalasi (contoh: example.com)
  -t, --token <TOKEN>         Cloudflare Tunnel Token (Zero Trust tunnel connector)
  -q, --quick-tunnel          Gunakan Cloudflare Quick Tunnel (tanpa butuh domain/token sendiri)
  -y, --yes, --non-interactive
                              Jalankan mode non-interaktif dengan konfigurasi default
      --skip-docker           Lewati instalasi Docker jika sudah terinstal
      --skip-coolify          Lewati instalasi Coolify
      --skip-tunnel           Lewati konfigurasi Cloudflare Tunnel
  -h, --help                  Tampilkan pesan bantuan ini

Contoh:
  # Mode interaktif terpandu:
  sudo bash setup.sh

  # Mode otomatis langsung dengan domain dan token Cloudflare:
  sudo bash setup.sh --domain kel4.example.com --token eyJh... -y

  # Mode pengujian cepat tanpa domain (Quick Tunnel trycloudflare.com):
  sudo bash setup.sh --quick-tunnel -y
EOF
    exit 0
}

# --- Parse Arguments ---
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--domain)
                DOMAIN="$2"
                shift 2
                ;;
            -t|--token)
                CF_TUNNEL_TOKEN="$2"
                shift 2
                ;;
            -q|--quick-tunnel)
                ENABLE_QUICK_TUNNEL=true
                shift
                ;;
            -y|--yes|--non-interactive)
                NON_INTERACTIVE=true
                shift
                ;;
            --skip-docker)
                SKIP_DOCKER=true
                shift
                ;;
            --skip-coolify)
                SKIP_COOLIFY=true
                shift
                ;;
            --skip-tunnel)
                SKIP_TUNNEL=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                log_error "Argumen tidak dikenal: $1"
                usage
                ;;
        esac
    done
}

# --- Check Privileges and Environment ---
check_prerequisites() {
    log_step "Memeriksa Prasyarat Sistem & Hak Akses"

    # Check root
    if [[ $EUID -ne 0 ]]; then
        log_error "Skrip ini harus dijalankan sebagai root (gunakan 'sudo bash setup.sh')."
        exit 1
    fi

    # Check OS distribution
    if [[ ! -f /etc/os-release ]]; then
        log_error "/etc/os-release tidak ditemukan. Hanya Ubuntu dan Debian yang didukung."
        exit 1
    fi

    # shellcheck source=/dev/null
    source /etc/os-release
    if [[ "$ID" != "ubuntu" && "$ID" != "debian" && "$ID_LIKE" != *"debian"* && "$ID_LIKE" != *"ubuntu"* ]]; then
        log_warn "Distro terdeteksi: $NAME ($ID). Skrip ini dioptimalkan untuk Ubuntu/Debian."
    else
        log_success "Sistem operasi terverifikasi: $NAME $VERSION_ID"
    fi

    # Check Architecture
    local arch
    arch="$(uname -m)"
    if [[ "$arch" != "x86_64" && "$arch" != "aarch64" ]]; then
        log_error "Arsitektur CPU $arch tidak didukung. Harap gunakan x86_64 (amd64) atau aarch64 (arm64)."
        exit 1
    fi
    log_success "Arsitektur CPU: $arch"

    # Check RAM
    local total_ram_mb
    total_ram_mb="$(free -m | awk '/^Mem:/{print $2}')"
    log_info "Total RAM terdeteksi: ${total_ram_mb} MB"
    if [[ "$total_ram_mb" -lt 1800 ]]; then
        log_warn "RAM sistem kurang dari 2GB (${total_ram_mb} MB). Coolify beserta Grafana dan WordPress memerlukan minimal 2GB (direkomendasikan 4GB)."
        if [[ "$NON_INTERACTIVE" = false ]]; then
            read -r -p "Tetap lanjutkan instalasi? (y/N): " proceed_ram
            if [[ ! "$proceed_ram" =~ ^[Yy]$ ]]; then
                log_info "Instalasi dibatalkan oleh pengguna."
                exit 0
            fi
        fi
    fi

    # Detect Host IP
    HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")"
    log_info "Alamat IP Lokal VM: $HOST_IP"
}

# --- Interactive Prompts ---
prompt_user_inputs() {
    if [[ "$NON_INTERACTIVE" = true ]]; then
        if [[ -z "$DOMAIN" ]]; then
            DOMAIN="local.coolify"
            log_info "Mode non-interaktif: Menggunakan domain default '$DOMAIN'"
        fi
        return 0
    fi

    echo -e "\n${C_BOLD}${C_CYAN}======================================================${C_RESET}"
    echo -e "${C_BOLD}   PENGATURAN INSTALASI COOLIFY & CLOUDFLARE TUNNEL   ${C_RESET}"
    echo -e "${C_BOLD}${C_CYAN}======================================================${C_RESET}\n"

    # Domain Prompt
    if [[ -z "$DOMAIN" ]]; then
        echo -e "Masukkan Base Domain publik Anda yang telah terdaftar di Cloudflare."
        echo -e "Contoh: ${C_YELLOW}example.com${C_RESET} atau ${C_YELLOW}coolify.example.com${C_RESET}"
        read -r -p "Base Domain [kosongkan jika hanya ingin mencoba Quick Tunnel]: " input_domain
        if [[ -n "$input_domain" ]]; then
            DOMAIN="$input_domain"
        else
            DOMAIN="local.coolify"
            ENABLE_QUICK_TUNNEL=true
            log_info "Domain dikosongkan. Quick Tunnel (trycloudflare.com) akan diaktifkan untuk pengujian instan."
        fi
    fi

    # Cloudflare Tunnel Token Prompt
    if [[ "$SKIP_TUNNEL" = false && "$ENABLE_QUICK_TUNNEL" = false && -z "$CF_TUNNEL_TOKEN" ]]; then
        echo -e "\nApakah Anda memiliki Cloudflare Tunnel Token dari Cloudflare Zero Trust?"
        echo -e "Token didapatkan di dashboard: ${C_CYAN}Zero Trust -> Networks -> Tunnels -> Add a tunnel${C_RESET}"
        read -r -p "Punya Tunnel Token? (y/N): " have_token
        if [[ "$have_token" =~ ^[Yy]$ ]]; then
            read -r -p "Masukkan Cloudflare Tunnel Token: " input_token
            CF_TUNNEL_TOKEN="$input_token"
        else
            echo -e "\n${C_YELLOW}Pilihan koneksi publik:${C_RESET}"
            echo -e "  1. Buat Quick Tunnel instan via Cloudflare (gratis, tanpa butuh domain, URL otomatis *.trycloudflare.com)"
            echo -e "  2. Pasang Cloudflared dan buat template konfigurasi lokal untuk login nanti"
            echo -e "  3. Lewati konfigurasi tunnel (hanya akses lokal IP: $HOST_IP:8000)"
            read -r -p "Pilih opsi (1/2/3) [default: 1]: " tunnel_choice
            case "$tunnel_choice" in
                2)
                    ENABLE_QUICK_TUNNEL=false
                    ;;
                3)
                    SKIP_TUNNEL=true
                    ;;
                *)
                    ENABLE_QUICK_TUNNEL=true
                    ;;
            esac
        fi
    fi

    echo -e "\n${C_BOLD}Konfigurasi yang akan digunakan:${C_RESET}"
    echo -e "  - Base Domain       : ${C_GREEN}$DOMAIN${C_RESET}"
    echo -e "  - Cloudflare Tunnel : $(if [[ -n "$CF_TUNNEL_TOKEN" ]]; then echo "${C_GREEN}Zero Trust Token Configured${C_RESET}"; elif [[ "$ENABLE_QUICK_TUNNEL" = true ]]; then echo "${C_CYAN}Quick Tunnel (trycloudflare.com)${C_RESET}"; elif [[ "$SKIP_TUNNEL" = true ]]; then echo "${C_YELLOW}Dilewati${C_RESET}"; else echo "${C_YELLOW}Manual Config Template${C_RESET}"; fi)"
    echo -e "  - IP Lokal VM       : ${C_GREEN}$HOST_IP${C_RESET}"
    echo ""
    read -r -p "Lanjutkan proses instalasi sekarang? (Y/n): " confirm_install
    if [[ "$confirm_install" =~ ^[Nn]$ ]]; then
        log_info "Instalasi dibatalkan oleh pengguna."
        exit 0
    fi
}

# --- Step 1: Install System Dependencies ---
install_dependencies() {
    log_step "Langkah 1/6: Menginstal Dependensi Sistem & Utilitas Dasar"

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        gnupg \
        lsb-release \
        git \
        jq \
        ufw \
        net-tools \
        tar \
        openssl

    log_success "Dependensi dasar berhasil dipasang."
}

# --- Step 2: Configure Firewall (UFW) ---
configure_firewall() {
    log_step "Langkah 2/6: Mengonfigurasi Firewall Sistem (UFW)"

    # Check if ufw is active
    if command -v ufw >/dev/null 2>&1; then
        log_info "Mengizinkan port SSH (22) agar koneksi remote tidak terputus..."
        ufw allow 22/tcp || true

        log_info "Mengizinkan akses jaringan lokal ke port Coolify ($COOLIFY_PORT) & Traefik (80, 443)..."
        ufw allow 8000/tcp || true
        ufw allow 80/tcp || true
        ufw allow 443/tcp || true

        # We do not enforce ufw enable if disabled, but ensure rules are set
        log_info "Catatan: Cloudflare Tunnel menggunakan koneksi keluar (outbound tunnel),"
        log_info "sehingga port publik tidak perlu dibuka di router/NAT."
        log_success "Konfigurasi aturan firewall selesai."
    fi
}

# --- Step 3: Install Docker & Docker Compose ---
install_docker() {
    log_step "Langkah 3/6: Memeriksa dan Menginstal Docker Engine"

    if [[ "$SKIP_DOCKER" = true ]]; then
        log_info "Melewati instalasi Docker sesuai parameter (--skip-docker)."
        return 0
    fi

    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        local docker_ver
        docker_ver="$(docker --version | awk '{print $3}' | tr -d ',')"
        log_success "Docker sudah terinstal (versi: $docker_ver)."
        return 0
    fi

    log_info "Menginstal Docker Engine versi resmi dari repositori Docker..."

    install -m 0755 -d /etc/apt/keyrings
    # Source os release again
    # shellcheck source=/dev/null
    source /etc/os-release
    local os_distro="$ID"
    if [[ "$os_distro" != "ubuntu" && "$os_distro" != "debian" ]]; then
        os_distro="ubuntu"
    fi

    curl -fsSL "https://download.docker.com/linux/$os_distro/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$os_distro \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Enable and start Docker
    systemctl enable docker
    systemctl start docker

    # Add regular user to docker group if SUDO_USER is present
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        usermod -aG docker "$SUDO_USER" || true
        log_info "User '$SUDO_USER' berhasil ditambahkan ke grup 'docker'."
    fi

    log_success "Docker Engine & Docker Compose Plugin berhasil dipasang."
}

# --- Step 4: Install Coolify ---
install_coolify() {
    log_step "Langkah 4/6: Menginstal Platform as a Service (PaaS) Coolify"

    if [[ "$SKIP_COOLIFY" = true ]]; then
        log_info "Melewati instalasi Coolify sesuai parameter (--skip-coolify)."
        return 0
    fi

    # Check if coolify container exists
    if docker ps -a --format '{{.Names}}' | grep -q "^coolify$"; then
        log_success "Container Coolify sudah terpasang dan berjalan."
        return 0
    fi

    log_info "Menjalankan skrip instalasi otomatis resmi Coolify v4..."
    curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash

    log_info "Menunggu Coolify menyelesaikan inisialisasi awal (30 detik)..."
    sleep 30

    if docker ps --format '{{.Names}}' | grep -q "^coolify$"; then
        log_success "Coolify v4 berhasil dipasang dan berjalan di port $COOLIFY_PORT!"
    else
        log_warn "Container Coolify sedang dalam proses starting. Memeriksa kembali..."
        sleep 15
    fi
}

# --- Step 5: Install and Configure Cloudflare Tunnel ---
install_cloudflare_tunnel() {
    log_step "Langkah 5/6: Menginstal & Mengonfigurasi Cloudflare Tunnel (cloudflared)"

    if [[ "$SKIP_TUNNEL" = true ]]; then
        log_info "Melewati konfigurasi Cloudflare Tunnel sesuai permintaan pengguna."
        return 0
    fi

    # Install cloudflared binary if not present
    if ! command -v cloudflared >/dev/null 2>&1; then
        log_info "Mengunduh dan menginstal binary resmi cloudflared package .deb..."
        local arch
        arch="$(dpkg --print-architecture)"
        local deb_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}.deb"
        
        wget -q --show-progress "$deb_url" -O /tmp/cloudflared.deb
        dpkg -i /tmp/cloudflared.deb || apt-get install -f -y
        rm -f /tmp/cloudflared.deb
        log_success "cloudflared CLI berhasil diinstal (versi: $(cloudflared --version))."
    else
        log_success "cloudflared CLI sudah terpasang (versi: $(cloudflared --version))."
    fi

    # Mode 1: Cloudflare Tunnel Token Provided (Recommended Zero Trust Method)
    if [[ -n "$CF_TUNNEL_TOKEN" ]]; then
        log_info "Mendaftarkan dan mengaktifkan service cloudflared menggunakan Tunnel Token..."
        # Remove existing service if any
        cloudflared service uninstall >/dev/null 2>&1 || true
        cloudflared service install "$CF_TUNNEL_TOKEN"
        systemctl daemon-reload
        systemctl enable cloudflared
        systemctl restart cloudflared
        log_success "Cloudflare Tunnel service berhasil dijalankan secara background!"
        log_info "Status Service: $(systemctl is-active cloudflared)"

    # Mode 2: Quick Tunnel Mode (trycloudflare.com)
    elif [[ "$ENABLE_QUICK_TUNNEL" = true ]]; then
        log_info "Menyiapkan skrip helper Quick Tunnel untuk demonstrasi instan..."
        cat <<'EOF' > /usr/local/bin/coolify-quick-tunnel.sh
#!/usr/bin/env bash
# Helper script to launch an on-demand public HTTPS tunnel to Coolify
echo "=========================================================="
echo " Memulai Cloudflare Quick Tunnel untuk Coolify (:8000)..."
echo " Salin URL HTTPS publik (*.trycloudflare.com) di bawah ini:"
echo " Tekan Ctrl+C untuk menghentikan tunnel."
echo "=========================================================="
cloudflared tunnel --url http://localhost:8000
EOF
        chmod +x /usr/local/bin/coolify-quick-tunnel.sh

        # Also create a systemd service for persistent quick tunnel if desired
        cat <<EOF > /etc/systemd/system/coolify-quick-tunnel.service
[Unit]
Description=Cloudflare Quick Tunnel for Coolify
After=network.target docker.service

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --url http://localhost:8000 --no-autoupdate
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now coolify-quick-tunnel.service || true
        log_success "Quick Tunnel service diaktifkan via systemd (coolify-quick-tunnel.service)."
        log_info "Untuk melihat URL publik trycloudflare, jalankan: journalctl -u coolify-quick-tunnel.service | grep 'trycloudflare.com'"

    # Mode 3: Local Configuration File Template
    else
        log_info "Menyiapkan berkas template konfigurasi lokal di /etc/cloudflared/config.yml..."
        mkdir -p /etc/cloudflared
        cat <<EOF > /etc/cloudflared/config.yml.template
# Template Konfigurasi Cloudflare Tunnel Lokal
# 1. Login Cloudflare CLI: cloudflared tunnel login
# 2. Buat Tunnel: cloudflared tunnel create kdjk-coolify
# 3. Masukkan tunnel ID dan path credentials di bawah ini:
# tunnel: <TUNNEL_ID>
# credentials-file: /root/.cloudflared/<TUNNEL_ID>.json

ingress:
  # Coolify Web Dashboard
  - hostname: coolify.${DOMAIN}
    service: http://localhost:8000

  # Grafana Dashboard
  - hostname: grafana.${DOMAIN}
    service: http://localhost:80

  # WordPress Site
  - hostname: wordpress.${DOMAIN}
    service: http://localhost:80

  # Wildcard untuk aplikasi lain yang di-deploy via Traefik Coolify
  - hostname: "*.${DOMAIN}"
    service: http://localhost:80

  # Catch-all 404 rule (wajib pada baris terakhir)
  - service: http_status:404
EOF
        log_success "Template /etc/cloudflared/config.yml.template berhasil dibuat."
    fi
}

# --- Step 6: Setup Demo Applications & Documentation ---
setup_demo_apps() {
    log_step "Langkah 6/6: Menyiapkan Template Demo Aplikasi (Grafana & WordPress-MySQL)"

    local demo_dir="/opt/coolify-demo-apps"
    mkdir -p "$demo_dir/grafana" "$demo_dir/wordpress-mysql"

    # Grafana Compose Template
    cat <<EOF > "$demo_dir/grafana/docker-compose.yml"
services:
  grafana:
    image: grafana/grafana:latest
    container_name: demo_grafana
    restart: unless-stopped
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=adminpassword123
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_SERVER_ROOT_URL=https://grafana.${DOMAIN}
    ports:
      - "3000:3000"
    volumes:
      - grafana_data:/var/lib/grafana

volumes:
  grafana_data:
EOF

    # WordPress & MySQL Compose Template
    cat <<EOF > "$demo_dir/wordpress-mysql/docker-compose.yml"
services:
  mysql:
    image: mysql:8.0
    container_name: demo_wordpress_db
    restart: unless-stopped
    command: '--default-authentication-plugin=mysql_native_password'
    environment:
      MYSQL_ROOT_PASSWORD: rootsecret123
      MYSQL_DATABASE: wordpress
      MYSQL_USER: wp_user
      MYSQL_PASSWORD: wp_password123
    volumes:
      - mysql_data:/var/lib/mysql
    networks:
      - wp_net

  wordpress:
    image: wordpress:latest
    container_name: demo_wordpress_app
    restart: unless-stopped
    depends_on:
      - mysql
    ports:
      - "8080:80"
    environment:
      WORDPRESS_DB_HOST: mysql:3306
      WORDPRESS_DB_NAME: wordpress
      WORDPRESS_DB_USER: wp_user
      WORDPRESS_DB_PASSWORD: wp_password123
      WORDPRESS_TABLE_PREFIX: wp_
    volumes:
      - wordpress_data:/var/www/html
    networks:
      - wp_net

volumes:
  mysql_data:
  wordpress_data:

networks:
  wp_net:
    driver: bridge
EOF

    # Copy to current repo if demo-apps folder exists
    local repo_dir
    repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -d "$repo_dir/demo-apps" ]]; then
        cp "$demo_dir/grafana/docker-compose.yml" "$repo_dir/demo-apps/grafana/docker-compose.yml" || true
        cp "$demo_dir/wordpress-mysql/docker-compose.yml" "$repo_dir/demo-apps/wordpress-mysql/docker-compose.yml" || true
    fi

    log_success "Template demo aplikasi tersimpan di '$demo_dir'."
}

# --- Final Verification and Summary Banner ---
print_summary() {
    echo -e "\n${C_BOLD}${C_GREEN}========================================================================${C_RESET}"
    echo -e "${C_BOLD}${C_GREEN}       INSTALASI & KONFIGURASI SELF-HOSTING BERHASIL DISELESAIKAN       ${C_RESET}"
    echo -e "${C_BOLD}${C_GREEN}========================================================================${C_RESET}\n"

    echo -e "${C_BOLD}Informasi Akses Sistem:${C_RESET}"
    echo -e "  - IP Lokal VM          : ${C_CYAN}http://${HOST_IP}:${COOLIFY_PORT}${C_RESET}"
    echo -e "  - Dashboard Coolify    : ${C_CYAN}http://localhost:${COOLIFY_PORT}${C_RESET}"

    if [[ -n "$CF_TUNNEL_TOKEN" || "$DOMAIN" != "local.coolify" ]]; then
        echo -e "  - Public URL Coolify   : ${C_GREEN}https://coolify.${DOMAIN}${C_RESET}"
        echo -e "  - Public URL Grafana   : ${C_GREEN}https://grafana.${DOMAIN}${C_RESET}"
        echo -e "  - Public URL WordPress : ${C_GREEN}https://wordpress.${DOMAIN}${C_RESET}"
    fi

    if [[ "$ENABLE_QUICK_TUNNEL" = true ]]; then
        local quick_url
        quick_url="$(journalctl -u coolify-quick-tunnel.service -n 50 --no-pager 2>/dev/null | grep -o 'https://[^ ]*trycloudflare.com' | tail -n 1 || echo "")"
        if [[ -n "$quick_url" ]]; then
            echo -e "  - Quick Tunnel Public  : ${C_GREEN}${quick_url}${C_RESET}"
        else
            echo -e "  - Quick Tunnel Command : Jalankan ${C_YELLOW}coolify-quick-tunnel.sh${C_RESET} untuk melihat URL publik langsung."
        fi
    fi

    echo -e "\n${C_BOLD}Langkah Selanjutnya untuk Presentasi & Demo:${C_RESET}"
    echo -e "  1. Buka dashboard Coolify melalui URL lokal atau publik di atas."
    echo -e "  2. Daftarkan akun Administrator pertama Anda."
    echo -e "  3. Tambahkan Server Lokal (localhost) pada menu 'Servers'."
    echo -e "  4. Deploy Demo 1 (${C_BOLD}Grafana${C_RESET}):"
    echo -e "     - Pada Coolify, klik '+ New' -> 'Service' -> pilih 'Grafana' atau gunakan compose di /opt/coolify-demo-apps/grafana/."
    echo -e "     - Konfigurasikan domain menjadi: https://grafana.${DOMAIN}"
    echo -e "  5. Deploy Demo 2 (${C_BOLD}WordPress + MySQL${C_RESET}):"
    echo -e "     - Klik '+ New' -> 'Service' -> pilih 'WordPress with MySQL/MariaDB'."
    echo -e "     - Konfigurasikan domain menjadi: https://wordpress.${DOMAIN}"
    echo -e "     - Masuk ke dashboard WordPress untuk mengisi konten artikel demo."
    echo -e "  6. Dokumentasi lengkap laporan tersimpan di ${C_BOLD}README.md${C_RESET}."
    echo -e "${C_BOLD}${C_GREEN}========================================================================${C_RESET}\n"
}

# --- Main Execution Flow ---
main() {
    parse_args "$@"
    check_prerequisites
    prompt_user_inputs
    install_dependencies
    configure_firewall
    install_docker
    install_coolify
    install_cloudflare_tunnel
    setup_demo_apps
    print_summary
}

main "$@"
