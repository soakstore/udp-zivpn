#!/bin/bash

# ============================================================================
# ZIVPN INSTALLER & MANAGEMENT SCRIPT
# ============================================================================
# Script ini digunakan untuk menginstall, mengelola, dan mengkonfigurasi
# layanan ZIVPN termasuk manajemen akun, lisensi, dan notifikasi Telegram.
# ============================================================================

# ----------------------------------------------------------------------------
# DEFINISI WARNA UNTUK OUTPUT TERMINAL
# ----------------------------------------------------------------------------
YELLOW='\033[1;33m'
RED='\033[0;31m'
LIGHT_BLUE='\033[1;36m' # biru muda terang
BOLD_WHITE='\033[1;37m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
LIGHT_GREEN='\033[1;32m'
NC='\033[0m' # No Color

# ----------------------------------------------------------------------------
# KONFIGURASI GLOBAL
# ----------------------------------------------------------------------------
LICENSE_URL="https://raw.githubusercontent.com/arivpnstores/izin/main/ip2"
LICENSE_INFO_FILE="/etc/zivpn/.license_info"
CONFIG_DIR="/etc/zivpn"
TELEGRAM_CONF="${CONFIG_DIR}/telegram.conf"

# ----------------------------------------------------------------------------
# PENGECEKAN HAK AKSES ROOT
# ----------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please use sudo or run as root user." >&2
    exit 1
fi

# ============================================================================
# FUNGSI NOTIFIKASI TELEGRAM
# ============================================================================

# ----------------------------------------------------------------------------
# Mengirim notifikasi ke Telegram
# Parameter: $1 = pesan, $2 = keyboard (opsional)
# ----------------------------------------------------------------------------
function send_telegram_notification() {
    local message="$1"
    local keyboard="$2"

    if [ ! -f "$TELEGRAM_CONF" ]; then
        return 1
    fi

    source "$TELEGRAM_CONF"

    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        local api_url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
        if [ -n "$keyboard" ]; then
            curl -s -X POST "$api_url" -d "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=${message}" -d "reply_markup=${keyboard}" >/dev/null
        else
            curl -s -X POST "$api_url" -d "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=${message}" -d "parse_mode=Markdown" >/dev/null
        fi
    fi
}

# ============================================================================
# FUNGSI VERIFIKASI LISENSI
# ============================================================================

# ----------------------------------------------------------------------------
# Memverifikasi lisensi instalasi berdasarkan IP server
# Mengecek apakah IP terdaftar dan lisensi masih aktif
# ----------------------------------------------------------------------------
function verify_license() {
    echo "Verifying installation license..."

    local SERVER_IP
    SERVER_IP=$(curl -4 -s ifconfig.me || curl -6 -s ifconfig.me)

    if [ -z "$SERVER_IP" ]; then
        echo -e "${RED}Failed to retrieve server IP. Please check your internet connection.${NC}"
        exit 1
    fi

    local license_data
    license_data=$(curl -s "$LICENSE_URL")

    if [ $? -ne 0 ] || [ -z "$license_data" ]; then
        echo -e "${RED}Gagal terhubung ke server lisensi. Mohon periksa koneksi internet Anda.${NC}"
        exit 1
    fi

    local license_entry
    license_entry=$(echo "$license_data" | grep -w "$SERVER_IP")

    if [ -z "$license_entry" ]; then
        echo -e "${RED}Verifikasi Lisensi Gagal! IP Anda tidak terdaftar. IP: ${SERVER_IP}${NC}"
        exit 1
    fi

    local client_name
    local expiry_date_str
    client_name=$(echo "$license_entry" | awk '{print $1}')
    expiry_date_str=$(echo "$license_entry" | awk '{print $2}')

    local expiry_timestamp
    expiry_timestamp=$(date -d "$expiry_date_str" +%s)

    local current_timestamp
    current_timestamp=$(date +%s)

    if [ "$expiry_timestamp" -le "$current_timestamp" ]; then
        echo -e "${RED}Verifikasi Lisensi Gagal! Lisensi untuk IP ${SERVER_IP} telah kedaluwarsa. Tanggal Kedaluwarsa: ${expiry_date_str}${NC}"
        exit 1
    fi

    echo -e "${LIGHT_GREEN}Verifikasi Lisensi Berhasil! Client: ${client_name}, IP: ${SERVER_IP}${NC}"
    sleep 2
    mkdir -p /etc/zivpn
    echo "CLIENT_NAME=${client_name}" >"$LICENSE_INFO_FILE"
    echo "EXPIRY_DATE=${expiry_date_str}" >>"$LICENSE_INFO_FILE"
}

# ============================================================================
# FUNGSI SERVICE MANAGEMENT
# ============================================================================

# ----------------------------------------------------------------------------
# Restart layanan ZIVPN dengan graceful reload
# Mencoba reload config tanpa disconnect, jika gagal restart service
# ----------------------------------------------------------------------------
function restart_zivpn() {
    if kill -HUP $(pidof zivpn) &>/dev/null; then
        echo "Reload config without disconnect"
    else
        systemctl restart zivpn.service --no-block
        echo "Service restarted gracefully"
    fi
}

# ============================================================================
# FUNGSI MANAJEMEN AKUN
# ============================================================================

# ----------------------------------------------------------------------------
# Logic internal untuk membuat akun baru
# Parameter: $1 = password, $2 = jumlah hari aktif
# ----------------------------------------------------------------------------
function _create_account_logic() {
    local password="$1"
    local days="$2"
    local db_file="/etc/zivpn/users.db"
    if [ -z "$password" ] || [ -z "$days" ]; then
        echo "Error: Password and days are required."
        return 1
    fi
    if ! [[ "$days" =~ ^[0-9]+$ ]]; then
        echo "Error: Invalid number of days."
        return 1
    fi
    if grep -q "^${password}:" "$db_file"; then
        echo "Error: Password '${password}' already exists."
        return 1
    fi
    local expiry_date
    expiry_date=$(date -d "+$days days" +%s)
    echo "${password}:${expiry_date}" >>"$db_file"
    jq --arg pass "$password" '.auth.config += [$pass]' /etc/zivpn/config.json >/etc/zivpn/config.json.tmp && mv /etc/zivpn/config.json.tmp /etc/zivpn/config.json
    if [ $? -eq 0 ]; then
        restart_zivpn
        local EXPIRE_FORMATTED
        EXPIRE_FORMATTED=$(date -d "@$expiry_date" +"%d %B %Y %H:%M")
        ip=$(curl -4 -s ifconfig.me || curl -6 -s ifconfig.me)
        isp=$(curl -s ipinfo.io | jq -r '.org // "N/A"' | sed 's/^AS[0-9]\+ //')
        CERT_CN=$(openssl x509 -in /etc/zivpn/zivpn.crt -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p')
        local host
        if [ "$CERT_CN" == "zivpn" ]; then
            host=$(curl -4 -s ifconfig.me || curl -6 -s ifconfig.me)
        else
            host=$CERT_CN
        fi
        clear
        echo "Success:"
        echo "CREATE AKUN ZIVPN"
        echo "┌────────────────────────┐"
        echo "│ Host   : $host"
        echo "│ IP     : $ip"
        echo "│ ISP    : $isp"
        echo "│ Pass   : $password"
        echo "│ Expire : $EXPIRE_FORMATTED"
        echo "└────────────────────────┘"
        echo "Terima kasih telah menggunakan layanan kami"
        local message=$(
            cat <<EOF
CREATE AKUN ZIVPN
┌────────────────────────┐
│ Host   : $host
│ IP     : $ip
│ ISP    : $isp
│ Pass   : $password
│ Expire : $EXPIRE_FORMATTED
└────────────────────────┘
Terima kasih telah menggunakan layanan kami
EOF
        )
        send_telegram_notification "$message"
        return 0
    else
        sed -i "/^${password}:/d" "$db_file"
        echo "Error: Failed to update config.json."
        return 1
    fi
}

# ----------------------------------------------------------------------------
# Menu interaktif untuk membuat akun manual
# Meminta input password dan durasi dari user
# ----------------------------------------------------------------------------
function create_manual_account() {
    echo "───────── Create New Zivpn Account ───────"
    read -p "Enter new password: " password
    if [ -z "$password" ]; then
        echo "Password cannot be empty."
        return
    fi
    read -p "Enter active period (in days): " days
    if ! [[ "$days" =~ ^[0-9]+$ ]]; then
        echo "Invalid number of days."
        return
    fi
    local result
    result=$(_create_account_logic "$password" "$days")
    if [[ "$result" == "Success"* ]]; then
        local db_file="/etc/zivpn/users.db"
        local user_line
        user_line=$(grep "^${password}:" "$db_file")
        if [ -n "$user_line" ]; then
            local expiry_date
            expiry_date=$(echo "$user_line" | cut -d: -f2)
            local CERT_CN
            CERT_CN=$(openssl x509 -in /etc/zivpn/zivpn.crt -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p')
            local HOST
            if [ "$CERT_CN" == "zivpn" ]; then
                HOST=$(curl -4 -s ifconfig.me || curl -6 -s ifconfig.me)
            else
                HOST=$CERT_CN
            fi
            local EXPIRE_FORMATTED
            EXPIRE_FORMATTED=$(date -d "@$expiry_date" +"%d %B %Y %H:%M")
        fi
    else
        echo "$result"
    fi
    read -p "Tekan Enter untuk kembali ke menu..."
}

# ----------------------------------------------------------------------------
# Generate API key baru untuk autentikasi REST API
# Menyimpan key ke file dan mengirim notifikasi ke Telegram
# ----------------------------------------------------------------------------
function _generate_api_key() {
    clear
    echo "─── Generate API Authentication Key ───"
    local api_key
    api_key=$(LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 6)
    local key_file="/etc/zivpn/api_auth.key"
    echo "$api_key" >"$key_file"
    chmod 600 "$key_file"
    echo "New API authentication key has been generated and saved."
    echo "Key: ${api_key}"
    echo "Sending API key to Telegram..."
    local server_ip
    server_ip=$(curl -4 -s ifconfig.me || curl -6 -s ifconfig.me)
    local cert_cn
    cert_cn=$(openssl x509 -in /etc/zivpn/zivpn.crt -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p' 2>/dev/null || echo "")
    local domain
    if [ "$cert_cn" == "zivpn" ] || [ -z "$cert_cn" ]; then
        domain=$server_ip
    else
        domain=$cert_cn
    fi
    /usr/local/bin/zivpn_helper.sh api-key-notification "$api_key" "$server_ip" "$domain"
    read -p "Tekan Enter untuk kembali ke menu..."
}

# ----------------------------------------------------------------------------
# Logic internal untuk membuat akun trial
# Parameter: $1 = jumlah menit aktif
# ----------------------------------------------------------------------------
function _create_trial_account_logic() {
    local minutes="$1"
    local db_file="/etc/zivpn/users.db"
    if ! [[ "$minutes" =~ ^[0-9]+$ ]]; then
        echo "Error: Invalid number of minutes."
        return 1
    fi
    local password="trial$(shuf -i 10000-99999 -n 1)"
    local expiry_date
    expiry_date=$(date -d "+$minutes minutes" +%s)
    echo "${password}:${expiry_date}" >>"$db_file"
    jq --arg pass "$password" '.auth.config += [$pass]' /etc/zivpn/config.json >/etc/zivpn/config.json.tmp && mv /etc/zivpn/config.json.tmp /etc/zivpn/config.json
    if [ $? -eq 0 ]; then
        restart_zivpn
        local EXPIRE_FORMATTED
        EXPIRE_FORMATTED=$(date -d "@$expiry_date" +"%d %B %Y %H:%M")
        ip=$(curl -4 -s ifconfig.me || curl -6 -s ifconfig.me)
        isp=$(curl -s ipinfo.io | jq -r '.org // "N/A"' | sed 's/^AS[0-9]\+ //')
        CERT_CN=$(openssl x509 -in /etc/zivpn/zivpn.crt -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p')
        local host
        if [ "$CERT_CN" == "zivpn" ]; then
            host=$(curl -4 -s ifconfig.me || curl -6 -s ifconfig.me)
        else
            host=$CERT_CN
        fi
        clear
        echo "Success:"
        echo "TRIAL AKUN ZIVPN"
        echo "┌────────────────────────┐"
        echo "│ Host   : $host"
        echo "│ IP     : $ip"
        echo "│ ISP    : $isp"
        echo "│ Pass   : $password"
        echo "│ Expire : $EXPIRE_FORMATTED"
        echo "└────────────────────────┘"
        echo "Terima kasih telah menggunakan layanan kami"
        local message=$(
            cat <<EOF
TRIAL AKUN ZIVPN
┌────────────────────────┐
│ Host   : $host
│ IP     : $ip
│ ISP    : $isp
│ Pass   : $password
│ Expire : $EXPIRE_FORMATTED
└────────────────────────┘
Terima kasih telah mencoba layanan kami
EOF
        )
        send_telegram_notification "$message"
        return 0
    else
        sed -i "/^${password}:/d" "$db_file"
        echo "Error: Failed to update config.json."
        return 1
    fi
}

# ----------------------------------------------------------------------------
# Menu interaktif untuk membuat akun trial
# Meminta input durasi dalam menit dari user
# ----------------------------------------------------------------------------
function create_trial_account() {
    echo "─────── Create Trial Zivpn Account ───────"
    read -p "Enter active period (in minutes): " minutes
    if ! [[ "$minutes" =~ ^[0-9]+$ ]]; then
        echo "Invalid number of minutes."
        return
    fi
    local result
    result=$(_create_trial_account_logic "$minutes")
    if [[ "$result" == "Success"* ]]; then
        local password
        password=$(echo "$result" | sed -n "s/Success: Trial account '\([^']*\)'.*/\1/p")
        local db_file="/etc/zivpn/users.db"
        local user_line
        user_line=$(grep "^${password}:" "$db_file")
        if [ -n "$user_line" ]; then
            local expiry_date
            expiry_date=$(echo "$user_line" | cut -d: -f2)
            local CERT_CN
            CERT_CN=$(openssl x509 -in /etc/zivpn/zivpn.crt -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p')
            local HOST
            if [ "$CERT_CN" == "zivpn" ]; then
                HOST=$(curl -4 -s ifconfig.me || curl -6 -s ifconfig.me)
            else
                HOST=$CERT_CN
            fi
            local EXPIRE_FORMATTED
            EXPIRE_FORMATTED=$(date -d "@$expiry_date" +"%d %B %Y %H:%M:%S")
        fi
    else
        echo "$result"
    fi
    read -p "Tekan Enter untuk kembali ke menu..."
}

# ----------------------------------------------------------------------------
# Logic internal untuk memperpanjang masa aktif akun
# Parameter: $1 = password, $2 = jumlah hari perpanjangan
# ----------------------------------------------------------------------------
function _renew_account_logic() {
    local password="$1"
    local days="$2"
    local db_file="/etc/zivpn/users.db"
    if [ -z "$password" ] || [ -z "$days" ]; then
        echo "Error: Password and days are required."
        return 1
    fi
    if ! [[ "$days" =~ ^[1-9][0-9]*$ ]]; then
        echo "Error: Invalid number of days."
        return 1
    fi
    local user_line
    user_line=$(grep "^${password}:" "$db_file")
    if [ -z "$user_line" ]; then
        echo "Error: Account '${password}' not found."
        return 1
    fi
    local current_expiry_date
    current_expiry_date=$(echo "$user_line" | cut -d: -f2)
    if ! [[ "$current_expiry_date" =~ ^[0-9]+$ ]]; then
        echo "Error: Corrupted database entry for user '$password'."
        return 1
    fi
    local seconds_to_add=$((days * 86400))
    local new_expiry_date=$((current_expiry_date + seconds_to_add))
    sed -i "s/^${password}:.*/${password}:${new_expiry_date}/" "$db_file"
    local new_expiry_formatted
    new_expiry_formatted=$(date -d "@$new_expiry_date" +"%d %B %Y %H:%M")
    ip=$(curl -4 -s ifconfig.me || curl -6 -s ifconfig.me)
    isp=$(curl -s ipinfo.io | jq -r '.org // "N/A"' | sed 's/^AS[0-9]\+ //')
    CERT_CN=$(openssl x509 -in /etc/zivpn/zivpn.crt -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p')
    local host
    if [ "$CERT_CN" == "zivpn" ]; then
        host=$(curl -4 -s ifconfig.me || curl -6 -s ifconfig.me)
    else
        host=$CERT_CN
    fi
    clear
    echo "Success:"
    echo "RENEW AKUN ZIVPN"
    echo "┌────────────────────────┐"
    echo "│ Host   : $host"
    echo "│ IP     : $ip"
    echo "│ ISP    : $isp"
    echo "│ Pass   : $password"
    echo "│ Expire : $new_expiry_formatted"
    echo "└────────────────────────┘"
    echo "Terima kasih telah menggunakan layanan kami"
    local message=$(
        cat <<EOF
RENEW AKUN ZIVPN
┌────────────────────────┐
│ Host   : $host
│ IP     : $ip
│ ISP    : $isp
│ Pass   : $password
│ Expire : $new_expiry_formatted
└────────────────────────┘
Terima kasih telah menggunakan layanan kami
EOF
    )
    send_telegram_notification "$message"
    return 0
}

# ----------------------------------------------------------------------------
# Menu interaktif untuk memperpanjang akun
# Menampilkan daftar akun dan meminta input dari user
# ----------------------------------------------------------------------------
function renew_account() {
    clear
    echo "───────────── Renew Account ──────────────"
    _display_accounts
    echo "" # Add a newline for better spacing
    read -p "Enter password to renew: " password
    if [ -z "$password" ]; then
        echo "Password cannot be empty."
        return
    fi
    read -p "Enter number of days to extend: " days
    if ! [[ "$days" =~ ^[1-9][0-9]*$ ]]; then
        echo "Invalid number of days. Please enter a positive number."
        return
    fi
    local result
    result=$(_renew_account_logic "$password" "$days")
    if [[ "$result" == "Success"* ]]; then
        local db_file="/etc/zivpn/users.db"
        local user_line
        user_line=$(grep "^${password}:" "$db_file")
        local new_expiry_date
        new_expiry_date=$(echo "$user_line" | cut -d: -f2)
        local new_expiry_formatted
        new_expiry_formatted=$(date -d "@$new_expiry_date" +"%d %B %Y")
    else
        echo "$result"
    fi
    read -p "Tekan Enter untuk kembali ke menu..."
}

# ----------------------------------------------------------------------------
# Logic internal untuk menghapus akun
# Parameter: $1 = password akun yang akan dihapus
# ----------------------------------------------------------------------------
function _delete_account_logic() {
    local password="$1"
    local db_file="/etc/zivpn/users.db"
    local config_file="/etc/zivpn/config.json"
    local tmp_config_file="${config_file}.tmp"
    if [ -z "$password" ]; then
        echo "Error: Password is required."
        return 1
    fi
    if [ ! -f "$db_file" ] || ! grep -q "^${password}:" "$db_file"; then
        echo "Error: Password '${password}' not found."
        return 1
    fi
    jq --arg pass "$password" 'del(.auth.config[] | select(. == $pass))' "$config_file" >"$tmp_config_file"
    if [ $? -eq 0 ]; then
        sed -i "/^${password}:/d" "$db_file"
        mv "$tmp_config_file" "$config_file"
        restart_zivpn
        ip=$(curl -4 -s ifconfig.me || curl -6 -s ifconfig.me)
        isp=$(curl -s ipinfo.io | jq -r '.org // "N/A"' | sed 's/^AS[0-9]\+ //')
        CERT_CN=$(openssl x509 -in /etc/zivpn/zivpn.crt -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p')
        local host
        if [ "$CERT_CN" == "zivpn" ]; then
            host=$(curl -4 -s ifconfig.me || curl -6 -s ifconfig.me)
        else
            host=$CERT_CN
        fi
        clear
        echo "Success:"
        echo "DELETE AKUN ZIVPN"
        echo "┌────────────────────────┐"
        echo "│ Host   : $host"
        echo "│ IP     : $ip"
        echo "│ ISP    : $isp"
        echo "│ Pass   : $password"
        echo "│ Status : Deleted"
        echo "└────────────────────────┘"
        echo "Terima kasih telah menggunakan layanan kami"
        local message=$(
            cat <<EOF
DELETE AKUN ZIVPN
┌────────────────────────┐
│ Host   : $host
│ IP     : $ip
│ ISP    : $isp
│ Pass   : $password
│ Status : Deleted
└────────────────────────┘
Terima kasih telah menggunakan layanan kami
EOF
        )
        send_telegram_notification "$message"
        return 0
    else
        rm -f "$tmp_config_file" # Clean up temp file
        echo "Error: Failed to update config.json. No changes were made."
        return 1
    fi
}

# ----------------------------------------------------------------------------
# Menu interaktif untuk menghapus akun
# Menampilkan daftar akun dan meminta konfirmasi dari user
# ----------------------------------------------------------------------------
function delete_account() {
    clear
    echo "───────────── Delete Account ─────────────"
    _display_accounts
    echo "" # Add a newline for better spacing
    read -p "Enter password to delete: " password
    if [ -z "$password" ]; then
        echo "Password cannot be empty."
        return
    fi
    local result
    result=$(_delete_account_logic "$password")
    echo "$result" # Display the result from the logic function
    read -p "Tekan Enter untuk kembali ke menu..."
}

# ----------------------------------------------------------------------------
# Mengubah domain SSL certificate
# Generate sertifikat baru dengan domain yang diinputkan
# ----------------------------------------------------------------------------
function change_domain() {
    echo "─────────────── Change Domain ───────────────"
    read -p "Enter the new domain name for the SSL certificate: " domain
    if [ -z "$domain" ]; then
        echo "Domain name cannot be empty."
        return
    fi
    echo "Generating new certificate for domain '${domain}'..."
    openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
        -subj "/C=US/ST=California/L=Los Angeles/O=Example Corp/OU=IT Department/CN=${domain}" \
        -keyout "/etc/zivpn/zivpn.key" -out "/etc/zivpn/zivpn.crt"
    echo "New certificate generated."
    restart_zivpn
}

# ============================================================================
# FUNGSI UTILITAS DAN HELPER
# ============================================================================

# ----------------------------------------------------------------------------
# Menyimpan total user ke file untuk ditampilkan di panel info
# ----------------------------------------------------------------------------
function _save_total_users() {
    local db_file="/etc/zivpn/users.db"
    local output_file="/etc/zivpn/total_users.txt"
    if [ ! -f "$db_file" ] || [ ! -s "$db_file" ]; then
        echo "0" >"$output_file"
        return
    fi
    local total_users
    total_users=$(wc -l <"$db_file" | tr -d ' ')
    echo "$total_users" >"$output_file"
}

# ----------------------------------------------------------------------------
# Menampilkan daftar akun dengan sisa hari aktif
# ----------------------------------------------------------------------------
function _display_accounts() {
    local db_file="/etc/zivpn/users.db"
    if [ ! -f "$db_file" ] || [ ! -s "$db_file" ]; then
        echo "No accounts found."
        return
    fi
    local current_date
    current_date=$(date +%s)
    printf "%-20s │ %s\n" "Password" "Expires in (days)"
    echo "──────────────────────────────────────────"
    while IFS=':' read -r password expiry_date; do
        if [[ -n "$password" ]]; then
            local remaining_seconds=$((expiry_date - current_date))
            if [ $remaining_seconds -gt 0 ]; then
                local remaining_days=$((remaining_seconds / 86400))
                printf "%-20s │ %s days\n" "$password" "$remaining_days"
            else
                printf "%-20s │ Expired\n" "$password"
            fi
        fi
    done <"$db_file"
    echo "──────────────────────────────────────────"
}

# ----------------------------------------------------------------------------
# Menu untuk menampilkan daftar akun aktif
# ----------------------------------------------------------------------------
function list_accounts() {
    clear
    echo "──────────── Active Accounts ─────────────"
    _display_accounts
    echo "" # Add a newline for better spacing
    read -p "Press Enter to return to the menu..."
}

# ----------------------------------------------------------------------------
# Konversi KiB ke format yang mudah dibaca (MiB/GiB)
# Parameter: $1 = nilai dalam KiB
# ----------------------------------------------------------------------------
function format_kib_to_human() {
    local kib=$1
    if ! [[ "$kib" =~ ^[0-9]+$ ]] || [ -z "$kib" ]; then
        kib=0
    fi
    if [ "$kib" -lt 1048576 ]; then
        awk -v val="$kib" 'BEGIN { printf "%.2f MiB", val / 1024 }'
    else
        awk -v val="$kib" 'BEGIN { printf "%.2f GiB", val / 1048576 }'
    fi
}

# ----------------------------------------------------------------------------
# Mendapatkan interface jaringan utama
# ----------------------------------------------------------------------------
function get_main_interface() {
    ip -o -4 route show to default | awk '{print $5}' | head -n 1
}

# ============================================================================
# FUNGSI TAMPILAN MENU
# ============================================================================

# ----------------------------------------------------------------------------
# Menampilkan panel informasi sistem (OS, IP, ISP, bandwidth, dll)
# ----------------------------------------------------------------------------
function _draw_info_panel() {
    local os_info isp_info ip_info host_info bw_today bw_month client_name license_exp
    os_info=$( (hostnamectl 2>/dev/null | grep "Operating System" | cut -d: -f2 | sed 's/^[ \t]*//') || echo "N/A")
    os_info=${os_info:-"N/A"}
    local ip_data
    ip_data=$(curl -s ipinfo.io)
    ip_info=$(echo "$ip_data" | jq -r '.ip // "N/A"')
    isp_info=$(echo "$ip_data" | jq -r '.org // "N/A"' | sed 's/^AS[0-9]\+ //')
    ip_info=${ip_info:-"N/A"}
    isp_info=${isp_info:-"N/A"}
    local CERT_CN
    CERT_CN=$(openssl x509 -in /etc/zivpn/zivpn.crt -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p' 2>/dev/null || echo "")
    if [ "$CERT_CN" == "zivpn" ] || [ -z "$CERT_CN" ]; then
        host_info=$ip_info
    else
        host_info=$CERT_CN
    fi
    host_info=${host_info:-"N/A"}
    cpu_name=$(lscpu | grep "Model name" | cut -d: -f2 | sed 's/^[ \t]*//')
    cpu_cores=$(nproc)
    mem_total=$(free -h | awk '/Mem:/ {print $2}')
    mem_used=$(free -h | awk '/Mem:/ {print $3}')
    mem_percent=$(free | awk '/Mem:/ {printf "%.0f%%", $3/$2*100}')
    disk_total=$(df -h / | awk 'NR==2 {print $2}')
    disk_used=$(df -h / | awk 'NR==2 {print $3}')
    disk_avail=$(df -h / | awk 'NR==2 {print $4}')
    disk_percent=$(df -h / | awk 'NR==2 {print $5}')
    uptime_info=$(uptime -p)
    iface=$(ip route | grep default | awk '{print $5}')
    bw_today=$(vnstat -d | awk '/'"$(date +%Y-%m-%d)"'/ {print $5 " " $6}')
    bw_month=$(vnstat -m | awk '/'"$(date +%Y-%m)"'/ {print $5 " " $6}')
    if [ -f "$LICENSE_INFO_FILE" ]; then
        source "$LICENSE_INFO_FILE" # Loads CLIENT_NAME and EXPIRY_DATE
        client_name=${CLIENT_NAME:-"N/A"}
        if [ -n "$EXPIRY_DATE" ]; then
            local expiry_timestamp
            expiry_timestamp=$(date -d "$EXPIRY_DATE" +%s)
            local current_timestamp
            current_timestamp=$(date +%s)
            local remaining_seconds=$((expiry_timestamp - current_timestamp))
            if [ $remaining_seconds -gt 0 ]; then
                license_exp="$((remaining_seconds / 86400)) days"
            else
                license_exp="Expired"
            fi
        else
            license_exp="N/A"
        fi
    else
        client_name="N/A"
        license_exp="N/A"
    fi
    _save_total_users
    total_users=$(cat /etc/zivpn/total_users.txt)
    apikey=$(cat /etc/zivpn/api_auth.key)
    printf "  ${LIGHT_BLUE}%-8s${BOLD_WHITE}%-20s ${LIGHT_BLUE}%-7s${BOLD_WHITE}%-15s${NC}\n" "OS:" "$os_info" "ISP:" "$isp_info"
    printf "  ${LIGHT_BLUE}%-8s${BOLD_WHITE}%-20s ${LIGHT_BLUE}%-7s${BOLD_WHITE}%-15s${NC}\n" "IP:" "$ip_info" "Host:" "$host_info"
    printf "  ${LIGHT_BLUE}%-8s${BOLD_WHITE}%-20s ${LIGHT_BLUE}%-7s${BOLD_WHITE}%-15s${NC}\n" "Client:" "$client_name" "EXP:" "$license_exp"
    printf "  ${LIGHT_BLUE}%-8s${BOLD_WHITE}%-20s ${LIGHT_BLUE}%-7s${BOLD_WHITE}%-15s${NC}\n" "Today:" "$bw_today" "Month:" "$bw_month"
    printf "  ${LIGHT_BLUE}%-8s${BOLD_WHITE}%-20s ${LIGHT_BLUE}%-7s${BOLD_WHITE}%-15s${NC}\n" "RAM:" "$mem_used/$mem_total ($mem_percent)" "Disk:" "$disk_used/$disk_total ($disk_percent)"
    printf "  ${LIGHT_BLUE}%-8s${BOLD_WHITE}%-20s ${LIGHT_BLUE}%-7s${BOLD_WHITE}%-15s${NC}\n" "CPU:" "$cpu_name ($cpu_cores cores)" ""
    printf "  ${LIGHT_BLUE}%-8s${BOLD_WHITE}%-20s ${LIGHT_BLUE}%-7s${BOLD_WHITE}%-15s${NC}\n" "Uptime:" "$uptime_info" ""
    printf "  ${LIGHT_BLUE}%-8s${BOLD_WHITE}%-20s ${LIGHT_BLUE}%-7s${BOLD_WHITE}%-15s${NC}\n" "Users:" "$total_users" ""
    printf "  ${LIGHT_BLUE}%-8s${BOLD_WHITE}%-20s ${LIGHT_BLUE}%-7s${BOLD_WHITE}%-15s${NC}\n" "API Key:" "$apikey" ""
}

# ----------------------------------------------------------------------------
# Menampilkan status service ZIVPN dan ZIVPN API
# ----------------------------------------------------------------------------
function _draw_service_status() {
    local menu_width=55
    local services=("zivpn.service" "zivpn-api.service")
    local names=("ZiVPN" "ZiVPN API")
    local status_text status_color status_output text_len_visible padding_total padding_left padding_right
    echo -e "${YELLOW}├────────────────────────────────────────────────────┤${NC}"
    for i in "${!services[@]}"; do
        local service_status
        service_status=$(systemctl is-active "${services[$i]}" 2>/dev/null || echo "unknown")
        case "$service_status" in
            active)
                status_text="Running"
                status_color="${LIGHT_GREEN}"
                ;;
            inactive)
                status_text="Stopped"
                status_color="${RED}"
                ;;
            failed)
                status_text="Error"
                status_color="${RED}"
                ;;
            activating)
                status_text="Starting..."
                status_color="${YELLOW}"
                ;;
            deactivating)
                status_text="Stopping..."
                status_color="${YELLOW}"
                ;;
            *)
                status_text="Unknown"
                status_color="${RED}"
                ;;
        esac
        status_output="${CYAN}${names[$i]}: ${status_color}${status_text}${NC}"
        text_len_visible=$(echo -e "$status_output" | sed 's/\x1b\[[0-9;]*m//g' | wc -c)
        text_len_visible=$((text_len_visible - 1))
        padding_total=$((menu_width - text_len_visible))
        padding_left=$((padding_total / 2))
        padding_right=$((padding_total - padding_left))
        echo -e "$(printf '%*s' $padding_left)${status_output}$(printf '%*s' $padding_right)"
    done
    echo -e "${YELLOW}├────────────────────────────────────────────────────┤${NC}"
}

# ============================================================================
# FUNGSI BACKUP & RESTORE
# ============================================================================

# ----------------------------------------------------------------------------
# Mengatur jadwal auto backup dengan cron
# ----------------------------------------------------------------------------
function setup_auto_backup() {
    echo "─── Configure Auto Backup ───"
    if [ ! -f "/etc/zivpn/telegram.conf" ]; then
        echo "Telegram is not configured. Please run a manual backup once to set it up."
        return
    fi
    read -p "Enter backup interval in hours (e.g., 6, 12, 24). Enter 0 to disable: " interval
    if ! [[ "$interval" =~ ^[0-9]+$ ]]; then
        echo "Invalid input. Please enter a number."
        return
    fi
    (crontab -l 2>/dev/null | grep -v "# zivpn-auto-backup") | crontab -
    if [ "$interval" -gt 0 ]; then
        local cron_schedule="0 */${interval} * * *"
        (
            crontab -l 2>/dev/null
            echo "${cron_schedule} /usr/local/bin/zivpn_helper.sh backup >/dev/null 2>&1 # zivpn-auto-backup"
        ) | crontab -
        echo "Auto backup scheduled to run every ${interval} hour(s)."
    else
        echo "Auto backup has been disabled."
    fi
}

# ============================================================================
# FUNGSI MENU UTAMA
# ============================================================================

# ----------------------------------------------------------------------------
# Menu untuk membuat akun (pilih manual atau trial)
# ----------------------------------------------------------------------------
function create_account() {
    clear
    echo -e "${YELLOW}┌────────────────// ${RED}Create Account${YELLOW} //────────────────┐${NC}"
    echo -e "${YELLOW}│                                                    │${NC}"
    echo -e "${YELLOW}│   ${LIGHT_BLUE}1)${NC} ${BOLD_WHITE}Create Zivpn                                  ${YELLOW}│${NC}"
    echo -e "${YELLOW}│   ${LIGHT_BLUE}2)${NC} ${BOLD_WHITE}Trial Zivpn                                   ${YELLOW}│${NC}"
    echo -e "${YELLOW}│   ${LIGHT_BLUE}0)${NC} ${BOLD_WHITE}Back to Main Menu                             ${YELLOW}│${NC}"
    echo -e "${YELLOW}│                                                    │${NC}"
    echo -e "${YELLOW}└────────────────────────────────────────────────────┘${NC}"
    read -p "Enter your choice [0-2]: " choice
    case $choice in
        1) create_manual_account ;;
        2) create_trial_account ;;
        0) return ;;
        *) echo "Invalid option." ;;
    esac
}

# ----------------------------------------------------------------------------
# Menu backup dan restore data
# ----------------------------------------------------------------------------
function show_backup_menu() {
    clear
    echo -e "${YELLOW}┌───────────────// ${LIGHT_BLUE}Backup/Restore${YELLOW} //───────────────┐${NC}"
    echo -e "${YELLOW}│                                                  │${NC}"
    echo -e "${YELLOW}│   ${LIGHT_BLUE}1)${NC} ${BOLD_WHITE}Backup Data                                 ${YELLOW}│${NC}"
    echo -e "${YELLOW}│   ${LIGHT_BLUE}2)${NC} ${BOLD_WHITE}Restore Data                                ${YELLOW}│${NC}"
    echo -e "${YELLOW}│   ${LIGHT_BLUE}3)${NC} ${BOLD_WHITE}Auto Backup                                 ${YELLOW}│${NC}"
    echo -e "${YELLOW}│   ${LIGHT_BLUE}4)${NC} ${BOLD_WHITE}Atur Ulang Notifikasi Telegram              ${YELLOW}│${NC}"
    echo -e "${YELLOW}│   ${LIGHT_BLUE}0)${NC} ${BOLD_WHITE}Back to Main Menu                           ${YELLOW}│${NC}"
    echo -e "${YELLOW}│                                                  │${NC}"
    echo -e "${YELLOW}└──────────────────────────────────────────────────┘${NC}"
    read -p "Enter your choice [0-4]: " choice
    case $choice in
        1) /usr/local/bin/zivpn_helper.sh backup ;;
        2) /usr/local/bin/zivpn_helper.sh restore ;;
        3) setup_auto_backup ;;
        4) /usr/local/bin/zivpn_helper.sh setup-telegram ;;
        0) return ;;
        *) echo "Invalid option." ;;
    esac
}

# ----------------------------------------------------------------------------
# Menampilkan pesan lisensi kedaluwarsa dan keluar dari script
# ----------------------------------------------------------------------------
function show_expired_message_and_exit() {
    clear
    echo -e "\n${RED}─────────────────────────────────────────────────────${NC}"
    echo -e "${RED}           LISENSI ANDA TELAH KEDALUWARSA!           ${NC}"
    echo -e "${RED}─────────────────────────────────────────────────────${NC}\n"
    echo -e "${BOLD_WHITE}Akses ke layanan ZIVPN di server anda telah dihentikan."
    echo -e "Segala aktivitas VPN tidak akan berfungsi lagi.\n"
    echo -e "Untuk memperpanjang lisensi dan mengaktifkan kembali layanan,"
    echo -e "silakan hubungi admin https://wa.me/ \n"
    echo -e "${LIGHT_GREEN}Setelah diperpanjang, layanan akan aktif kembali secara otomatis.${NC}\n"
    exit 0
}

# ----------------------------------------------------------------------------
# Menampilkan menu utama dengan panel info dan pilihan menu
# ----------------------------------------------------------------------------
function show_menu() {
    if [ -f "/etc/zivpn/.expired" ]; then
        show_expired_message_and_exit
    fi
    clear
    figlet "UDP ZIVPN" | lolcat
    echo -e "${YELLOW}┌───────────// ${CYAN}NAYTRA DIGITAL NETWORK${YELLOW} //─────────────┐${NC}"
    _draw_info_panel
    _draw_service_status
    echo -e "${YELLOW}│                                                    │${NC}"
    echo -e "${YELLOW}│   ${LIGHT_BLUE}1)${NC} ${BOLD_WHITE}Create Account                                ${YELLOW}│${NC}"
    echo -e "${YELLOW}│   ${LIGHT_BLUE}2)${NC} ${BOLD_WHITE}Renew Account                                 ${YELLOW}│${NC}"
    echo -e "${YELLOW}│   ${LIGHT_BLUE}3)${NC} ${BOLD_WHITE}Delete Account                                ${YELLOW}│${NC}"
    echo -e "${YELLOW}│   ${LIGHT_BLUE}4)${NC} ${BOLD_WHITE}Change Domain                                 ${YELLOW}│${NC}"
    echo -e "${YELLOW}│   ${LIGHT_BLUE}5)${NC} ${BOLD_WHITE}List Accounts                                 ${YELLOW}│${NC}"
    echo -e "${YELLOW}│   ${LIGHT_BLUE}6)${NC} ${BOLD_WHITE}Backup/Restore                                ${YELLOW}│${NC}"
    echo -e "${YELLOW}│   ${LIGHT_BLUE}7)${NC} ${BOLD_WHITE}Generate API Auth Key                         ${YELLOW}│${NC}"
    echo -e "${YELLOW}│   ${LIGHT_BLUE}8)${NC} ${BOLD_WHITE}Restart Service                               ${YELLOW}│${NC}"
    echo -e "${YELLOW}│   ${LIGHT_BLUE}0)${NC} ${BOLD_WHITE}Exit                                          ${YELLOW}│${NC}"
    echo -e "${YELLOW}│                                                    │${NC}"
    echo -e "${YELLOW}└────────────────────────────────────────────────────┘${NC}"
    read -p "Enter your choice [0-7]: " choice
    case $choice in
        1) create_account ;;
        2) renew_account ;;
        3) delete_account ;;
        4) change_domain ;;
        5) list_accounts ;;
        6) show_backup_menu ;;
        7) _generate_api_key ;;
        8) systemctl restart zivpn ;;
        0) exit 0 ;;
        *) echo "Invalid option. Please try again." ;;
    esac
}

# ============================================================================
# FUNGSI INSTALASI DAN SETUP
# ============================================================================

# ----------------------------------------------------------------------------
# Menjalankan proses instalasi lengkap ZIVPN
# Termasuk: verifikasi lisensi, install dependensi, setup service,
# konfigurasi cron job, dan setup REST API
# ----------------------------------------------------------------------------
function run_setup() {
    # Verifikasi lisensi sebelum melanjutkan instalasi
    verify_license

    # ---- TAHAP 1: INSTALASI DEPENDENSI DASAR ----
    export DEBIAN_FRONTEND=noninteractive
    apt --fix-broken install -y
    apt update -y
    apt install sudo -y
    apt install screen ufw ruby figlet lolcat curl wget python3-pip -y
    sudo gem install lolcat

    # ---- TAHAP 2: KONFIGURASI IPTABLES ----
    # Hapus rule lama jika ada
    sudo iptables -t nat -D PREROUTING -i eth0 -p udp --dport 1:21 -j DNAT --to-destination :36712
    sudo iptables -t nat -D PREROUTING -i eth0 -p udp --dport 23:52 -j DNAT --to-destination :36712
    # Tambah rule baru untuk redirect port UDP
    sudo iptables -t nat -I PREROUTING 1 -i eth0 -p udp --dport 6000:19999 -j DNAT --to-destination :5667
    # Simpan konfigurasi iptables secara persistent
    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
    sudo apt install iptables-persistent -y
    apt install -y iptables-persistent netfilter-persistent
    sudo netfilter-persistent save
    # ---- TAHAP 3: UPDATE OS DAN INSTALASI ZIVPN ----
    echo "1. Update OS dan install dependensi..."
    apt upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
    apt install -y wget curl ca-certificates
    update-ca-certificates

    echo "2. Hentikan service lama (jika ada)..."
    systemctl stop zivpn 2>/dev/null

    echo "3. Hapus binary lama (jika ada)..."
    rm -f /usr/local/bin/zivpn

    echo "4. Download skrip resmi ZiVPN..."
    wget -O /root/zi.sh https://raw.githubusercontent.com/soakstore/udp-zivpn/main/zi.sh

    echo "5. Beri izin executable..."
    chmod +x /root/zi.sh

    echo "6. Jalankan skrip instalasi ZiVPN..."
    sudo /root/zi.sh

    echo "7. Reload systemd dan start service..."
    systemctl daemon-reload
    systemctl start zivpn
    systemctl enable zivpn

    echo "8. Cek status service..."
    systemctl status zivpn --no-pager
    echo "✅ Instalasi selesai. Service ZiVPN harusnya aktif dan panel bisa mendeteksi."

    # ---- TAHAP 4: SETUP ADVANCED MANAGEMENT ----
    echo "─── Setting up Advanced Management ───"
    export DEBIAN_FRONTEND=noninteractive
    # Daftar dependensi yang dibutuhkan
    dependencies=(jq curl zip figlet lolcat vnstat)
    need_update=false
    for pkg in "${dependencies[@]}"; do
        if ! command -v "$pkg" &>/dev/null; then
            echo "Installing $pkg..."
            need_update=true
            missing_packages+=("$pkg")
        else
            echo "$pkg is already installed."
        fi
    done
    if [ "$need_update" = true ]; then
        apt-get update -y
        apt-get install -y "${missing_packages[@]}"
    fi
    echo "All dependencies are installed and up to date."

    # ---- TAHAP 5: KONFIGURASI VNSTAT UNTUK MONITORING BANDWIDTH ----
    vnstat --json
    echo "Configuring vnstat for bandwidth monitoring..."
    local net_interface
    net_interface=$(ip -o -4 route show to default | awk '{print $5}' | head -n 1)
    if [ -n "$net_interface" ]; then
        echo "Detected network interface: $net_interface"
        sleep 2
        systemctl stop vnstat
        vnstat -u -i "$net_interface" --force
        systemctl enable vnstat
        systemctl start vnstat
        echo "vnstat setup complete for interface $net_interface."
    else
        echo "Warning: Could not automatically detect network interface for vnstat."
    fi

    # ---- TAHAP 6: DOWNLOAD DAN SETUP HELPER SCRIPT ----
    echo "Downloading helper script..."
    wget -O /usr/local/bin/zivpn_helper.sh https://raw.githubusercontent.com/soakstore/udp-zivpn/main/zivpn_helper.sh
    if [ $? -ne 0 ]; then
        echo "Failed to download helper script. Aborting."
        exit 1
    fi
    chmod +x /usr/local/bin/zivpn_helper.sh

    # ---- TAHAP 7: INISIALISASI DATABASE USER ----
    echo "Clearing initial password(s) set during base installation..."
    jq '.auth.config = []' /etc/zivpn/config.json >/etc/zivpn/config.json.tmp && mv /etc/zivpn/config.json.tmp /etc/zivpn/config.json
    touch /etc/zivpn/users.db
    RANDOM_PASS="zivpn$(shuf -i 10000-99999 -n 1)"
    EXPIRY_DATE=$(date -d "+1 day" +%s)
    echo "Creating a temporary initial account..."
    echo "${RANDOM_PASS}:${EXPIRY_DATE}" >>/etc/zivpn/users.db
    jq --arg pass "$RANDOM_PASS" '.auth.config += [$pass]' /etc/zivpn/config.json >/etc/zivpn/config.json.tmp && mv /etc/zivpn/config.json.tmp /etc/zivpn/config.json

    # ---- TAHAP 8: SETUP CRON JOB UNTUK CEK EXPIRED ACCOUNT ----
    echo "Setting up expiry check cron job..."
    cat <<'EOF' >/etc/zivpn/expire_check.sh
DB_FILE="/etc/zivpn/users.db"
CONFIG_FILE="/etc/zivpn/config.json"
TMP_DB_FILE="${DB_FILE}.tmp"
CURRENT_DATE=$(date +%s)
SERVICE_RESTART_NEEDED=false
if [ ! -f "$DB_FILE" ]; then exit 0; fi
> "$TMP_DB_FILE"
while IFS=':' read -r password expiry_date; do
if [[ -z "$password" ]]; then continue; fi
if [ "$expiry_date" -le "$CURRENT_DATE" ]; then
echo "User '${password}' has expired. Deleting permanently."
jq --arg pass "$password" 'del(.auth.config[] | select(. == $pass))' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
SERVICE_RESTART_NEEDED=true
else
echo "${password}:${expiry_date}" >> "$TMP_DB_FILE"
fi
done < "$DB_FILE"
mv "$TMP_DB_FILE" "$DB_FILE"
if [ "$SERVICE_RESTART_NEEDED" = true ]; then
echo "Restarting zivpn service due to user removal."
systemctl restart zivpn.service
fi
exit 0
EOF
    chmod +x /etc/zivpn/expire_check.sh
    # Daftarkan cron job untuk cek expired setiap menit
    CRON_JOB_EXPIRY="* * * * * /etc/zivpn/expire_check.sh # zivpn-expiry-check"
    (crontab -l 2>/dev/null | grep -v "# zivpn-expiry-check") | crontab -
    (
        crontab -l 2>/dev/null
        echo "$CRON_JOB_EXPIRY"
    ) | crontab -

    # ---- TAHAP 9: SETUP CRON JOB UNTUK CEK LISENSI ----
    echo "Setting up license check script and cron job..."
    cat <<'EOF' >/etc/zivpn/license_checker.sh
LICENSE_URL="https://raw.githubusercontent.com/soakstore/izin/main/ip"
LICENSE_INFO_FILE="/etc/zivpn/.license_info"
EXPIRED_LOCK_FILE="/etc/zivpn/.expired"
TELEGRAM_CONF="/etc/zivpn/telegram.conf"
LOG_FILE="/var/log/zivpn_license.log"
log() {
echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}
function get_host() {
local CERT_CN
CERT_CN=$(openssl x509 -in /etc/zivpn/zivpn.crt -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p' 2>/dev/null || echo "")
if [ "$CERT_CN" == "zivpn" ] || [ -z "$CERT_CN" ]; then
curl -4 -s ifconfig.me || curl -6 -s ifconfig.me
else
echo "$CERT_CN"
fi
}
function get_isp() {
curl -s ipinfo.io | jq -r '.org // "N/A"' | sed 's/^AS[0-9]\+ //'
}
send_telegram_message() {
local message="$1"
if [ ! -f "$TELEGRAM_CONF" ]; then
log "Telegram config not found, skipping notification."
return
fi
source "$TELEGRAM_CONF"
if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
local api_url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
curl -s -X POST "$api_url" -d "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=${message}" -d "parse_mode=Markdown" > /dev/null
log "Simple telegram notification sent."
else
log "Telegram config found but token or chat ID is missing."
fi
}
log "Starting license check..."
SERVER_IP=$(curl -4 -s ifconfig.me || curl -6 -s ifconfig.me)
if [ -z "$SERVER_IP" ]; then
log "Error: Failed to retrieve server IP. Exiting."
exit 1
fi
if [ ! -f "$LICENSE_INFO_FILE" ]; then
log "Error: Local license info file not found. Exiting."
exit 1
fi
source "$LICENSE_INFO_FILE" # This loads CLIENT_NAME and EXPIRY_DATE
license_data=$(curl -s "$LICENSE_URL")
if [ $? -ne 0 ] || [ -z "$license_data" ]; then
log "Error: Failed to connect to license server. Exiting."
exit 1
fi
license_entry=$(echo "$license_data" | grep -w "$SERVER_IP")
if [ -z "$license_entry" ]; then
if [ ! -f "$EXPIRED_LOCK_FILE" ]; then
log "License for IP ${SERVER_IP} has been REVOKED."
systemctl stop zivpn.service
touch "$EXPIRED_LOCK_FILE"
local MSG="Notifikasi Otomatis: Lisensi untuk Klien \`${CLIENT_NAME}\` dengan IP \`${SERVER_IP}\` telah dicabut (REVOKED). Layanan zivpn telah dihentikan."
send_telegram_message "$MSG"
fi
exit 0
fi
client_name_remote=$(echo "$license_entry" | awk '{print $1}')
expiry_date_remote=$(echo "$license_entry" | awk '{print $2}')
expiry_timestamp_remote=$(date -d "$expiry_date_remote" +%s)
current_timestamp=$(date +%s)
if [ "$expiry_date_remote" != "$EXPIRY_DATE" ]; then
log "Remote license has a different expiry date (${expiry_date_remote}). Updating local file."
echo "CLIENT_NAME=${client_name_remote}" > "$LICENSE_INFO_FILE"
echo "EXPIRY_DATE=${expiry_date_remote}" >> "$LICENSE_INFO_FILE"
CLIENT_NAME=$client_name_remote
EXPIRY_DATE=$expiry_date_remote
fi
if [ "$expiry_timestamp_remote" -le "$current_timestamp" ]; then
if [ ! -f "$EXPIRED_LOCK_FILE" ]; then
log "License for IP ${SERVER_IP} has EXPIRED."
systemctl stop zivpn.service
touch "$EXPIRED_LOCK_FILE"
local host
host=$(get_host)
local isp
isp=$(get_isp)
log "Sending rich expiry notification via helper script..."
/usr/local/bin/zivpn_helper.sh expiry-notification "$host" "$SERVER_IP" "$CLIENT_NAME" "$isp" "$EXPIRY_DATE"
fi
else
if [ -f "$EXPIRED_LOCK_FILE" ]; then
log "License for IP ${SERVER_IP} has been RENEWED/ACTIVATED."
rm "$EXPIRED_LOCK_FILE"
systemctl start zivpn.service
local host
host=$(get_host)
local isp
isp=$(get_isp)
log "Sending rich renewed notification via helper script..."
/usr/local/bin/zivpn_helper.sh renewed-notification "$host" "$SERVER_IP" "$CLIENT_NAME" "$isp" "$expiry_timestamp_remote"
else
log "License is active and valid. No action needed."
fi
fi
log "License check finished."
exit 0
EOF
    chmod +x /etc/zivpn/license_checker.sh
    # Daftarkan cron job untuk cek lisensi setiap 5 menit
    CRON_JOB_LICENSE="*/5 * * * * /etc/zivpn/license_checker.sh # zivpn-license-check"
    (crontab -l 2>/dev/null | grep -v "# zivpn-license-check") | crontab -
    (
        crontab -l 2>/dev/null
        echo "$CRON_JOB_LICENSE"
    ) | crontab -

    # ---- TAHAP 10: SETUP NOTIFIKASI TELEGRAM (OPSIONAL) ----
    if [ ! -f "/etc/zivpn/telegram.conf" ]; then
        echo ""
        read -p "Apakah Anda ingin mengatur notifikasi Telegram untuk status lisensi? (y/n): " confirm
        if [[ "$confirm" == [yY] || "$confirm" == [yY][eE][sS] ]]; then
            /usr/local/bin/zivpn_helper.sh setup-telegram
        else
            echo "Anda dapat mengaturnya nanti melalui menu Backup/Restore."
        fi
    fi
    restart_zivpn

    # ---- TAHAP 11: SETUP REST API SERVICE ----
    echo "─── Setting up REST API Service ───"
    if ! command -v node &>/dev/null; then
        echo "Node.js not found. Installing Node.js v18..."
        curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
        sudo apt-get install -y nodejs
    else
        echo "Node.js is already installed."
    fi

    # Buat direktori dan file konfigurasi API
    mkdir -p /etc/zivpn/api
    cat <<'EOF' >/etc/zivpn/api/package.json
{
"name": "zivpn-api",
"version": "1.0.0",
"description": "API for managing ZIVPN",
"main": "api.js",
"scripts": { "start": "node api.js" },
"dependencies": { "express": "^4.17.1" }
}
EOF
    cat <<'EOF' >/etc/zivpn/api/api.js
const express = require('express');
const { execFile } = require('child_process');
const fs = require('fs');
const app = express();
const PORT = 5888;
const AUTH_KEY_PATH = '/etc/zivpn/api_auth.key';
const ZIVPN_MANAGER_SCRIPT = '/usr/local/bin/zivpn-manager';
const authenticate = (req, res, next) => {
const providedAuthKey = req.query.auth;
if (!providedAuthKey) return res.status(401).json({ status: 'error', message: 'Authentication key is required.' });
fs.readFile(AUTH_KEY_PATH, 'utf8', (err, storedKey) => {
if (err) return res.status(500).json({ status: 'error', message: 'Could not read authentication key.' });
if (providedAuthKey.trim() !== storedKey.trim()) return res.status(403).json({ status: 'error', message: 'Invalid authentication key.' });
next();
});
};
app.use(authenticate);
const executeZivpnManager = (command, args, res) => {
execFile('sudo', [ZIVPN_MANAGER_SCRIPT, command, ...args], (error, stdout, stderr) => {
if (error) {
const errorMessage = stderr.includes('Error:') ? stderr : 'An internal server error occurred.';
return res.status(500).json({ status: 'error', message: errorMessage.trim() });
}
if (stdout.toLowerCase().includes('success')) {
res.json({ status: 'success', message: stdout.trim() });
} else {
res.status(400).json({ status: 'error', message: stdout.trim() });
}
});
};
app.all('/create/zivpn', (req, res) => {
const { password, exp } = req.query;
if (!password || !exp) return res.status(400).json({ status: 'error', message: 'Parameters password and exp are required.' });
executeZivpnManager('create_account', [password, exp], res);
});
app.all('/delete/zivpn', (req, res) => {
const { password } = req.query;
if (!password) return res.status(400).json({ status: 'error', message: 'Parameter password is required.' });
executeZivpnManager('delete_account', [password], res);
});
app.all('/renew/zivpn', (req, res) => {
const { password, exp } = req.query;
if (!password || !exp) return res.status(400).json({ status: 'error', message: 'Parameters password and exp are required.' });
executeZivpnManager('renew_account', [password, exp], res);
});
app.all('/trial/zivpn', (req, res) => {
const { exp } = req.query;
if (!exp) return res.status(400).json({ status: 'error', message: 'Parameter exp is required.' });
executeZivpnManager('trial_account', [exp], res);
});
app.listen(PORT, () => console.log('ZIVPN API server running on port ' + PORT));
EOF

    # Install dependensi API
    echo "Installing API dependencies..."
    npm install --prefix /etc/zivpn/api

    # Buat systemd service untuk API
    cat <<'EOF' >/etc/systemd/system/zivpn-api.service
[Unit]
Description=ZIVPN REST API Service
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=/etc/zivpn/api
ExecStart=/usr/bin/node /etc/zivpn/api/api.js
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

    # Aktifkan dan jalankan service API
    systemctl daemon-reload
    systemctl enable zivpn-api.service
    systemctl start zivpn-api.service

    # Generate API key jika belum ada
    if [ ! -f /etc/zivpn/api_auth.key ]; then
        echo "🔑 API Key belum tersedia."
        echo "Generating initial API key..."
        local initial_api_key
        initial_api_key=$(LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 6)
        echo "$initial_api_key" >/etc/zivpn/api_auth.key
        chmod 600 /etc/zivpn/api_auth.key
        echo "✔ API Key berhasil disimpan!"
    fi

    # Buka port firewall untuk API
    echo "Opening firewall port 5888 for API..."
    iptables -I INPUT -p tcp --dport 5888 -j ACCEPT
    echo "─── API Setup Complete ───"

    # ---- TAHAP 12: INTEGRASI MANAGEMENT SCRIPT KE SISTEM ----
    echo "─── Integrating management script into the system ───"
    # Copy script ke /usr/local/bin untuk akses global
    cp "$0" /usr/local/bin/zivpn-manager
    chmod +x /usr/local/bin/zivpn-manager

    # Pilih mode menu VPS
    if [ -f "/usr/local/bin/zivpn-manager" ]; then
        echo ""
        echo "┌──────────────────────────────────────┐"
        echo "│   PILIH MODE MENU VPS                │"
        echo "│--------------------------------------│"
        echo "│   1. Dual SC (Mode gabungan)         │"
        echo "│   2. ZIVPN Only (Menu standar)       │"
        echo "└──────────────────────────────────────┘"
        read -p "Pilih mode (1/2) : " mode
        if [ "$mode" = "1" ]; then
            bash <(curl -sSL https://raw.githubusercontent.com/arivpnstores/costum/main/.bashrc)
            echo "Mode: Dual SC aktif"
        elif [ "$mode" = "2" ]; then
            rm -rf /root/.profile
            cat <<EOF >/root/.profile
if [ "$BASH" ]; then
if [ -f ~/.bashrc ]; then
. ~/.bashrc
fi
fi
mesg n || true
ln -fs /usr/share/zoneinfo/Asia/Jakarta /etc/localtime
$WEB_SERVER
menu
EOF
            PROFILE_FILE="/root/.bashrc"
            [ -f "/root/.bash_profile" ] && PROFILE_FILE="/root/.bash_profile"
            ALIAS_CMD="alias menu='/usr/local/bin/zivpn-manager'"
            AUTORUN_CMD="/usr/local/bin/zivpn-manager"
            grep -qF "$ALIAS_CMD" "$PROFILE_FILE" || echo "$ALIAS_CMD" >>"$PROFILE_FILE"
            grep -qF "$AUTORUN_CMD" "$PROFILE_FILE" || echo "$AUTORUN_CMD" >>"$PROFILE_FILE"
            echo "The 'menu' command is now available."
            echo "The management menu will now open automatically on login."
            echo "Mode: ZIVPN Only aktif"
        else
            echo "Pilihan tidak valid, menu default tidak diaktifkan."
        fi
        echo "────────────────────────────────────────────────────"
        echo "Advanced management setup complete."
        echo "────────────────────────────────────────────────────"
    else
        echo "File /usr/local/bin/zivpn-manager tidak ditemukan."
        echo "Menu tidak dapat diaktifkan otomatis."
    fi
    show_menu
}

# ============================================================================
# FUNGSI UTAMA (ENTRY POINT)
# ============================================================================

# ----------------------------------------------------------------------------
# Fungsi main - entry point script
# Menangani mode CLI dan mode interaktif
# Mode CLI: create_account, delete_account, renew_account, trial_account
# Mode Interaktif: menampilkan menu utama
# ----------------------------------------------------------------------------
function main() {
    # Cek apakah ada argumen command line (mode CLI)
    if [ "$#" -gt 0 ]; then
        local command="$1"
        shift
        case "$command" in
            create_account)
                _create_account_logic "$@"
                ;;
            delete_account)
                _delete_account_logic "$@"
                ;;
            renew_account)
                _renew_account_logic "$@"
                ;;
            trial_account)
                _create_trial_account_logic "$@"
                ;;
            *)
                echo "Error: Unknown command '$command'"
                exit 1
                ;;
        esac
        exit $?
    fi

    # Jika ZIVPN belum terinstall, jalankan setup
    if [ ! -f "/etc/systemd/system/zivpn.service" ]; then
        run_setup
    fi

    # Loop menu utama (mode interaktif)
    while true; do
        show_menu
    done
}

# ----------------------------------------------------------------------------
# Eksekusi script hanya jika dijalankan langsung (bukan di-source)
# ----------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
