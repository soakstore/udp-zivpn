#!/bin/bash

# ============================================================================
# ZIVPN UPDATE SCRIPT
# ============================================================================
# Script untuk mengupdate ZIVPN ke versi terbaru
# Mengunduh script terbaru dari repository GitHub
# ============================================================================

echo -e "Update ZiVPN..."

# ----------------------------------------------------------------------------
# STEP 1: UPDATE ZIVPN MANAGER
# ----------------------------------------------------------------------------
# Download versi terbaru install.sh sebagai zivpn-manager
wget -q https://raw.githubusercontent.com/soakstore/udp-zivpn/main/install.sh -O /usr/local/bin/zivpn-manager
chmod +x /usr/local/bin/zivpn-manager

# ----------------------------------------------------------------------------
# STEP 2: UPDATE HELPER SCRIPT
# ----------------------------------------------------------------------------
# Download versi terbaru zivpn_helper.sh
wget -q https://raw.githubusercontent.com/soakstore/udp-zivpn/main/zivpn_helper.sh -O /usr/local/bin/zivpn_helper.sh
chmod +x /usr/local/bin/zivpn_helper.sh

# ----------------------------------------------------------------------------
# STEP 3: JALANKAN MENU
# ----------------------------------------------------------------------------
# Buka menu setelah update selesai
/usr/local/bin/zivpn-manager
