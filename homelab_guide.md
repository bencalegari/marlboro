# Mac Mini Homelab Setup Guide

## Overview

This guide sets up the following services on a 2018 Mac Mini running Ubuntu 25.10 (Questing Quokka).

- **Jellyfin** — Media server with Intel QuickSync hardware transcoding
- **AdGuard Home** — Network-wide DNS ad blocking
- **Sunshine** — Game streaming host (Moonlight client)
- **Steam** — Light gaming on the Mac Mini
- **RetroArch** — Retro game emulation
- **Prowlarr** — Indexer manager
- **Radarr** — Movie collection manager
- **Sonarr** — TV collection manager
- **Bazarr** — Automatic subtitle downloading
- **Profilarr** — Quality profile sync from Dictionarry
- **Seerr** — Media request UI for Jellyfin users
- **Flaresolverr** — Cloudflare bypass proxy for Prowlarr indexers
- **qBittorrent** — Torrent client
- **Immich** — Self-hosted photo/video library with mobile backup
- **RomM** — ROM manager and in-browser emulator
- **Portainer** — Docker management UI
- **Nginx Proxy Manager** — Reverse proxy with Let's Encrypt
- **Scrutiny** — Drive S.M.A.R.T. monitoring
- **Watchtower** — Automatic container updates
- **Glance** — Homelab dashboard

---

## Quick Reference

### Port Map

| Service | Host Port | Notes |
|---|---|---|
| Glance Dashboard | 8080 | Main homelab UI |
| Jellyfin | host network | Uses host networking for DLNA |
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
| qBittorrent | 8181 | Internal container port is 8080 |
| Immich | 2283 | |
| RomM | 7070 | |
| Portainer | 9000 | |
| Nginx Proxy Manager (admin) | 81 | |
| Nginx Proxy Manager (http) | 80 | |
| Nginx Proxy Manager (https) | 443 | |
| Scrutiny | 8085 | Internal container port is 8080 |
| Sunshine web UI | 47990 HTTPS | Runs on host, not Docker |
| Sunshine streaming | 47984, 47989 TCP | Moonlight ports |
| Sunshine streaming | 47998–48000, 48010 UDP | Moonlight ports |

### Key Details

Network info is stored in 1Password after running `setup.sh`. Retrieve with:

```bash
op item get "Marlboro NAS — Network" --vault Private
```

- **Static IP:** `op item get "Marlboro NAS — Network" --vault Private --fields static-ip`
- **Router/Gateway:** `<gateway-ip>`
- **Network interface:** `<network-interface>`
- **Tailscale hostname:** `op item get "Marlboro NAS — Network" --vault Private --fields tailscale-hostname`
- **Tailscale IP:** `op item get "Marlboro NAS — Network" --vault Private --fields tailscale-ip`
- **Username:** `<your-username>`
- **Homelab directory:** `~/homelab`

### Customization Checklist

**Required before first run:**
- Run `setup.sh` — handles all credential generation and 1Password storage
- Update `PUID`/`PGID` (currently `1000`) if your user differs — check with `id`
- Update Scrutiny device entries once drives arrive — run `lsblk`
- Add IGDB and Screenscraper API keys to RomM (see Part 13.3)

**Recommended:**
- Router DHCP DNS set to `<server-ip>` ✅ done
- Change Nginx Proxy Manager default credentials immediately after first launch

### Key Caveats

**Ubuntu 25.10 reaches end-of-life July 2026.** Upgrade to 26.04 LTS in April 2026 with `sudo do-release-upgrade`.

**Jellyfin uses host networking.** Reference it from other containers via `http://host.docker.internal:8096` or `http://<server-ip>:8096`, not `http://jellyfin:8096`.

**`host.docker.internal` requires `extra_hosts` on Linux.** Added to Radarr, Sonarr, Bazarr, Profilarr, and Seerr in the compose file.

**Docker needs explicit DNS.** `/etc/docker/daemon.json` must contain `{"dns": ["1.1.1.1", "8.8.8.8"]}`.

**AdGuard conflicts with systemd-resolved.** Fixed via `/etc/systemd/resolved.conf.d/adguard.conf` with `DNSStubListener=no`.

**qBittorrent WebUI requires `WebUI\HostHeaderValidation=false`** and `WebUI\Port=8080` in `qBittorrent.conf`.

**Watchtower requires `DOCKER_API_VERSION=1.54`** on Ubuntu 25.10.

**Sunshine runs as an AppImage** with Sway as the Wayland compositor. Managed via `systemctl --user`.

**Scrutiny devices commented out** until drives arrive in Phase 2.

**Seerr config lives in `./jellyseerr/config`** — the directory was kept from the Jellyseerr migration.

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
  "dns": ["1.1.1.1", "8.8.8.8"]
}
```

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
op item get "Marlboro NAS — Immich DB" --fields password --reveal
```

---

## Part 4: Directory Structure

```bash
mkdir -p ~/homelab/services/{jellyfin,prowlarr,radarr,sonarr,bazarr,profilarr,jellyseerr,qbittorrent,portainer,nginx-proxy-manager,uptime-kuma}/config
mkdir -p ~/homelab/services/adguard/{work,conf}
mkdir -p ~/homelab/services/immich/{model-cache,postgres}
mkdir -p ~/homelab/services/romm/{db,resources,assets,config}
mkdir -p ~/homelab/services/nginx-proxy-manager/letsencrypt
mkdir -p ~/homelab/services/scrutiny/{config,influxdb}
mkdir -p ~/homelab/services/glance/config
```

---

## Part 5: Run the Setup Script

```bash
chmod +x ~/homelab/setup.sh
cd ~/homelab
./setup.sh
```

Generates credentials, stores everything in 1Password tagged `marlboro-nas`, and captures network details. Docker Compose reads secrets at runtime via `op run` — no credentials are written to disk.

To start the stack:

```bash
op run --env-file=.op.env -- docker compose up -d
```

---

## Part 6: Glance Configuration

Create `~/homelab/glance/config/glance.yml`:

```yaml
server:
  port: 8080

pages:
  - name: Home
    columns:
      - size: small
        widgets:
          - type: server-stats
          - type: clock
            hour-format: 12h
          - type: weather
            location: Petaluma, California, US
            units: imperial
            hour-format: 12h
      - size: full
        widgets:
          - type: docker-containers
          - type: monitor
            title: Services
            sites:
              - title: Jellyfin
                url: http://<server-ip>:8096
                same-tab: true
              - title: AdGuard Home
                url: http://adguard:3001
                same-tab: true
              - title: Sunshine
                url: https://<server-ip>:47990
                allow-insecure: true
                same-tab: true
              - title: Prowlarr
                url: http://prowlarr:9696
                same-tab: true
              - title: Radarr
                url: http://radarr:7878
                same-tab: true
              - title: Sonarr
                url: http://sonarr:8989
                same-tab: true
              - title: Bazarr
                url: http://bazarr:6767
                same-tab: true
              - title: Seerr
                url: http://seerr:5055
                same-tab: true
              - title: Profilarr
                url: http://profilarr:6868
                same-tab: true
              - title: qBittorrent
                url: http://qbittorrent:8080
                same-tab: true
              - title: Immich
                url: http://immich-server:2283
                same-tab: true
              - title: RomM
                url: http://romm:8080
                same-tab: true
              - title: Portainer
                url: http://portainer:9000
                same-tab: true
              - title: Nginx Proxy Manager
                url: http://nginx-proxy-manager:81
                same-tab: true
              - title: Scrutiny
                url: http://scrutiny:8080
                same-tab: true
      - size: small
        widgets:
          - type: releases
            cache: 6h
            repositories:
              - glanceapp/glance
              - jellyfin/jellyfin
              - LizardByte/Sunshine
              - AdguardTeam/AdGuardHome
              - Prowlarr/Prowlarr
              - Radarr/Radarr
              - Sonarr/Sonarr
              - immich-app/immich
              - rommapp/romm
              - seerr-team/seerr
```

---

## Part 7: Install Sunshine (on host, not Docker)

### 7.1 Install Sway and Sunshine AppImage

```bash
sudo apt install sway
wget https://github.com/LizardByte/Sunshine/releases/latest/download/sunshine.AppImage
chmod +x ~/sunshine.AppImage
sudo setcap cap_sys_admin+p ~/sunshine.AppImage
```

### 7.2 Create Sway Service

```bash
vim ~/.config/systemd/user/weston.service
```

```ini
[Unit]
Description=Sway Wayland Compositor
Before=sunshine.service

[Service]
Environment=XDG_RUNTIME_DIR=/run/user/1000
Environment=WLR_BACKENDS=headless
Environment=WLR_RENDERER=pixman
Environment=WLR_LIBINPUT_NO_DEVICES=1
ExecStart=/usr/bin/sway
Restart=on-failure

[Install]
WantedBy=default.target
```

```bash
systemctl --user enable weston
systemctl --user start weston
```

### 7.3 Create Sunshine Service

```bash
vim ~/.config/systemd/user/sunshine.service
```

```ini
[Unit]
Description=Sunshine Game Streaming Server
After=weston.service
Requires=weston.service

[Service]
Environment=XDG_RUNTIME_DIR=/run/user/1000
Environment=WAYLAND_DISPLAY=wayland-1
ExecStart=/home/<your-username>/sunshine.AppImage
Restart=on-failure

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable sunshine
systemctl --user start sunshine
```

### 7.4 Configure Sunshine

```bash
mkdir -p ~/.config/sunshine
vim ~/.config/sunshine/sunshine.conf
```

```
adapter_name = /dev/dri/renderD128
```

### 7.5 First Launch

Access `https://<server-ip>:47990` (accept the self-signed cert warning). Set a password and store it:

```bash
op item create \
  --category Login \
  --title "Marlboro NAS — Sunshine" \
  --vault Private \
  --tags marlboro-nas \
  --url https://<server-ip>:47990 \
  username=admin \
  password=your-chosen-password
```

### 7.6 Add Steam and RetroArch Apps

In Sunshine web UI → **Applications → Add**:

| Name | Command |
|---|---|
| Steam | `steam -gamepadui` |
| RetroArch | `retroarch` |

### 7.7 Port Forwarding (for remote streaming)

Forward to `<server-ip>` on your TP-Link BE3600 (**Advanced → NAT Forwarding → Virtual Servers**):

| Port | Protocol | Service |
|---|---|---|
| 47984 | TCP | Moonlight streaming |
| 47989 | TCP | Moonlight streaming |
| 47990 | TCP | Sunshine web UI |
| 47998–48000 | UDP | Moonlight streaming |
| 48010 | UDP | Moonlight streaming |

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
cd ~/homelab
op run --env-file=.op.env -- docker compose up -d
docker compose ps
```

> **If headless:** all web UIs accessible from other devices at `<server-ip>`. SSH back in for `op item create` commands after setting passwords.

### 9.3 AdGuard First-run

Navigate to `http://<server-ip>:3000` and complete the setup wizard.

If AdGuard binds to port 80 instead of 3001 after setup:

```bash
docker compose stop adguard
vim ~/homelab/services/adguard/conf/AdGuardHome.yaml
# Change: address: 0.0.0.0:80  →  address: 0.0.0.0:3001
docker compose up -d adguard
```

Store credentials:

```bash
op item create \
  --category Login \
  --title "Marlboro NAS — AdGuard" \
  --vault Private \
  --tags marlboro-nas \
  --url http://<server-ip>:3001 \
  username=your-username \
  password=your-password
```

### 9.4 Point Router at AdGuard

On TP-Link BE3600: **Advanced → Network → DHCP Server → Primary DNS** → `<server-ip>`

### 9.5 Recommended AdGuard Settings

- **Settings → DNS settings → Upstream DNS:** add `https://dns.cloudflare.com/dns-query`
- **Settings → DNS settings → Rate limit:** set to 300 or 0
- **Filters → DNS blocklists:** add EasyList, EasyPrivacy, Steven Black's Hosts

---

## Part 10: Wire Up the Arr Stack

### 10.1 qBittorrent

Get temp password:

```bash
docker logs qbittorrent | grep -i password
```

Log in at `http://<server-ip>:8181`. If you see a plain "Unauthorized" page:

```bash
docker compose stop qbittorrent
vim ~/homelab/services/qbittorrent/config/qBittorrent/qBittorrent.conf
# Add under [Preferences]:
# WebUI\HostHeaderValidation=false
# WebUI\Port=8080
docker compose up -d qbittorrent
```

Set permanent password in **Tools → Options → Web UI**, then:

```bash
op item edit "Marlboro NAS — qBittorrent" password=your-new-password
```

Downloads: **Tools → Options → Downloads**
- Default Save Path: `/downloads/complete`
- Incomplete: `/downloads/incomplete`

### 10.2 Flaresolverr → Prowlarr

1. Prowlarr → **Settings → Indexer Proxies → Add → FlareSolverr**
2. Host: `http://flaresolverr:8191`
3. Add tag e.g. `flare`, enable and save
4. Assign same `flare` tag to Cloudflare-protected indexers

### 10.3 Prowlarr → Radarr/Sonarr

1. Add indexers in Prowlarr
2. **Settings → Apps → Add → Radarr**: `http://radarr:7878`, API key from Radarr → Settings → General
3. Repeat for Sonarr: `http://sonarr:8989`

### 10.4 Radarr/Sonarr → qBittorrent

Radarr: **Settings → Download Clients → Add → qBittorrent**
- Host: `qbittorrent`, Port: `8080`, Category: `radarr`

Sonarr: same, category `sonarr`.

### 10.5 Root Folders

```bash
sudo mkdir -p /mnt/tank/media/movies /mnt/tank/media/tv
sudo mkdir -p /mnt/tank/downloads/complete /mnt/tank/downloads/incomplete
sudo chown -R 1000:1000 /mnt/tank
```

- Radarr: **Settings → Media Management → Root Folders** → `/movies`
- Sonarr: **Settings → Media Management → Root Folders** → `/tv`

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

1. **Settings → Databases**: add `https://github.com/Dictionarry-Hub/dictionarry`
2. Add Radarr and Sonarr instances
3. Select quality profiles:
   - Radarr: **2160p Remux** (LG C1 4K display)
   - Sonarr: **1080p Remux**
4. Set sync to **Auto**, trigger manual sync immediately

### 10.9 Seerr

1. Navigate to `http://<server-ip>:5055`
2. Sign in with Jellyfin — use `http://172.18.0.1:8096`
3. Add Movies library in Jellyfin first if Continue button is greyed out
4. Connect Radarr: host `radarr`, port `7878`, uncheck 4K Server
5. Connect Sonarr: host `sonarr`, port `8989`

---

## Part 11: Portainer

Access `http://<server-ip>:9000`. **If headless, open from another device.** Set admin password then:

```bash
op item create \
  --category Login \
  --title "Marlboro NAS — Portainer" \
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
sudo rm -rf ~/homelab/services/immich/postgres
mkdir -p ~/homelab/services/immich/postgres
docker compose up -d immich-postgres
```

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

Add API keys to `.op.env` (e.g. `IGDB_CLIENT_ID=op://Private/IGDB/client-id`) or set them directly in `docker-compose.yml` as empty optional env vars, then `op run --env-file=.op.env -- docker compose up -d romm`.

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

1. **AdGuard** — DNS first
2. **qBittorrent** — change default password
3. **Flaresolverr** — register in Prowlarr, add `flare` tag
4. **Prowlarr** — add indexers, connect to Radarr/Sonarr
5. **Radarr/Sonarr** — root folders, connect to qBittorrent and Jellyfin
6. **Bazarr** — connect to Radarr/Sonarr, add subtitle providers
7. **Profilarr** — link Dictionarry, connect instances, sync
8. **Jellyfin** — create Libraries (Movies → `/media/movies`, TV → `/media/tv`)
9. **Seerr** — connect to Jellyfin, Radarr, Sonarr
10. **Immich** — admin account, enable mobile backup
11. **RomM** — admin account, add metadata API keys
12. **Portainer** — set admin password
13. **Sunshine** — pair first Moonlight client
14. **Glance** — verify all services green

---

# Phase 2: When Drives Arrive

---

## Part 17: Storage Setup

### 17.1 Install ZFS

```bash
sudo apt install zfsutils-linux
```

### 17.2 Identify Drives

```bash
lsblk
ls /dev/disk/by-id/
```

Use `/dev/disk/by-id/` paths — stable across reboots.

### 17.3 Create ZFS Pool

```bash
sudo zpool create -o ashift=12 tank raidz \
  /dev/disk/by-id/ata-DRIVE1 \
  /dev/disk/by-id/ata-DRIVE2 \
  /dev/disk/by-id/ata-DRIVE3 \
  /dev/disk/by-id/ata-DRIVE4

sudo zfs set compression=lz4 tank
```

### 17.4 Create Datasets

```bash
sudo zfs create tank/media
sudo zfs create tank/media/movies
sudo zfs create tank/media/tv
sudo zfs create tank/media/roms
sudo zfs create tank/downloads
sudo zfs create tank/downloads/complete
sudo zfs create tank/downloads/incomplete
sudo zfs create tank/photos
sudo chown -R 1000:1000 /mnt/tank
```

### 17.5 Enable Scrutiny

Uncomment devices in `docker-compose.yml`, update paths from `lsblk`:

```bash
vim ~/homelab/docker-compose.yml
docker compose up -d scrutiny
```

---

## Part 18: Maintenance

**Update containers manually:**

```bash
docker compose pull
docker compose up -d
```

**ZFS health:**

```bash
zpool status
zpool scrub tank  # run monthly
```

**Drive health:** `http://<server-ip>:8085`

**ZFS snapshots:**

```bash
sudo zfs snapshot tank@$(date +%Y-%m-%d)
sudo zfs list -t snapshot
```

**Upgrade Ubuntu to 26.04 LTS (April 2026):**

```bash
sudo do-release-upgrade
```
