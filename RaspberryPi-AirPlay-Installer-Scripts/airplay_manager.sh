#!/bin/bash

# ===================================================================================
# AirPlay 2 Manager — Unified menu for install / modify / uninstall
#
# Dispatches to the dedicated scripts in the same directory:
#   install_airplay_v3.sh   — First-time installation
#   modify_airplay.sh       — Modify existing installation
#   uninstall_airplay.sh    — Remove the installation
# ===================================================================================

set -eo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

run_script() {
    local script_name="$1"
    local script_path="$SCRIPT_DIR/$script_name"
    if [ ! -f "$script_path" ]; then
        cecho "red" "❌ Script not found: $script_path"
        read -p "Press Enter to continue..." || true
        return 1
    fi
    echo
    bash "$script_path" || true
    echo
    read -p "Press Enter to return to the menu..." || true
}

is_installed() {
    [ -f /etc/shairport-sync.conf ] && command -v shairport-sync >/dev/null 2>&1
}

service_status_line() {
    if systemctl is-active --quiet shairport-sync 2>/dev/null; then
        echo "active"
    elif systemctl list-unit-files 2>/dev/null | grep -q '^shairport-sync\.service'; then
        echo "inactive"
    else
        echo "not registered"
    fi
}

current_name() {
    [ -f /etc/shairport-sync.conf ] || { echo ""; return; }
    grep -oE '^[[:space:]]*name[[:space:]]*=[[:space:]]*"[^"]*"' /etc/shairport-sync.conf 2>/dev/null \
        | head -1 | sed -E 's/.*"([^"]*)".*/\1/' || true
}

spotify_installed() {
    dpkg -l raspotify 2>/dev/null | grep -q '^ii'
}

spotify_status_line() {
    if ! spotify_installed; then
        echo "not installed"
    elif systemctl is-active --quiet raspotify 2>/dev/null; then
        echo "active"
    else
        echo "inactive"
    fi
}

while true; do
    clear
    cecho "green" "╔═════════════════════════════════════════════════════╗"
    cecho "green" "║      AirPlay 2 Manager (Raspberry Pi)   v$SCRIPT_VERSION       ║"
    cecho "green" "╚═════════════════════════════════════════════════════╝"
    echo
    if is_installed; then
        cecho "green" "  ✓ Shairport-Sync installed"
        cecho "blue"  "    AirPlay service:  $(service_status_line)"
        cecho "blue"  "    AirPlay name:     $(current_name)"
        cecho "blue"  "    Spotify Connect:  $(spotify_status_line)"
    else
        cecho "yellow" "  ⚠ Shairport-Sync NOT installed."
    fi
    echo
    echo "  1) Install AirPlay 2"
    echo "  2) Modify existing installation"
    echo "  3) Uninstall"
    echo "  4) Show service logs (live, Ctrl+C to exit)"
    echo "  5) Rebuild / repair (fixes crashes after 'apt upgrade')"
    echo "  0) Exit"
    echo
    read -p "Choose: " choice || true
    case "$choice" in
        1) run_script "install_airplay_v3.sh" ;;
        2)
            if ! is_installed; then
                cecho "red" "❌ No installation detected. Install first."
                read -p "Press Enter..." || true
                continue
            fi
            run_script "modify_airplay.sh"
            ;;
        3)
            if ! is_installed; then
                cecho "red" "❌ No installation detected to uninstall."
                read -p "Press Enter..." || true
                continue
            fi
            run_script "uninstall_airplay.sh"
            ;;
        4)
            if ! is_installed; then
                cecho "red" "❌ No installation detected."
                read -p "Press Enter..." || true
                continue
            fi
            sudo journalctl -u shairport-sync -f || true
            ;;
        5)
            if ! is_installed; then
                cecho "red" "❌ No installation detected. Install first."
                read -p "Press Enter..." || true
                continue
            fi
            run_script "repair_airplay.sh"
            ;;
        0|q|Q|"") cecho "blue" "Bye!"; exit 0 ;;
        *) cecho "red" "Invalid choice."; sleep 1 ;;
    esac
done
