#!/bin/bash

# ===================================================================================
# Shairport-Sync AirPlay 2 - Uninstaller
#
# Completely removes Shairport-Sync, NQPTP, configuration files, systemd services,
# the dedicated user/group and UFW firewall rules added by install_airplay_v3.sh.
#
# APT build dependencies are left installed (they may be in use by other software).
# ===================================================================================

set -eo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="1.0"

cecho() {
    local code="\033["
    local color
    case "$1" in
        "red")     color="${code}1;31m" ;;
        "green")   color="${code}1;32m" ;;
        "yellow")  color="${code}1;33m" ;;
        "blue")    color="${code}1;34m" ;;
        "magenta") color="${code}1;35m" ;;
        "cyan")    color="${code}1;36m" ;;
        *)         color="${code}0m" ;;
    esac
    echo -e "${color}$2\033[0m"
}

if [ "$EUID" -eq 0 ]; then
    cecho "red" "❌ Don't run this script with sudo or as root."
    cecho "yellow" "   Just run: bash uninstall_airplay.sh"
    exit 1
fi

if ! sudo -n true 2>/dev/null; then
    cecho "yellow" "Sudo access is required for uninstallation."
    sudo true || { cecho "red" "Sudo required."; exit 1; }
fi

cecho "magenta" "╔═════════════════════════════════════════════════════╗"
cecho "magenta" "║   AirPlay 2 / Shairport-Sync Uninstaller  v$SCRIPT_VERSION       ║"
cecho "magenta" "╚═════════════════════════════════════════════════════╝"
echo
cecho "yellow" "This will REMOVE:"
cecho "yellow" "  • shairport-sync and nqptp binaries (/usr/local/bin)"
cecho "yellow" "  • /etc/shairport-sync.conf and sample"
cecho "yellow" "  • systemd services (shairport-sync, nqptp)"
cecho "yellow" "  • shairport-sync user and group"
cecho "yellow" "  • UFW firewall rules for AirPlay (5353/udp, 319/udp, 320/udp, 7000/tcp)"
if dpkg -l raspotify 2>/dev/null | grep -q '^ii'; then
    cecho "yellow" "  • raspotify (Spotify Connect) package + apt repo"
fi
echo
cecho "blue" "APT build dependencies (libsoxr-dev, libplist-dev, ...) are NOT removed."
cecho "blue" "Other software on your system may rely on them."
echo
read -p "Type 'yes' to confirm uninstall: " confirm || true
if [ "$confirm" != "yes" ]; then
    cecho "yellow" "Cancelled."
    exit 0
fi

# Backup current configuration (best effort)
BACKUP_DIR="/tmp/airplay_uninstall_backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
[ -f /etc/shairport-sync.conf ] && sudo cp /etc/shairport-sync.conf "$BACKUP_DIR/" 2>/dev/null || true
[ -f /etc/shairport-sync.conf.sample ] && sudo cp /etc/shairport-sync.conf.sample "$BACKUP_DIR/" 2>/dev/null || true
cecho "blue" "Config backup saved to: $BACKUP_DIR"
echo

# --- Stop services ---
cecho "blue" "Stopping services..."
sudo systemctl stop shairport-sync 2>/dev/null || true
sudo systemctl stop nqptp 2>/dev/null || true
sudo systemctl stop raspotify 2>/dev/null || true

cecho "blue" "Disabling services..."
sudo systemctl stop airplay-volume 2>/dev/null || true
sudo systemctl disable airplay-volume 2>/dev/null || true
sudo systemctl disable shairport-sync 2>/dev/null || true
sudo systemctl disable nqptp 2>/dev/null || true
sudo systemctl disable raspotify 2>/dev/null || true

# --- Remove raspotify (Spotify Connect) ---
if dpkg -l raspotify 2>/dev/null | grep -q '^ii'; then
    cecho "blue" "Removing raspotify package..."
    sudo cp /etc/raspotify/conf "$BACKUP_DIR/raspotify.conf" 2>/dev/null || true
    sudo apt-get remove --purge -y raspotify 2>/dev/null || true
fi
if [ -f /etc/apt/sources.list.d/raspotify.list ]; then
    cecho "blue" "Removing raspotify apt repository..."
    sudo rm -f /etc/apt/sources.list.d/raspotify.list
    sudo rm -f /usr/share/keyrings/raspotify_key.asc
fi

# --- Remove systemd service files ---
cecho "blue" "Removing systemd service files..."
sudo rm -f /lib/systemd/system/shairport-sync.service
sudo rm -f /etc/systemd/system/shairport-sync.service
sudo rm -f /usr/local/lib/systemd/system/shairport-sync.service
sudo rm -f /lib/systemd/system/nqptp.service
sudo rm -f /etc/systemd/system/nqptp.service
sudo rm -f /usr/local/lib/systemd/system/nqptp.service
sudo rm -f /lib/systemd/system/airplay-volume.service
sudo rm -rf /etc/systemd/system/raspotify.service.d
sudo systemctl daemon-reload
sudo systemctl reset-failed 2>/dev/null || true

# --- Remove binaries ---
cecho "blue" "Removing binaries..."
sudo rm -f /usr/local/bin/shairport-sync
sudo rm -f /usr/local/bin/nqptp

# --- Remove configuration files ---
cecho "blue" "Removing configuration files..."
sudo rm -f /etc/shairport-sync.conf
sudo rm -f /etc/shairport-sync.conf.sample

# --- Remove ancillary files ---
cecho "blue" "Removing ancillary files (man pages, shared data)..."
sudo rm -rf /usr/local/share/shairport-sync 2>/dev/null || true
sudo rm -rf /etc/shairport-sync 2>/dev/null || true
sudo rm -f /usr/local/share/man/man7/shairport-sync.7 2>/dev/null || true
sudo rm -f /usr/local/share/man/man7/nqptp.7 2>/dev/null || true

# --- Remove user and group ---
cecho "blue" "Removing shairport-sync user and group..."
if getent passwd shairport-sync >/dev/null 2>&1; then
    sudo userdel shairport-sync 2>/dev/null || true
fi
if getent group shairport-sync >/dev/null 2>&1; then
    sudo groupdel shairport-sync 2>/dev/null || true
fi

# --- Remove firewall rules ---
if command -v ufw >/dev/null 2>&1; then
    cecho "blue" "Removing UFW firewall rules..."
    sudo ufw delete allow 5353/udp 2>/dev/null || true
    sudo ufw delete allow 319/udp 2>/dev/null || true
    sudo ufw delete allow 320/udp 2>/dev/null || true
    sudo ufw delete allow 7000/tcp 2>/dev/null || true
fi

# --- Verify ---
echo
cecho "blue" "Verifying removal..."
failures=0
if command -v shairport-sync >/dev/null 2>&1; then
    cecho "yellow" "⚠ shairport-sync still present at $(command -v shairport-sync)"
    failures=$((failures+1))
fi
if command -v nqptp >/dev/null 2>&1; then
    cecho "yellow" "⚠ nqptp still present at $(command -v nqptp)"
    failures=$((failures+1))
fi
if [ -f /etc/shairport-sync.conf ]; then
    cecho "yellow" "⚠ /etc/shairport-sync.conf still present"
    failures=$((failures+1))
fi
if systemctl list-unit-files 2>/dev/null | grep -qE '^(shairport-sync|nqptp|raspotify)\.service'; then
    cecho "yellow" "⚠ Some systemd unit files are still registered"
    failures=$((failures+1))
fi
if dpkg -l raspotify 2>/dev/null | grep -q '^ii'; then
    cecho "yellow" "⚠ raspotify package still installed"
    failures=$((failures+1))
fi

echo
if [ "$failures" -eq 0 ]; then
    cecho "green" "╔═════════════════════════════════════════════════════╗"
    cecho "green" "║            ✅ UNINSTALL COMPLETE ✅                 ║"
    cecho "green" "╚═════════════════════════════════════════════════════╝"
else
    cecho "yellow" "⚠ Uninstall finished with $failures leftover item(s) — see warnings above."
fi
echo
cecho "blue" "Config backup (if any): $BACKUP_DIR"
echo
cecho "blue" "To also remove the APT build dependencies (only if not used by anything else):"
cecho "blue" "  sudo apt-get remove --purge libsoxr-dev libplist-dev libplist-utils libsodium-dev \\"
cecho "blue" "       libavutil-dev libavcodec-dev libavformat-dev libpopt-dev libconfig-dev \\"
cecho "blue" "       libgcrypt20-dev libavahi-client-dev libssl-dev"
cecho "blue" "  sudo apt-get autoremove"
echo

read -p "Reboot now to ensure a clean state? (y/N): " do_reboot || true
if [[ "$do_reboot" =~ ^[Yy]$ ]]; then
    cecho "yellow" "Rebooting in 3 seconds..."
    sleep 3
    sudo reboot
fi
