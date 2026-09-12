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
- **Pterodactyl** — Game server control panel (Panel + Wings node); runs a Valheim dedicated server
- **Portainer** — Docker management UI
- **Nginx Proxy Manager** — Reverse proxy with Let's Encrypt
- **Scrutiny** — Drive S.M.A.R.T. monitoring
- **Watchtower** — Automatic container updates
- **Uptime Kuma** — Uptime monitoring
- **ntfy** — Self-hosted push notifications (Profilarr sends quality-profile drift alerts here)
- **SMS Bridge** — Text a title to the Twilio number to request it in Seerr; get a text back when it lands in Jellyfin
- **Glance** — Homelab dashboard
- **Forgejo** — Self-hosted Git forge
- **DuckDNS** — Dynamic DNS for external access
- **Samba (SMB)** — Network file sharing of `/mnt/tank` to Mac/Windows (host, not Docker)

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
| Pterodactyl (panel) | 8091 | Internal container port is 80. Tailnet/LAN only — not proxied |
| Pterodactyl (wings API) | 8092 | Identity-mapped on purpose: the node's daemon port is also what the browser console dials |
| Pterodactyl (SFTP) | 2022 | Wings implements SFTP itself; no sshd involved |
| Valheim (game) | 2456–2457 UDP | Published on the host by the game container. Crossplay is on, so players join by code and **no router forward is needed** (see 24.8) |
| Portainer | 9000 | |
| Nginx Proxy Manager (admin) | 81 | |
| Nginx Proxy Manager (http) | 80 | |
| Nginx Proxy Manager (https) | 443 | |
| Scrutiny | 8085 | Internal container port is 8080 |
| Uptime Kuma | 3002 | Internal container port is 3001 |
| ntfy | 8194 | Push notifications; internal container port is 80. LAN/Tailscale only (not proxied) |
| SMS Bridge | 8195 | Twilio ↔ Seerr glue; internal container port is 8080. Only `/twilio/inbound` is public — see Part 23 |
| Forgejo (web) | 3003 | Internal container port is 3000 |
| Forgejo (git SSH) | 2222 | Maps to container 22; host 22 is the OS sshd |
| DuckDNS | — | No ports, DDNS updater only |
| Sunshine web UI | 47990 HTTPS | Runs on host, not Docker |
| Sunshine streaming | 47984, 47989 TCP | Moonlight ports |
| Sunshine streaming | 47998–48000, 48010 UDP | Moonlight ports |
| Samba (SMB) | 445 TCP | On host, not Docker; LAN + Tailscale only |
| wsdd (Windows discovery) | 3702 UDP, 5357 TCP | WS-Discovery for Windows Network tab |

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

**Watchtower updates nightly at 4 AM, and only containers that opt in.** `WATCHTOWER_SCOPE=homelab` means it considers *only* containers carrying a matching `com.centurylinklabs.watchtower.scope=homelab` label — **a new service gets no auto-updates until you add that label.** The scope exists because Pterodactyl's Wings creates game-server containers on the host Docker socket using floating egg images (`ghcr.io/parkervcp/games:valheim`); without it, Watchtower would recreate a *running game server* at 4 AM. Per-container `enable=false` labels can't solve that, since they only cover containers that already exist — every server added later would be exposed again. Opting in is fine for stateless services, but data-bearing apps that ship breaking DB migrations must not float — an unattended major bump can crash-loop or corrupt on-disk data (this bit Immich: a `:release` jump to v3 dropped pgvecto.rs while the DB image stayed put). Policy:
- **Pin the tag** so Watchtower only patches within a safe line: `jellyfin:10.11`, `mariadb:12` (romm-db), `rommapp/romm:4`, `jc21/nginx-proxy-manager:2`, `codeberg.org/forgejo/forgejo:11`, `postgres:15-alpine`/`14-…` (coolify-db, immich-postgres), `binwiederhier/ntfy:2.26.0` (pinned by tag+digest). Bump these deliberately after reading release notes; **back up the DB first** for anything stateful.
- **Fence with `com.centurylinklabs.watchtower.enable=false`** where there's no clean version tag or the app self-updates: Immich (`immich-server`/`immich-machine-learning`/`immich-postgres`, upgraded by hand in lockstep), Coolify (`coolify`/`coolify-realtime`, update via Coolify's own UI), and ntfy (holds a message cache DB — pinned, bump deliberately).
- **Omit the scope label entirely** for anything that should never auto-update: the four Pterodactyl containers (`pterodactyl-db`, `pterodactyl-cache`, `pterodactyl-panel`, `wings`) are pinned and carry `enable=false` as well, belt-and-braces. `enable=false` and the scope are independent mechanisms; the fence still wins if both are present.
- **Two DB containers auto-update within their pinned tag** (`romm-db` on `mariadb:12`, `coolify-db` on `postgres:15-alpine`, `immich-redis` on `redis:6.2-alpine`). That was the behaviour before the scope change and it was preserved deliberately, but consider fencing them too the next time you touch that area.

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

Generates credentials, stores everything in 1Password tagged `marlboro-nas`, pulls all values, and writes `~/marlboro/.env`. It also does the host-level, non-container setup for this pre-compose phase: media dirs + ownership, the docker wait-for-tank drop-in, **provisioning the Sunshine stream host** (`configure_sunshine` — sway autologin + KMS capture; see Part 7), and the **SMB file share of `/mnt/tank`** (`configure_samba` — Mac/Windows network access; see Part 17.8). Re-run anytime to sync credentials + converge host state.

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
| Marlboro NAS - Pterodactyl Client API | `api_token` | Pterodactyl → avatar → Account → API Credentials → Create (see 24.14) |

`TAILSCALE_HOSTNAME` is auto-populated into `Marlboro NAS - Network` by `setup_script.sh` (pulled from `tailscale status`). `setup_script.sh` writes all five values into `.env`, and `docker-compose.yml` passes them into the Glance container's environment.

If any 1Password item is missing, `setup_script.sh` prints a warning and that widget renders blank until you add the key.

**Adding a widget that needs a *new* env var is two steps, not one.** Glance watches `glance.yml` and hot-reloads it, but a `${VAR}` it cannot resolve fails the **entire** config, not just that widget — `Config has errors: parsing variable: environment variable X not found`. It keeps serving the last good config, so the dashboard stays up and the failure is silent from the browser; every later `glance.yml` edit is also ignored until the variable exists. So add the variable to `setup_script.sh`'s `.env` heredoc and to the `glance` service's `environment:` in `docker-compose.yml`, then `docker compose up -d glance` (a recreate — `restart` does not pick up new env vars). An empty value is enough to make the config load; the widget itself can then report its own auth failure.

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

**Current config:** movies and TV deliberately run **different profiles**.

| App | Profile synced | Assigned to | Ceiling |
|---|---|---|---|
| Radarr | `2160p Quality` **+** `2160p Remux` | all monitored movies → `2160p Remux` | lossless `Remux-2160p` / `Remux-1080p` (`2160p Remux` custom format `+980000`) |
| Sonarr | `2160p Quality` only | all series | `Bluray-2160p` re-encodes (`Remux` custom format is banned at `-999999`) |

Why the split: a 4K HDR remux runs 60–80 Mbps and always forces an HDR→SDR tone-map on the webOS path, and the UHD 630 is already at its limit doing that (Part 16.5). Worth it for a film you sat down to watch; not worth it × 300 episodes at 15–30 GB each. **Both** profiles ban full discs, so neither can pull an unplayable ISO.

`2160p Quality` stays ticked in Profilarr alongside `2160p Remux` on purpose — untick it and the next Sync would delete it from Radarr, orphaning anything still assigned to it.

Upgrades are on in both, so they chase the best release via Dictionarry's custom-format scoring rather than just the highest tier. Note this is **format-score** driven: existing files sit at 860k–985k against `cutoffFormatScore=1000000`, which is *not* reported as "cutoff unmet" (the quality group counts SDTV→Remux-2160p as equivalent), so switching to `2160p Remux` does **not** trigger a mass re-download — better releases just get picked up opportunistically via RSS.

Delay profiles differ by app on purpose:

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
5. **Per instance → Sync**: tick `2160p Quality` **and** `2160p Remux` on Radarr, `2160p Quality` only on Sonarr; select the matching delay profile (Radarr/Sonarr — mandatory), then **Sync**. Profilarr is now the single source of truth for both; re-syncing reproduces exactly these values (no drift to manage).
6. In each arr, assign your library (Sonarr *series editor* / Radarr *movie editor*, bulk) — Radarr movies to `2160p Remux`, Sonarr series to `2160p Quality`.

> **Driving the sync page without the UI.** The selection is stored in `arr_sync_quality_profiles` (`instance_id`, `database_id`, `profile_name`) in `services/profilarr/config/data/profilarr.db`. Don't write that table directly on a running container — go through the same SvelteKit form actions the page uses. `local_bypass_enabled=1` means no login is needed from the LAN, but SvelteKit rejects the POST without an `Origin` header:
>
> ```bash
> # instance 1 = Radarr, 2 = Sonarr; database_id 1 = Dictionarry
> curl -sS -X POST "http://localhost:6868/arr/1/sync?/saveQualityProfiles" \
>   -H 'Origin: http://localhost:6868' \
>   --data-urlencode 'selections=[{"databaseId":1,"profileName":"2160p Quality"},{"databaseId":1,"profileName":"2160p Remux"}]' \
>   --data-urlencode 'trigger=on_pull' --data-urlencode 'cron=0 0 * * *'
>
> curl -sS -X POST "http://localhost:6868/arr/1/sync?/syncQualityProfiles" \
>   -H 'Origin: http://localhost:6868' --data-urlencode 'x=1'
> ```
>
> Without the `Origin` header it returns `Cross-site POST form submissions are forbidden`. The sibling actions are `saveDelayProfiles`/`syncDelayProfiles` and `saveMediaManagement`/`syncMediaManagement`.

> **Resurrect gotcha:** a Sync pushes **only the profiles you tick**. Tick just the one you want — if you select a profile and later delete it in Sonarr/Radarr, the next Sync re-creates it. Starting from a clean v2 install (nothing selected) is the moment to avoid this permanently.

**Drift notifications (via ntfy).** Sync is manual (auto-on-pull left **off**), so Profilarr's **drift detection** is the safety net: it periodically compares the live arr profiles against what Profilarr expects and alerts when they diverge (e.g. a Dictionarry DB update changed `2160p Quality` upstream → time to review + re-Sync). Alerts go to the self-hosted **ntfy** container (`http://ntfy:80` in-stack; `http://192.168.0.10:8194` on LAN/Tailscale). This wiring is **UI-only** (v2 notifications/drift are form-action, not API):

1. **Subscribe** on your phone/browser: ntfy app → add server `http://192.168.0.10:8194` (reachable on LAN or over Tailscale) → subscribe to a topic, e.g. `marlboro-drift` (pick a hard-to-guess name — the server is open read-write, network-gated only).
2. **Profilarr → Settings → Notifications → New → ntfy**: **Server URL** `http://ntfy:80`, **Topic** `marlboro-drift`, enable the **drift** event type, **Save**, then **Test** (confirm it lands on your phone).
3. **Per arr → Drift**: enable drift detection and set a check schedule (cron). Leave auto-sync off — the alert tells you *when* a manual re-Sync is worth doing.

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
download client + root folders + settings, AdGuard, Pterodactyl location/node).
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
16. **Pterodactyl** — ⚙ location + node + allocations + wings `config.yml`; then admin user, egg import and server creation (manual — see Part 24)
17. **Sunshine** — pair first Moonlight client
18. **Glance** — verify all services green

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

> **No BluRay ISOs or disc folders in the library.** Jellyfin reads `.iso` / `BDMV` / `VIDEO_TS` through libbluray (`-f mpegts -i bluray:"…"`), which breaks playback in ways that look like a performance problem but aren't — the transcode runs at 40×+ realtime while the client stutters, hard-stops, or seeks backward in a loop. Three causes stack: (1) libbluray often can't build a seek index (`bluray.c:299: … no timestamp for SPN 0`), so every seek is a blind `-ss -noaccurate_seek` guess and HLS segment numbers stop matching their content; (2) BluRay m2ts timestamps start at an arbitrary offset (`Duration: 01:23:33, start: 4198.000000`) which, fed through `-copyts -avoid_negative_ts disabled`, leaves the player correcting a mismatch it can never resolve; (3) multi-clip playlists change stream layout mid-file (`New audio stream with index 9 at pos:…`) while `-map 0:1` was fixed at launch. Discs with several equal-length playlists are worse — libbluray picks one arbitrarily and it may not be the right cut.
>
> Fix is a lossless remux of the main playlist to MKV — no re-encode, keeps DTS-HD MA and PGS subs, and drops the menus/extras (a 16 GB ISO became an 11 GB MKV). Pick the playlist from the `usable playlists` list ffmpeg prints, matching the known runtime:
>
> ```bash
> docker exec jellyfin /usr/lib/jellyfin-ffmpeg/ffmpeg -playlist 1 \
>   -i "bluray:/media/movies/<Title>/<file>.iso" \
>   -map 0:v:0 -map 0:a -map 0:s -c copy -fflags +genpts \
>   -f matroska "/media/<Title>.mkv"
> ```
>
> Verify with `ffprobe -show_entries format=start_time,duration` — `start_time` must be `0.000000` and `duration` must match the source runtime. **Chapters are lost** (libbluray playlist marks don't survive the mpegts demuxer); re-add them with a chapter-aware tool if they matter.
>
> **How discs are kept out of the library.** Three layers, all in `setup_services.sh` / tracked settings — nothing to click:
>
> | Layer | Where | Effect |
> |---|---|---|
> | `BR-DISK` + `Raw-HD` disallowed | `services/{radarr,sonarr}/settings/quality-profile-any.json` | Radarr parses full discs as quality `BR-DISK`, so this is a hard reject on the `Any` profile |
> | `Full Disc` / `Full Disc (Quality Match)` scored `-999999` | Dictionarry/Profilarr `2160p Quality` **and** `2160p Remux` profiles (`minFormatScore=200000`) | Anything matching scores far below the floor and can never be grabbed. Neither profile lists `BR-DISK` or `Raw-HD` as a selectable quality either |
> | `Block full-disc releases` release profile | `services/sonarr/settings/releaseprofile-nodisc.json` | **Sonarr has no `BR-DISK` quality at all** — a `COMPLETE.BLURAY` TV release misparses as plain `Bluray-1080p` and bypasses the quality filter entirely, so it has to be blocked on release title |
>
> The two ISOs that got in (`Baboon Heart`, `The Witch`) were auto-grabbed from IPTorrents in May/June 2026 while assigned to a quality profile that still allowed `BR-DISK`. Seerr is bound by profile **name** in `configure_seerr` (`SEERR_PROFILE_RADARR` / `SEERR_PROFILE_SONARR`), so it can't drift onto an unguarded profile again — but anything added directly in Radarr/Sonarr lands on `Any`, which is why `BR-DISK`/`Raw-HD` had to be turned off there too.
>
> **Gotcha that hid this for weeks:** a quality-profile `PUT` must carry *every* custom format currently in the *arr and no extras, or it 400s with `All Custom Formats and no extra ones need to be present inside your Profile!`. Profilarr adds and renames Dictionarry formats over time (this stack's `Any` profile went 163 → 164 formats mid-session just from syncing one new profile), so a stored `formatItems` list goes stale and the `BR-DISK` fix silently stopped applying — `setup_services.sh` was discarding the response body and only logging a generic warning. `apply_settings_json` now reports the validation error, and `configure_arr` re-keys the tracked scores onto the **live** format roster before PUTting, so the tracked file stays the source of truth for intent while the server decides the roster.

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

### 17.8 Network File Sharing (SMB)

Exposes the tank on the macOS Finder sidebar and the Windows "Network" tab. The
whole host side is scripted in [`setup_script.sh`](./setup_script.sh) (its
`configure_samba` step, Part 5) — installs `samba` + `wsdd`, creates/pulls the
SMB password from 1Password (`Marlboro NAS - Samba`), writes
`/etc/samba/smb.conf`, advertises via avahi (Bonjour, macOS) + wsdd
(WS-Discovery, Windows), and enables the daemons. Already handled by the Part 5
run — there's no separate Samba command. To (re)provision just this on its own:

```bash
eval $(op signin)        # smbpasswd + the 1Password item need an active session
./setup_script.sh        # idempotent; converges the whole host incl. Samba
```

Shares (SMB3-only, opportunistically encrypted; user `bcalegari`):

| Share | Path | Access |
|---|---|---|
| `media` | `/mnt/tank/media` | read-write (movies/tv/roms) |
| `downloads` | `/mnt/tank/downloads` | read-write |

`photos` is **not** shared — it's Immich-managed and writing to it out-of-band
would drift Immich's DB. smbd binds all addresses and is fenced by **source
subnet** (`hosts allow`/`hosts deny`) to LAN + Tailscale + loopback — docker
bridges (172.16/12) are denied. (`bind interfaces only` is *not* used: it can't
serve Tailscale, whose point-to-point TUN Samba's interface matching drops —
and MagicDNS resolves `marlboro` to the tailnet IP, so SMB must answer there.)
Every connection is still user/password-gated and SMB3-encrypted. No ufw is active; if you enable it,
allow `445/tcp` (SMB), `3702/udp` + `5357/tcp` (wsdd), and `5353/udp` (mDNS).

**Mounting from a Mac** — `marlboro` appears in the Finder sidebar under
Network/Locations, or connect explicitly with **⌘K** (Finder → Go → Connect to
Server). Username `bcalegari`, password from the `Marlboro NAS - Samba` item:

```
smb://<lan-ip>/media            # on the LAN
smb://<tailscale-ip>/media      # remote, over Tailscale
```

**Mounting from Windows** — `MARLBORO` shows in File Explorer → Network, or type
into the address bar (same credentials):

```
\\<lan-ip>\media
\\<tailscale-ip>\media           # remote, over Tailscale
```

> Retrieve the IPs with `op item get "Marlboro NAS - Network" --vault Private
> --fields static-ip` (and `--fields tailscale-ip`). To rotate the SMB password:
> `op item edit "Marlboro NAS - Samba" password=…` then re-run `setup_script.sh`.

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

> **This stack is currently STOPPED.** It was stopped to free memory for the Pterodactyl
> game server (Part 24) on a 7 GB box that was already swapping ~5.5 GB. The compose
> blocks and everything under `services/coolify/` are kept, so it can come back at any
> time. Two things to know:
>
> - **`docker compose up -d` with no service name will restart it.** Bring the rest of
>   the stack up by naming services, or stop Coolify again afterwards.
> - **`coolify-sentinel` is spawned by Coolify itself, not by compose**, so it needs a
>   plain `docker stop coolify-sentinel`.
>
> ```bash
> # bring it back
> docker compose up -d coolify-db coolify-redis coolify coolify-realtime
> # stop it again (note sentinel is not a compose service)
> docker compose stop coolify coolify-realtime coolify-db coolify-redis
> docker stop coolify-sentinel
> ```

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

## Part 23: SMS Requests (Twilio → Seerr → Jellyfin)

Text a title to the house number, get numbered matches back, reply with a number, get a text when it's playable in Jellyfin. Nothing to install on anyone's phone.

```
  "dune part two"  ──►  Twilio  ──►  NPM :443  ──►  sms-bridge  ──►  Seerr
                                                          ▲             │
  "1. Dune: Part Two (2024) [movie]  ◄───────────────────┘             │
   Reply 1-3 to request."                                              ▼
                                                                  Radarr/Sonarr
  "Dune: Part Two is ready on Jellyfin."  ◄── sms-bridge ◄── Seerr webhook
```

The bridge itself (`services/sms-bridge/bridge.py`), its proxy host, and Seerr's webhook agent are all scripted — ⚙ `setup_services.sh` handles them. What's below is only the part that can't be: the Twilio account, the number, and collecting people's phone numbers.

### 23.1 Number and carrier registration (10DLC sole proprietor)

**Toll-free was tried first and failed. Don't retry it.** Recorded so nobody repeats it:

| Attempt | Result |
|---|---|
| 1st | `30530` Entity Misclassification — `business_type=SOLE_PROPRIETOR` with `business_name="Cousin Ben Consulting LLC"`. Auto-rejected in 15 seconds. Fixed by using the individual's name plus `doing_business_as`. |
| 2nd | `30445` business information could not be verified, `30489` website must be established and active, `30513` opt-in consent required. |

Root cause of the second round: **toll-free verification is business vetting.** There is no business here, no established website, and the contact email was an iCloud Hide My Email relay. Pointing `business_website` at the self-hosted Forgejo (`git.marlboro-bc.duckdns.org`) made it worse — a dynamic-DNS host serving a git repo is not an established site, and that alone earns `30489`. Don't go back to toll-free without a registered domain with real content and a non-relay mailbox.

10DLC sole proprietor is the path built for an individual with no company and no website: verification is **identity-based** (legal name, address, email, mobile OTP), website optional. Costs about $4 once for the brand, ~$2/mo for the campaign, and ~$1.15/mo for a local number. Sole-prop throughput caps are far above a few messages a week.

**Upgrade off the trial first.** A trial account can only message numbers you've verified in the console, and it prepends `Sent from your Twilio trial account -` to every message — which corrupts the sample messages and any screenshot you submit.

**Steps:**

1. **Buy a local number.** Phone Numbers → Buy a number → filter **Local**, capability **SMS**.
2. **Register the brand.** Messaging → Regulatory Compliance → A2P 10DLC → Brands → create, type **Sole Proprietor**. Two things that caused `30445` last time and will do it again here:
   - Use a **real mailbox**, not an iCloud Hide My Email relay. Relay aliases read as unverifiable to identity checks.
   - Make the **address match the state of the mobile number you verify with**. A San Francisco address with a `+1603` New Hampshire phone is a standard mismatch trigger.
3. **Create the campaign.** Sole-prop brands allow exactly one. Use the samples and opt-in wording from 23.2.
4. **Create a Messaging Service**, add the number to its sender pool, and link the campaign. 10DLC sending requires this.
5. **Keep the inbound webhook working.** A Messaging Service can override the number's own webhook — either enable *use inbound webhook on number* on the Service, or set the Service's inbound webhook to the same URL from 23.3.
6. **Release the toll-free number** once 10DLC is delivering, to stop paying $2.15/mo for it.

### 23.2 Registration content: samples, opt-in, keywords

The campaign asks for the same substance the toll-free form did.

| Field | What to put |
|---|---|
| Use case | Sole Proprietor (the only option on a sole-prop brand) |
| Description | Private household media server. Members text a movie or TV title to request it and receive one notification when it becomes available. Every conversation is initiated by the member. |
| Opt-in method | Consumer-initiated: the member texts a title to the number. Numbers were also collected verbally, in person. No web form, no purchased or imported lists, no marketing. |
| Message volume | Lowest bucket offered |

**Sample messages** — paste verbatim; these are what the bridge actually sends:

```
Marlboro Media: 1. Dune: Part Two (2024) [movie]
2. Dune (2021) [movie]
Reply 1-2 to request.
Reply STOP to opt out.

Marlboro Media: Requested Dune: Part Two. You'll get a text when it's on Jellyfin.

Marlboro Media: Dune: Part Two is ready on Jellyfin.
```

Every outbound text is branded (`BRAND` in `bridge.py`) so a recipient can always tell who is texting them, and the sender identity must match the campaign's `doing_business_as`. The opt-out notice rides on the **first message of a conversation only**, and again if a number goes quiet for 30 days; repeating it every time would burn an SMS segment for no compliance gain.

**Opt-in evidence** — keep the artifacts already published; campaign vetting asks for the same thing:

1. A screenshot of your phone showing *you texting the number first*. That outbound message **is** the consent under consumer-initiated opt-in.
2. A screenshot of **Monitor → Logs → Messages** showing the inbound message and the `outbound-reply` with its full body.
3. The consent notice (`services/sms-bridge/OPT-IN.md`), published publicly — see 23.8.

Every URL must load with **no login**. Reviewers will not authenticate, and will not reach anything behind Tailscale.

**Keyword handling changes once a Messaging Service exists.** Twilio's Advanced Opt-Out — which answers `STOP`/`HELP` before the webhook fires — is a Messaging Service feature. On the toll-free setup there was no Service, so every keyword reached the bridge and `bridge.py` had to answer `HELP` itself; without that, "HELP" was treated as a search and replied with movie titles (*Send Help (2026)*, *The Help (2011)*).

With a Messaging Service in place for 10DLC, **verify which side answers** — text `HELP` and count the replies:

- **One reply** → whichever side handled it is fine. If Advanced Opt-Out answered, make its HELP text match `HELP_TEXT` in `bridge.py` so the campaign samples stay accurate.
- **Two replies** → both sides answered. Either disable Advanced Opt-Out on the Service, or remove `HELP`/`INFO` from `HELP_KEYWORDS`.
- **No reply** → neither side answered; check the Service's inbound webhook (step 5 in 23.1).

`STOP`, `STOPALL`, `UNSUBSCRIBE`, `CANCEL`, `END`, `QUIT`, `START`, `UNSTOP`, `YES` stay silent in the bridge (HTTP 204, logged) either way. Twilio enforces opt-out account-wide regardless — a send to an opted-out number fails with `21610` — so answering would double up on the platform or contradict it. Carrier-reserved words beat titles, which does mean a film literally called *Cancel* can't be found by exact title. Correct trade.

### 23.3 Point the number at the bridge

**Phone Numbers → Manage → Active numbers →** your number **→ Configure → Messaging**:

- **A message comes in:** Webhook, `HTTPS POST`
- URL: `https://sms.marlboro-bc.duckdns.org/twilio/inbound`

This URL must match `SMS_BRIDGE_PUBLIC_URL` in `.env` **character for character**. Twilio signs the exact URL it POSTs to, and the bridge — sitting behind NPM, where it only ever sees the internal URL — verifies against the configured value rather than the request headers. A trailing-slash mismatch shows up as every message 403ing with `REJECTED: bad Twilio signature`, which reads like a credentials problem and isn't.

Only `/twilio/inbound` is publicly routable. NPM 404s every other path on that hostname (see `npm_advanced_config` in `setup_services.sh`), so `/seerr/hook` and `/healthz` stay LAN/Tailscale-only despite the public name.

### 23.4 Create the 1Password items

Two items, both created by hand (`setup_script.sh` only warns if they're missing — it can't invent them):

**`Marlboro NAS - Twilio`** — from **Account → API keys & tokens** in the console:

| Field | Value |
|---|---|
| `account_sid` | `AC…` |
| `auth_token` | the account auth token (this is what signs webhooks — treat it as a password) |
| `from_number` | your 10DLC local number in E.164, e.g. `+15035550142` |

**`Marlboro NAS - SMS Allowlist`** — one field, `allowlist`:

```
+15035550142=bcalegari,+15035550143=mom
```

Phone in E.164 `=` that person's **Seerr display name**, comma-separated. The name must match a real Seerr user (`http://192.168.0.10:5055/users`) — the bridge matches it against `displayName`, `username`, and `jellyfinUsername`, case-insensitively, because a Jellyfin-linked account carries no `username` at all.

This lives in 1Password rather than the repo because it's household phone numbers — PII that has no business in git history.

**The allowlist is the security boundary.** A number that isn't on it gets no reply of any kind (the bridge returns `204` and logs the attempt), and the bridge will never send a text to a number that isn't on it, even if Seerr asks. That's what stops a public SMS endpoint from becoming a relay someone else can run up your Twilio bill with. `SMS_DAILY_CAP` in `.env` (default 100) is the backstop if that ever fails.

Requests are attributed to the mapped Seerr user, so each person's existing approval permissions and quotas apply unchanged — the bridge makes no approval policy of its own.

### 23.5 Bring it up

```bash
./setup_script.sh                    # writes the Twilio vars into .env
docker compose up -d sms-bridge
./setup_services.sh                  # proxy host + cert + Seerr's webhook agent
docker logs sms-bridge | tail -5     # should list the allowlist size
```

Then in Seerr: **Settings → Notifications → Webhook → Test**. `sms-bridge` logs `seerr hook: test notification OK`.

### 23.6 Caveats

- **"Ready" means Seerr noticed, not that the import finished.** Seerr marks media available on its own Jellyfin sync, so expect a few minutes' lag between the file landing and the text.
- **Requests made in the Seerr web UI still get a text**, as long as that user's display name is in the allowlist — the bridge falls back to `requestedBy_username` when it has no request-id row of its own.
- Failed and declined requests text too. A request that dies in silence is worse than no bot.
- Each person is rate-limited to 12 inbound messages an hour, and pick-a-number sessions expire after 15 minutes.
- Long replies truncate the *body*, never the brand prefix or the opt-out notice, and pad with `...` rather than `…` — one non-GSM-7 character flips the whole message to UCS-2 and halves what fits in a segment.

### 23.7 Verify it works

Run these in order — each isolates a different layer, so the first one that fails tells you where the problem is.

**1. Bridge is alive (on the box):**

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8195/healthz   # 200
docker logs sms-bridge | tail -3        # should print the allowlist size, no "unset env" warning
```

**2. DNS resolves to you:**

```bash
dig +short sms.marlboro-bc.duckdns.org        # your public IP
curl -s ifconfig.me; echo                     # same IP
```

**3. Public endpoint, from OFF your network.** Use a laptop on a phone hotspot — not the LAN, and not Tailscale. A double-NAT setup can pass a LAN test and still fail from the internet (see Part 19):

```bash
curl -s -o /dev/null -w 'inbound  %{http_code}\n' -X POST https://sms.marlboro-bc.duckdns.org/twilio/inbound  # 403
curl -s -o /dev/null -w 'healthz  %{http_code}\n' https://sms.marlboro-bc.duckdns.org/healthz                 # 404
curl -s -o /dev/null -w 'hook     %{http_code}\n' -X POST https://sms.marlboro-bc.duckdns.org/seerr/hook      # 404
```

`403` on the first proves the route is live and signature-gated. `404` on the other two proves the path lockdown holds — those must stay LAN/Tailscale-only.

**4. Text it.** Start with a title **already in the library** — that path replies without creating a request or starting a download, so it exercises the whole loop for free:

```
you  ->  paprika
bot  ->  Marlboro Media: Paprika is already on Jellyfin.
         Reply STOP to opt out.
```

Watch it land with `docker logs -f sms-bridge`. Then do a real one: text a title you don't have, reply with its number, and confirm in Seerr that the request is attributed to **your user**, not the admin account.

**Troubleshooting:**

| Symptom | Cause |
|---|---|
| No log line at all in `sms-bridge` | Twilio never reached you. Check the number's Messaging webhook, and Twilio console → Monitor → Errors |
| `REJECTED: bad Twilio signature` | `SMS_BRIDGE_PUBLIC_URL` ≠ the webhook URL in Twilio, character for character. Trailing slash counts |
| `IGNORED: message from non-allowlisted` | Number isn't in the allowlist item, or isn't E.164 |
| `allowlist name 'x' matches no Seerr user` | Name doesn't match any Seerr `displayName`/`username`/`jellyfinUsername` |
| Reply never arrives on the handset | Carrier registration incomplete. Twilio console → Monitor → Logs → Messages; `30032` is unverified toll-free, `30034` is unregistered 10DLC, `30007` is carrier filtering |
| Request created but no "ready" text | Seerr's webhook agent — re-run `./setup_services.sh`, then Settings → Notifications → Webhook → Test |

### 23.8 Publish the opt-in evidence

Carrier registration wants a publicly reachable URL showing the opt-in. `services/sms-bridge/OPT-IN.md` is the consent notice — publish a copy where a reviewer can read it without logging in.

Use the Forgejo already running at `git.marlboro-bc.duckdns.org` (public hostname, no new attack surface):

1. Fill in the three placeholders at the top of `OPT-IN.md` (name, contact, number).
2. New repo on Forgejo named `sms-optin`, visibility **Public**.
3. Add the notice as `README.md` so the repo's landing page renders it, plus a screenshot of a real conversation as `optin-screenshot.png`.
4. Give Twilio both URLs:
   - `https://git.marlboro-bc.duckdns.org/<user>/sms-optin`
   - `https://git.marlboro-bc.duckdns.org/<user>/sms-optin/raw/branch/main/optin-screenshot.png`
5. **Open both in a private window with no session.** If either asks for a login, the reviewer sees nothing and the submission is rejected. This is the most common failure.

Keep that repo limited to the notice and the screenshot — no allowlist, no phone numbers other than the sending number itself.

---

## Part 24: Pterodactyl (Game Server Panel + Valheim)

Pterodactyl is two pieces: a **Panel** (Laravel web app — this is the UI and API) and a
**Wings** node daemon. Wings is *not* docker-in-docker; it talks to the **host** Docker
socket and creates one sibling container per game server. Four containers make up the
stack: `pterodactyl-db` (MariaDB), `pterodactyl-cache` (Redis), `pterodactyl-panel`, and
`wings`.

**Tailnet-only, and deliberately not behind NPM.** That isn't just a scope decision — it
removes the single most awkward part of a Pterodactyl install. The browser console opens a
websocket **directly to Wings** at `ws(s)://<node fqdn>:<daemon port>/api/servers/<uuid>/ws`,
built from the node record rather than proxied through the panel. An HTTPS panel therefore
forces TLS on Wings too (mixed content blocks `ws://` from an `https://` page), which means
a second cert and a second proxy vhost. Plain HTTP end-to-end over the tailnet keeps
`ws://` legal and needs no certificate at all. Valheim's game traffic is UDP and could
never traverse NPM regardless — and with crossplay on it never has to be exposed to the
internet at all, because the PlayFab relay carries it (24.8).

Pterodactyl publishes **no official Docker install documentation** — only two
`docker-compose.example.yml` files (see `pterodactyl/documentation#457`). Three of their
assumptions are wrong on this host; all three are fixed in `docker-compose.yml` and
explained in 24.13.

Everything up to and including the node, its Wings config, its allocations and the
server's crossplay flag is scripted (24.1, 24.4, 24.5, 24.8). Three steps stay manual: the
**admin user** (needs 1Password, like Forgejo), the **egg import** plus **server creation**
(both UI-only in panel 1.x), and the **client API key** that feeds the Glance tile (24.14).
No router forward is needed while crossplay is on.

### 24.1 Run the Setup Script

```bash
./setup_script.sh
```

| 1Password Item | .env Variable | Used For |
|---|---|---|
| `Marlboro NAS - Pterodactyl App Key` | `PTERO_APP_KEY` | Laravel `APP_KEY`. **Also decrypts every Wings node's daemon token** |
| `Marlboro NAS - Pterodactyl Hashids` | `PTERO_HASHIDS_SALT` | Obfuscates short server IDs in panel URLs |
| `Marlboro NAS - Pterodactyl DB` | `PTERO_DB_PASSWORD` | Panel → MariaDB |
| `Marlboro NAS - Pterodactyl DB Root` | `PTERO_DB_ROOT_PASSWORD` | MariaDB root (also used for the reconciler's existence checks) |
| `Marlboro NAS - Pterodactyl Admin` | *(not in .env)* | Panel admin account, created by CLI in 24.3 |

`APP_KEY` is **not rotatable.** The panel encrypts each node's daemon token with it, so
changing it takes every node offline until its `config.yml` is regenerated. It is pinned in
`.env` rather than left to the image (whose entrypoint would self-generate one), and
`services/pterodactyl/panel-var` is a persistent mount because the panel's own generated
`.env` lives there. Back both up alongside the DB.

The script also creates the data directories, including the identity-mapped ones under
`/mnt/tank/pterodactyl` (see 24.10).

### 24.2 Start the Panel

```bash
docker compose up -d pterodactyl-db pterodactyl-cache
docker compose up -d pterodactyl-panel
docker compose logs -f pterodactyl-panel
```

The image's entrypoint waits for the DB and then runs `php artisan migrate --seed --force`
itself, so there is no manual migration step — wait for the migrations to finish and nginx
to come up. No separate queue-worker or cron container is needed either: the image runs
supervisord (`php-fpm`, `nginx`, `queue:work --queue=high,standard,low`) and bakes
`artisan schedule:run` into root's crontab.

Confirm before going further:

```bash
curl -I http://192.168.0.10:8091     # expect 302 -> /auth/login
```

### 24.3 Create the Admin Account

Same pattern as Forgejo (Part 22.3) — the password comes straight from 1Password and never
lands in `.env`:

```bash
docker compose exec -T pterodactyl-panel php artisan p:user:make \
  --email=bencalegari@navapbc.com \
  --username="$(op item get 'Marlboro NAS - Pterodactyl Admin' --vault Private --fields username --reveal)" \
  --name-first=Ben --name-last=Calegari \
  --password="$(op item get 'Marlboro NAS - Pterodactyl Admin' --vault Private --fields password --reveal)" \
  --admin=1
```

Every artisan option falls through to an **interactive prompt** when omitted, and
`docker compose exec -T` has no TTY — so pass every flag explicitly or the command hangs.
`p:user:make` requires 8+ characters, mixed case and at least one digit; the generator's
`letters,digits,32` satisfies that.

Log in at `http://marlboro.tail314238.ts.net:8091` to confirm.

### 24.4 Create the Node and Generate Wings' Config (scripted)

```bash
./setup_services.sh          # configure_pterodactyl step
```

`configure_pterodactyl()` creates the `home` location and the `marlboro` node
(`p:location:make` / `p:node:make`), generates Wings' `config.yml` with
`p:node:configuration` into `services/pterodactyl/wings-etc/`, and seeds the allocations
(24.5). It is idempotent: it skips the location, node and allocations if they exist, and
only regenerates `config.yml` when the node's daemon token no longer matches the panel.

It then **patches two things the panel never emits**, which is the part that makes this
work on this host:

- **Paths.** Wings' directory defaults are literal strings (`/var/lib/pterodactyl/...`),
  *not* derived from `root_directory`. Each one is set explicitly to
  `/mnt/tank/pterodactyl/{volumes,archives,backups,logs}` — otherwise world backups land
  on the 30 GB root disk.
- **Network.** Wings' default game-server network is `172.18.0.0/16`, which
  `marlboro_homelab` **already occupies** (172.17 is docker0, 172.19 is coolify). It is
  overridden to `172.22.0.0/16`.

`configure_pterodactyl()` also **pre-creates the `pterodactyl_nw` bridge, IPv4-only.**
Wings creates that network itself when it is missing, and it creates it with an IPv6 ULA
subnet — which breaks Valheim on this host (24.13). Wings uses an existing network exactly
as it finds it, so creating it first is the whole fix.

Then start Wings and confirm the node badge goes green in the panel:

```bash
docker compose up -d wings
docker compose logs -f wings
```

Wings is a **distroless** image — no shell, so `docker exec` debugging is impossible. Use
`docker run --rm --entrypoint /usr/bin/wings ghcr.io/pterodactyl/wings:v1.13.3 --help`.

### 24.5 Allocations (scripted)

`configure_pterodactyl()` also seeds the allocations: IP `0.0.0.0`, ports `2456` and
`2457`. Verify at Panel → **Admin → Nodes → marlboro → Allocations**.

`0.0.0.0` rather than `192.168.0.10` so the server answers on LAN, tailnet and the public
forward alike. Wings registers **both TCP and UDP** for every allocated port
automatically, so Valheim's UDP needs nothing special. Note these ports are published by
the *game* container, not by the `wings` service — which is why they are absent from the
`wings` block's `ports:` list.

These go in by **direct SQL**, unlike everything else in that function: panel 1.x has no
`p:allocation:*` artisan command (confirmed against `artisan list` — there are no egg,
nest or allocation commands at all), and the Application API needs an API key that doesn't
exist yet on a fresh install. `allocations` is a flat `(node_id, ip, port)` table and the
insert is guarded by `WHERE NOT EXISTS`, so it stays idempotent. To add ports for a second
game server later, extend `PTERO_ALLOC_PORTS` and re-run.

### 24.6 Import the Valheim Egg (manual, UI-only)

Panel → **Admin → Nests** → create a nest (e.g. `Games`) → **Import Egg** → upload
`services/pterodactyl/egg-valheim.json`.

This is the one step with no automation path: panel 1.x has no egg-import artisan command
and no Application API endpoint for it. That is exactly why the egg JSON is **committed**
to the repo (with a `.gitignore` exception) — it is the only record of what to re-import
on a rebuild, rather than depending on the upstream repo still existing. It came from
`pelican-eggs/eggs` (formerly `parkervcp/eggs`),
`game_eggs/steamcmd_servers/valheim/valheim_vanilla/egg-valheim.json`, `meta.version`
`PTDL_v2`, docker image `ghcr.io/parkervcp/games:valheim`.

### 24.7 Create the Valheim Server (manual)

Panel → **Servers → Create New**. Owner = the admin from 24.3, nest/egg = the imported
Valheim egg.

| Setting | Value | Why |
|---|---|---|
| Primary allocation | `0.0.0.0:2456` | `{{SERVER_PORT}}` in the startup command |
| Additional allocation | `0.0.0.0:2457` | Valheim's query port is always game port + 1 |
| Memory | `2560` MB | Hard cap — this box has ~4 GB spare (see 24.10) |
| Swap | `0` | A game server must never swap |
| Disk | `8192` MB | Valheim + SteamCMD is ~2–3 GB; leaves room for backups |

Egg variables worth setting: `SERVER_NAME`, `WORLD` (default `Dedicated`), `PASSWORD`
(**5–20 chars, and it must not contain the world name** or Valheim refuses to start),
`PUBLIC_SERVER=1`, `AUTO_UPDATE=1`, and **`ENABLE_CROSSPLAY=1`** — the last two are
reconciled by `setup_services.sh` from `PTERO_VALHEIM_AUTO_UPDATE` /
`PTERO_VALHEIM_CROSSPLAY`, so set those there rather than in the UI (24.8, 24.16).

Start it and watch the console. First boot pulls several GB via SteamCMD. It is ready when
the console prints **`DungeonDB Start`** (the egg's configured done-string).

### 24.8 External Access — Join Code (crossplay on)

**Current config: `ENABLE_CROSSPLAY=1`**, reconciled by `setup_services.sh`
(`PTERO_VALHEIM_CROSSPLAY`). The server runs over the PlayFab relay, so it is reachable
from anywhere with **no router forward, no DuckDNS name and no open port** — and it admits
Xbox/Game Pass players. Restored on 2026-09-10 after the Steam-only configuration below
turned out to be unreachable from outside this LAN.

Players join with the **join code**, printed once per boot:

```bash
docker logs <server-uuid> 2>&1 | grep -i "registered with join code"
# 09/11/2026 06:10:24: Session "Valhymen" registered with join code 666894
```

The code changes on every restart. The console also shows it, and `Opened PlayFab server`
+ `Game server connected` is the healthy-boot signature in this mode. A healthy boot then
prints the session line with a real address:
`Session "<name>" with join code <code> and IP <public-ip>:2456 is active`. If that line
shows an empty IP and the log is filling with `Could not extract valid IP address from
externalIP download string`, the game network has IPv6 enabled — see 24.13.

Changing the flag is a `setup_services.sh` edit, not a UI click:

```bash
# PTERO_VALHEIM_CROSSPLAY=1 in setup_services.sh, then:
./setup_services.sh                      # writes the panel egg variable, idempotent
docker compose restart wings             # wings re-reads server configs from the panel
# then stop + start the server from the panel (a restart re-creates the game container,
# which is what actually picks up the new startup flag)
```

**Stopping loses anything since the last autosave.** Wings stops this egg with `^C`, and
the observed shutdown wrote **no** final world save — the last one was 6 minutes earlier,
and `BACKUP_INTERVAL` is 1800s. Valheim's dedicated server takes no stdin commands, so
there is no way to force a save first. Stop shortly after a `World save (5/5) done` line,
or accept losing up to 30 minutes of world changes (player inventories are client-side and
unaffected).

#### Why crossplay was turned off, and back on

Off on 2026-09-10 for a PC-only group, after a clean 2.5-hour five-player session ended
with relay-teardown noise as each player quit:

```
Keep socket for playfab/<id>, try to reconnect before timeout
PlayFab network error ... code '4098': the operation was called with an invalid handle
ZRpc timeout detected
```

Those were harmless quit artifacts — zero network errors in the preceding 2h34m — so the
only real motive was dropping relay dependency. Back on the same day: in Steam-only mode
LAN clients connected fine to `192.168.0.10:2456`, but **no off-network player could
connect at all**, and the server logged no inbound connection attempt in 22 hours. The
relay costs nothing measurable and needs no NAT cooperation, so the Steam-only path was
abandoned rather than debugged further.

Saves survive the switch in both directions — the world reloaded with all 66,156 ZDOs and
its player history intact each time.

#### What was ruled out while the Steam-only mode was failing

Worth keeping, because it applies to any future UDP service here.

**Inbound WAN traffic works in general — this is not CGNAT.** NPM's access log shows
Twilio reaching 443 from public addresses:

```bash
docker exec nginx-proxy-manager sh -c 'cat /data/logs/proxy-host-*_access.log' | tail -3
# [10/Sep/2026:19:00:34 +0000] - 200 ... [Client 3.83.172.168] ... "TwilioProxy/1.1"
```

DuckDNS was also current (`getent hosts marlboro-bc.duckdns.org` == `curl api.ipify.org`).

**Check both address families when verifying the game is listening.** Valheim binds the
game port as an IPv6 wildcard socket (`[::]:2456`), which serves IPv4 too because
`net.ipv6.bindv6only=0`. Reading only `/proc/<pid>/net/udp` gives a **false negative**:

```bash
PID=$(docker inspect <uuid> --format '{{.State.Pid}}')
for f in udp udp6; do
  echo "-- $f"; tail -n +2 /proc/$PID/net/$f | awk '{split($2,a,":"); print a[2]}' \
    | while read h; do echo $((16#$h)); done | sort -n | uniq
done
# crossplay OFF -> udp: 2457 + ephemerals   udp6: 2456      <- game port here
# crossplay ON  -> udp: 2457 + ephemerals   udp6: (no 2456) <- game port never bound
```

Under crossplay the game port is never bound at all, which is why a forward is pointless
in that mode.

**The query port answers A2S, and that is a clean LAN-side health probe** (crossplay does
not change it — 2457 stays bound either way):

```bash
python3 -c "
import socket,sys
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(4)
s.sendto(b'\xff\xff\xff\xffTSource Engine Query\x00',(sys.argv[1],2457)); print(s.recvfrom(64)[0])" 192.168.0.10
# b'\xff\xff\xff\xffA...'  = challenge reply, server is alive
```

**An inbound UDP forward cannot be tested from inside this LAN.** UDP hairpin (NAT
loopback) does not work here even though TCP hairpin does: the A2S probe above answers on
`192.168.0.10` and times out on the public IP, and a `curl --resolve` to the public IP on
443 returns 302. A near-zero result from inside therefore proves nothing. The only honest
test is an off-network client.

Counting arrivals inside the container's namespace is the matching check, but note the
counter is per-netns and includes the Steam/PlayFab ephemeral sockets — baseline drift here
was ~6 datagrams per 90s with nobody connected:

```bash
ind(){ grep -A1 '^Udp:' /proc/$PID/net/snmp | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="InDatagrams") c=i} NR==2{print $c}'; }
a=$(ind); sleep 90; echo "drift: $(( $(ind) - a ))"
```

`NoPorts` is the right counter only while 2456 is unbound; once it is bound, use
`InDatagrams`. The unambiguous signal is the game log itself — a real client attempt prints
`Got connection SteamID <id>` followed by `Got handshake from client`.

#### Router forward — only needed with crossplay off

Not in use. If crossplay is ever set to 0, these two rules become required:
TP-Link BE3600 → Advanced → NAT Forwarding → **Virtual Servers**:

| External Port | Internal Port | Internal IP | Protocol |
|---|---|---|---|
| 2456 | 2456 | 192.168.0.10 | UDP |
| 2457 | 2457 | 192.168.0.10 | UDP |

NPM cannot help — it does not proxy UDP. Use `192.168.0.10`: it is the static address and
what the host sources outbound traffic from. The NIC also carries a stray dynamic
`192.168.0.37` lease which is **not** the right target.

**UPnP is not an option here.** It looks healthy (`upnpc -l` finds the IGD and lists
working Plex/qBittorrent mappings) but every `AddPortMapping` returns
`501 (Action Failed)` for any port and protocol — the router's table is capped at **64 and
permanently saturated**, 56 entries being transient `tailscale-portmap` churn:

```bash
upnpc -l | grep -cE '^ *[0-9]+ (TCP|UDP) '                     # 64 = full
upnpc -l | awk -F"'" '{print $2}' | sort | uniq -c | sort -rn   # 56 are tailscale
```

`upnpc -s` also fails to return an external address at all on this router
(`GetExternalIPAddress failed`), so it is no help for confirming the WAN IP either.

Remember that when debugging *other* services: while the table is full, nothing on this
LAN can add a UPnP mapping, so an evicted Plex or qBittorrent mapping will not return by
itself.

### 24.9 Ports Used

| Port | Purpose |
|---|---|
| 8091 | Panel web UI (container port 80). Tailnet/LAN only |
| 8092 | Wings API + console websocket. Port is **identity-mapped** on purpose (see 24.13) |
| 2022 | Wings SFTP (implemented by Wings itself, no sshd) |
| 2456–2457 UDP | Valheim game + query. Under crossplay only 2457 binds; 2456 binds as `[::]:2456` (dual-stack — check `udp6`, not just `udp`) only with crossplay off. **Not forwarded** (24.8) |

### 24.10 Recovering a Server Stuck at `installing`

If a server row exists but wings never built it (the panel 500'd on create, or wings was
unreachable at that moment), the panel shows `installing` forever. Fix the underlying
connectivity first, then re-dispatch the install rather than deleting and recreating.

```bash
# 1. Confirm both directions resolve. Both must print an address and reach the other.
docker compose exec -T pterodactyl-panel sh -c \
  'getent hosts marlboro.tail314238.ts.net && curl -s -o /dev/null -w "wings http=%{http_code}\n" http://marlboro.tail314238.ts.net:8092/api/system'
# 401 from wings is CORRECT — it means HTTP works and auth is required.

# 2. Make wings pick up any server rows it doesn't know about.
docker compose restart wings
docker compose logs --tail=20 wings      # expect: total_configs=1

# 3. Re-dispatch the install (this is the same call the panel makes).
UUID=$(docker compose exec -T pterodactyl-db mariadb -N -B -u root \
  -p"$(grep -E '^PTERO_DB_ROOT_PASSWORD=' .env | cut -d= -f2-)" panel \
  -e "SELECT uuid FROM servers WHERE status='installing' LIMIT 1;")
TOK=$(python3 -c "import yaml;print(yaml.safe_load(open('services/pterodactyl/wings-etc/config.yml'))['token'])")
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  -H "Authorization: Bearer $TOK" "http://192.168.0.10:8092/api/servers/$UUID/install"
# 202 = accepted. Watch: docker compose logs -f wings
```

**SteamCMD's first run can silently fail the download.** On a fresh volume, SteamCMD
self-updates and *restarts mid-run*, which drops the queued `app_update`. The install log
ends with `ERROR! Failed to install app '896660' (Missing configuration)` — but wings
still marks `installed_at`, so the panel looks fine while the volume contains only
`steamcmd/` and an empty `steamapps/` (~289 MB, no `valheim_server.x86_64`). Simply
re-dispatch the install: the appinfo cache now persists in the volume, so the second run
downloads all 2.3 GB and ends with `Success! App '896660' fully installed.` Check with:

```bash
ls -la /mnt/tank/pterodactyl/volumes/<uuid>/valheim_server.x86_64
docker run --rm -v /mnt/tank/pterodactyl/logs/install:/l:ro alpine sh -c 'tail -20 /l/*.log'
```

(The install log directory is root-owned `0700`, hence reading it through a container.)

A `could create base environment for server` error in the wings log **at boot** is benign
— wings cannot pre-create a game container for a server that isn't installed yet. It is
only a problem if it appears in response to an actual install or start request.

Alternatively, Admin → Servers → *server* → Manage → **Reinstall Server** does the same
thing from the UI once connectivity is fixed.

### 24.11 Volume Ownership Looks Wrong But Isn't

After a successful start, `/mnt/tank/pterodactyl/volumes/<uuid>` is owned by
**`fwupd-refresh:fwupd-refresh`** on the host. That is not a bug — wings chowns server
files to its configured `system.user` (uid/gid **988**), and 988 happens to map to
`fwupd-refresh` in this host's `/etc/passwd`. The install script leaves everything
root-owned; wings fixes it during the boot preflight. Don't "correct" it.

### 24.12 Panel Log Permissions

The panel's log directory is bind-mounted, and the entrypoint runs as **root** while
php-fpm runs as **nginx** (uid 100). If a log file gets created during the root-run
migration phase, the app cannot append to it afterwards — so **exceptions vanish silently
and you get a bare 500 with no stack trace**, which makes any other problem far harder to
diagnose. If `services/pterodactyl/panel-logs/laravel-*.log` is root-owned:

```bash
docker compose exec -T --user root pterodactyl-panel chown -R nginx:nginx /app/storage/logs
```

### 24.13 Caveats

- **The game network must be IPv4-only.** Wings creates `pterodactyl_nw` with IPv6 enabled
  (ULA `fdba:17c8:6c94::/64`). This LAN has router-assigned ULA addresses but **no IPv6
  egress**, so a game container that holds a v6 address sends Valheim's public-IP probe
  into a hot loop — `ipv6.icanhazip.com`, `api6.ipify.org`, `ipv6.myip.wtf`, each failing
  with `This instance has already started one or more requests` (a .NET `HttpClient` reuse
  bug in the game) and then `Could not extract valid IP address from externalIP download
  string`. Measured: **~90 log lines/s and ~48% of a core**, with the PlayFab session
  registered without an IP. Only crossplay triggers it; in Steam mode the game never makes
  that call, which is why it appeared the moment crossplay went back on. Fix, and what
  `setup_services.sh` now keeps in place:

  ```bash
  # stop every game server first - the network cannot be removed while attached
  docker network rm pterodactyl_nw
  ./setup_services.sh            # recreates it IPv4-only
  docker compose restart wings
  ```

  Verify with `docker network inspect pterodactyl_nw --format '{{.EnableIPv6}}'` (want
  `false`) and `docker logs <uuid> | grep -c "Could not extract"` (want `0`). With v6 gone
  the IPv4 probe succeeds and the console prints the real address:
  `Session "Valhymen" with join code 362087 and IP 98.35.33.57:2456 is active`.
- **Host path must equal container path.** Wings hands bind-mount *source* paths to the
  host Docker daemon when creating a game container, while also reading those same files
  through its own mount namespace — both views must resolve to the same place. So
  `/mnt/tank/pterodactyl`, `/tmp/pterodactyl` and `/mnt/tank/docker/containers` are all
  mounted **host:container identically** and cannot be remapped. Symptoms of getting this
  wrong: servers install into an empty directory, `no such file or directory` on container
  create, or files visible in the panel's file manager but missing inside the game
  container. Internal-only paths (`/etc/pterodactyl`, `/run/wings`) are exempt and live
  under `services/` like everything else.
- **Docker's data-root is not `/var/lib/docker`.** `daemon.json` sets it to
  `/mnt/tank/docker` (Part 17.6), so the upstream example's
  `/var/lib/docker/containers` mount points at an **empty directory** here. The console
  would show no output, with no error logged anywhere. Mounted as
  `/mnt/tank/docker/containers` instead.
- **The MagicDNS shim is needed on BOTH containers.** `wings` needs it because
  `remote` in its `config.yml` is the panel's `APP_URL`; the **panel** needs it because
  it reaches the node at `<fqdn>:<daemonListen>` — it does *not* use the container name.
  Container DNS (1.1.1.1/8.8.8.8 per `daemon.json`) cannot resolve a `.ts.net` name, so
  both get `extra_hosts: marlboro.tail314238.ts.net:host-gateway`. Fixing only the wings
  side is a trap with a nasty signature: the panel commits the server row to the DB, then
  **500s** when it dispatches the build to wings. You are left with a server stuck at
  `status=installing` that wings has never heard of. Recovery is in 24.10.
- **`/run/wings` is an identity mount too, and it is the easy one to miss.** The obvious
  identity mounts are the data paths, but wings also writes a per-server machine-id to
  `/run/wings/machine-id/<uuid>` and bind-mounts *that* into the game container — so the
  host daemon has to resolve it as well. Mapping it under `services/` instead looks
  harmless and installs fine, then fails only at container **create** with
  `bind source path does not exist: /run/wings/machine-id/<uuid>`, after a successful
  2.3 GB install. `/run` is tmpfs, so the directory is wiped each boot and re-created by
  dockerd on container start; the contents are per-boot scratch and that is fine. The
  rule of thumb: if wings hands the path to the Docker daemon, it must be identity
  mapped — only `/etc/pterodactyl` is genuinely wings-internal.
- **Wings exits fatally if the panel isn't reachable when it starts.** It calls
  `GET <remote>/api/remote/servers` on boot and treats a connection refusal as
  `FATAL: failed to load server configurations`, then exits. So the panel carries a
  healthcheck and wings uses `depends_on: condition: service_healthy` — "container
  started" is not a strong enough signal, because the entrypoint's `migrate --seed` run
  means the panel is up long before it is serving. Docker restart policies do **not**
  honour `depends_on`, so after a *host* reboot wings can still lose the race and
  crash-loop briefly; that is self-healing and harmless. Reassuringly, wings does not
  kill a running game server when it comes back — it logs
  `detected server is running, re-attaching to process...`, so a wings restart is safe
  mid-session.
- **The daemon port is load-bearing twice.** The node's `daemonListen` is both what Wings
  binds *inside* the container and what the panel embeds in the console websocket URL the
  browser opens. Host 8080 is Glance, so the node uses 8092 and compose maps `8092:8092`.
  A conventional `8092:8080` would leave the browser dialling a port nothing listens on.
- **Watchtower is now opt-in.** `WATCHTOWER_SCOPE=homelab` exists because of this service:
  Wings creates game containers with floating egg images, and Watchtower would happily
  recreate a running game server at 4 AM. See the Watchtower policy in Quick Reference —
  **a new service gets no auto-updates until you add the scope label.**
- **Memory is the real constraint.** This is a 7 GB box that was already swapping ~5.5 GB.
  Coolify was stopped to make room (Part 20). Two things measured along the way that are
  worth not re-litigating: qBittorrent's apparent 1.7 GB is libtorrent mmap page cache
  that the kernel reclaims on demand (its actual cgroup working set is ~35 MB), and
  FlareSolverr **cannot** be removed — IPTorrents and BlueRoms are both enabled and
  routed through it via Prowlarr's `flaresolverr` tag. If the box thrashes, the honest
  fix is dropping Coolify permanently or moving Valheim to another host, not more tuning.
- **Optional: enable zswap.** With swap this active, compressing swapped pages in RAM is a
  cheap win. `max_pool_percent` is already 20; only `enabled` and `compressor` need
  changing. Runtime (takes effect immediately, resets on reboot):

  ```bash
  echo 1    | sudo tee /sys/module/zswap/parameters/enabled
  echo zstd | sudo tee /sys/module/zswap/parameters/compressor
  ```

  To persist, add `zswap.enabled=1 zswap.compressor=zstd zswap.max_pool_percent=20` to
  `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`, then `sudo update-grub` and reboot.
- **Pinned and fenced.** All four containers are pinned by tag and carry
  `watchtower.enable=false`. The panel runs DB migrations on every boot, so bump
  `pterodactyl-panel` and `wings` **together**, deliberately, after backing up
  `services/pterodactyl/db`.
- **No official Docker docs.** Only the two `docker-compose.example.yml` files upstream.
  Two further bugs in the panel example, for the record: `MAIL_ENCRYPTION: "true"` is
  invalid (only `tls`/`ssl`/`none`), and `QUEUE_DRIVER` works only as a legacy fallback —
  the current name is `QUEUE_CONNECTION`.

### 24.14 Glance Status Tile (manual — client API key)

Glance shows the Valheim server as a tile in the right-hand column: state, uptime, CPU, RAM
and the two things a player actually needs — the current **join code** and the server
**password**. Both come from a subrequest to the watcher in 24.15 rather than from the
panel: no Pterodactyl API exposes the code at all, and the password is read from Wings so it
is never duplicated into `.env` or into `glance.yml`. They are deliberately rendered in
**both** template branches, so a dead panel API (a missing key, say) still shows credentials
that are perfectly valid. The tile is defined in `services/glance/config/glance.yml` next to the
Tailscale widget, plus panel bookmarks in the Local and Tailscale groups.

**Why it is not in the `monitor` widget.** That widget is an HTTP prober, and the game is
UDP 2456/2457 with no web surface. Listing it there would mean probing some unrelated
endpoint and reporting a status that is not the game's. The panel's **client API** is the
authoritative source instead:

```
GET /api/client/servers/<uuidShort>/resources
-> attributes.current_state, .resources.cpu_absolute, .resources.memory_bytes, .resources.uptime
```

**`setup_services.sh` mints the key** (`configure_ptero_client_key`), for the admin user
that owns the server, with **Allowed IPs blank** — Glance fetches server-side from the
`homelab` Docker network, so an allowlist that omits that subnet 403s the widget with no
visible error beyond a blank tile. Only the storing is manual, because it is the one part
that lives in an external account:

```bash
./setup_services.sh     # prints the key whenever .env does not already carry it
# store it in 1Password as item 'Marlboro NAS - Pterodactyl Client API', field api_token
./setup_script.sh       # rewrites .env from 1Password
docker compose up -d glance
```

`up -d`, not `restart` — a new environment variable needs a container recreate. And
1Password is not optional bookkeeping here: `setup_script.sh` rebuilds `.env` from it on
every run, so a key that exists only in `.env` is erased by the next run of that script.
That is exactly how the tile broke on 2026-09-12 — `PTERO_CLIENT_API_KEY` was blank, no
client key existed in the panel at all, and the tile rendered `panel API 401` while the
join code (a different source — 24.15) kept showing correctly.

**Re-running is safe, and never mints a second key.** Panel 1.x has no `p:user:api-key`
command — consistent with the missing egg, nest and allocation commands in 24.5 — but this
never needed the UI: `api_keys` stores the identifier in the clear and the remainder
encrypted with `APP_KEY`, so the script recovers the full key
(`$key->identifier . decrypt($key->token)`) from an existing row instead of issuing a new
one. To deliberately rotate it, delete the key in **Account → API Credentials** and re-run.

**It must be a client (`ptlc_`) key.** The Application (`ptla_`) key under Admin →
Application API is *not* interchangeable: that API can list servers but has no resources
endpoint, so it cannot report whether one is running.

**The server identifier is hardcoded** in `glance.yml` as `0fe911ae` (`servers.uuidShort`,
not a secret). It is stable for the life of the server and changes only if the server is
deleted and recreated. Re-read it from the panel console URL, or:

```bash
# ptero_sql is defined in setup_services.sh
docker compose exec -T pterodactyl-db mariadb -N -B -u root -p"$PTERO_DB_ROOT_PASSWORD" \
  panel -e 'SELECT id,uuidShort,name FROM servers;'
```

Units in that response are **not** uniform, which is worth knowing before editing the
template: `memory_bytes` is bytes, `limits.memory` is MiB, and `uptime` is milliseconds.
Every resource field also reads `0` while the server is stopped, so the tile gates the
CPU/RAM rows on `current_state` rather than rendering zeros.

### 24.15 Join Code Watcher (`valheim-joincode`)

Crossplay means players join with a **code, not an address** — and the code is awkward to
get at. The game prints it exactly once, at boot:

```
09/11/2026 06:18:31: Session "Valhymen" registered with join code 362087
```

It then changes on every restart. Pterodactyl's client API exposes no logs at all (the
panel console is a Wings websocket, not a REST resource), and Wings' own
`GET /api/servers/<uuid>/logs` returns only the last **~100 lines** — about two hours on an
idle server, minutes with players on. Wait too long and the code is simply gone; the only
way to recover it then is to restart the server and take a different one.

The **server name and password** are not in the log at all. They are egg variables, and
Wings serves the egg's resolved environment at `GET /api/servers/<uuid>` under
`configuration.environment` — so they are read from there rather than copied into `.env`.
The panel stays the single source of truth: change the password in the panel and the
dashboard follows on the next poll, with no file to edit and no secret in this repo.

So `valheim-joincode` polls Wings every 60s and publishes whatever changed:

1. `services/valheim-joincode/www/joincode.json` — `{code, server, password, captured}`,
   served over HTTP on port 8099 (container-internal only) for the Glance tile in 24.14;
2. a push to the **`valheim` ntfy topic** carrying the code and the password. Subscribe to
   that topic in the ntfy app to get them on your phone whenever the code changes.

Only a **new code** notifies. A password edit reaches the tile silently, and a restart that
comes back with the same code sends nothing — codes are not unique per boot, which is
observed behaviour, not an assumption: the 2026-09-12 restarts produced `666894` twice in a
row after an earlier boot had produced `362087`.

Stock `python:3.13-alpine` running one authored script, `watch.py`; the whole job is
stdlib, so there is nothing to build and no packages installed at boot. Plain `alpine` is
not enough — its BusyBox is compiled without the `httpd` applet (it lives in
`busybox-extras`), and a runtime `apk add` would make container start depend on the
network.

It reads Wings' node token straight from `services/pterodactyl/wings-etc/config.yml`,
mounted read-only, rather than copying it into `.env` — the file is the authoritative copy,
so rotating the token needs no second edit.

**State, and why the notification is not chatty.** The last known code lives in that JSON
file, which is mounted from the host and therefore survives a container recreate. Only a
*different* code triggers a write and a push, so restarting the watcher, or the game server
coming back with the same session, sends nothing.

**Seeding an already-running server.** Deploying the watcher while the server has been up
for hours finds nothing — the boot line has long scrolled out of Wings' window. Either
restart the server, or seed the state file with the code you already have:

```bash
docker exec valheim-joincode python3 -c "
import sys; sys.path.insert(0,'/')
import watch
state = dict(watch.server_env(watch.wings_token()), code='362087')
print(watch.store(state))"
```

`watch.push(watch.load_state())` sends the ntfy message on its own, which is also the
quickest way to prove that half of the path works.

**Checking it:**

```bash
docker logs valheim-joincode              # 'watching <uuid> every 60s (known code: ...)'
docker exec glance wget -q -O - http://valheim-joincode:8099/joincode.json
curl -s 'http://192.168.0.10:8194/valheim/json?poll=1'   # what ntfy has cached (12h)
```

**Limits worth knowing.** Neither value is a secret from anyone who can already open the
dashboard, which is tailnet/LAN-only — that is the point of putting the password there. If
the watcher is down while the game server restarts, and stays down past the ~100-line
window, that boot's code is missed and the tile keeps showing the stale one — the game gives no way to re-read it. The Glance monitor entry (24.14) is there
to make a dead watcher visible. The `VALHEIM_UUID` in `docker-compose.yml` is the **full**
`servers.uuid`, unlike the tile's `uuidShort`; Wings' API is keyed by the full one.

### 24.16 Nightly Auto-Update

Valheim refuses a client whose build is newer than the server's, so a long-lived server
quietly rots out of reach of everyone who launches the game through Steam. Observed on
2026-09-12: 37 hours of uptime, server on `l-1.0.7` (network version 39), and a player
locked out with a version-mismatch error.

**Restarting *is* the update mechanism.** The egg's image entrypoint runs
`steamcmd +app_update ${SRCDS_APPID}` on every container start whenever `AUTO_UPDATE=1`,
and there is no in-place updater — the dedicated server takes no stdin commands. So
"auto-update" here means "restart on a schedule":

| Half | Where | Value |
|---|---|---|
| SteamCMD runs on every boot | `PTERO_VALHEIM_AUTO_UPDATE` in `setup_services.sh` → egg variable `AUTO_UPDATE` | `1` |
| Something restarts it nightly | `valheim-autoupdate` container (24.17) | 03:00 local, only while empty |

**Why the restart is not a panel schedule.** Pterodactyl can restart on a cron, and this
stack did that for a few hours — the code is still in the git history. Its only
precondition is `only_when_online`, which asks Wings whether the process is up; it says
nothing about whether anyone is *playing*, because Pterodactyl has no game-query support
and so exposes no player count anywhere in its API. A 3 AM restart on top of a live
session kicks everyone and drops up to `BACKUP_INTERVAL` (1800s) of world state (24.8), so
the trigger moved to a container that can read the player count off the server's own
console. `setup_services.sh` now *deletes* a panel schedule named `Nightly update restart`
if it finds one, since two triggers would restart the server twice.

### 24.17 Empty-Server Guard (`valheim-autoupdate`)

`services/valheim-autoupdate/guard.py`, same shape as the join-code watcher (24.15): the
stock `python:3.13-alpine` image running one authored stdlib script, reading Wings' node
token straight out of `services/pterodactyl/wings-etc/config.yml` rather than keeping a
second copy in `.env`.

Once a night, from `RESTART_AT` onward, it asks two questions and restarts only on a clear
yes to both:

1. **Is the server running?** `GET /api/servers/<uuid>` → `state`. Anything but `running`
   ends the night: a stopped server runs SteamCMD whenever it is next started, so there is
   nothing to miss.
2. **Is anyone on it?** The count comes from the console line the server prints every ten
   minutes, which is the *only* place it exists:

   ```
   09/12/2026 19:28:54:  Connections 0 ZDOS:66156  sent:0 recv:0
   ```

   Read via Wings' `/api/servers/<uuid>/logs?size=100`. With players on it waits and asks
   again every `POLL_SECONDS`, up to `WINDOW_MINUTES` past `RESTART_AT` (03:00 → 06:00); a
   session that outlasts the window simply gets no update that night.

Then `POST /api/servers/<uuid>/power {"action":"restart"}`, again on the node token — the
panel needs no involvement, since it reads server state from Wings anyway.

**Every unknown counts as "someone might be on."** No `Connections` line in the window, a
line older than `MAX_LINE_AGE_SECONDS` (25 minutes — they come every 10), an unparseable
one, an unreachable Wings: all of them skip. A skipped night costs nothing; a wrong restart
lands on live players.

| Environment | Default | Notes |
|---|---|---|
| `RESTART_AT` | `03:00` | Read in the container's `TZ`; the image carries tzdata, so it follows DST. Must not put the window across midnight |
| `WINDOW_MINUTES` | `180` | How long to keep retrying while players are on |
| `POLL_SECONDS` | `300` | Retry interval inside the window |
| `MAX_LINE_AGE_SECONDS` | `1500` | Freshness bar for the `Connections` line |
| `VALHEIM_UUID` | — | The **full** `servers.uuid`, like the watcher's; Wings' API is keyed by it |

**The game's log timestamps are UTC**, whatever `TZ` says — the game container gets no
timezone from Wings. That is why the line is parsed as UTC while `RESTART_AT` is local; do
not "align" them.

**State** lives in `services/valheim-autoupdate/state/autoupdate.json`, mounted from the
host so a container recreate mid-window cannot fire a second restart. It is also what the
Glance monitor entry probes (a dead guard means the game silently stops updating):

```bash
docker logs valheim-autoupdate           # 'guarding <uuid>: restart at 03:00 local when empty...'
docker exec glance wget -q -O - http://valheim-autoupdate:8098/autoupdate.json
# {"status": "restarted while empty", "updated": "...", "done_for": "2026-09-12"}
```

`status` is one of `idle`, `waiting: N online`, `restarted while empty`, `skipped: server
offline`, `skipped: players on all window`. `done_for` is the date already handled.

**Testing it without waiting for 3 AM** — a throwaway container with the window moved to a
minute from now, which leaves the running one alone (stop it first so the two do not both
act, and clear the state file so "tonight" counts as unhandled):

```bash
docker compose stop valheim-autoupdate
rm -f services/valheim-autoupdate/state/autoupdate.json
docker compose run --rm --no-deps \
  -e RESTART_AT="$(date -d '+1 minute' '+%H:%M')" -e WINDOW_MINUTES=8 -e POLL_SECONDS=20 \
  valheim-autoupdate
# then confirm the restart actually pulled an update:
docker logs <server-uuid> 2>&1 | grep -aE "Success! App '896660'|Valheim version:"
docker compose up -d valheim-autoupdate
```

**Expect a join code push every morning** (24.15) — the code rotates on every boot, so a
nightly restart means a nightly ntfy notification with the new one. That is the guard
working, not the watcher misfiring.

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
