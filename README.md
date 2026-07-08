# Mac Mini Homelab Setup Guide

## Overview

This guide sets up the following services on a 2018 Mac Mini running Ubuntu 26.04 LTS (Resolute), booting the 25.10 "questing" t2 kernel — see [Part 18](#upgrading-the-ubuntu-release-t2-aware) for why the kernel stays pinned.

- **Jellyfin** — Media server with Intel QuickSync hardware transcoding
- **Plex** — Second media server (existing plex.tv account) with QuickSync transcoding
- **AdGuard Home** — Network-wide DNS ad blocking
- **Sunshine** — Game streaming host for Moonlight clients
- **Steam** — Light gaming on the Mac Mini
- **RetroArch** — Retro game emulation
- **Prowlarr** — Indexer manager
- **Radarr** — Movie collection manager
- **Sonarr** — TV collection manager
- **Bazarr** — Automatic subtitle downloading
- **Profilarr** — Quality profile sync from Dictionarry
- **Seerr** — Media request UI for Jellyfin users
- **Flaresolverr** — Cloudflare bypass proxy for Prowlarr indexers
- **qBittorrent** — Torrent client (BitTorrent engine)
- **Flood** — Web UI for qBittorrent
- **Unpackerr** — Auto-extracts `.rar`/`.zip` releases so Radarr/Sonarr can import them
- **Immich** — Self-hosted photo/video library with mobile backup
- **RomM** — ROM manager and in-browser emulator
- **Portainer** — Docker management UI
- **Nginx Proxy Manager** — Reverse proxy with Let's Encrypt
- **Scrutiny** — Drive S.M.A.R.T. monitoring
- **Watchtower** — Automatic container updates
- **Uptime Kuma** — Uptime monitoring
- **Glance** — Homelab dashboard
- **Forgejo** — Self-hosted Git forge
- **DuckDNS** — Dynamic DNS for external access

---

## Quick Reference

### Port Map

| Service | Host Port | Notes |
|---|---|---|
| Glance Dashboard | 8080 | Main homelab UI |
| Jellyfin | host network | Uses host networking for DLNA |
| Plex | host network (32400) | Host networking for GDM discovery + remote access |
| AdGuard (setup) | 3000 | First-run wizard only |
| AdGuard (web UI) | 3001 | After initial setup |
| AdGuard (DNS) | 53 TCP/UDP | Set this as your router's DNS |
| Prowlarr | 9696 | |
| Radarr | 7878 | |
| Sonarr | 8989 | |
| Bazarr | 6767 | |
| Seerr | 5055 | Formerly Jellyseerr |
| Profilarr | 6868 | |
| Flaresolverr | 8191 | Internal proxy only |
| qBittorrent | 8181 | Built-in WebUI; internal container port is 8080 |
| Flood | 3004 | Main torrent UI (front-end for qBittorrent); internal container port is 3000 |
| Unpackerr | — | Background archive extractor for the Arr stack; no web UI |
| Immich | 2283 | |
| RomM | 7070 | |
| Portainer | 9000 | |
| Nginx Proxy Manager (admin) | 81 | |
| Nginx Proxy Manager (http) | 80 | |
| Nginx Proxy Manager (https) | 443 | |
| Scrutiny | 8085 | Internal container port is 8080 |
| Uptime Kuma | 3002 | Internal container port is 3001 |
| Forgejo (web) | 3003 | Internal container port is 3000 |
| Forgejo (git SSH) | 2222 | Maps to container 22; host 22 is the OS sshd |
| DuckDNS | — | No ports, DDNS updater only |
| Sunshine web UI | 47990 HTTPS | Runs on host, not Docker |
| Sunshine streaming | 47984, 47989 TCP | Moonlight ports |
| Sunshine streaming | 47998–48000, 48010 UDP | Moonlight ports |

### Key Details

Network info is stored in 1Password after running `setup_script.sh`. Retrieve with:

```bash
op item get "Marlboro NAS - Network" --vault Private
```

- **Static IP:** `op item get "Marlboro NAS - Network" --vault Private --fields static-ip`
- **Router/Gateway:** `<gateway-ip>`
- **Network interface:** `<network-interface>`
- **Tailscale hostname:** `op item get "Marlboro NAS - Network" --vault Private --fields tailscale-hostname`
- **Tailscale IP:** `op item get "Marlboro NAS - Network" --vault Private --fields tailscale-ip`
- **Username:** `<your-username>`
- **Homelab directory:** `~/marlboro`

### Customization Checklist

**Required before first run:**
- Run `setup_script.sh` — handles all credential generation and 1Password storage
- Update `PUID`/`PGID` (currently `1000`) if your user differs — check with `id`
- IGDB and Screenscraper API keys must exist in 1Password (pulled by `setup_script.sh`)

**Recommended:**
- Router DHCP DNS set to `<server-ip>` ✅ done
- Change Nginx Proxy Manager default credentials immediately after first launch

### Key Caveats

**Now on Ubuntu 26.04 LTS, booting the 25.10 "questing" t2 kernel.** The 26.04 upgrade on this T2 Mac was *not* a plain `sudo do-release-upgrade` — the upgrader disables the t2linux kernel repo, which can orphan the T2 kernel (it gets offered for removal) or leave the machine booting a stock kernel with no T2 audio/Wi-Fi/Bluetooth. The 26.04 "resolute" kernel additionally hangs at boot on this box, so GRUB stays pinned to the questing kernel (a working steady state — *not* a failed upgrade). Full T2-aware procedure + the boot-hang details in [Part 18 → Upgrading the Ubuntu Release](#upgrading-the-ubuntu-release-t2-aware).

**Jellyfin uses host networking.** Reference it from other containers via `http://host.docker.internal:8096` or `http://<server-ip>:8096`, not `http://jellyfin:8096`.

**Plex also uses host networking** (for GDM discovery and direct remote access on `:32400`). Reference it from other containers via `http://host.docker.internal:32400` or `http://<server-ip>:32400`, not `http://plex:32400`. Two consequences of running both media servers in host mode: (1) they both want UDP `1900` for DLNA/SSDP — leave Plex's DLNA disabled (the default) so it doesn't collide with Jellyfin; (2) Plex's QuickSync hardware transcoding requires an **active Plex Pass** — this account's pass **expires November 2026**, after which Plex transcodes on CPU (Jellyfin's QSV is unaffected). The `PLEX_CLAIM` token only links the server to the account on first start; see [Part 16.6](#part-166-plex-media-server).

**`host.docker.internal` requires `extra_hosts` on Linux.** Added to Radarr, Sonarr, Bazarr, Profilarr, Seerr, and Coolify in the compose file.

**Docker needs explicit DNS and uses external data root.** `/etc/docker/daemon.json` must contain `{"data-root": "/mnt/tank/docker", "dns": ["1.1.1.1", "8.8.8.8"]}`.

**AdGuard conflicts with systemd-resolved.** Fixed via `/etc/systemd/resolved.conf.d/adguard.conf` with `DNSStubListener=no`.

**qBittorrent WebUI requires `WebUI\HostHeaderValidation=false`** and `WebUI\Port=8080` in `qBittorrent.conf`. Disabling host-header validation is also what lets the Flood container reach the Web API as `qbittorrent:8080`.

**Flood is a separate container, not a qBittorrent WebUI mod.** It replaces the old VueTorrent `DOCKER_MODS` entry. Flood runs with `--auth none` (no Flood-level login — the stack is gated at the network layer) and connects to qBittorrent via `FLOOD_OPTION_qburl=http://qbittorrent:8080`, seeded with `QBIT_PASSWORD` (the same value `setup_script.sh` writes into `qBittorrent.conf`). qBittorrent's own WebUI still works at `:8181`. To require a login on Flood instead, set `FLOOD_OPTION_auth=default`, drop the `qburl`/`qbuser`/`qbpass` vars, and configure the connection in Flood's first-run wizard.

**Watchtower requires `DOCKER_API_VERSION=1.55`** to match the 26.04 host Docker engine. This pin tracks the host engine's API version, so revisit it after any OS/engine upgrade — match `docker version --format '{{.Server.APIVersion}}'`.

**Watchtower watches every container (no `WATCHTOWER_LABEL_ENABLE`) and updates nightly at 4 AM.** That's fine for stateless services, but data-bearing apps that ship breaking DB migrations must not float — an unattended major bump can crash-loop or corrupt on-disk data (this bit Immich: a `:release` jump to v3 dropped pgvecto.rs while the DB image stayed put). Policy:
- **Pin the tag** so Watchtower only patches within a safe line: `jellyfin:10.11`, `mariadb:12` (romm-db), `rommapp/romm:4`, `jc21/nginx-proxy-manager:2`, `codeberg.org/forgejo/forgejo:11`, `postgres:15-alpine`/`14-…` (coolify-db, immich-postgres). Bump these deliberately after reading release notes; **back up the DB first** for anything stateful.
- **Fence with `com.centurylinklabs.watchtower.enable=false`** where there's no clean version tag or the app self-updates: Immich (`immich-server`/`immich-machine-learning`/`immich-postgres`, upgraded by hand in lockstep) and Coolify (`coolify`/`coolify-realtime`, update via Coolify's own UI).

**Sunshine runs as the native Ubuntu `.deb`** (not Docker), started by `systemctl --user` inside a **sway** (wlroots) session, capturing the connected display with `capture=kms`. Sway is required: GNOME/Mutter Wayland is uncapturable (empty KMS monitor list, no `wlr-screencopy`) and questing ships no GNOME-on-Xorg session, so `capture=x11` is a dead end. It streams **H.264 only** — this Mac Mini's Intel UHD 630 can decode HEVC but has no HEVC/AV1 *encode* entrypoint (same hardware limit as the Jellyfin note). The whole host is provisioned idempotently by `setup_script.sh` (its `configure_sunshine` step, Part 5/7) — including seeding the web-UI login from 1Password; only Moonlight pairing is manual (Part 7).

**Scrutiny monitors all 4 drives** (`/dev/sda`–`/dev/sdd`) via device passthrough. Its **Status Threshold is set to "Smart" (not "Both")** — Scrutiny's observed-failure-rate heuristic produces false positives on these Seagate ST8000DM004 drives (e.g. it fails `Spin_Up_Time` for an "observed failure rate >10%" even though the attribute's raw value is 0 and the drive's own SMART self-assessment passes). Smart-only makes the dashboard badge follow the drive's actual SMART verdict. This setting lives in the app-managed `scrutiny.db` (not tracked in git), so **re-apply it after a fresh setup** via Settings → "Metric Status Threshold" → *Smart*, or the API:

```bash
# status_threshold: 1=Smart, 2=Scrutiny, 3=Both — dashboard renders device_status & threshold
curl -s -X POST http://localhost:8085/api/settings -H "Content-Type: application/json" \
  -d '{"theme":"system","layout":"material","dashboard_display":"name","dashboard_sort":"status","temperature_unit":"celsius","file_size_si_units":false,"line_stroke":"smooth","powered_on_hours_unit":"humanize","collector":{"discard_sct_temp_history":false},"metrics":{"notify_level":2,"status_filter_attributes":0,"status_threshold":1,"repeat_notifications":true}}'
```

**Seerr config lives in `./services/jellyseerr/config`** — the directory was kept from the Jellyseerr migration.

**Wi-Fi needs Apple firmware extracted from macOS.** The BCM4364 (`lanai`) chip stays dark until firmware lands in `/lib/firmware/brcm` — see [Part 1 → 1.8 Enable Wi-Fi](#18-enable-wi-fi-broadcom-firmware). A reusable `~/t2-wifi-bt-firmware.tar` backup skips the macOS re-download.

---

# Phase 1: No Drives Required

---

## Part 1: Install Ubuntu on the 2018 Mac Mini (T2)

### 1.1 Prepare macOS

1. Hold **Cmd+R** at startup → **Startup Security Utility**
2. Set security to **No Security**
3. Enable **Allow booting from external media**

### 1.2 Flash the t2linux Ubuntu ISO

Download from https://github.com/t2linux/T2-Ubuntu/releases. Flash **directly into a USB-A port — no hub**:

```bash
diskutil unmountDisk /dev/diskN
sudo dd if=ubuntu-t2.iso of=/dev/rdiskN bs=4m conv=sync
```

Boot from USB — hold **Option** at startup.

### 1.3 Install Ubuntu

- Connect via **ethernet**
- Use **manual partitioning ("Something else")**:
  - Keep EFI partition (~300MB) — EFI System Partition, do not format
  - Delete macOS partition
  - Create 8GB swap
  - Create ext4 root (`/`) with remaining space

### 1.4 Strip Desktop Environment (optional)

```bash
sudo apt remove --purge ubuntu-desktop gnome* -y
sudo apt autoremove -y
sudo systemctl set-default multi-user.target
sudo reboot
```

### 1.5 Set Static IP

Remove all conflicting netplan files first:

```bash
ls /etc/netplan/
sudo rm /etc/netplan/00-installer-config.yaml
sudo rm /etc/netplan/01-network-manager-all.yaml
sudo rm /etc/netplan/90-NM-*.yaml  # adjust to match actual filenames
```

Create the config:

```bash
sudo vim /etc/netplan/01-netcfg.yaml
```

```yaml
network:
  version: 2
  ethernets:
    <network-interface>:
      dhcp4: no
      addresses: [<server-ip>/24]
      routes:
        - to: default
          via: <gateway-ip>
      nameservers:
        addresses: [1.1.1.1, 8.8.8.8]
```

```bash
sudo chmod 600 /etc/netplan/01-netcfg.yaml
sudo systemctl enable systemd-networkd
sudo systemctl start systemd-networkd
sudo netplan apply
```

Verify:

```bash
ip addr show <network-interface>   # should show <server-ip> only
ip route              # single default route via <gateway-ip>
```

### 1.6 Install Intel VAAPI Drivers

```bash
sudo apt install intel-media-va-driver vainfo
vainfo
```

### 1.7 Configure Docker DNS

```bash
sudo mkdir -p /etc/docker
sudo vim /etc/docker/daemon.json
```

```json
{
  "data-root": "/mnt/tank/docker",
  "dns": ["1.1.1.1", "8.8.8.8"]
}
```

### 1.8 Enable Wi-Fi (Broadcom firmware)

The BCM4364 Wi-Fi chip (board codename `lanai`) needs proprietary Apple firmware that isn't in `linux-firmware`. Without it, `brcmfmac` loads but no `wlan` interface appears — `nmcli radio` shows `WIFI-HW: missing` and `dmesg` shows `brcmfmac4364b2-pcie...bin failed with error -2`. (Wired works regardless, so this is optional for a headless server.)

**If you kept the backup tar from a prior setup**, that's all you need:

```bash
sudo tar -xC /lib/firmware/brcm -f ~/t2-wifi-bt-firmware.tar
sudo modprobe -r brcmfmac && sudo modprobe brcmfmac
```

**From scratch** (single-boot, no macOS partition): extract the firmware from a macOS recovery image. The `apple-firmware-script` package provides `get-apple-firmware`, but its `get_from_online` path has two bugs on Linux — it runs `losetup -f` without `sudo`, and its `rename_only` subcommand only exists in the macOS branch — so drive it manually:

```bash
sudo apt install apple-firmware-script dmg2img

# 1. Download a macOS Sonoma recovery image (~750 MB) and convert to a raw img
mkdir -p ~/fwtmp && cd ~/fwtmp
curl -sO https://raw.githubusercontent.com/kholia/OSX-KVM/master/fetch-macOS-v2.py
python3 fetch-macOS-v2.py --shortname sonoma   # --shortname keeps it non-interactive
dmg2img -s BaseSystem.dmg fw.img

# 2. Loop-mount it (note the sudo on losetup -f that the upstream script omits)
M=$(mktemp -d); L=$(sudo losetup -fP --show fw.img)
sudo mount -o ro "$L" "$M" 2>/dev/null || sudo mount -o ro "${L}p1" "$M"

# 3. Extract + rename with the script's embedded python (rename_only is macOS-only, so call it directly)
sed -n "/python3 - \"\$@\" <<'EOF'/,/^EOF\$/p" /usr/bin/get-apple-firmware | sed '1d;$d' > /tmp/rename_fw.py
python3 /tmp/rename_fw.py "$M/usr/share/firmware" ~/t2-wifi-bt-firmware.tar

# 4. Install, clean up, reload
sudo tar -xC /lib/firmware/brcm -f ~/t2-wifi-bt-firmware.tar
sudo umount "$M"; sudo losetup -d "$L"; cd ~ && rm -rf ~/fwtmp
sudo modprobe -r brcmfmac && sudo modprobe brcmfmac
```

Verify and connect:

```bash
nmcli radio                                      # WIFI-HW should now read "enabled"
nmcli device wifi list
nmcli device wifi connect "SSID" password "PASSWORD"
```

> **Keep `~/t2-wifi-bt-firmware.tar` (12 MB).** Reinstalling later is just step 4 again — no macOS download needed. Firmware in `/lib/firmware/brcm` persists across reboots and kernel updates, so this is a one-time setup. `sudo` here needs a real TTY (it can't prompt over a non-interactive pipe).

---

## Part 2: Install Docker

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
```

Verify:

```bash
docker run hello-world
docker compose version
```

---

## Part 3: Install 1Password CLI

```bash
curl -sS https://downloads.1password.com/linux/keys/1password.asc | \
  sudo gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] \
  https://downloads.1password.com/linux/debian/$(dpkg --print-architecture) stable main" | \
  sudo tee /etc/apt/sources.list.d/1password.list

sudo apt update && sudo apt install 1password-cli jq
op --version
op signin
```

Integrate with desktop app: **Settings → Developer → Integrate with 1Password CLI**.

```bash
# List marlboro-nas credentials
op item list --tags marlboro-nas

# Retrieve a password
op item get "Marlboro NAS - Immich DB" --fields password --reveal
```

---

## Part 4: Directory Structure

```bash
mkdir -p ~/marlboro/services/{jellyfin,prowlarr,radarr,sonarr,bazarr,profilarr,jellyseerr,qbittorrent,portainer,nginx-proxy-manager,uptime-kuma}/config
mkdir -p ~/marlboro/services/adguard/{work,conf}
mkdir -p ~/marlboro/services/immich/{model-cache,postgres}
mkdir -p ~/marlboro/services/romm/{db,resources,assets,config}
mkdir -p ~/marlboro/services/nginx-proxy-manager/letsencrypt
mkdir -p ~/marlboro/services/scrutiny/{config,influxdb}
mkdir -p ~/marlboro/services/glance/config
mkdir -p ~/marlboro/services/flood/data   # Flood runs as 1000:1000; this dir must be owned by your user
```

---

## Part 5: Run the Setup Script

```bash
chmod +x ~/marlboro/setup_script.sh
cd ~/marlboro
./setup_script.sh
```

Generates credentials, stores everything in 1Password tagged `marlboro-nas`, pulls all values, and writes `~/marlboro/.env`. It also does the host-level, non-container setup for this pre-compose phase: media dirs + ownership, the docker wait-for-tank drop-in, and **provisioning the Sunshine stream host** (`configure_sunshine` — sway autologin + KMS capture; see Part 7). Re-run anytime to sync credentials + converge host state.

> If this is a first run, the Sunshine step may print **`REBOOT REQUIRED`** (it added you to the `input` group / switched the login session to sway). Reboot before continuing, then come back for `docker compose up -d`.

To start the stack:

```bash
docker compose up -d
```

Then reconcile all in-app settings from the repo — one idempotent script (safe
to re-run; it converges and never clobbers manual edits):

```bash
./setup_services.sh    # qBit, Sonarr/Radarr, Prowlarr, AdGuard, NPM proxy hosts + certs
```

Run it once the containers are up. It configures everything that has an
API/config surface (see Part 10 + Part 19); the handful of steps that require a
first-run wizard or an external account stay manual and are called out below.
Re-run it any time you change a tracked setting (e.g. edit
`services/<app>/settings/*.json`, or the `NPM_HOSTS` list in the script) to push
it back.

---

## Part 6: Glance Configuration

The Glance dashboard config lives at `services/glance/config/glance.yml` and is tracked in this repo (the rest of `services/` is gitignored — see `.gitignore` for the exception). Edit the file, commit, push/pull — the live container reads it directly.

Several widgets pull from external APIs and need credentials in 1Password (vault: Private, tag: marlboro-nas):

| 1Password Item | Field | Where to get it |
|---|---|---|
| Marlboro NAS - Sonarr | `api_key` | Sonarr → Settings → General → Security → API Key |
| Marlboro NAS - Radarr | `api_key` | Radarr → Settings → General → Security → API Key |
| Marlboro NAS - Tailscale | `api_key` | [tailscale admin → Keys → API access tokens](https://login.tailscale.com/admin/settings/keys) |

`TAILSCALE_HOSTNAME` is auto-populated into `Marlboro NAS - Network` by `setup_script.sh` (pulled from `tailscale status`). `setup_script.sh` writes all four values into `.env`, and `docker-compose.yml` passes them into the Glance container's environment.

If any 1Password item is missing, `setup_script.sh` prints a warning and that widget renders blank until you add the key.

---

## Part 7: Install Sunshine (on host, not Docker)

Sunshine streams the connected display (`DP-3`, a 4K ASUS) to Moonlight clients under a
**sway** (wlroots) session, using **KMS capture** + Intel VAAPI. The GPU (UHD 630)
encodes **H.264 only** (no HEVC/AV1 encode), so streams are H.264.

> **Why sway, not GNOME/Xorg?** GNOME/Mutter Wayland can't be KMS-captured — the KMS
> monitor list comes back empty (Mutter holds DRM master) and GNOME doesn't implement
> `wlr-screencopy`. Ubuntu questing also ships **no GNOME-on-Xorg** session, so
> `capture=x11` is a dead end here. sway (wlroots) exposes the framebuffer to KMS
> capture and is the working path.

**The host is provisioned by `setup_script.sh` (Part 5)** — its `configure_sunshine`
step, run in the same pre-compose phase (see the repo's scripting-over-docs rule).
It's idempotent and does everything scriptable: installs the pinned `.deb` +
`sway`/`swayidle`/`retroarch`, sets GDM to autologin the sway session, adds you to the
`input` group (uinput = virtual gamepad/keyboard/mouse), writes the sway config +
`sway-session.target` (which launches Sunshine — `graphical-session.target` refuses
manual start), the shared-monitor power scripts (7.6), `sunshine.conf` (`capture=kms`,
`encoder=vaapi`, auto-detected `csrf_allowed_origins`), a starter `apps.json`, and seeds
the web-UI login from the `Marlboro NAS - Sunshine` 1Password item (7.3). Only Moonlight
pairing is manual.

### 7.1 Provision + reboot

Already done by `./setup_script.sh` in Part 5 — there's no separate Sunshine command.
If that run added you to `input` or switched the session to sway, it prints
`REBOOT REQUIRED`; apply it before the wizard:

```bash
sudo reboot              # applies the sway autologin session + the 'input' group
```

### 7.2 Verify after reboot

```bash
systemctl --user is-active app-dev.lizardbyte.app.Sunshine.service swayidle.service   # -> active / active
journalctl --user -u app-dev.lizardbyte.app.Sunshine.service -b | grep -E 'Screencasting with KMS|Found H.264'
```

### 7.3 Web-UI login (seeded from 1Password)

The login is **seeded from the `Marlboro NAS - Sunshine` 1Password item** by
`setup_script.sh` on first run — it runs `sunshine --creds`, which hashes the password
itself (the scheme is internal/version-specific, so we don't reproduce it) and merges,
preserving Moonlight pairings. So create that item with your desired username/password
*before* Part 5 (**upsert** — don't blind-`create`; duplicate titles break credential
pulls, which bit this setup once):

```bash
op item get "Marlboro NAS - Sunshine" --vault Private &>/dev/null \
  || op item create --category Login --title "Marlboro NAS - Sunshine" \
       --vault Private --tags marlboro-nas \
       --url "https://$(tailscale ip -4 | head -1):47990" \
       username=admin password=your-chosen-password
```

Then open `https://<tailscale-ip>:47990` (accept the self-signed cert) and log in with
those creds. The browser Origin must be in `csrf_allowed_origins` or login fails with a
CSRF error — the script auto-adds every LAN + tailscale IP (`:47990`); add others to
`sunshine.conf` if you reach it by a hostname/other IP.

> Seeding is **first-run only** (skipped once creds exist, so re-runs don't reset the
> salt or bounce the service). To rotate the password: update the 1Password item, delete
> the top-level `username`/`salt`/`password` from `~/.config/sunshine/sunshine_state.json`
> (keep `root` to preserve pairings), and re-run `setup_script.sh` — or just change it in
> the web UI.

### 7.4 Pair a Moonlight client

Preferred path is **Tailscale** — `marlboro` and your client devices
(`bcalegari-mac`, `bcalegari-iphone`, `bcalegari-pc`) are already on the tailnet, so no
port forwarding is needed.

1. In Moonlight, add the host by its Tailscale IP (`tailscale ip -4` on the server).
2. Moonlight shows a PIN → enter it in the Sunshine web UI **PIN** page.
3. In Moonlight's stream settings, set the codec to **H.264** (this GPU can't encode HEVC).

Apps `Desktop`, `Steam Big Picture`, and `RetroArch` are seeded in `apps.json` (RetroArch
uses `cmd`+`auto-detach:false`, so it **quits when the stream ends**); add/edit more in
the web UI (**Applications**).

### 7.5 Remote streaming without Tailscale (optional)

Only if a client isn't on the tailnet: forward these to `<server-ip>` on the TP-Link
BE3600 (**Advanced → NAT Forwarding → Virtual Servers**). If `ufw` is active, also
`sudo ufw allow` them.

| Port | Protocol | Service |
|---|---|---|
| 47984 | TCP | Moonlight streaming |
| 47989 | TCP | Moonlight streaming |
| 47990 | TCP | Sunshine web UI |
| 47998–48000 | UDP | Moonlight streaming |
| 48010 | UDP | Moonlight streaming |

### 7.6 Shared-monitor sleep (scripted)

The `DP-3` display is shared with other machines, so it must sleep when the Mac is idle —
but KMS capture needs a **lit** connector during a stream. `setup_script.sh`
(`configure_sunshine`) wires both sides automatically:

- `swayidle.service` blanks the output after `IDLE_TIMEOUT` (default 300s) idle via
  `~/.config/sunshine/display.sh` (`swaymsg 'output * power off'`).
- Sunshine's `global_prep_cmd` runs `display.sh stream-start` on stream start (force the
  output on + pause the blanker) and `display.sh stream-end` on stream end (re-arm the
  blanker → sleeps again if idle).

Net: idle → monitor sleeps; streaming → forced on and won't blank; local input → wakes and
stays on. Change the timeout via `IDLE_TIMEOUT` in the script (then re-run it) or edit
`~/.config/systemd/user/swayidle.service`. (This replaces the old X11-capture "black screen
when the monitor sleeps" EDID workaround — KMS + wake-on-stream doesn't have that failure.)

---

## Part 8: Install Steam & RetroArch

```bash
sudo apt install steam-installer retroarch
```

---

## Part 9: AdGuard Setup

### 9.1 Fix systemd-resolved Conflict

```bash
sudo mkdir -p /etc/systemd/resolved.conf.d
sudo vim /etc/systemd/resolved.conf.d/adguard.conf
```

```ini
[Resolve]
DNS=127.0.0.1
DNSStubListener=no
```

```bash
sudo systemctl restart systemd-resolved
sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
```

### 9.2 Start the Stack

```bash
cd ~/marlboro
docker compose up -d
docker compose ps
```

> **If headless:** all web UIs accessible from other devices at `<server-ip>`. SSH back in for `op item create` commands after setting passwords.

### 9.3 AdGuard First-run

Navigate to `http://<server-ip>:3000` and complete the setup wizard.

If AdGuard binds to port 80 instead of 3001 after setup:

```bash
docker compose stop adguard
vim ~/marlboro/services/adguard/conf/AdGuardHome.yaml
# Change: address: 0.0.0.0:80  →  address: 0.0.0.0:3001
docker compose up -d adguard
```

Store credentials:

```bash
op item create \
  --category Login \
  --title "Marlboro NAS - AdGuard" \
  --vault Private \
  --tags marlboro-nas \
  --url http://<server-ip>:3001 \
  username=your-username \
  password=your-password
```

### 9.4 Point Router at AdGuard

On TP-Link BE3600: **Advanced → Network → DHCP Server → Primary DNS** → `<server-ip>`

### 9.5 Recommended AdGuard Settings

Applied by `setup_services.sh` (reconciles `AdGuardHome.yaml` via sudo, then
restarts AdGuard — idempotent). It ensures:

- Upstream DNS includes `https://dns.cloudflare.com/dns-query`
- Rate limit `300`
- DNS blocklists: EasyList, EasyPrivacy, Steven Black's Hosts

The yaml is root-owned and AdGuard has no stored API creds here, so this step
needs passwordless sudo; without it, `setup_services.sh` prints these three
settings to apply by hand in **Settings → DNS settings** / **Filters**.

---

## Part 10: Wire Up the Arr Stack

### 10.1 qBittorrent

**Scripted.** WebUI credentials + `WebUI\HostHeaderValidation=false` are seeded
into `qBittorrent.conf` by `setup_script.sh` (pre-compose, from 1Password) — no
temp-password dance. Runtime prefs are applied by `setup_services.sh`
(post-compose): save path `/data/downloads/complete`, incomplete
`/data/downloads/incomplete`, and the seeding share limits below. WebUI at
`http://<server-ip>:8181`.

> **Changing the password:** `op item edit "Marlboro NAS - qBittorrent"
> password=...`, re-run `setup_script.sh` to reseed the conf, then
> `docker compose up -d --force-recreate flood` so Flood picks up the new value.

**Seeding / share limits (auto-remove completed torrents)** — applied by
`setup_services.sh` to match the tracker rule *seed to ratio 1:1 or 336 h,
whichever first*:

- ratio `1.0` (`max_ratio=1`) and seed time `20160` min / 336 h (`max_seeding_time=20160`)
- action **remove torrent + delete files** (`max_ratio_act=2`); triggers on whichever hits first

Deleting files is safe because imports are **hardlinks** (storage note below):
the seeding file in `/data/downloads` and the library file in `/data/media` are
two names for the **same inode** — removing the torrent's copy just unlinks one
name; the library name (and data) remain.

> **Storage — single mount + hardlinks:** qBittorrent, Sonarr, Radarr and Unpackerr
> all share **one** bind mount `/mnt/tank:/data` (paths `/data/downloads`,
> `/data/media/tv`, `/data/media/movies`). Because downloads and library sit under a
> single mount, Sonarr/Radarr **hardlink** on import (`copyUsingHardlinks=true`)
> instead of copying, so an imported file is **not** stored twice. Requirement: the
> `*arr` root folders must be under `/data/media` and the download client path under
> `/data/downloads` — if any service is mounted so downloads and library land on
> different mount points, `link()` fails `EXDEV` and it silently falls back to copy.
> (Flood keeps its own `/downloads` mount — it's only a UI and does no imports.)

**Flood (torrent web UI):**

Flood replaces the old VueTorrent alternative-WebUI mod. It runs as its own
container and reaches qBittorrent over the Web API — there's nothing to install
into qBittorrent and no manual wiring:

- Browse to `http://<server-ip>:3004`. With `FLOOD_OPTION_auth=none` there's no
  Flood login; it connects to qBittorrent automatically using `QBIT_PASSWORD`
  from `.env`, so you should see qBittorrent's torrents immediately.
- qBittorrent's built-in WebUI stays available at `http://<server-ip>:8181`.

If you previously enabled VueTorrent, remove its lines from `qBittorrent.conf`
so the built-in WebUI loads again, then recreate the container:

```bash
docker compose stop qbittorrent
sed -i '/^WebUI\\AlternativeUIEnabled=/d; /^WebUI\\RootFolder=/d' \
  ~/marlboro/services/qbittorrent/config/qBittorrent/qBittorrent.conf
docker compose up -d qbittorrent flood
```

### 10.2 Prowlarr, download clients, root folders (scripted)

`setup_services.sh` reconciles all of this idempotently:

- **Prowlarr:** FlareSolverr indexer proxy (`http://flaresolverr:8191`) + the
  Radarr and Sonarr applications.
- **Radarr/Sonarr:** the qBittorrent download client (host `qbittorrent`, port
  `8080`, categories `radarr` / `tv-sonarr`) and the root folders
  (`/data/media/movies`, `/data/media/tv`).
- **Radarr/Sonarr settings:** applies the tracked `services/<app>/settings/*.json`
  — quality profile `Any`, naming, media management (`copyUsingHardlinks=true`),
  delay profile.

Media directories + ownership are created by `setup_script.sh`. To fix ownership
manually: `docker run --rm -v /mnt/tank:/mnt/tank alpine chown 1000:1000
/mnt/tank/media/movies /mnt/tank/media/tv /mnt/tank/downloads/{complete,incomplete}`.

**Still manual** (you choose these): add indexers in Prowlarr, then — for any
Cloudflare-protected ones — create a tag (e.g. `flare`) on the FlareSolverr proxy
and assign the same tag to those indexers.

### 10.6 Radarr/Sonarr → Jellyfin

Radarr: **Settings → Connect → Add → Jellyfin**
- Host: `host.docker.internal`, Port: `8096`
- API Key: Jellyfin Dashboard → API Keys

Repeat in Sonarr.

### 10.7 Bazarr

1. **Settings → Sonarr**: host `sonarr`, port `8989`
2. **Settings → Radarr**: host `radarr`, port `7878`
3. **Settings → Providers**: add OpenSubtitles.com
4. **Settings → Languages**: set preferred profile

### 10.8 Profilarr

Profilarr syncs quality profiles + custom formats from the Dictionarry database (`Dictionarry-Hub/database`, branch `v2`) into Sonarr/Radarr. This stack runs Profilarr **v2** (image `ghcr.io/dictionarry-hub/profilarr`, pinned by `tag@sha256` digest in `docker-compose.yml`). v2 is a rewrite: new PCD 2.0 database format, mandatory login, and a database moved off the abandoned `santiagosayshey` Docker Hub image.

**Current config:** the **`2160p Quality`** profile is synced to both apps and every movie/series is assigned to it (upgrades on → chases the best 4K release via Dictionarry's custom-format scoring, not just the highest tier). Delay profiles differ by app on purpose:

- **Sonarr — torrent delay `0`**: grab the first qualifying release the moment an episode airs, then upgrade continuously via RSS as better releases seed.
- **Radarr — torrent delay `360` (6h)**: no rush on a film, so wait for the best release before grabbing (Dictionarry's default).

**v2 has no REST API** (it's a SvelteKit app driven by form actions), so setup is **UI-only** — `setup_services.sh` does **not** reconcile Profilarr. First-run, in the Profilarr UI (`http://192.168.0.10:6868`):

1. Create the admin **login** (v2 auth; local-network requests bypass it).
2. **Add arr instances** — Radarr `http://192.168.0.10:7878`, Sonarr `http://192.168.0.10:8989` (+ API keys).
3. **Link the database** — `https://github.com/Dictionarry-Hub/database`, branch **`v2`**, and paste a GitHub **PAT** (avoids the 60/hr rate limit on database refresh).
4. **Set the delays in Profilarr** (**Delay Profiles** → select **Radarr** / **Sonarr**) so the synced value *is* the value you want — don't edit delays in the arrs directly, or a Sync overwrites them:
   - Sonarr → **torrent delay `0`**
   - Radarr → **torrent delay `360`** (6h — Dictionarry's default)

   v2's change layer keeps these as local overrides — they survive Dictionarry DB updates. Each delay profile also has a **Bypass if above custom-format score** option: grab immediately (skip the delay) when a release scores over a threshold. Optional — handy on Radarr so a genuinely top-tier release doesn't sit through the full 6h wait.
5. **Per instance → Sync**: tick **only** `2160p Quality`, select the matching delay profile (Radarr/Sonarr — mandatory), then **Sync**. Profilarr is now the single source of truth for both; re-syncing reproduces exactly these values (no drift to manage).
6. In each arr, assign your library to `2160p Quality` (Sonarr *series editor* / Radarr *movie editor*, bulk).

> **Resurrect gotcha:** a Sync pushes **only the profiles you tick**. Tick just the one you want — if you select a profile and later delete it in Sonarr/Radarr, the next Sync re-creates it. Starting from a clean v2 install (nothing selected) is the moment to avoid this permanently.

### 10.9 Seerr

1. Navigate to `http://<server-ip>:5055`
2. Sign in with Jellyfin — use `http://172.18.0.1:8096`
3. Add Movies library in Jellyfin first if Continue button is greyed out
4. Connect Radarr: host `radarr`, port `7878`, uncheck 4K Server
5. Connect Sonarr: host `sonarr`, port `8989`

### 10.10 Unpackerr (automatic archive extraction)

Sonarr and Radarr **detect** scene-style multi-part `.rar`/`.zip` releases but never unpack them — the grab downloads fine, then sits in the queue forever with *"Found archive file, might need to be extracted"* and never imports. Unpackerr is the companion worker that fixes this: it polls the Sonarr/Radarr queues, extracts any archived release in place, lets the *arr import the result, then deletes the extracted copies once the queue item clears.

There is **nothing to configure in a web UI** — Unpackerr has none. It's wired entirely through `docker-compose.yml` and reuses the existing Sonarr/Radarr API keys from `.env` (the same `SONARR_API_KEY`/`RADARR_API_KEY` that Glance uses), so no new credentials and no setup-script changes are needed:

- It shares the single `/mnt/tank:/data` mount and watches `/data/downloads` (`UN_*_PATHS_0`) — **the same path Radarr/Sonarr use.** This is the one hard requirement: Unpackerr matches the queue item's download path against this mount, so if it ever drifts from the *arr mount, extraction silently does nothing.
- It runs as `1000:1000` so extracted files are owned consistently and the *arr can import them.

Start it and confirm it connected to both apps:

```bash
docker compose up -d unpackerr
docker logs unpackerr | grep -iE 'sonarr|radarr|extract'
# Expect lines like "Watching Sonarr: http://sonarr:8989" / "Watching Radarr: ..."
```

To force a test, leave a `.rar` release stuck in a queue (or wait for the next one) — within `UN_INTERVAL` (default 2m) Unpackerr logs `Extracted` and the item imports on the next Sonarr/Radarr scan. No new indexers or download clients are needed; this only changes what happens *after* a download completes.

> **Caveat:** Unpackerr only acts on items currently in a Sonarr/Radarr queue. Archives that were already abandoned/removed from the queue (like a one-time backlog) still need a manual `unrar` — it's the *going-forward* automation, not a retroactive cleanup.

---

## Part 11: Portainer

Access `http://<server-ip>:9000`. **If headless, open from another device.** Set admin password then:

```bash
op item create \
  --category Login \
  --title "Marlboro NAS - Portainer" \
  --vault Private \
  --tags marlboro-nas \
  --url http://<server-ip>:9000 \
  username=admin \
  password=your-chosen-password
```

---

## Part 12: Immich Setup

### 12.1 Start Immich

```bash
docker compose up -d immich-postgres immich-redis
sleep 10
docker compose up -d immich-server immich-machine-learning
```

If postgres fails with "directory is not empty":

```bash
sudo rm -rf ~/marlboro/services/immich/postgres
mkdir -p ~/marlboro/services/immich/postgres
docker compose up -d immich-postgres
```

### 12.1a Version pinning (do not let Watchtower float it)

`immich-server` and `immich-machine-learning` are pinned to an exact version tag (not `:release`) and carry `com.centurylinklabs.watchtower.enable=false`. Immich ships **breaking DB migrations** across majors — a floating tag let Watchtower jump the server to a new major while the DB image stayed put, which crash-loops the server with `No vector extension found`. Bump both image tags together, on purpose, after reading the Immich release notes.

The DB uses the Immich-maintained image `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0`, which bundles **VectorChord (`vchord`)** plus pgvecto.rs (`vectors`) and pgvector — so v3+ auto-migrates the old `vectors` data to `vchord` and reindexes on first boot. Keep this tag pinned too. (History: the DB was originally `tensorchord/pgvecto-rs:pg14-v0.2.0`; pgvecto.rs was removed in Immich v3.) Before any Immich major upgrade, back up first: `docker exec immich-postgres pg_dumpall -U immich > ~/immich-pre-upgrade-$(date +%F).sql`.

### 12.2 Initial Setup

Navigate to `http://<server-ip>:2283`, create admin account.

### 12.3 Mobile App (replaces iCloud)

Install **Immich** from the App Store:
- Server URL: `http://<tailscale-ip>:2283` (Tailscale IP)
- Enable **Background Backup**

---

## Part 13: RomM Setup

### 13.1 Start RomM

```bash
docker compose up -d romm-db
sleep 30
docker compose up -d romm
```

### 13.2 Initial Setup

Navigate to `http://<server-ip>:7070`, create admin account.

### 13.3 Metadata Providers

- **IGDB:** free Twitch developer account at https://dev.twitch.tv — get Client ID and Secret
- **Screenscraper:** free account at https://screenscraper.fr

These are stored in 1Password ("Marlboro NAS - IGDB" and "Marlboro NAS - Screenscraper") and pulled into `.env` by `setup_script.sh`. After adding them to 1Password, re-run:

```bash
./setup_script.sh && docker compose up -d romm
```

### 13.4 ROM Folder Structure

RomM expects ROMs organized by platform folder name:

```
/mnt/tank/media/roms/
├── gba/
├── n64/
├── nes/
├── snes/
├── ps2/
├── psx/
└── ...
```

Full platform list: https://docs.romm.app/latest/Getting-Started/Folder-Structure/

### 13.5 Adding ROMs

Either upload via the RomM web UI, or place files in the correct folder and trigger a scan from the RomM dashboard.

---

## Part 14: Nginx Proxy Manager

1. Access `http://<server-ip>:81`
2. Default login: `admin@example.com` / `changeme` — change immediately
3. Add Proxy Hosts for clean local domain names
4. Add DNS rewrites in AdGuard

---

## Part 15: Tailscale

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --ssh   # enables Tailscale SSH so you're never locked out
tailscale ip              # note the 100.x.x.x IP
```

Tailscale hostname: `<tailscale-hostname>`
Tailscale IP: `<tailscale-ip>`

Connect remotely via Tailscale SSH:

```bash
tailscale ssh <your-username>@<tailscale-hostname>
```

---

## Part 16: Recommended Service Startup Order

After `docker compose up -d`, run **`./setup_services.sh`** — it does the wiring
marked ⚙ below (qBittorrent, Prowlarr apps + FlareSolverr proxy, Radarr/Sonarr
download client + root folders + settings, AdGuard).
The rest are first-run wizards / external accounts that stay manual.

1. **AdGuard** — DNS first; ⚙ upstream/rate-limit/blocklists
2. **qBittorrent** — ⚙ creds seeded pre-compose, save paths + share limits post-compose
3. **Flood** — browse to `:3004`, confirm it shows qBittorrent's torrents
4. **Flaresolverr** — ⚙ registered as a Prowlarr proxy; assign `flare` tag to CF indexers (manual)
5. **Prowlarr** — ⚙ Radarr/Sonarr apps linked; add indexers (manual)
6. **Radarr/Sonarr** — ⚙ root folders + qBittorrent download client + tracked settings; connect to Jellyfin (manual, 10.6)
7. **Unpackerr** — no setup; `docker logs unpackerr` should show it watching Sonarr/Radarr
8. **Bazarr** — connect to Radarr/Sonarr, add subtitle providers (manual)
9. **Profilarr** — login, connect instances, link Dictionarry DB (`v2` + PAT), sync `2160p Quality` to both, assign library (manual, UI-only — see 10.8)
10. **Jellyfin** — create Libraries (Movies → `/media/movies`, TV → `/media/tv`)
11. **Plex** — claim with `PLEX_CLAIM`, create Libraries pointing at the same `/media/movies` and `/media/tv` (see Part 16.6)
12. **Seerr** — connect to Jellyfin, Radarr, Sonarr (optionally add Plex too)
13. **Immich** — admin account, enable mobile backup
14. **RomM** — admin account, add metadata API keys
15. **Portainer** — set admin password
16. **Sunshine** — pair first Moonlight client
17. **Glance** — verify all services green

---

## Part 16.5: Jellyfin Hardware Transcoding & HDR Tone Mapping

The Intel UHD 630 iGPU is already exposed to the container via `/dev/dri` in `docker-compose.yml`. Jellyfin still needs to be told to use it, otherwise HDR/Dolby Vision titles direct-play and fail silently on clients that claim codec support but don't actually handle DV (notably the LG webOS Jellyfin app — audio plays, video is black).

In Jellyfin **Dashboard → Playback → Transcoding**:

- **Hardware acceleration**: `Intel QuickSync (QSV)`
- **QSV device**: leave blank (auto-detects `/dev/dri/renderD128`)
- **Enable hardware decoding for**: H264, HEVC, HEVC 10bit, VC1
- **Enable hardware encoding**: ✅
- **Allow encoding in HEVC format**: ✅ (UHD 630 does QSV HEVC 10-bit; keeps transcode quality close to source)
- **Enable Tone mapping**: ✅
- **Enable VPP Tone mapping**: ✅ (Intel-native, faster than OpenCL)
- **Tone mapping algorithm**: `mobius` (brighter than the technically-accurate `bt2390` default; preferable for SDR output to an HDR-capable display since the TV can't enter HDR mode for a tone-mapped stream)
- **VPP Tone-mapping Brightness**: `24` (default `16` is too dim once tone-mapped)
- **Stereo downmix algorithm**: `NightmodeDialogue` (boosts the center channel into L/R; rescues dialogue when 5.1 collapses to stereo, which happens whenever a TV passes AAC 5.1 over HDMI ARC)

Then on each client, lower **Home network quality** below the source bitrate (e.g. 20 Mbps) so 4K DV/HDR titles (typically 50–80 Mbps) trigger a server transcode + tone-map instead of direct-playing.

> **Surround audio caveat:** the official `jellyfin-webos` client transcodes audio to AAC 5.1, which doesn't pass reliably over HDMI ARC — soundbars often see stereo and rear surrounds go silent. On the LG TV, set **Sound → Sound Out → HDMI ARC → Auto / Pass-through** (not PCM), and on the soundbar, enable any "Dolby/DTS direct" option. If rears are still silent, the only complete fix is a client that supports surround passthrough (Apple TV 4K, Shield TV, or a rooted webOS Homebrew Channel install).

> **Why not commit `encoding.xml`?** Jellyfin rewrites it whenever any dashboard setting changes (subtitles, deinterlacing, etc.), so tracking it creates constant noise diffs. It's gitignored under `services/*`. Re-apply the settings above on a fresh install.

> **Verify transcoding is using the GPU:** during playback, `docker logs jellyfin --tail 50` should show ffmpeg invoked with `-hwaccel qsv` and `vpp_qsv` / `tonemap_vaapi` filters. `intel_gpu_top` on the host (from `intel-gpu-tools`) shows live engine utilization.

---

## Part 16.6: Plex Media Server

Plex runs alongside Jellyfin as a second media server, pointed at the **same** library on disk (`/mnt/tank/media`, mounted as `/media` inside the container). It's a separate `plexinc`-compatible server *instance* linked to an existing plex.tv account — the account's other servers (on the old PC) are untouched.

Like Jellyfin, Plex uses `network_mode: host` so GDM discovery and direct remote access work; it listens on `:32400`.

### 16.6.1 Get a Claim Token

The claim token links this new server instance to your account on first start. While **signed in to plex.tv in a browser**, open:

```
https://plex.tv/claim
```

Copy the `claim-xxxxxxxxxxxxxxxxxxxx` value. **It expires 4 minutes after issue**, so grab it right before the next step.

### 16.6.2 First Start (Claim)

Pass the token **inline** — do *not* hand-edit `.env`, because `setup_script.sh` regenerates `.env` with a blank `PLEX_CLAIM` on every run (the token is ephemeral and intentionally not stored in 1Password):

```bash
cd ~/marlboro
PLEX_CLAIM=claim-xxxxxxxxxxxxxxxxxxxx docker compose up -d plex
```

Watch it come up and confirm it claimed the server:

```bash
docker logs plex --tail 30   # look for the server registering against your account
```

Once claimed, the permanent server token is written to `./services/plex/config` (gitignored under `services/*`). On every subsequent `docker compose up -d plex`, a blank `PLEX_CLAIM` is correct — the server is already linked.

### 16.6.3 Create Libraries

Open Plex at `http://<server-ip>:32400/web` — you should already be signed in via the claim. During (or after) the setup wizard, add libraries pointing at the in-container paths (the same content Jellyfin serves):

- **Movies** → `/media/movies`
- **TV Shows** → `/media/tv`

> **Don't enable DLNA** (Settings → DLNA). Jellyfin already binds UDP `1900` for DLNA/SSDP on the host network; enabling it on Plex too causes a bind conflict. Leave it off (the default).

### 16.6.4 Hardware Transcoding (Plex Pass)

`/dev/dri` is already passed to the container in `docker-compose.yml`. In Plex, **Settings → Transcoder**:

- **Use hardware acceleration when available**: ✅
- **Use hardware-accelerated video encoding**: ✅ (HEVC encode on the UHD 630)

> **Requires an active Plex Pass.** This account's pass **expires November 2026** — after that, hardware transcoding silently stops and Plex falls back to CPU transcoding (Jellyfin's QSV path is independent and unaffected). To confirm HW is engaged: during a transcode, **Settings → Status → Now Playing** shows `(hw)` next to the transcode session, and `intel_gpu_top` on the host shows Video/VideoEnhance engine load.

### 16.6.5 (Optional) Add Plex to Seerr

Seerr (the Jellyseerr fork) can drive requests from Plex as well as Jellyfin. In Seerr → **Settings → Plex**, sign in and select this server. Radarr/Sonarr connections are already configured from the Jellyfin setup and are shared.

---

# Phase 2: When Drives Arrive

---

## Part 17: Storage Setup

### 17.1 Install btrfs Tools

```bash
sudo apt install btrfs-progs
```

### 17.2 Identify Drives

```bash
lsblk
```

4x Seagate Barracuda 8TB (ST8000DM004) at `/dev/sda`–`/dev/sdd`.

### 17.3 Create btrfs Filesystem

Data uses `single` profile (~29TiB usable), metadata uses `raid1` (duplicated on 2 drives).

```bash
sudo wipefs -a /dev/sda /dev/sdb /dev/sdc /dev/sdd
sudo mkfs.btrfs -d single -m raid1 /dev/sda /dev/sdb /dev/sdc /dev/sdd -L tank
```

### 17.4 Mount and Persist

```bash
sudo mkdir -p /mnt/tank
sudo mount /dev/sda /mnt/tank

# Add to fstab (use the UUID from mkfs output)
echo 'UUID=<your-uuid> /mnt/tank btrfs defaults,autodefrag,compress=zstd 0 0' | sudo tee -a /etc/fstab
```

### 17.5 Create Directory Structure

```bash
sudo mkdir -p /mnt/tank/{media,downloads,photos,media/roms}
sudo chown -R 1000:1000 /mnt/tank
```

> **Note:** `setup_script.sh` also creates media subdirectories and fixes their ownership on every run, so permission drift from Docker creating root-owned dirs is self-correcting.

### 17.6 Move Docker Data Root

```bash
docker compose down
sudo systemctl stop docker docker.socket
sudo mkdir -p /mnt/tank/docker
sudo rsync -aP /var/lib/docker/ /mnt/tank/docker/
echo '{"data-root": "/mnt/tank/docker", "dns": ["1.1.1.1", "8.8.8.8"]}' | sudo tee /etc/docker/daemon.json
sudo systemctl start docker
docker compose up -d
# Verify, then remove old data:
sudo rm -rf /var/lib/docker
```

### 17.7 Make Docker Wait for `/mnt/tank`

Because the data root and every service bind mount live on `/mnt/tank`, Docker must not start before the mount is available. Without this, a boot race — or any window where the pool is unmounted while containers run (e.g. the ZFS→btrfs migration) — leaves containers bound to plain directories on the root filesystem. Two failures follow: imports fail with phantom "not enough free space" errors even though the tank has 29 TB free, and qBittorrent/Radarr/Sonarr write downloads and media straight onto the root SSD under `/mnt/tank/...`. When the tank later mounts over those paths the data is hidden but still consumes root-disk blocks, silently filling `/` — and it's invisible to `du`, `ncdu`, and baobab alike (see "Recovering shadowed space" below).

```bash
sudo install -D -m 644 /dev/stdin /etc/systemd/system/docker.service.d/wait-for-tank.conf <<'EOF'
[Unit]
RequiresMountsFor=/mnt/tank
EOF
sudo systemctl daemon-reload
```

> **Creating the file is not enough — it must be loaded.** systemd won't apply the drop-in to a running `docker.service` until `daemon-reload` (or a reboot). A drop-in placed live without a reload sits inert until the next reboot. Always verify it's actually *effective*, not just present on disk:
>
> ```bash
> systemctl show docker -p RequiresMountsFor   # must print RequiresMountsFor=/mnt/tank
> ```
>
> If that line is empty, the guard is inert: run `sudo systemctl daemon-reload`, or reboot.

> **`setup_script.sh` only auto-installs this with passwordless sudo.** On this host sudo requires a password, so the script *skips* the install and prints the manual commands above. They must be run by hand and then confirmed with the `systemctl show` check.

#### Recovering shadowed space

If `df -h /` shows the root disk far fuller than `sudo du -x / | tail -1` can account for, data is likely stranded under the `/mnt/tank` mountpoint on the root SSD. Expose it with a bind mount of `/`, which shows the root filesystem *without* the tank overlay:

```bash
sudo mkdir -p /tmp/rootcheck && sudo mount --bind / /tmp/rootcheck
sudo du -shx /tmp/rootcheck/mnt/tank/*     # what's stranded on the SSD
```

Confirm `stat -c %d /tmp/rootcheck/mnt/tank` equals the device of `/` and differs from the live (btrfs) `/mnt/tank`, then reclaim and clean up:

```bash
sudo rm -rf /tmp/rootcheck/mnt/tank/{downloads,media,photos}
sudo chattr +i /tmp/rootcheck/mnt/tank   # optional failsafe: block writes to the bare mountpoint so a failed mount can't refill /
sudo umount /tmp/rootcheck && sudo rmdir /tmp/rootcheck
```

### 17.7 Create Immich Upload Directories

Immich requires marker files in its upload subdirectories:

```bash
mkdir -p /mnt/tank/photos/{encoded-video,thumbs,upload,backups,library,profile}
for dir in encoded-video thumbs upload backups library profile; do
  touch "/mnt/tank/photos/$dir/.immich"
done
```

---

## Part 19: Expose Jellyfin Externally via Nginx Proxy Manager

This uses DuckDNS (`marlboro-bc.duckdns.org`) for dynamic DNS and NPM for the reverse proxy with a free Let's Encrypt TLS certificate. After this, Jellyfin is reachable at `https://jellyfin.marlboro-bc.duckdns.org` from anywhere on the internet.

### 19.0 Reconcile Proxy Hosts from the Repo (scripted)

The proxy topology is codified in [`setup_services.sh`](./setup_services.sh) — a declarative `NPM_HOSTS=( … )` list of `domain | forward_host | forward_port | websockets | ssl_forced` rows (the `configure_proxy_hosts` section). Run it **after `docker compose up -d`** (NPM up on `:81`, DuckDNS reachable) to create any missing proxy host plus its DNS-01 Let's Encrypt cert through the NPM API:

```bash
cd ~/marlboro
./setup_services.sh
```

It reads `NGINX_EMAIL_ID` / `NGINX_PASSWORD` / `DUCKDNS_TOKEN` from `.env`. **Idempotent:** existing hosts are skipped and never modified, so manual tweaks survive and re-runs are safe. To expose a new service, add a row to `NPM_HOSTS` and re-run. (The same script also reconciles all the other in-app settings — see Part 10.)

What it does **not** do (still manual, per the sections below): router port-forwarding (19.1), the AdGuard DNS rewrite (19.5 — one wildcard rule covers all subdomains), and app-side public-URL config (e.g. Jellyfin 19.6, Plex 19.10 step 3). Host-networked services (Jellyfin, Plex, Coolify, the apex) forward to the LAN IP `192.168.0.10`; bridge services (Seerr, Forgejo) forward to their container name.

### 19.1 Forward Ports on the Router

On your TP-Link BE3600 (**Advanced → NAT Forwarding → Virtual Servers**), forward to `<server-ip>`:

| External Port | Internal Port | Protocol | Notes |
|---|---|---|---|
| 443 | 443 | TCP | HTTPS traffic (required) |
| 80 | 80 | TCP | Optional — only needed for `http://` → `https://` redirect. Many residential ISPs (e.g. Comcast) block inbound port 80, so we use a DNS-01 challenge for cert issuance instead. |

> Cert issuance does **not** require port 80 in this setup — see 19.4.

> **Heads up — double NAT:** if the TP-Link's WAN is plugged into another router (not directly into the modem), traffic to your public IP hits that upstream router first and never reaches the TP-Link's forward rule. To check, look at the TP-Link's WAN IP — if it's a private address (e.g. `192.168.1.x`), you're double-NATted. See [`UPSTREAM_ROUTER_FORWARDING.md`](./UPSTREAM_ROUTER_FORWARDING.md) for the fix. As a workaround that bypasses NAT entirely, Tailscale Funnel can expose a service publicly without any port forwarding (`sudo tailscale funnel --bg http://localhost:8096`).

### 19.2 Verify DuckDNS Is Updating

DuckDNS updates automatically via the container. Confirm it resolves to your current public IP:

```bash
dig +short marlboro-bc.duckdns.org
curl -s ifconfig.me
```

Both should return the same IP. If the container isn't running, check:

```bash
docker logs duckdns
```

### 19.3 Restart NPM to Pick Up the New Config

The `extra_hosts` change (needed so NPM can reach Jellyfin on the host network) requires a container restart:

```bash
cd ~/marlboro
docker compose up -d nginx-proxy-manager
```

### 19.4 Create the Jellyfin Proxy Host in NPM

> **Fastest path:** [`setup_services.sh`](#190-reconcile-proxy-hosts-from-the-repo-scripted) already creates this host (and its cert) from the repo. The manual steps below are the same thing by hand — and the source of *why* each setting is what it is (websockets, DNS-01, force SSL).

1. Open NPM at `http://<server-ip>:81`
2. **Proxy Hosts → Add Proxy Host**
3. **Details tab:**
   - Domain Names: `jellyfin.marlboro-bc.duckdns.org`
   - Scheme: `http`
   - Forward Hostname / IP: `host.docker.internal`
   - Forward Port: `8096`
   - Enable: **Websockets Support** (required for Jellyfin)
4. **SSL tab:**
   - SSL Certificate: **Request a new SSL Certificate**
   - Provider: Let's Encrypt
   - Email: your email address
   - Enable: **Use a DNS Challenge**
   - DNS Provider: **DuckDNS**
   - Credentials File Content:
     ```
     dns_duckdns_token=<your-duckdns-token>
     ```
     Same token as `DUCKDNS_TOKEN` in `.env` (used by the `duckdns` container). Get it from <https://www.duckdns.org>.
   - Propagation Seconds: leave blank (default 30s is fine)
   - Enable: **Force SSL**
   - Enable: **HTTP/2 Support**
   - Agree to Terms of Service
5. Click **Save** — NPM installs `certbot-dns-duckdns` on first use, sets a TXT record at `_acme-challenge.marlboro-bc.duckdns.org` via the DuckDNS API, and Let's Encrypt validates the domain. No inbound port 80 required.

> **Tip:** You can also request a wildcard cert by adding `*.marlboro-bc.duckdns.org` to Domain Names — DNS-01 is the only challenge type Let's Encrypt accepts for wildcards.

### 19.5 AdGuard DNS Rewrite

In AdGuard Home → **Filters → DNS Rewrites → Add DNS Rewrite**:
- Domain: `*.marlboro-bc.duckdns.org`
- Answer: `<server-ip>`

A single wildcard rule covers every subdomain you'll proxy through NPM (Jellyfin, Coolify, Seerr, anything you add later) — one rule instead of one per service.

Without this, LAN devices resolve the domain to your public IP and hairpin through the TP-Link's NAT, which is slower (and on some routers, broken) than going straight to the LAN IP. Particularly worth it for Jellyfin since 4K transcodes are bandwidth-heavy.

> **Caveats:** the wildcard does not match the bare apex (`marlboro-bc.duckdns.org` with no subdomain) — fine, since we only use subdomains. Let's Encrypt DNS-01 validation queries DuckDNS's authoritative nameservers from the public internet, not via AdGuard, so the wildcard doesn't interfere with cert issuance. Containers use `1.1.1.1`/`8.8.8.8` directly (per `/etc/docker/daemon.json`), so the wildcard also doesn't affect inter-container traffic.

### 19.6 Configure Jellyfin's Public URL

In Jellyfin: **Dashboard → Networking**

- **Server Address Settings → Public HTTPS port:** `443`
- **Server Address Settings → Known Proxies:** add your server's LAN IP (e.g. `<server-ip>`)
- **Server Address Settings → Base URL:** leave blank (using a subdomain, not a path)

Save and restart Jellyfin if prompted.

### 19.7 Test External Access

From a device **not on your home network** (e.g. phone with Wi-Fi off):

```
https://jellyfin.marlboro-bc.duckdns.org
```

You should see the Jellyfin login page over HTTPS with a valid certificate.

### 19.8 Troubleshooting: "Internal Error" When Requesting a Cert

If NPM shows only "Internal Error" after submitting the cert request, check the container logs:

```bash
docker logs nginx-proxy-manager --tail 100
docker exec nginx-proxy-manager tail -200 /data/logs/letsencrypt.log
```

Common causes:

- **`Timeout during connect (likely firewall problem)` on port 80** — the HTTP-01 challenge can't reach your server. Either port 80 isn't forwarded to `<server-ip>`, or your ISP blocks inbound 80 (common on residential Comcast). **Fix:** use DNS-01 as described in 19.4 instead of HTTP-01.
- **`unauthorized` from DuckDNS** — `dns_duckdns_token` is wrong or missing. Re-copy from <https://www.duckdns.org> and re-save the cert.
- **Rate limit hit** — Let's Encrypt limits failed validations to 5/hour and certs to 5/week per registered domain. Wait an hour and retry, ideally after fixing the underlying cause.

### 19.9 (Optional) Lock Down to Jellyfin Only

If you only want to expose Jellyfin and not other services, no additional steps are needed — NPM only proxies hostnames you explicitly configure. Other services remain LAN/Tailscale-only.

To block direct port access to Jellyfin's raw port (8096) from the internet while still allowing the proxy, add a UFW rule:

```bash
sudo ufw allow from 127.0.0.1 to any port 8096
sudo ufw deny 8096
```

NPM communicates with Jellyfin via `host.docker.internal` which resolves to the host's bridge gateway address — traffic stays local, so this rule doesn't block the proxy.

### 19.10 Also Expose Plex

Plex ships its own remote-access (plex.tv relay / direct connect on `:32400`), so native Plex apps (mobile, TV, etc.) reach the server without any of this. NPM is for a clean HTTPS URL to the **web app** at `https://plex.marlboro-bc.duckdns.org`. Setup mirrors 19.4. The AdGuard wildcard rewrite from 19.5 already covers the `plex` subdomain (it's a DNS rule), but the TLS certs here are **per-subdomain — there is no wildcard cert** — so a new `plex.marlboro-bc.duckdns.org` cert is issued via DNS-01 below.

> **Fastest path:** [`setup_services.sh`](#190-reconcile-proxy-hosts-from-the-repo-scripted) already creates this host (and its cert) from the repo. The manual steps below are the same thing by hand.

1. NPM → **Proxy Hosts → Add Proxy Host → Details tab:**
   - Domain Names: `plex.marlboro-bc.duckdns.org`
   - Scheme: `http`
   - Forward Hostname / IP: `192.168.0.10` (the host's LAN IP — Plex is on host networking; `host.docker.internal` works too)
   - Forward Port: `32400`
   - Enable: **Websockets Support** (Plex uses them for the web client)
2. **SSL tab:** **Request a new SSL Certificate** via the **DNS-01 / DuckDNS** challenge exactly as in 19.4 (each subdomain gets its own cert — there's no shared wildcard), then **Force SSL** + **HTTP/2 Support**.
3. In Plex → **Settings → Network**:
   - **Custom server access URLs:** `https://plex.marlboro-bc.duckdns.org:443`
   - **Secure connections:** `Preferred`
   - Add your server's LAN IP under **List of IP addresses and networks that are allowed without auth** only if you want unauthenticated LAN access (optional).

> Plex validates the TLS cert against the hostname, so the `Custom server access URLs` entry must match the NPM domain exactly. Without it, the web app loads but the player may refuse the connection as insecure.

To block direct internet access to the raw `:32400` port while keeping the proxy (same idea as 19.9):

```bash
sudo ufw allow from 127.0.0.1 to any port 32400
sudo ufw deny 32400
```

---

## Part 20: Coolify

Coolify is a self-hosted PaaS for deploying apps and managing servers via Docker. It runs alongside the existing stack with NPM as its reverse proxy. Coolify's built-in Traefik proxy is disabled so it doesn't conflict with NPM on ports 80/443.

### 20.1 Create Directories and the `coolify` Network

```bash
mkdir -p ~/marlboro/services/coolify/{app,postgres,redis,ssh}
chmod 700 ~/marlboro/services/coolify/ssh
sudo mkdir -p /data/coolify/source
sudo chown $USER:$USER /data/coolify/source
docker network create coolify
```

The `/data/coolify/source` path is a fixed host path Coolify hard-codes internally — it must exist outside the repo directory.

The `coolify` Docker network is where every app Coolify deploys lands (Coolify uses it for service discovery between deployed apps). The `coolify` service in `docker-compose.yml` is attached to both `homelab` (so it can talk to the rest of the stack) and `coolify` (so it can manage deployed apps). Without this network, deploys fail with `Error response from daemon: network coolify not found`.

### 20.2 Run the Setup Script

```bash
cd ~/marlboro
./setup_script.sh
```

The script will create these items in 1Password (vault: Private, tag: marlboro-nas):

| 1Password Item | .env Variable |
|---|---|
| Marlboro NAS - Coolify App Key | `COOLIFY_APP_KEY` |
| Marlboro NAS - Coolify DB | `COOLIFY_DB_PASSWORD` |
| Marlboro NAS - Coolify Redis | `COOLIFY_REDIS_PASSWORD` |
| Marlboro NAS - Coolify Pusher App ID | `COOLIFY_PUSHER_APP_ID` |
| Marlboro NAS - Coolify Pusher App Key | `COOLIFY_PUSHER_APP_KEY` |
| Marlboro NAS - Coolify Pusher Secret | `COOLIFY_PUSHER_APP_SECRET` |

### 20.3 Start Coolify Services

```bash
docker compose up -d
# Coolify runs Laravel DB migrations on first start — takes ~30 seconds
docker compose logs -f coolify
# Wait for "Application is ready" in the logs
```

The `depends_on` health checks ensure PostgreSQL is accepting connections before Coolify starts its migration.

### 20.4 Configure NPM Proxy Host

Open NPM at `http://<server-ip>:81` → **Proxy Hosts → Add Proxy Host**:

- **Details tab:**
  - Domain Names: `coolify.marlboro-bc.duckdns.org`
  - Scheme: `http`
  - Forward Hostname / IP: `coolify` (resolves via the `homelab` Docker network)
  - Forward Port: `8080` (nginx inside the container; the `8000:8080` host mapping is for direct access / Tailscale Funnel)
  - Enable: **Websockets Support** (required for real-time log streaming)
- **SSL tab:**
  - SSL Certificate: **Request a new SSL Certificate**
  - Provider: Let's Encrypt
  - Email: your email address
  - Enable: **Use a DNS Challenge**
  - DNS Provider: **DuckDNS**
  - Credentials File Content:
    ```
    dns_duckdns_token=<your-duckdns-token>
    ```
    Same token as `DUCKDNS_TOKEN` in `.env`. Get it from <https://www.duckdns.org>.
  - Propagation Seconds: leave blank (default 30s is fine)
  - Enable: **Force SSL**
  - Enable: **HTTP/2 Support**
  - Agree to Terms of Service → Save

> **Why DNS-01:** residential ISPs (e.g. Comcast) block inbound port 80, so HTTP-01 challenges time out. DNS-01 validates by writing a TXT record to `_acme-challenge.marlboro-bc.duckdns.org` via the DuckDNS API — no port 80 required. Same approach as 19.4 (Jellyfin).

### 20.5 AdGuard DNS Rewrite

If you set up the wildcard rule in 19.5 (`*.marlboro-bc.duckdns.org` → `<server-ip>`), it already covers this hostname — skip ahead to 20.6.

Otherwise, in AdGuard Home → **Filters → DNS Rewrites → Add DNS Rewrite**:
- Domain: `coolify.marlboro-bc.duckdns.org`
- Answer: `<server-ip>`

This ensures the domain resolves to your LAN IP from inside the network.

### 20.6 First Login & Admin Account

Navigate to `https://coolify.marlboro-bc.duckdns.org`. On first access you'll see a registration form — create the admin account and store the credentials in 1Password:

```bash
op item create \
  --category Login \
  --title "Marlboro NAS - Coolify" \
  --vault Private \
  --tags marlboro-nas \
  --url https://coolify.marlboro-bc.duckdns.org \
  username=your@email.com \
  password=your-chosen-password
```

### 20.7 Server Configuration Inside Coolify

After login, Coolify will prompt you to add a server. Choose **This Machine** (older builds called this "Localhost") — Coolify communicates with the local Docker daemon via the mounted `/var/run/docker.sock`.

**Skip any prompts to install Traefik or Caddy.** The env var `DISABLE_STANDALONE_MODE=true` prevents Coolify's built-in proxy from starting; NPM handles all TLS termination.

### 20.8 Ports Used

| Port | Purpose |
|------|---------|
| 8000 | Coolify web UI (also proxied via NPM) |
| 6001 | Soketi WebSocket server (real-time events) |
| 6002 | Soketi internal metrics |

### 20.9 Caveats

- **Coolify runs privileged.** Required for Docker management. The container has significant host access — expected for a PaaS tool.
- **Postgres UID mismatch.** `postgres:15-alpine` runs as UID 999. If the DB fails to start with a permissions error, fix with: `sudo chown -R 999:999 ~/marlboro/services/coolify/postgres`
- **`DISABLE_STANDALONE_MODE` naming.** This env var has changed across Coolify beta releases. If Traefik appears running inside the container, check Coolify's release notes — it may also be `STANDALONE_MODE=false` in some builds.
- **Server validation requires a matching SSH key.** When you add the "This Machine" server in 20.7, Coolify generates a private key and stores its public key. Copy that public key into `/root/.ssh/authorized_keys` on the host (`echo '<pubkey>' | sudo tee /root/.ssh/authorized_keys && sudo chmod 600 /root/.ssh/authorized_keys`). If the UI doesn't display the public key cleanly, extract it via `docker exec coolify php artisan tinker --execute='echo App\Models\PrivateKey::find(<id>)->getPublicKey();'`.
- **Watch the `private_key_id` foreign key.** Coolify's UI has occasionally been observed to leave the `servers.private_key_id` column at `0` after generating and assigning a key, producing a misleading "key not valid" error during validation. Confirm with `docker exec coolify-db psql -U coolify -d coolify -c "SELECT id, private_key_id FROM servers;"` and `UPDATE servers SET private_key_id = <real-id> WHERE id = <server-id>;` if it's stale.

### 20.10 Proxying Deployed Apps Through NPM

Apps Coolify deploys land on the `coolify` Docker network, but NPM is on the `homelab` network — they can't see each other by default. Two options when you want to expose a deployed app via `*.marlboro-bc.duckdns.org`:

1. **Attach NPM to the `coolify` network too.** Add `coolify` to NPM's `networks` block in `docker-compose.yml`, recreate NPM, then point the proxy host at the deployed container's name and internal port.
2. **Have Coolify publish the app on a host port.** In the Coolify UI, set a host port mapping for the app's service. NPM can then proxy to `host.docker.internal:<port>`.

Option 1 is cleaner for many apps; option 2 avoids cross-network coupling at the cost of a reserved host port per app.

---

## Part 21: Expose Seerr Externally via Nginx Proxy Manager

Same DuckDNS + NPM + Let's Encrypt DNS-01 pattern as Jellyfin (Part 19) and Coolify (Part 20). Port forwarding from Part 19.1 already covers 443/80, so no router changes are needed. After this, Seerr is reachable at `https://seerr.marlboro-bc.duckdns.org`.

### 21.1 Create the Seerr Proxy Host in NPM

Open NPM at `http://<server-ip>:81` → **Proxy Hosts → Add Proxy Host**:

- **Details tab:**
  - Domain Names: `seerr.marlboro-bc.duckdns.org`
  - Scheme: `http`
  - Forward Hostname / IP: `seerr` (resolves via the `homelab` Docker network)
  - Forward Port: `5055`
  - Enable: **Cache Assets**
  - Enable: **Block Common Exploits**
  - Enable: **Websockets Support** (Seerr uses WS for real-time request status updates)
- **SSL tab:**
  - SSL Certificate: **Request a new SSL Certificate**
  - Provider: Let's Encrypt
  - Email: your email address
  - Enable: **Use a DNS Challenge**
  - DNS Provider: **DuckDNS**
  - Credentials File Content:
    ```
    dns_duckdns_token=<your-duckdns-token>
    ```
    Same token as `DUCKDNS_TOKEN` in `.env`. Get it from <https://www.duckdns.org>.
  - Propagation Seconds: leave blank (default 30s is fine)
  - Enable: **Force SSL**
  - Enable: **HTTP/2 Support**
  - Agree to Terms of Service → Save

> **Why DNS-01:** residential ISPs (e.g. Comcast) block inbound port 80, so HTTP-01 challenges time out. Same approach as 19.4 and 20.4.

### 21.2 AdGuard DNS Rewrite

If you set up the wildcard rule in 19.5 (`*.marlboro-bc.duckdns.org` → `<server-ip>`), it already covers this hostname — skip ahead to 21.3.

Otherwise, in AdGuard Home → **Filters → DNS Rewrites → Add DNS Rewrite**:
- Domain: `seerr.marlboro-bc.duckdns.org`
- Answer: `<server-ip>`

Without this, devices on your LAN would resolve the hostname to your public IP and try to hairpin through the router — which often fails or is slower than just hitting the local IP.

### 21.3 Tell Seerr It's Behind a Proxy

In Seerr: **Settings → General**
- **Application URL:** `https://seerr.marlboro-bc.duckdns.org` (enables password-reset email links and external notifications)

Then in Seerr: **Settings → Network**
- **Enable Proxy Support / Trust Proxy:** ✅ (trust `X-Forwarded-*` headers from NPM so audit logs show real client IPs instead of NPM's container IP)
- **Enable CSRF Protection:** ❌ **Leave this OFF.** When enabled, Seerr marks its CSRF cookies `Secure`, so browsers only send them over **HTTPS**. That means login works *only* through the HTTPS NPM URL — logging in over plain HTTP via the Tailscale IP (`http://100.102.118.61:5055`) or LAN IP (`http://192.168.0.10:5055`) fails with `invalid csrf token` (a generic login error in the UI). Since we want to reach Seerr from the external URL, Tailscale, **and** the local IP, CSRF must stay disabled (this is also Seerr's own default). Only enable it if you commit to HTTPS-only access on every network.

Save and restart the container if prompted (`docker compose restart seerr`).

> **If you already enabled CSRF and login broke:** set `"csrfProtection": false` under the `network` block in `services/jellyseerr/config/settings.json`, then `docker compose restart seerr`. (Edit it while the container is stopped, or it may be overwritten on shutdown.)

### 21.4 Test External Access

From a device **not on your home network** (phone with Wi-Fi off):

```
https://seerr.marlboro-bc.duckdns.org
```

Sign in with Jellyfin — the OAuth-style sign-in flow uses websockets, so if login hangs at "Authenticating…", revisit 21.1 and confirm Websockets Support is enabled on the proxy host.

---

## Part 22: Forgejo

Forgejo is a self-hosted, lightweight Git forge (a Gitea fork). It runs on the `homelab` network with NPM as its reverse proxy, uses SQLite (no extra DB container), and exposes git over SSH on host port `2222` since the OS sshd owns port 22.

### 22.1 Run the Setup Script

```bash
cd ~/marlboro
./setup_script.sh
```

The script generates the admin login in 1Password (vault: Private, tag: marlboro-nas):

| 1Password Item | Used For |
|---|---|
| Marlboro NAS - Forgejo | Admin account created in 22.3 (`username` + `password`) |

Forgejo itself needs no `.env` variables — it generates its own `SECRET_KEY`/`INTERNAL_TOKEN` into `services/forgejo/data/gitea/conf/app.ini` on first run. The admin password isn't consumed by the container; it lives in 1Password so the CLI step below can pull it.

### 22.2 Start Forgejo

```bash
docker compose up -d forgejo
docker compose logs -f forgejo
# Wait for "Starting new server: tcp:0.0.0.0:3000" — the bind-mounted
# services/forgejo/data is created and chowned to UID 1000 automatically.
```

`FORGEJO__security__INSTALL_LOCK=true` skips the web installer, so Forgejo boots straight into the app with SQLite. Registration is disabled (`DISABLE_REGISTRATION=true`), so there's no open sign-up window to race — you create the admin via CLI next.

### 22.3 Create the Admin Account

Forgejo runs as the `git` user inside the container. Create the first admin from the credentials in 1Password:

```bash
docker exec -u git forgejo forgejo admin user create \
  --admin \
  --username "$(op item get 'Marlboro NAS - Forgejo' --vault Private --fields username --reveal)" \
  --email bencalegari@navapbc.com \
  --password "$(op item get 'Marlboro NAS - Forgejo' --vault Private --fields password --reveal)" \
  --must-change-password=false
```

Then log in at `http://<server-ip>:3003` to confirm before wiring up the proxy.

### 22.4 Configure NPM Proxy Host

Open NPM at `http://<server-ip>:81` → **Proxy Hosts → Add Proxy Host**:

- **Details tab:**
  - Domain Names: `git.marlboro-bc.duckdns.org`
  - Scheme: `http`
  - Forward Hostname / IP: `forgejo` (resolves via the `homelab` Docker network)
  - Forward Port: `3000` (the internal container port, not the `3003` host mapping)
  - Enable: **Block Common Exploits**
  - Enable: **Websockets Support**
- **SSL tab:**
  - SSL Certificate: **Request a new SSL Certificate**
  - Provider: Let's Encrypt
  - Email: your email address
  - Enable: **Use a DNS Challenge**
  - DNS Provider: **DuckDNS**
  - Credentials File Content:
    ```
    dns_duckdns_token=<your-duckdns-token>
    ```
    Same token as `DUCKDNS_TOKEN` in `.env`. Get it from <https://www.duckdns.org>.
  - Propagation Seconds: leave blank (default 30s is fine)
  - Enable: **Force SSL**
  - Enable: **HTTP/2 Support**
  - Agree to Terms of Service → Save

> **Heads up — `413 Request Entity Too Large` on push.** NPM caps request bodies at 1 MB by default, which breaks pushing larger objects over HTTPS. In the proxy host's **Advanced** tab add `client_max_body_size 0;` (0 = unlimited), or push over SSH instead (22.6). Same DNS-01 reasoning as 19.4/20.4 — residential ISPs block inbound 80.

### 22.5 AdGuard DNS Rewrite

If you set up the wildcard rule in 19.5 (`*.marlboro-bc.duckdns.org` → `<server-ip>`), it already covers this hostname — skip ahead to 22.6.

Otherwise, in AdGuard Home → **Filters → DNS Rewrites → Add DNS Rewrite**:
- Domain: `git.marlboro-bc.duckdns.org`
- Answer: `<server-ip>`

### 22.6 Git Over SSH

The compose file maps host `2222` → container `22` and sets `SSH_PORT=2222`, so Forgejo prints clone URLs with the right port:

```
git clone ssh://git@git.marlboro-bc.duckdns.org:2222/<owner>/<repo>.git
```

Add your public key in Forgejo under **Settings → SSH / GPG Keys**. Port `2222` is reachable on the LAN and over Tailscale without any router change; only forward it on the router if you need SSH git from the public internet (HTTPS already works externally via NPM).

### 22.7 Git LFS (Large File Storage)

LFS is enabled server-wide via `FORGEJO__server__LFS_START_SERVER=true` in the compose file. Objects are stored on disk under `/data/git/lfs` (the `[lfs]` `PATH` in `app.ini`), which sits inside the `./services/forgejo/data` volume — so LFS data is persisted and backed up alongside everything else. Forgejo auto-generates an `LFS_JWT_SECRET` into `app.ini` on first start after the flag is set; like `SECRET_KEY`, it is app-managed and not in git.

There's nothing to toggle per-repo — once the server flag is on, any repo can use LFS. On the client:

```bash
git lfs install                      # one-time, installs the git hooks
git lfs track "*.psd" "*.fbx"        # writes patterns to .gitattributes
git add .gitattributes
git add big-file.psd && git commit -m "Add asset" && git push
```

LFS transfers ride the same HTTPS endpoint as normal git, so the `client_max_body_size 0;` fix from 22.4 is what keeps large LFS uploads from failing with `413`. (Pushing over SSH on `2222` still negotiates LFS transfers over HTTPS via `ROOT_URL`.)

### 22.8 Ports Used

| Port | Purpose |
|------|---------|
| 3003 | Web UI (host mapping for container port 3000; also proxied via NPM) |
| 2222 | Git over SSH (container port 22) |

### 22.9 Caveats

- **SQLite, not Postgres.** Fine for a single-user/small-team forge and Forgejo's own recommendation at this scale. To migrate to Postgres later you'd add a `forgejo-db` container, set `FORGEJO__database__*` env vars, and run `forgejo dump` → restore — not a drop-in swap once data exists.
- **Pinned to major tag `:11`.** Avoids a surprise major upgrade (which runs DB migrations) from Watchtower. Bump the tag deliberately and read the Forgejo release notes when moving to a new major.
- **`app.ini` is app-managed.** It lives under the gitignored `services/forgejo/data` and holds the generated `SECRET_KEY`/`INTERNAL_TOKEN` — back it up with the data dir; it is **not** in git. A fresh `data` dir means a fresh forge.
- **Changing the public URL.** `DOMAIN`/`ROOT_URL`/`SSH_*` are seeded from env on first run but then persisted in `app.ini`; editing the env later may not take effect until you also update `app.ini` (or start from a clean `data` dir).

### 22.10 External Access — Push for Off-Tailscale Collaborators

Collaborators who aren't on the Tailscale VPN push over **HTTPS with a personal access token**. This rides the existing setup — no new router change and no new exposed port:

- Port `443` is already forwarded to the server (Part 19.1), and DuckDNS already resolves `git.marlboro-bc.duckdns.org` publicly. The NPM proxy host from 22.4 terminates TLS and forwards to `forgejo:3000`.
- **Confirm the push-size fix is in place:** the proxy host's Advanced tab must contain `client_max_body_size 0;` (22.4), or pushes larger than 1 MB fail with `413`.
- Git over SSH (port `2222`) stays **LAN/Tailscale-only by design** — it is *not* used for this and is not exposed to the internet.

**1. Create an account for each collaborator.** Registration is disabled (`DISABLE_REGISTRATION=true`), so the admin provisions users. Either **Site Administration → Identities → Users → Create User** in the UI, or via CLI:

```bash
docker exec -u git forgejo forgejo admin user create \
  --username alice \
  --email alice@example.com \
  --random-password
# prints a one-time password — share it securely; Forgejo forces a reset at first login
```

**2. Grant repo access.** On the repo: **Settings → Collaborators & Teams → add the user** (or add them to an org team). Give `Write` for push access.

**3. The collaborator creates a token.** In their account: **Settings → Applications → Generate New Token**, with the `write:repository` scope (read+write to repos). Forgejo shows the token once — copy it immediately.

**4. They clone and push over HTTPS:**

```bash
git clone https://git.marlboro-bc.duckdns.org/<owner>/<repo>.git
# On push, Git prompts for credentials:
#   Username: their Forgejo username
#   Password: the access token (NOT their account password)
```

To avoid retyping, they can cache it with `git config --global credential.helper store` (or their OS keychain helper).

**Revoking access:** delete the token (their **Settings → Applications**), remove them as a collaborator, or deactivate the whole account in **Site Administration → Users**. Per-token revocation is the least disruptive.

---

## Part 18: Maintenance

**Update containers manually:**

```bash
docker compose pull
docker compose up -d
```

**btrfs health:**

```bash
sudo btrfs scrub start /mnt/tank   # also runs monthly via /etc/cron.d/btrfs-scrub
sudo btrfs scrub status /mnt/tank
sudo btrfs filesystem show /mnt/tank
sudo btrfs filesystem df /mnt/tank
```

**Drive health:** `http://<server-ip>:8085` (Scrutiny)

**Scheduled SMART self-tests:** long (extended) self-tests run monthly via `/etc/cron.d/smart-selftest`, one drive per month staggered across the 8th/12th/16th/20th at 03:00 — full coverage monthly, never two at once, and clear of the 1st-of-month btrfs scrub. Each long test takes ~16h on these ST8000DM004 drives and runs in the background on the drive (auto-pausing during real I/O); Scrutiny ingests the results on its next collector run. `smartctl` is invoked inside the Scrutiny container (it isn't installed on the host). To (re)install the cron file:

```bash
sudo tee /etc/cron.d/smart-selftest > /dev/null <<'EOF'
# SMART long (extended) self-tests — one drive/month, staggered, clear of the 1st-of-month btrfs scrub
0 3 8  * * root /usr/bin/docker exec scrutiny /usr/sbin/smartctl -t long /dev/sda
0 3 12 * * root /usr/bin/docker exec scrutiny /usr/sbin/smartctl -t long /dev/sdb
0 3 16 * * root /usr/bin/docker exec scrutiny /usr/sbin/smartctl -t long /dev/sdc
0 3 20 * * root /usr/bin/docker exec scrutiny /usr/sbin/smartctl -t long /dev/sdd
EOF
sudo chmod 644 /etc/cron.d/smart-selftest
```

Check progress/results anytime: `docker exec scrutiny smartctl -l selftest /dev/sdX`

**btrfs snapshots:**

```bash
sudo btrfs subvolume snapshot -r /mnt/tank /mnt/tank/.snapshots/$(date +%Y-%m-%d)
sudo btrfs subvolume list /mnt/tank
```

**Sync credentials from 1Password:**

```bash
cd ~/marlboro && ./setup_script.sh && docker compose up -d
```

### Upgrading the Ubuntu Release (T2-aware)

> **This is not a plain `do-release-upgrade`.** This is a T2 Mac — the kernel (`linux-t2`) and all Apple hardware support (audio, Wi-Fi, Bluetooth) come from the [t2linux](https://github.com/AdityaGarg8/t2-ubuntu-repo) third-party repo. `do-release-upgrade` **disables every third-party repo** for the duration of the upgrade, so without the steps below the T2 kernel gets flagged as an orphan (offered for removal) and the box can come up on a stock generic kernel with no T2 drivers.

t2linux publishes a kernel per Ubuntu codename (`questing` = 25.10, `resolute` = 26.04 LTS). **Confirm the target codename's kernel exists** at <https://github.com/AdityaGarg8/t2-ubuntu-repo/releases> before you start — if it's missing, don't upgrade yet.

**1. *Before* launching `do-release-upgrade`, update the current release fully and note your working kernel:**

```bash
sudo apt update && sudo apt full-upgrade
uname -r        # e.g. 7.0.10-1-t2-questing — your known-good fallback
```

**2. Run the upgrade — but two prompts matter:**

```bash
sudo do-release-upgrade
```

- **"Remove obsolete packages?" → No** (or review the list first). With the t2 repo disabled, `linux-t2`, every `*-t2-*` kernel/header, and `apple-t2-audio-config` look orphaned and will be offered for removal — accepting strips your only working kernel.
- **Final "Restart now?" → No.** Do steps 3–4 *before* rebooting.

**3. Re-enable and re-point the third-party repos.** `do-release-upgrade` disables them under `/etc/apt/sources.list.d/`. **Do not rely on the `*.migrate` backups** — they don't reliably survive the upgrade (this run they were cleaned up before the post-reboot steps). Write the repo lines explicitly. The codename-pinned ones (`t2`, `docker`, `tailscale`) move to the new codename; `1password` and `github-cli` track a codename-less `stable` channel.

```bash
# t2 — re-point the existing list in place (flat github.io line + codename-tagged release line):
sudo sed -i 's#/download/questing#/download/resolute#' /etc/apt/sources.list.d/t2.list

# docker:
echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu resolute stable' | sudo tee /etc/apt/sources.list.d/docker.list

# tailscale:
echo 'deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu resolute main' | sudo tee /etc/apt/sources.list.d/tailscale.list

# 1password (stable, no codename):
echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/amd64 stable main' | sudo tee /etc/apt/sources.list.d/1password.list

# github-cli (stable, no codename):
echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main' | sudo tee /etc/apt/sources.list.d/github-cli.list

sudo apt update
```

> If `apt update` 404s on `resolute` for Docker or Tailscale (they sometimes lag a fresh Ubuntu release by days), swap `resolute` for the previous LTS codename `noble` in those two lines until they publish. Once `apt update` is clean, delete any `*.disabled` / `*.migrate` leftovers.

**4. Install the new release's T2 kernel — but keep the old one as a fallback:**

```bash
sudo apt install linux-t2
ls /boot/vmlinuz*t2*              # both the old and new T2 kernels should be present
sudo update-grub
```

**Keep the previous codename's T2 kernel installed — do NOT `apt autoremove` it.** The new codename's T2 kernel is not guaranteed to boot this hardware (see the step 5 callout), so the old one is your lifeline.

Then make the GRUB menu visible and pin the default to a *known-good* kernel, so a bad new kernel can't strand you on an unattended reboot. `GRUB_DEFAULT=saved` survives future `update-grub` runs (e.g. `apt upgrade`):

```bash
sudo sed -i -e 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' -e 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' -e 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=10/' /etc/default/grub
sudo update-grub
# pin to your known-good kernel — replace 7.0.10-1-t2-questing with `uname -r` from step 1:
ENT=$(sudo grep -oP "(?<=menuentry ').*?(?=')" /boot/grub/grub.cfg | grep -m1 -- '7.0.10-1-t2-questing'); SUB=$(sudo grep -oP "(?<=submenu ').*?(?=')" /boot/grub/grub.cfg | head -1); if [ -n "$SUB" ] && ! sudo grep -qE "^menuentry .*7.0.10-1-t2-questing" /boot/grub/grub.cfg; then TARGET="$SUB>$ENT"; else TARGET="$ENT"; fi; sudo grub-set-default "$TARGET"; sudo grub-editenv list
```

> If GRUB defaults to a stock `*-generic` kernel, don't bother purging it — a generic kernel can't drive the T2-bridged NVMe and won't boot here either. Just pin the `-t2-` entry as above.

**5. Reboot and verify the stack:**

```bash
sudo reboot
# after it comes back:
uname -r                                       # ideally ends in -t2-resolute (but see callout)
vainfo                                         # Jellyfin QSV — /dev/dri/renderD128 present
systemctl show docker -p RequiresMountsFor     # must still print /mnt/tank (Part 17.7)
docker compose -f ~/marlboro/docker-compose.yml ps
```

> **Observed on this box (Macmini8,1, May 2026): the `7.0.10-1-t2-resolute` kernel hangs at boot.** `apple_bce`'s DMA-IRQ thread (`irq/NN-bce_dma`) oopses inside `bce_vhci_firmware_event_completion` and dies holding a spinlock; the module probe (`apple_bce_probe → bce_vhci_create → bce_create_sq`) then soft-locks forever (`native_queued_spin_lock_slowpath`) and the boot never finishes. **The *same upstream version* `7.0.10-1-t2-questing` boots fine and runs 26.04 LTS userspace without issue** (all containers healthy, QSV + tank intact), so the box deliberately stays on the questing kernel (GRUB pinned to it per step 4) until t2linux ships a kernel newer than `7.0.10-1` to retry. **If `uname -r` shows the old codename after this upgrade, that's a working steady state — not a failed upgrade.** Confirm the signature with `journalctl -b -1 -k | grep -iE 'bce|soft lockup'`. Because it's not headless, you can also just pick the new kernel from the visible GRUB menu to re-test, and power-cycle back to questing if it wedges.

**6. Re-check the Watchtower API pin.** 26.04 ships a newer Docker engine, so the `DOCKER_API_VERSION` pin in `docker-compose.yml` (set for 25.10) likely needs bumping. Match it to `docker version --format '{{.Server.APIVersion}}'` (or drop the override if Watchtower negotiates cleanly), then `docker compose up -d watchtower`.
