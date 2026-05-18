# RaspberryPi-AirPlay-Installer 📻

Turn any Raspberry Pi (Zero 2 W, 3, 4, 5) into a modern, high-quality **AirPlay 2** receiver in just a few minutes. This project automates the entire build of [Shairport-Sync](https://github.com/mikebrady/shairport-sync) + [NQPTP](https://github.com/mikebrady/nqptp) with a set of robust, interactive scripts.

> **If you find this project helpful, please consider giving it a ⭐ star on GitHub!**

---

## ✨ Features

* **🚀 Fast setup** — From a fresh Raspberry Pi OS to a working AirPlay 2 speaker in minutes.
* **🤖 Fully automated** — Handles system update, dependencies, compiling and configuration.
* **✅ Smart pre-flight checks** — Validates internet, disk space, memory and detected hardware before changing anything.
* **🔊 Flexible audio** — Works with **USB DAC**, **audio HAT**, or the **Raspberry Pi's built-in audio** (3.5mm jack / HDMI). All detected devices are listed and labelled `[built-in]` / `[external/DAC]`.
* **🛠️ Idempotent management** — Dedicated scripts to **modify** or **uninstall** an existing installation without reinstalling from scratch.
* **🎚️ Volume control aware** — Auto-selects the best ALSA mixer (`PCM`, `Master`, `Speaker`, ...) and falls back to software volume if no hardware mixer is available.
* **🔁 Rollback on failure** — Backs up configuration files and cleans up on failed installs.
* **📋 Detailed logging** — Every installation writes a timestamped log under `/tmp/airplay_install_*.log`.

---

## 🧰 Hardware Requirements

| Component | Recommended |
| --- | --- |
| Raspberry Pi | Zero 2 W, 3, 4 or 5 |
| MicroSD card | Quality card, ≥ 8 GB |
| Power supply | Official PSU for your Pi |
| Audio output | USB DAC, audio HAT **or** built-in 3.5mm / HDMI |

> The older Pi 1 / Pi Zero W are not officially supported — they typically lack the CPU headroom for AirPlay 2.

---

## 📦 What's in the box

All scripts live under `RaspberryPi-AirPlay-Installer-Scripts/`:

| Script | Purpose |
| --- | --- |
| `pre_check_airplay_on_pi.sh` | Read-only system check before installing. |
| `install_airplay_v3.sh` | Main installer: deps, build, service, config. |
| `modify_airplay.sh` | Edit an existing install (name, audio device, mixer, volume...). |
| `uninstall_airplay.sh` | Cleanly remove Shairport-Sync, NQPTP, services and config. |
| `airplay_manager.sh` | Unified menu that dispatches to the three scripts above. |

---

## 🚀 Quick Start

After flashing **Raspberry Pi OS** (Lite is fine) and connecting via SSH, you have two options.

### Option A — Run from this repo (recommended for development)

```bash
git clone https://github.com/Techposts/RaspberryPi-AirPlay-Installer.git
cd RaspberryPi-AirPlay-Installer/RaspberryPi-AirPlay-Installer-Scripts
bash airplay_manager.sh         # unified menu
```

The menu lets you install, modify or uninstall, and tail live service logs.

### Option B — One-shot install from upstream

```bash
curl -sSL https://raw.githubusercontent.com/Techposts/RaspberryPi-AirPlay-Installer/main/RaspberryPi-AirPlay-Installer-Scripts/pre_check_airplay_on_pi.sh | bash
curl -sSL https://raw.githubusercontent.com/Techposts/RaspberryPi-AirPlay-Installer/main/RaspberryPi-AirPlay-Installer-Scripts/install_airplay_v3.sh | bash
```

The installer is interactive: it will ask you to pick the audio device, give your AirPlay endpoint a name and decide on Wi-Fi power management. When it's done, the Pi will offer to reboot and your speaker is ready.

> **Do not run any of these scripts with `sudo`.** They invoke `sudo` only where needed and will refuse to start as `root`.

---

## 🎛️ Modifying an existing installation

Need to rename the speaker, change the audio output or adjust volume limits? You don't have to reinstall.

```bash
bash modify_airplay.sh
```

The interactive menu provides:

1. Change AirPlay name
2. Change audio output device (USB DAC / HAT / built-in)
3. Change mixer / hardware volume control (or disable it)
4. Change volume limits (`volume_max_db`, `default_airplay_volume`)
5. Test audio output
6. View current configuration
7. Show service status
8. Restart service
9. Edit `/etc/shairport-sync.conf` manually (+ auto restart)

All changes are written to `/etc/shairport-sync.conf` and the service is restarted automatically.

---

## 🧹 Uninstalling

```bash
bash uninstall_airplay.sh
```

Removes:

* `shairport-sync` and `nqptp` binaries
* `/etc/shairport-sync.conf` and sample
* systemd units (`shairport-sync.service`, `nqptp.service`)
* The `shairport-sync` user and group
* UFW firewall rules added during install (`5353/udp`, `319/udp`, `320/udp`, `7000/tcp`)

A backup of the current config is saved under `/tmp/airplay_uninstall_backup_<timestamp>/` before anything is deleted.

> APT build dependencies (`libsoxr-dev`, `libplist-dev`, ...) are intentionally **not** removed — other software on your system may rely on them. The uninstaller prints the `apt-get` command to remove them manually if you want a fully clean state.

---

## 🐛 Troubleshooting

**`configure: error: plistutil can not be found`** (Debian 13 "Trixie" / Pi OS Bookworm successor)

On recent releases the `plistutil` binary moved from `libplist-dev` to a separate package `libplist-utils`. The installer in this repo already pulls it in. If you hit this on an older copy:

```bash
sudo apt-get install -y libplist-utils
bash install_airplay_v3.sh
```

**The Pi doesn't appear in the AirPlay picker**

* Make sure iPhone/iPad and Pi are on the **same Wi-Fi network and same subnet**.
* Check that `avahi-daemon` is running: `systemctl status avahi-daemon`.
* Tail the service: `sudo journalctl -u shairport-sync -f`.

**Audio stutters / drops out**

* Disable Wi-Fi power management: `sudo raspi-config` → Performance → Wireless LAN → Power Management → Disable.
* On Pi Zero 2, prefer a wired ethernet adapter or stay close to the access point.

**Useful one-liners**

```bash
sudo systemctl status shairport-sync       # service health
sudo journalctl -u shairport-sync -f       # live logs
sudo nano /etc/shairport-sync.conf         # manual edit (then restart)
sudo systemctl restart shairport-sync
```

---

## ⚙️ How it works

1. **`pre_check_airplay_on_pi.sh`** — non-invasive system check (no changes made).
2. **`install_airplay_v3.sh`** — installs build deps, clones and compiles `nqptp` and `shairport-sync` with `--with-airplay-2`, writes `/etc/shairport-sync.conf`, creates a systemd service and a dedicated user, configures UFW if active.
3. **`modify_airplay.sh`** — edits `/etc/shairport-sync.conf` in place via targeted `sed` rules and restarts the service.
4. **`uninstall_airplay.sh`** — reverses everything the installer did, in dependency-safe order.
5. **`airplay_manager.sh`** — thin wrapper that picks the right script based on what's currently installed.

---

## 🙏 Credits

* [Mike Brady](https://github.com/mikebrady) — author of Shairport-Sync and NQPTP, the upstream projects that make all of this possible.
* Original installer scripts: [Techposts/RaspberryPi-AirPlay-Installer](https://github.com/Techposts/RaspberryPi-AirPlay-Installer).

---

## 📜 License

This project is licensed under the MIT License. See the `LICENSE` file for details.
