#!/bin/bash

# ===================================================================================
# Shairport-Sync AirPlay 2 - Configuration Modifier
#
# Modify an existing AirPlay 2 installation (name, audio device, mixer, volume...)
# without reinstalling. Designed to work with installs done by install_airplay_v3.sh.
# ===================================================================================

set -eo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="/etc/shairport-sync.conf"
SERVICE_NAME="shairport-sync"
RASPOTIFY_CONF="/etc/raspotify/conf"
SPOTIFY_ZEROCONF_PORT="5354"

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

require_install() {
    if [ ! -f "$CONFIG_FILE" ]; then
        cecho "red" "❌ Configuration file $CONFIG_FILE not found."
        cecho "yellow" "   Shairport-Sync does not appear to be installed."
        cecho "yellow" "   Run install_airplay_v3.sh first."
        exit 1
    fi
    if ! command -v shairport-sync >/dev/null 2>&1; then
        cecho "red" "❌ shairport-sync binary not found in PATH."
        cecho "yellow" "   Run install_airplay_v3.sh first."
        exit 1
    fi
}

require_sudo() {
    if [ "$EUID" -eq 0 ]; then
        cecho "red" "❌ Don't run this script with sudo or as root."
        cecho "yellow" "   Just run: bash modify_airplay.sh"
        exit 1
    fi
    if ! sudo -n true 2>/dev/null; then
        cecho "yellow" "Checking sudo access..."
        sudo true || { cecho "red" "Sudo required."; exit 1; }
    fi
}

restart_service() {
    cecho "blue" "Restarting $SERVICE_NAME..."
    if sudo systemctl restart "$SERVICE_NAME"; then
        sleep 2
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            cecho "green" "✓ $SERVICE_NAME is running"
        else
            cecho "red" "✗ $SERVICE_NAME is not active after restart"
            sudo systemctl status "$SERVICE_NAME" --no-pager -l | tail -20
        fi
    else
        cecho "red" "✗ Failed to restart $SERVICE_NAME (check config syntax)"
        sudo systemctl status "$SERVICE_NAME" --no-pager -l | tail -20
    fi
}

# --- Current value readers (best-effort, tolerate missing keys) ---
current_name() {
    grep -oE '^[[:space:]]*name[[:space:]]*=[[:space:]]*"[^"]*"' "$CONFIG_FILE" 2>/dev/null \
        | head -1 | sed -E 's/.*"([^"]*)".*/\1/' || true
}

current_output_device() {
    grep -oE '^[[:space:]]*output_device[[:space:]]*=[[:space:]]*"[^"]*"' "$CONFIG_FILE" 2>/dev/null \
        | head -1 | sed -E 's/.*"([^"]*)".*/\1/' || true
}

current_mixer() {
    grep -oE '^[[:space:]]*mixer_control_name[[:space:]]*=[[:space:]]*"[^"]*"' "$CONFIG_FILE" 2>/dev/null \
        | head -1 | sed -E 's/.*"([^"]*)".*/\1/' || true
}

# --- Spotify helpers ---
spotify_installed() {
    dpkg -l raspotify 2>/dev/null | grep -q '^ii'
}

spotify_current_name() {
    [ -f "$RASPOTIFY_CONF" ] || { echo ""; return; }
    grep -oE '^[[:space:]]*LIBRESPOT_NAME[[:space:]]*=[[:space:]]*"[^"]*"' "$RASPOTIFY_CONF" 2>/dev/null \
        | head -1 | sed -E 's/.*"([^"]*)".*/\1/' || true
}

spotify_current_device() {
    [ -f "$RASPOTIFY_CONF" ] || { echo ""; return; }
    grep -oE '^[[:space:]]*LIBRESPOT_DEVICE[[:space:]]*=[[:space:]]*"[^"]*"' "$RASPOTIFY_CONF" 2>/dev/null \
        | head -1 | sed -E 's/.*"([^"]*)".*/\1/' || true
}

write_spotify_managed_block() {
    # Args: name, device
    local name="$1" device="$2"
    sudo sed -i '/^# >>> airplay-installer >>>$/,/^# <<< airplay-installer <<<$/d' "$RASPOTIFY_CONF"
    sudo tee -a "$RASPOTIFY_CONF" > /dev/null <<EOF
# >>> airplay-installer >>>
LIBRESPOT_NAME="$name"
LIBRESPOT_DEVICE="$device"
LIBRESPOT_BITRATE="320"
LIBRESPOT_INITIAL_VOLUME="100"
LIBRESPOT_ZEROCONF_PORT="$SPOTIFY_ZEROCONF_PORT"
# <<< airplay-installer <<<
EOF
}

restart_spotify() {
    cecho "blue" "Restarting raspotify..."
    if sudo systemctl restart raspotify 2>/dev/null; then
        sleep 2
        if systemctl is-active --quiet raspotify; then
            cecho "green" "✓ raspotify is running"
        else
            cecho "red" "✗ raspotify is not active after restart"
            sudo systemctl status raspotify --no-pager -l | tail -15
        fi
    else
        cecho "red" "✗ Failed to restart raspotify"
    fi
}

# --- Actions ---
action_change_name() {
    local cur new_name
    cur=$(current_name)
    cecho "blue" "Current AirPlay name: ${cur:-<not set>}"
    echo
    read -p "Enter new name (empty to cancel): " new_name || true
    if [ -z "$new_name" ]; then
        cecho "yellow" "Cancelled."
        return
    fi
    new_name=$(echo "$new_name" | sed 's/[^a-zA-Z0-9 _-]//g')
    if [ -z "$new_name" ]; then
        cecho "red" "Name became empty after sanitization. Cancelled."
        return
    fi
    sudo sed -i -E "s|^[[:space:]]*(//[[:space:]]*)?name[[:space:]]*=.*|        name = \"$new_name\";|" "$CONFIG_FILE"
    cecho "green" "✓ AirPlay name updated to '$new_name'"
    restart_service
}

action_change_audio_device() {
    cecho "blue" "Scanning for audio devices..."
    local all_cards
    all_cards=$(aplay -l 2>/dev/null | grep '^card' || true)
    if [ -z "$all_cards" ]; then
        cecho "red" "❌ No audio devices detected."
        return
    fi

    local all_devices device_labels=() i
    mapfile -t all_devices < <(echo "$all_cards")
    for i in "${!all_devices[@]}"; do
        local label="${all_devices[$i]}"
        if echo "$label" | grep -qi 'bcm2835\|Headphones\|vc4-hdmi'; then
            label="$label  [built-in]"
        else
            label="$label  [external/DAC]"
        fi
        device_labels+=("$label")
    done

    cecho "yellow" "Available audio devices:"
    for i in "${!device_labels[@]}"; do
        echo "  [$i] ${device_labels[$i]}"
    done
    echo
    cecho "blue" "Current output_device: $(current_output_device)"
    echo

    local choice
    while true; do
        read -p "Enter number [0-$((${#all_devices[@]}-1))] (empty=cancel): " choice || true
        [ -z "$choice" ] && { cecho "yellow" "Cancelled."; return; }
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -lt "${#all_devices[@]}" ]; then
            break
        fi
        cecho "red" "Invalid selection."
    done

    local selected="${all_devices[$choice]}"
    local card_number device_number
    card_number=$(echo "$selected" | grep -oE 'card [0-9]+' | grep -oE '[0-9]+')
    device_number=$(echo "$selected" | grep -oE 'device [0-9]+' | grep -oE '[0-9]+')
    [ -z "$device_number" ] && device_number=0
    local audio_device_plug="plughw:$card_number,$device_number"

    sudo sed -i -E "s|^[[:space:]]*(//[[:space:]]*)?output_device[[:space:]]*=.*|        output_device = \"$audio_device_plug\";|" "$CONFIG_FILE"
    cecho "green" "✓ output_device set to $audio_device_plug"

    # Refresh mixer config to match the new card
    local mixers=()
    mapfile -t mixers < <(amixer -c "$card_number" scontrols 2>/dev/null | grep -oP "Simple mixer control '\K[^']+" || true)
    if [ ${#mixers[@]} -eq 0 ]; then
        cecho "yellow" "⚠ No mixer controls on card $card_number — disabling hardware mixer in config."
        sudo sed -i -E "s|^[[:space:]]*(//[[:space:]]*)?mixer_control_name[[:space:]]*=.*|//        mixer_control_name = \"PCM\";|" "$CONFIG_FILE"
        sudo sed -i -E "s|^[[:space:]]*(//[[:space:]]*)?mixer_device[[:space:]]*=.*|//        mixer_device = \"default\";|" "$CONFIG_FILE"
    else
        local mixer_control="" preferred m
        for preferred in "PCM" "Master" "Speaker" "Headphone" "Digital"; do
            for m in "${mixers[@]}"; do
                if [[ "$m" == "$preferred" ]]; then
                    mixer_control="$m"; break 2
                fi
            done
        done
        [ -z "$mixer_control" ] && mixer_control="${mixers[0]}"
        cecho "green" "✓ mixer_control_name = $mixer_control (on hw:$card_number)"
        sudo sed -i -E "s|^[[:space:]]*(//[[:space:]]*)?mixer_control_name[[:space:]]*=.*|        mixer_control_name = \"$mixer_control\";|" "$CONFIG_FILE"
        sudo sed -i -E "s|^[[:space:]]*(//[[:space:]]*)?mixer_device[[:space:]]*=.*|        mixer_device = \"hw:$card_number\";|" "$CONFIG_FILE"
    fi

    restart_service
}

action_change_mixer() {
    local cur_out
    cur_out=$(current_output_device)
    if [ -z "$cur_out" ]; then
        cecho "yellow" "No output_device configured yet. Change the audio device first."
        return
    fi
    local card_number
    card_number=$(echo "$cur_out" | grep -oE '[0-9]+' | head -1)
    if [ -z "$card_number" ]; then
        cecho "red" "Could not parse card number from current output_device: $cur_out"
        return
    fi

    local mixers=()
    mapfile -t mixers < <(amixer -c "$card_number" scontrols 2>/dev/null | grep -oP "Simple mixer control '\K[^']+" || true)
    cecho "blue" "Current mixer_control_name: $(current_mixer)"
    echo

    if [ ${#mixers[@]} -eq 0 ]; then
        cecho "yellow" "No mixer controls available on card $card_number."
        local ans
        read -p "Disable hardware mixer in config (use software volume)? (y/N): " ans || true
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            sudo sed -i -E "s|^[[:space:]]*(//[[:space:]]*)?mixer_control_name[[:space:]]*=.*|//        mixer_control_name = \"PCM\";|" "$CONFIG_FILE"
            cecho "green" "✓ Hardware mixer disabled."
            restart_service
        fi
        return
    fi

    cecho "yellow" "Available mixer controls on card $card_number:"
    local i
    for i in "${!mixers[@]}"; do
        echo "  [$i] ${mixers[$i]}"
    done
    echo "  [d] Disable hardware mixer (software volume only)"
    echo
    local choice
    read -p "Choose [0-$((${#mixers[@]}-1))] / d / empty=cancel: " choice || true
    if [ -z "$choice" ]; then
        cecho "yellow" "Cancelled."; return
    fi
    if [ "$choice" = "d" ] || [ "$choice" = "D" ]; then
        sudo sed -i -E "s|^[[:space:]]*(//[[:space:]]*)?mixer_control_name[[:space:]]*=.*|//        mixer_control_name = \"PCM\";|" "$CONFIG_FILE"
        cecho "green" "✓ Hardware mixer disabled."
        restart_service
        return
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -lt "${#mixers[@]}" ]; then
        local mixer_control="${mixers[$choice]}"
        sudo sed -i -E "s|^[[:space:]]*(//[[:space:]]*)?mixer_control_name[[:space:]]*=.*|        mixer_control_name = \"$mixer_control\";|" "$CONFIG_FILE"
        sudo sed -i -E "s|^[[:space:]]*(//[[:space:]]*)?mixer_device[[:space:]]*=.*|        mixer_device = \"hw:$card_number\";|" "$CONFIG_FILE"
        cecho "green" "✓ Mixer set to $mixer_control"
        restart_service
    else
        cecho "red" "Invalid selection."
    fi
}

action_change_volume_limits() {
    cecho "blue" "Volume limits are expressed in dB (0 = max, negative attenuates)."
    cecho "blue" "Examples: volume_max_db = 0  |  -10 to cap max output"
    cecho "blue" "          default_airplay_volume = -6  (volume at first connection)"
    echo
    local vmax vdef
    read -p "Enter volume_max_db (empty = skip): " vmax || true
    read -p "Enter default_airplay_volume (empty = skip): " vdef || true
    local changed=0
    if [ -n "$vmax" ]; then
        if [[ "$vmax" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
            sudo sed -i -E "s|^[[:space:]]*(//[[:space:]]*)?volume_max_db[[:space:]]*=.*|        volume_max_db = ${vmax};|" "$CONFIG_FILE"
            cecho "green" "✓ volume_max_db = $vmax"
            changed=1
        else
            cecho "red" "✗ '$vmax' is not a valid number, skipped."
        fi
    fi
    if [ -n "$vdef" ]; then
        if [[ "$vdef" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
            sudo sed -i -E "s|^[[:space:]]*(//[[:space:]]*)?default_airplay_volume[[:space:]]*=.*|        default_airplay_volume = ${vdef};|" "$CONFIG_FILE"
            cecho "green" "✓ default_airplay_volume = $vdef"
            changed=1
        else
            cecho "red" "✗ '$vdef' is not a valid number, skipped."
        fi
    fi
    if [ "$changed" -eq 1 ]; then
        restart_service
    else
        cecho "yellow" "Nothing changed."
    fi
}

action_test_audio() {
    local dev
    dev=$(current_output_device)
    if [ -z "$dev" ]; then
        cecho "red" "No output_device configured."
        return
    fi
    cecho "blue" "Stopping shairport-sync to free the audio device..."
    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    sleep 1
    cecho "yellow" "Playing test sound on $dev..."
    timeout 10 speaker-test -D "$dev" -c 2 -t wav -l 1 || true
    cecho "blue" "Restarting service..."
    sudo systemctl start "$SERVICE_NAME" || true
}

action_view_config() {
    cecho "blue" "Current configuration ($CONFIG_FILE):"
    echo
    cecho "yellow" "  AirPlay name:    $(current_name)"
    cecho "yellow" "  Output device:   $(current_output_device)"
    cecho "yellow" "  Mixer control:   $(current_mixer)"
    echo
    cecho "blue" "Active uncommented settings (first 50 lines):"
    grep -vE '^[[:space:]]*//|^[[:space:]]*$|^[[:space:]]*#' "$CONFIG_FILE" | head -50
}

action_service_status() {
    cecho "blue" "─── shairport-sync ───"
    sudo systemctl status shairport-sync --no-pager -l | head -20 || true
    echo
    cecho "blue" "─── nqptp ───"
    sudo systemctl status nqptp --no-pager -l | head -10 || true
}

action_rebuild() {
    local repair="$SCRIPT_DIR/repair_airplay.sh"
    if [ ! -f "$repair" ]; then
        cecho "red" "❌ repair_airplay.sh not found next to this script."
        return
    fi
    cecho "blue" "Launching rebuild / repair..."
    echo
    bash "$repair" || true
}

# --- Spotify actions ---
action_install_spotify() {
    if spotify_installed; then
        cecho "yellow" "raspotify is already installed."
        read -p "Reinstall / refresh configuration? (y/N): " ans || true
        [[ ! "$ans" =~ ^[Yy]$ ]] && { cecho "yellow" "Cancelled."; return; }
    fi

    local cur_dev cur_name spotify_name
    cur_dev=$(current_output_device)
    cur_name=$(current_name)
    if [ -z "$cur_dev" ]; then
        cecho "red" "❌ No AirPlay output_device configured. Configure AirPlay audio first."
        return
    fi

    echo
    read -p "Spotify device name (Enter for '$cur_name'): " spotify_name || true
    [ -z "$spotify_name" ] && spotify_name="$cur_name"
    spotify_name=$(echo "$spotify_name" | sed 's/[^a-zA-Z0-9 _-]//g')
    if [ -z "$spotify_name" ]; then
        cecho "red" "Name became empty after sanitization. Cancelled."
        return
    fi

    if [ ! -f /etc/apt/sources.list.d/raspotify.list ]; then
        cecho "yellow" "Adding raspotify apt repository..."
        if ! curl -fsSL https://dtcooper.github.io/raspotify/key.asc \
                | sudo tee /usr/share/keyrings/raspotify_key.asc > /dev/null; then
            cecho "red" "❌ Failed to fetch raspotify repository key. Cancelled."
            return
        fi
        sudo chmod 644 /usr/share/keyrings/raspotify_key.asc
        echo 'deb [signed-by=/usr/share/keyrings/raspotify_key.asc] https://dtcooper.github.io/raspotify raspotify main' \
            | sudo tee /etc/apt/sources.list.d/raspotify.list > /dev/null
        sudo apt-get update -qq || true
    fi

    cecho "blue" "Installing raspotify..."
    if ! sudo apt-get install -y raspotify; then
        cecho "red" "❌ Failed to install raspotify."
        return
    fi

    if [ ! -f "$RASPOTIFY_CONF" ]; then
        cecho "red" "❌ $RASPOTIFY_CONF not found after install."
        return
    fi

    write_spotify_managed_block "$spotify_name" "$cur_dev"
    cecho "green" "✓ raspotify configured: '$spotify_name' on $cur_dev"

    # Defensive unmask in case a previous installer run left it masked.
    sudo systemctl unmask raspotify 2>/dev/null || true
    sudo systemctl enable raspotify >/dev/null 2>&1 || true
    restart_spotify
}

action_uninstall_spotify() {
    if ! spotify_installed; then
        cecho "yellow" "raspotify is not installed."
        return
    fi
    read -p "Remove Spotify Connect (raspotify)? (y/N): " ans || true
    [[ ! "$ans" =~ ^[Yy]$ ]] && { cecho "yellow" "Cancelled."; return; }

    sudo systemctl stop raspotify 2>/dev/null || true
    sudo systemctl disable raspotify 2>/dev/null || true
    sudo apt-get remove --purge -y raspotify || true
    sudo rm -f /etc/apt/sources.list.d/raspotify.list
    sudo rm -f /usr/share/keyrings/raspotify_key.asc
    cecho "green" "✓ Spotify Connect removed"
}

action_change_spotify_name() {
    if ! spotify_installed; then
        cecho "yellow" "raspotify is not installed."
        return
    fi
    local cur new_name
    cur=$(spotify_current_name)
    cecho "blue" "Current Spotify name: ${cur:-<not set>}"
    echo
    read -p "Enter new name (empty to cancel): " new_name || true
    [ -z "$new_name" ] && { cecho "yellow" "Cancelled."; return; }
    new_name=$(echo "$new_name" | sed 's/[^a-zA-Z0-9 _-]//g')
    [ -z "$new_name" ] && { cecho "red" "Name became empty after sanitization."; return; }

    local cur_dev
    cur_dev=$(spotify_current_device)
    [ -z "$cur_dev" ] && cur_dev=$(current_output_device)
    write_spotify_managed_block "$new_name" "$cur_dev"
    cecho "green" "✓ Spotify name updated to '$new_name'"
    restart_spotify
}

action_sync_spotify_to_airplay() {
    if ! spotify_installed; then
        cecho "yellow" "raspotify is not installed."
        return
    fi
    local cur_dev cur_spo_name
    cur_dev=$(current_output_device)
    if [ -z "$cur_dev" ]; then
        cecho "red" "No AirPlay output_device configured."
        return
    fi
    cur_spo_name=$(spotify_current_name)
    [ -z "$cur_spo_name" ] && cur_spo_name=$(current_name)
    write_spotify_managed_block "$cur_spo_name" "$cur_dev"
    cecho "green" "✓ Spotify audio device synced to $cur_dev"
    restart_spotify
}

# --- Menu ---
main() {
    require_install
    require_sudo
    while true; do
        echo
        cecho "magenta" "═══════════════════════════════════════════════════════"
        cecho "magenta" "   AirPlay 2 — Modify Existing Installation  v$SCRIPT_VERSION"
        cecho "magenta" "═══════════════════════════════════════════════════════"
        echo
        cecho "yellow" "  AirPlay name:   $(current_name)"
        cecho "yellow" "  Audio device:   $(current_output_device)"
        cecho "yellow" "  Mixer:          $(current_mixer)"
        if spotify_installed; then
            cecho "yellow" "  Spotify:        installed — $(spotify_current_name)"
        else
            cecho "yellow" "  Spotify:        not installed"
        fi
        echo
        cecho "cyan" " AirPlay:"
        echo "   1) Change AirPlay name"
        echo "   2) Change audio output device"
        echo "   3) Change mixer / hardware volume control"
        echo "   4) Change volume limits (volume_max_db, default_airplay_volume)"
        echo "   5) Test audio output"
        echo "   6) View configuration"
        echo "   7) Show service status"
        echo "   8) Restart service"
        echo "   9) Edit configuration file manually (nano)"
        echo "  14) Rebuild / repair (fixes crashes after 'apt upgrade')"
        echo
        cecho "cyan" " Spotify Connect:"
        echo "  10) Install / reconfigure Spotify Connect"
        echo "  11) Change Spotify device name"
        echo "  12) Sync Spotify audio device to AirPlay one"
        echo "  13) Uninstall Spotify Connect"
        echo
        echo "   0) Exit"
        echo
        local choice
        read -p "Choose: " choice || true
        case "$choice" in
            1)  action_change_name ;;
            2)  action_change_audio_device ;;
            3)  action_change_mixer ;;
            4)  action_change_volume_limits ;;
            5)  action_test_audio ;;
            6)  action_view_config ;;
            7)  action_service_status ;;
            8)  restart_service ;;
            9)  sudo nano "$CONFIG_FILE" && restart_service ;;
            10) action_install_spotify ;;
            11) action_change_spotify_name ;;
            12) action_sync_spotify_to_airplay ;;
            13) action_uninstall_spotify ;;
            14) action_rebuild ;;
            0|q|Q|"") cecho "blue" "Bye!"; return 0 ;;
            *)  cecho "red" "Invalid choice." ;;
        esac
    done
}

main "$@"
