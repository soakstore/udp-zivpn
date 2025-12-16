#!/bin/bash

# ============================================================================
# ZIVPN INSTALLER - ARM64 (aarch64)
# ============================================================================
# Script instalasi ZIVPN untuk arsitektur ARM64/aarch64
# Cocok untuk: Raspberry Pi 4, Oracle ARM, AWS Graviton, dll
# ============================================================================

# ----------------------------------------------------------------------------
# STEP 1: UPDATE SISTEM
# ----------------------------------------------------------------------------
echo -e "Updating server"
sudo apt-get update && apt-get upgrade -y

# ----------------------------------------------------------------------------
# STEP 2: STOP SERVICE LAMA (JIKA ADA)
# ----------------------------------------------------------------------------
systemctl stop zivpn.service

# ----------------------------------------------------------------------------
# STEP 3: DOWNLOAD BINARY ZIVPN (ARM64)
# ----------------------------------------------------------------------------
echo -e "Downloading UDP Service"
wget https://github.com/soakstore/udp-zivpn/releases/download/V1/udp-zivpn-linux-arm64 -O /usr/local/bin/zivpn
chmod +x /usr/local/bin/zivpn

# ----------------------------------------------------------------------------
# STEP 4: BUAT DIREKTORI KONFIGURASI
# ----------------------------------------------------------------------------
mkdir -p /etc/zivpn

# Download config default
wget https://raw.githubusercontent.com/soakstore/udp-zivpn/main/config.json -O /etc/zivpn/config.json

# ----------------------------------------------------------------------------
# STEP 5: GENERATE SSL CERTIFICATE
# ----------------------------------------------------------------------------
echo "Generating cert files:"
openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
    -subj "/C=US/ST=California/L=Los Angeles/O=Example Corp/OU=IT Department/CN=zivpn" \
    -keyout "/etc/zivpn/zivpn.key" \
    -out "/etc/zivpn/zivpn.crt"

# ----------------------------------------------------------------------------
# STEP 6: OPTIMASI NETWORK BUFFER
# ----------------------------------------------------------------------------
# Tingkatkan buffer untuk performa UDP yang lebih baik
sysctl -w net.core.rmem_max=16777216
sysctl -w net.core.wmem_max=16777216

# ----------------------------------------------------------------------------
# STEP 7: BUAT SYSTEMD SERVICE
# ----------------------------------------------------------------------------
cat <<EOF > /etc/systemd/system/zivpn.service
[Unit]
Description=zivpn VPN Server
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
WorkingDirectory=/etc/zivpn
ExecStart=/usr/local/bin/zivpn server -c /etc/zivpn/config.json
Restart=always
RestartSec=3
Environment=ZIVPN_LOG_LEVEL=info
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

# ----------------------------------------------------------------------------
# STEP 8: SET PASSWORD DEFAULT
# ----------------------------------------------------------------------------
echo -e "ZIVPN UDP Passwords -> otomatis pakai 'zi'"
new_config_str="\"config\": [\"zi\"]"
sed -i -E "s/\"config\": ?\[[^]]*\]/${new_config_str}/" /etc/zivpn/config.json
echo "Config berhasil diupdate menjadi: [\"zi\"]"

# ----------------------------------------------------------------------------
# STEP 9: ENABLE & START SERVICE
# ----------------------------------------------------------------------------
systemctl enable systemd-networkd-wait-online.service
systemctl daemon-reload
systemctl enable zivpn.service
systemctl restart zivpn.service

# ----------------------------------------------------------------------------
# STEP 10: KONFIGURASI FIREWALL & PORT FORWARDING
# ----------------------------------------------------------------------------
# Forward port 6000-19999 ke port 5667 (port utama ZIVPN)
iptables -t nat -A PREROUTING -i $(ip -4 route ls|grep default|grep -Po '(?<=dev )(\S+)'|head -1) -p udp --dport 6000:19999 -j DNAT --to-destination :5667

# Buka port di UFW
ufw allow 6000:19999/udp
ufw allow 5667/udp

# ----------------------------------------------------------------------------
# STEP 11: CLEANUP
# ----------------------------------------------------------------------------
rm -f zi.*

echo -e "ZIVPN UDP Installed"
