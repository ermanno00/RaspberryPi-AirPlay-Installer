#!/bin/bash

# ===================================================================================
# Shairport-Sync AirPlay 2 - Rebuild / Repair
#
# Recompiles NQPTP and Shairport-Sync from source against the libraries currently
# installed on the system, WITHOUT touching the configuration.
#
# Why this exists:
#   This installer builds nqptp and shairport-sync from source and links them
#   dynamically against system libraries (libplist, libsodium, libsoxr, libavcodec,
#   libssl, libasound, ...). After an "apt upgrade" that bumps one of those
#   libraries, the locally-compiled binary has a stale ABI and can read garbage
#   from internal structs. The classic symptom is a fatal crash on connection:
#
#       fatal error: Unexpected SPS_FORMAT_* with index 52 while outputting silence
#       shairport-sync.service: Main process exited, code=killed, status=6/ABRT
#
#   "index 52" is not a real audio format — it is uninitialized memory. Rebuilding
#   against the upgraded libraries restores a coherent ABI and fixes the crash.
#
# The existing /etc/shairport-sync.conf is preserved (and backed up).
# ===================================================================================

set -eo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="1.0"
CONFIG_FILE="/etc/shairport-sync.conf"
SERVICE_NAME="shairport-sync"

# Pinned stable upstream versions — must match install_airplay_v3.sh.
# Building from `master` pulls Shairport-Sync 5.0-dev, which crashes on some
# DACs with "Unexpected SPS_FORMAT_* with index N while outputting silence".
SHAIRPORT_VERSION="4.3.7"
NQPTP_VERSION="1.2.8"
BACKUP_DIR="$HOME/airplay-repair-backup-$(date +%Y%m%d-%H%M%S)"
LOG_FILE="/tmp/airplay-repair-$(date +%Y%m%d-%H%M%S).log"

# --- Helpers ---
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

log() { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null || true; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

safe_cd() {
    cd "$1" || { cecho "red" "❌ Cannot enter directory: $1"; exit 1; }
}

require_sudo() {
    if [ "$EUID" -eq 0 ]; then
        cecho "red" "❌ Don't run this script with sudo or as root."
        cecho "yellow" "   Just run: bash repair_airplay.sh"
        exit 1
    fi
    if ! sudo -n true 2>/dev/null; then
        cecho "yellow" "Checking sudo access..."
        sudo true || { cecho "red" "Sudo required."; exit 1; }
    fi
}

check_service() {
    local service_name="$1"
    local wait_time="${2:-5}"
    sleep "$wait_time"
    systemctl is-active --quiet "$service_name"
}

# --- Steps ---
backup_config() {
    if [ -f "$CONFIG_FILE" ]; then
        mkdir -p "$BACKUP_DIR"
        cp "$CONFIG_FILE" "$BACKUP_DIR/" 2>/dev/null || true
        cecho "green" "✓ Config backed up to $BACKUP_DIR"
        log "Backed up $CONFIG_FILE to $BACKUP_DIR"
    else
        cecho "yellow" "⚠ $CONFIG_FILE not found — nothing to back up (a fresh install may be needed instead)."
    fi
}

install_dependencies() {
    cecho "blue" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    cecho "blue" "   Refreshing build dependencies..."
    cecho "blue" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "Installing build dependencies..."

    # Same set used by install_airplay_v3.sh — ensures the -dev headers match the
    # libraries that 'apt upgrade' just installed.
    local dependencies=(
        build-essential git autoconf automake libtool pkg-config
        libpopt-dev libconfig-dev libasound2-dev
        avahi-daemon libavahi-client-dev libssl-dev
        libsoxr-dev libplist-dev libplist-utils libsodium-dev
        libavutil-dev libavcodec-dev libavformat-dev
        uuid-dev libgcrypt20-dev xxd alsa-utils
    )

    if ! sudo apt-get install -y "${dependencies[@]}" 2>&1 | tee -a "$LOG_FILE"; then
        cecho "red" "❌ Failed to install/refresh build dependencies"
        exit 1
    fi
    cecho "green" "✓ Dependencies up to date"
    echo
}

rebuild_nqptp() {
    cecho "blue" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    cecho "blue" "   Rebuilding NQPTP (Timing System)..."
    cecho "blue" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "Rebuilding NQPTP..."

    sudo systemctl stop nqptp 2>/dev/null || true

    safe_cd /tmp
    rm -rf nqptp 2>/dev/null || true
    log "Pinning NQPTP to release $NQPTP_VERSION"
    if ! git clone --branch "$NQPTP_VERSION" --depth 1 \
            https://github.com/mikebrady/nqptp.git 2>&1 | tee -a "$LOG_FILE"; then
        cecho "red" "❌ Failed to clone NQPTP repository (check your internet connection)"
        exit 1
    fi

    safe_cd nqptp
    if ! autoreconf -fi 2>&1 | tee -a "$LOG_FILE" \
        || ! ./configure --with-systemd-startup 2>&1 | tee -a "$LOG_FILE" \
        || ! make -j"$(nproc)" 2>&1 | tee -a "$LOG_FILE" \
        || ! sudo make install 2>&1 | tee -a "$LOG_FILE"; then
        cecho "red" "❌ NQPTP rebuild failed (see $LOG_FILE)"
        exit 1
    fi

    if ! command_exists nqptp; then
        cecho "red" "❌ NQPTP binary not found after rebuild"
        exit 1
    fi

    sudo systemctl daemon-reload
    sudo systemctl enable nqptp >/dev/null 2>&1 || true
    sudo systemctl restart nqptp 2>&1 | tee -a "$LOG_FILE"

    if ! check_service "nqptp" 3; then
        cecho "red" "❌ NQPTP service failed to start after rebuild"
        sudo systemctl status nqptp --no-pager -l | tail -20
        exit 1
    fi
    cecho "green" "✓ NQPTP rebuilt and running"
    echo
}

rebuild_shairport() {
    cecho "blue" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    cecho "blue" "   Rebuilding Shairport-Sync..."
    cecho "blue" "   (This takes 10-20 mins on slower Pis)"
    cecho "blue" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "Rebuilding Shairport-Sync..."

    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true

    safe_cd /tmp
    rm -rf shairport-sync 2>/dev/null || true
    log "Pinning Shairport-Sync to release $SHAIRPORT_VERSION"
    if ! git clone --branch "$SHAIRPORT_VERSION" --depth 1 \
            https://github.com/mikebrady/shairport-sync.git 2>&1 | tee -a "$LOG_FILE"; then
        cecho "red" "❌ Failed to clone Shairport-Sync repository (check your internet connection)"
        exit 1
    fi

    safe_cd shairport-sync
    if ! autoreconf -fi 2>&1 | tee -a "$LOG_FILE"; then
        cecho "red" "❌ Shairport-Sync autoreconf failed"
        exit 1
    fi

    cecho "yellow" "Configuring build (same flags as the installer)..."
    # IMPORTANT: must match install_airplay_v3.sh so behaviour is identical.
    if ! ./configure --sysconfdir=/etc --with-alsa --with-avahi \
        --with-ssl=openssl --with-soxr --with-systemd \
        --with-airplay-2 2>&1 | tee -a "$LOG_FILE"; then
        cecho "red" "❌ Shairport-Sync configure failed"
        exit 1
    fi

    cecho "yellow" "Compiling (be patient)..."
    if ! make -j"$(nproc)" 2>&1 | tee -a "$LOG_FILE"; then
        cecho "red" "❌ Shairport-Sync compilation failed"
        cecho "yellow" "Last 20 lines of build log:"
        tail -20 "$LOG_FILE" 2>/dev/null || true
        exit 1
    fi

    cecho "yellow" "Installing..."
    # make install can fail on the systemd unit step — that's fine, the binary is
    # what matters and we recreate the unit below if needed.
    sudo make install 2>&1 | tee -a "$LOG_FILE" || true

    if ! command_exists shairport-sync; then
        cecho "red" "❌ Shairport-Sync binary not found after rebuild"
        exit 1
    fi
    cecho "green" "✓ Shairport-Sync rebuilt and installed"
    echo
}

ensure_service_unit() {
    # Preserve an existing unit; only recreate it if it disappeared.
    if systemctl list-unit-files 2>/dev/null | grep -q '^shairport-sync\.service'; then
        return
    fi
    cecho "yellow" "systemd unit missing — recreating it..."
    log "Recreating shairport-sync.service unit"

    if ! getent group shairport-sync >/dev/null 2>&1; then
        sudo groupadd -r shairport-sync
    fi
    if ! getent passwd shairport-sync >/dev/null 2>&1; then
        sudo useradd -r -M -g shairport-sync -s /usr/sbin/nologin -G audio shairport-sync
    fi

    sudo tee /lib/systemd/system/shairport-sync.service > /dev/null <<EOF
[Unit]
Description=Shairport Sync - AirPlay Audio Receiver
After=sound.target network-online.target

[Service]
ExecStart=/usr/local/bin/shairport-sync
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl enable shairport-sync >/dev/null 2>&1 || true
}

restart_and_verify() {
    cecho "blue" "Restarting services..."
    sudo systemctl daemon-reload
    ensure_service_unit
    sudo systemctl restart nqptp 2>/dev/null || true
    sudo systemctl restart "$SERVICE_NAME" 2>&1 | tee -a "$LOG_FILE"

    if check_service "$SERVICE_NAME" 5; then
        cecho "green" "✓ $SERVICE_NAME is running"
    else
        cecho "red" "✗ $SERVICE_NAME is NOT active after rebuild."
        cecho "yellow" "Recent logs:"
        sudo journalctl -u "$SERVICE_NAME" --no-pager -n 25 || true
        cecho "yellow" "Your previous config is backed up in: $BACKUP_DIR"
        exit 1
    fi

    if ! systemctl is-active --quiet avahi-daemon; then
        cecho "yellow" "⚠ avahi-daemon not running — starting it (needed for discovery)..."
        sudo systemctl start avahi-daemon || true
    fi
}

main() {
    clear
    cecho "magenta" "═══════════════════════════════════════════════════════"
    cecho "magenta" "   AirPlay 2 — Rebuild / Repair  v$SCRIPT_VERSION"
    cecho "magenta" "═══════════════════════════════════════════════════════"
    echo
    cecho "yellow" "This recompiles NQPTP and Shairport-Sync from source against the"
    cecho "yellow" "libraries currently on your system. Use it when AirPlay broke after"
    cecho "yellow" "an 'apt upgrade' (e.g. the 'Unexpected SPS_FORMAT_* / status=6/ABRT'"
    cecho "yellow" "crash). Your configuration is preserved."
    echo
    cecho "blue" "Log file: $LOG_FILE"
    echo

    if [ ! -f "$CONFIG_FILE" ]; then
        cecho "red" "⚠ No existing configuration found at $CONFIG_FILE."
        cecho "yellow" "  This looks like a fresh system — a full install is more appropriate."
        read -p "Continue with rebuild anyway? (y/N): " ans || true
        [[ ! "$ans" =~ ^[Yy]$ ]] && { cecho "yellow" "Cancelled."; exit 0; }
    fi

    read -p "Proceed with the rebuild? (y/N): " ans || true
    [[ ! "$ans" =~ ^[Yy]$ ]] && { cecho "yellow" "Cancelled."; exit 0; }
    echo

    require_sudo
    backup_config
    install_dependencies
    rebuild_nqptp
    rebuild_shairport
    restart_and_verify

    echo
    cecho "green" "╔═════════════════════════════════════════════════════╗"
    cecho "green" "║   ✓ Rebuild complete — AirPlay should work again.   ║"
    cecho "green" "╚═════════════════════════════════════════════════════╝"
    cecho "blue" "Try connecting from your Mac/iPhone now."
    cecho "blue" "If issues persist, check: sudo journalctl -u shairport-sync -f"
}

main "$@"
