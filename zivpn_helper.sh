#!/bin/bash

# ============================================================================
# ZIVPN HELPER SCRIPT
# ============================================================================
# Script helper untuk fungsi-fungsi pendukung ZIVPN:
# - Backup & Restore data ke GitHub
# - Notifikasi Telegram (expiry, renew, API key)
# - Setup konfigurasi Telegram
# ============================================================================

# ============================================================================
# SECTION 1: KONFIGURASI PATH
# ============================================================================
CONFIG_DIR="/etc/zivpn"
TELEGRAM_CONF="${CONFIG_DIR}/telegram.conf"

# ============================================================================
# SECTION 2: FUNGSI GET HOST
# ============================================================================
# Mendapatkan hostname dari SSL certificate atau IP publik
function get_host() {
    local CERT_CN
    CERT_CN=$(openssl x509 -in "${CONFIG_DIR}/zivpn.crt" -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p')
    
    if [ "$CERT_CN" == "zivpn" ]; then
        # Jika CN default, gunakan IP publik
        curl -4 -s ifconfig.me
    else
        # Jika CN custom domain, gunakan domain tersebut
        echo "$CERT_CN"
    fi
}

# ============================================================================
# SECTION 3: FUNGSI NOTIFIKASI TELEGRAM
# ============================================================================
# Mengirim pesan ke Telegram
# Parameter:
#   $1 = message (pesan yang akan dikirim)
#   $2 = keyboard (optional, inline keyboard JSON)
function send_telegram_notification() {
    local message="$1"
    local keyboard="$2"
    
    # Cek apakah file konfigurasi ada
    if [ ! -f "$TELEGRAM_CONF" ]; then
        return 1
    fi
    
    source "$TELEGRAM_CONF"
    
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        local api_url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
        
        if [ -n "$keyboard" ]; then
            # Kirim dengan inline keyboard
            curl -s -X POST "$api_url" \
                -d "chat_id=${TELEGRAM_CHAT_ID}" \
                --data-urlencode "text=${message}" \
                -d "reply_markup=${keyboard}" > /dev/null
        else
            # Kirim dengan Markdown parsing
            curl -s -X POST "$api_url" \
                -d "chat_id=${TELEGRAM_CHAT_ID}" \
                --data-urlencode "text=${message}" \
                -d "parse_mode=Markdown" > /dev/null
        fi
    fi
}

# ============================================================================
# SECTION 4: FUNGSI SETUP TELEGRAM
# ============================================================================
# Konfigurasi bot token dan chat ID untuk notifikasi
function setup_telegram() {
    echo "--- Konfigurasi Notifikasi Telegram ---"
    
    read -p "Masukkan Bot API Key Anda: " api_key
    read -p "Masukkan ID Chat Telegram Anda (dapatkan dari @userinfobot): " chat_id
    
    # Validasi input
    if [ -z "$api_key" ] || [ -z "$chat_id" ]; then
        echo "API Key dan ID Chat tidak boleh kosong. Pengaturan dibatalkan."
        return 1
    fi
    
    # Simpan konfigurasi
    echo "TELEGRAM_BOT_TOKEN=${api_key}" > "$TELEGRAM_CONF"
    echo "TELEGRAM_CHAT_ID=${chat_id}" >> "$TELEGRAM_CONF"
    chmod 600 "$TELEGRAM_CONF"
    
    echo "Konfigurasi berhasil disimpan di $TELEGRAM_CONF"
    return 0
}

# ============================================================================
# SECTION 5: FUNGSI BACKUP KE TELEGRAM
# ============================================================================
# Backup file konfigurasi ZIVPN dan kirim langsung ke Telegram
function handle_backup() {
    echo "--- Memulai Proses Backup ---"
    
    # Cek konfigurasi Telegram
    if [ ! -f "$TELEGRAM_CONF" ]; then
        echo "❌ Konfigurasi Telegram belum diatur!"
        echo "Silakan jalankan: zivpn_helper.sh setup-telegram"
        read -p "Tekan [Enter] untuk kembali ke menu..." && /usr/local/bin/zivpn-manager
        return 1
    fi
    
    source "$TELEGRAM_CONF"
    
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        echo "❌ Bot Token atau Chat ID tidak valid!"
        read -p "Tekan [Enter] untuk kembali ke menu..." && /usr/local/bin/zivpn-manager
        return 1
    fi
    
    # Info VPS
    VPS_IP=$(curl -4 -s ifconfig.me || curl -6 -s ifconfig.me)
    backup_filename="zivpn_backup_${VPS_IP}_$(date +%Y%m%d-%H%M%S).zip"
    temp_backup_path="/tmp/${backup_filename}"
    
    # Password backup
    backup_password="Naytra123Done"
    
    # Daftar file yang akan di-backup
    files_to_backup=(
        "$CONFIG_DIR/config.json"
        "$CONFIG_DIR/users.db"
        "$CONFIG_DIR/api_auth.key"
        "$CONFIG_DIR/telegram.conf"
        "$CONFIG_DIR/total_users.txt"
        "$CONFIG_DIR/zivpn.crt"
        "$CONFIG_DIR/zivpn.key"
    )
    
    # Buat file ZIP dengan password random
    echo "Membuat backup ZIP..."
    zip -j -P "${backup_password}" "$temp_backup_path" "${files_to_backup[@]}" >/dev/null 2>&1
    
    if [ $? -ne 0 ]; then
        echo "❌ Gagal membuat file backup!" | tee -a /var/log/zivpn_backup.log
        read -p "Tekan [Enter] untuk kembali ke menu..." && /usr/local/bin/zivpn-manager
        return 1
    fi
    
    # Kirim file ZIP langsung ke Telegram
    echo "Mengirim backup ke Telegram..."
    
    caption="⚠️ *Backup ZIVPN* ⚠️
━━━━━━━━━━━━━━━━━━
📍 *VPS IP:* \`${VPS_IP}\`
📅 *Tanggal:* $(date +"%d %B %Y")
⏰ *Waktu:* $(date +"%H:%M:%S")
📁 *File:* \`${backup_filename}\`
🔐 *Password:* \`${backup_password}\`
━━━━━━━━━━━━━━━━━━"
    
    telegram_response=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
        -F chat_id="${TELEGRAM_CHAT_ID}" \
        -F document=@"${temp_backup_path}" \
        -F caption="${caption}" \
        -F parse_mode="Markdown")
    
    # Cek hasil kirim
    if echo "$telegram_response" | grep -q '"ok":true'; then
        echo "✔️ Backup berhasil dikirim ke Telegram!" | tee -a /var/log/zivpn_backup.log
    else
        echo "❌ Gagal mengirim backup ke Telegram!" | tee -a /var/log/zivpn_backup.log
        echo "Response: $telegram_response"
        rm -f "$temp_backup_path"
        read -p "Tekan [Enter] untuk kembali ke menu..." && /usr/local/bin/zivpn-manager
        return 1
    fi
    
    # Cleanup
    rm -f "$temp_backup_path"
    
    clear
    echo "✔️ Backup ZIVPN Berhasil!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "VPS IP    : ${VPS_IP}"
    echo "Tanggal   : $(date +"%d %B %Y %H:%M:%S")"
    echo "File      : ${backup_filename}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "File backup sudah dikirim ke Telegram Anda."
    
    read -p "Tekan [Enter] untuk kembali ke menu..." && /usr/local/bin/zivpn-manager
}

# ============================================================================
# SECTION 6: FUNGSI NOTIFIKASI EXPIRY
# ============================================================================
# Kirim notifikasi ketika lisensi expired
# Parameter:
#   $1 = host
#   $2 = ip
#   $3 = client
#   $4 = isp
#   $5 = exp_date
function handle_expiry_notification() {
    local host="$1"
    local ip="$2"
    local client="$3"
    local isp="$4"
    local exp_date="$5"
    
    local message
    message=$(cat <<EOF
◇━━━━━━━━━━━━━━◇
⛔SC ZIVPN EXPIRED ⛔
◇━━━━━━━━━━━━━━◇
IP VPS  : ${ip}
HOST  : ${host}
ISP     : ${isp}
CLIENT : ${client}
EXP DATE  : ${exp_date}
◇━━━━━━━━━━━━━━◇
EOF
)
    
    # Inline keyboard untuk perpanjang lisensi
    local keyboard
    keyboard=$(cat <<EOF
{
    "inline_keyboard": [
        [
            {
                "text": "Perpanjang Licence",
                "url": "https://t.me/ARI_VPN_STORE"
            }
        ]
    ]
}
EOF
)
    
    send_telegram_notification "$message" "$keyboard"
}

# ============================================================================
# SECTION 7: FUNGSI NOTIFIKASI RENEW
# ============================================================================
# Kirim notifikasi ketika lisensi diperpanjang
# Parameter:
#   $1 = host
#   $2 = ip
#   $3 = client
#   $4 = isp
#   $5 = expiry_timestamp
function handle_renewed_notification() {
    local host="$1"
    local ip="$2"
    local client="$3"
    local isp="$4"
    local expiry_timestamp="$5"
    
    # Hitung sisa hari
    local current_timestamp
    current_timestamp=$(date +%s)
    local remaining_seconds=$((expiry_timestamp - current_timestamp))
    local remaining_days=$((remaining_seconds / 86400))
    
    local message
    message=$(cat <<EOF
◇━━━━━━━━━━━━━━◇
✅RENEW SC ZIVPN✅
◇━━━━━━━━━━━━━━◇
IP VPS  : ${ip}
HOST  : ${host}
ISP     : ${isp}
CLIENT : ${client}
EXP : ${remaining_days} Days
◇━━━━━━━━━━━━━━◇
EOF
)
    
    send_telegram_notification "$message"
}

# ============================================================================
# SECTION 8: FUNGSI NOTIFIKASI API KEY
# ============================================================================
# Kirim notifikasi API key baru ke Telegram
# Parameter:
#   $1 = api_key
#   $2 = server_ip
#   $3 = domain
function handle_api_key_notification() {
    local api_key="$1"
    local server_ip="$2"
    local domain="$3"
    
    local message
    message=$(cat <<EOF
🚀 API UDP ZIVPN 🚀
🔑 Auth Key: ${api_key}
🌐 Server IP: ${server_ip}
🌍 Domain: ${domain}
EOF
)
    
    send_telegram_notification "$message"
}

# ============================================================================
# SECTION 9: FUNGSI RESTORE DARI FILE LOKAL
# ============================================================================
# Restore file konfigurasi dari /root/backup.zip
function handle_restore() {
    echo "--- Memulai Proses Restore ---"
    
    local backup_file="/root/backup.zip"
    
    # Cek apakah file backup ada
    if [ ! -f "$backup_file" ]; then
        echo "❌ File backup tidak ditemukan!"
        echo ""
        echo "Cara restore:"
        echo "1. Download file backup dari Telegram"
        echo "2. Upload ke VPS dengan nama: /root/backup.zip"
        echo "3. Jalankan restore lagi"
        echo ""
        read -p "Tekan [Enter] untuk kembali ke menu..." && /usr/local/bin/zivpn-manager
        return 1
    fi
    
    echo "✔️ File backup ditemukan: $backup_file"
    echo ""
    
    # Konfirmasi restore
    read -p "⚠️ Data saat ini akan ditimpa. Lanjutkan? (y/n): " confirm
    if [ "$confirm" != "y" ]; then
        echo "Restore dibatalkan."
        read -p "Tekan [Enter] untuk kembali ke menu..." && /usr/local/bin/zivpn-manager
        return 0
    fi
    
    # Extract dan restore
    echo "Extracting dan restore data..."
    unzip -P "Naytra123Done" -o "$backup_file" -d "$CONFIG_DIR"
    
    if [ $? -ne 0 ]; then
        echo "❌ Gagal extract file backup!"
        echo "Pastikan password benar atau file tidak corrupt."
        read -p "Tekan [Enter] untuk kembali ke menu..." && /usr/local/bin/zivpn-manager
        return 1
    fi
    
    # Hapus file backup setelah restore
    rm -f "$backup_file"
    
    # Restart service
    echo "Restart ZIVPN service..."
    systemctl restart zivpn.service
    
    echo ""
    echo "✅ Restore berhasil!"
    echo "File backup sudah dihapus dari /root/"
    
    read -p "Tekan [Enter] untuk kembali ke menu..." && /usr/local/bin/zivpn-manager
}

# ============================================================================
# SECTION 10: COMMAND HANDLER (ENTRY POINT)
# ============================================================================
# Parse argumen command line dan jalankan fungsi yang sesuai
case "$1" in
    backup)
        # Jalankan backup
        handle_backup
        ;;
    restore)
        # Jalankan restore
        handle_restore
        ;;
    setup-telegram)
        # Setup konfigurasi Telegram
        setup_telegram
        ;;
    expiry-notification)
        # Kirim notifikasi expiry
        if [ $# -ne 6 ]; then
            echo "Usage: $0 expiry-notification <host> <ip> <client> <isp> <exp_date>"
            exit 1
        fi
        handle_expiry_notification "$2" "$3" "$4" "$5" "$6"
        ;;
    renewed-notification)
        # Kirim notifikasi renew
        if [ $# -ne 6 ]; then
            echo "Usage: $0 renewed-notification <host> <ip> <client> <isp> <expiry_timestamp>"
            exit 1
        fi
        handle_renewed_notification "$2" "$3" "$4" "$5" "$6"
        ;;
    api-key-notification)
        # Kirim notifikasi API key
        if [ $# -ne 4 ]; then
            echo "Usage: $0 api-key-notification <api_key> <server_ip> <domain>"
            exit 1
        fi
        handle_api_key_notification "$2" "$3" "$4"
        ;;
    *)
        # Tampilkan usage jika command tidak dikenal
        echo "Usage: $0 {backup|restore|setup-telegram|expiry-notification|renewed-notification|api-key-notification}"
        exit 1
        ;;
esac
