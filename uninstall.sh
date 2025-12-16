#!/bin/bash

# ============================================================================
# ZIVPN UNINSTALL SCRIPT
# ============================================================================
# Script untuk menghapus instalasi ZIVPN dari server
# Menghentikan service, menghapus file, dan membersihkan cache
# ============================================================================

echo -e "Uninstalling ZiVPN Old..."

# ----------------------------------------------------------------------------
# STEP 1: STOP & DISABLE SERVICE
# ----------------------------------------------------------------------------
svc="zivpn.service"

# Stop service
systemctl stop $svc 1>/dev/null 2>/dev/null

# Disable autostart
systemctl disable $svc 1>/dev/null 2>/dev/null

# Hapus file service
rm -f /etc/systemd/system/$svc 1>/dev/null 2>/dev/null

echo "Removed service $svc"

# ----------------------------------------------------------------------------
# STEP 2: KILL PROSES YANG MASIH BERJALAN
# ----------------------------------------------------------------------------
if pgrep "zivpn" >/dev/null; then
    killall zivpn 1>/dev/null 2>/dev/null
    echo "Killed running zivpn processes"
fi

# ----------------------------------------------------------------------------
# STEP 3: HAPUS FILE & DIREKTORI
# ----------------------------------------------------------------------------
# Hapus direktori konfigurasi
[ -d /etc/zivpn ] && rm -rf /etc/zivpn

# Hapus binary
[ -f /usr/local/bin/zivpn ] && rm -f /usr/local/bin/zivpn

# ----------------------------------------------------------------------------
# STEP 4: VERIFIKASI PENGHAPUSAN
# ----------------------------------------------------------------------------
# Cek apakah proses masih berjalan
if ! pgrep "zivpn" >/dev/null; then
    echo "Server Stopped"
else
    echo "Server Still Running"
fi

# Cek apakah file sudah terhapus
if [ ! -f /usr/local/bin/zivpn ]; then
    echo "Files successfully removed"
else
    echo "Some files remain, try again"
fi

# ----------------------------------------------------------------------------
# STEP 5: BERSIHKAN CACHE SISTEM
# ----------------------------------------------------------------------------
echo "Cleaning Cache"
echo 3 > /proc/sys/vm/drop_caches
sysctl -w vm.drop_caches=3

echo -e "Done."
