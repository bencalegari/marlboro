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
- **Uptime Kuma** — Uptime monitoring
- **Glance** — Homelab dashboard
- **DuckDNS** — Dynamic DNS for external access

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
| Uptime Kuma | 3002 | Internal container port is 3001 |
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

**Ubuntu 25.10 reaches end-of-life July 2026.** Upgrade to 26.04 LTS in April 2026 with `sudo do-release-upgrade`.

**Jellyfin uses host networking.** Reference it from other containers via `http://host.docker.internal:8096` or `http://<server-ip>:8096`, not `http://jellyfin:8096`.

**`host.docker.internal` requires `extra_hosts` on Linux.** Added to Radarr, Sonarr, Bazarr, Profilarr, Seerr, and Coolify in the compose file.

**Docker needs explicit DNS and uses external data root.** `/etc/docker/daemon.json` must contain `{"data-root": "/mnt/tank/docker", "dns": ["1.1.1.1", "8.8.8.8"]}`.

**AdGuard conflicts with systemd-resolved.** Fixed via `/etc/systemd/resolved.conf.d/adguard.conf` with `DNSStubListener=no`.

**qBittorrent WebUI requires `WebUI\HostHeaderValidation=false`** and `WebUI\Port=8080` in `qBittorrent.conf`.

**Watchtower requires `DOCKER_API_VERSION=1.54`** on Ubuntu 25.10.

**Sunshine runs as an AppImage** with Sway as the Wayland compositor. Managed via `systemctl --user`.

**Scrutiny monitors all 4 drives** (`/dev/sda`–`/dev/sdd`) via device passthrough.

**Seerr config lives in `./services/jellyseerr/config`** — the directory was kept from the Jellyseerr migration.

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
```

---

## Part 5: Run the Setup Script

```bash
chmod +x ~/marlboro/setup_script.sh
cd ~/marlboro
./setup_script.sh
```

Generates credentials, stores everything in 1Password tagged `marlboro-nas`, pulls all values, and writes `~/marlboro/.env`. Re-run anytime to sync credentials from 1Password.

To start the stack:

```bash
docker compose up -d
```

---

## Part 6: Glance Configuration

Create `~/marlboro/glance/config/glance.yml`:

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
  --title "Marlboro NAS - Sunshine" \
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
vim ~/marlboro/services/qbittorrent/config/qBittorrent/qBittorrent.conf
# Add under [Preferences]:
# WebUI\HostHeaderValidation=false
# WebUI\Port=8080
docker compose up -d qbittorrent
```

Set permanent password in **Tools → Options → Web UI**, then:

```bash
op item edit "Marlboro NAS - qBittorrent" password=your-new-password
```

Downloads: **Tools → Options → Downloads**
- Default Save Path: `/downloads/complete`
- Incomplete: `/downloads/incomplete`

**Install VueTorrent (alternative WebUI):**

```bash
curl -sL https://github.com/VueTorrent/VueTorrent/releases/latest/download/vuetorrent.zip \
  -o /tmp/vuetorrent.zip
unzip -o /tmp/vuetorrent.zip -d ~/marlboro/services/qbittorrent/config/
```

Then stop qBittorrent, add these lines under `[Preferences]` in `qBittorrent.conf`, and start it:

```ini
WebUI\AlternativeUIEnabled=true
WebUI\RootFolder=/config/vuetorrent
```

To update VueTorrent later, re-run the `curl`/`unzip` commands and restart qBittorrent.

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

Media directories and ownership are created automatically by `setup_script.sh`. If you need to fix them manually:

```bash
docker run --rm -v /mnt/tank:/mnt/tank alpine chown 1000:1000 \
  /mnt/tank/media/movies /mnt/tank/media/tv \
  /mnt/tank/downloads/complete /mnt/tank/downloads/incomplete
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
5. **After first sync**, edit Profilarr's local profile YAML to prefer individual episode downloads over season packs:

   ```bash
   docker exec profilarr sed -i '/^- name: Season Pack$/{n;s/score: 10/score: -10/}' \
     "/config/db/profiles/1080p Remux.yml"
   ```

   > **Caveat:** If Profilarr pulls a fresh copy of the Dictionarry database, this YAML may be overwritten and the score reset to +10. Re-apply after database updates, or disable auto-pull in Profilarr settings.

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

Because the data root and every service bind mount live on `/mnt/tank`, Docker must not start before the mount is available. Without this, a boot race can leave containers bound to empty directories on the root filesystem — imports then fail with phantom "not enough free space" errors even though the tank has 29 TB free.

```bash
sudo install -D -m 644 /dev/stdin /etc/systemd/system/docker.service.d/wait-for-tank.conf <<'EOF'
[Unit]
RequiresMountsFor=/mnt/tank
EOF
sudo systemctl daemon-reload
```

`setup_script.sh` installs this drop-in on every run, so a fresh provision or a wiped system will re-apply it automatically.

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

### 19.5 Configure Jellyfin's Public URL

In Jellyfin: **Dashboard → Networking**

- **Server Address Settings → Public HTTPS port:** `443`
- **Server Address Settings → Known Proxies:** add your server's LAN IP (e.g. `<server-ip>`)
- **Server Address Settings → Base URL:** leave blank (using a subdomain, not a path)

Save and restart Jellyfin if prompted.

### 19.6 Test External Access

From a device **not on your home network** (e.g. phone with Wi-Fi off):

```
https://jellyfin.marlboro-bc.duckdns.org
```

You should see the Jellyfin login page over HTTPS with a valid certificate.

### 19.7 Troubleshooting: "Internal Error" When Requesting a Cert

If NPM shows only "Internal Error" after submitting the cert request, check the container logs:

```bash
docker logs nginx-proxy-manager --tail 100
docker exec nginx-proxy-manager tail -200 /data/logs/letsencrypt.log
```

Common causes:

- **`Timeout during connect (likely firewall problem)` on port 80** — the HTTP-01 challenge can't reach your server. Either port 80 isn't forwarded to `<server-ip>`, or your ISP blocks inbound 80 (common on residential Comcast). **Fix:** use DNS-01 as described in 19.4 instead of HTTP-01.
- **`unauthorized` from DuckDNS** — `dns_duckdns_token` is wrong or missing. Re-copy from <https://www.duckdns.org> and re-save the cert.
- **Rate limit hit** — Let's Encrypt limits failed validations to 5/hour and certs to 5/week per registered domain. Wait an hour and retry, ideally after fixing the underlying cause.

### 19.8 (Optional) Lock Down to Jellyfin Only

If you only want to expose Jellyfin and not other services, no additional steps are needed — NPM only proxies hostnames you explicitly configure. Other services remain LAN/Tailscale-only.

To block direct port access to Jellyfin's raw port (8096) from the internet while still allowing the proxy, add a UFW rule:

```bash
sudo ufw allow from 127.0.0.1 to any port 8096
sudo ufw deny 8096
```

NPM communicates with Jellyfin via `host.docker.internal` which resolves to the host's bridge gateway address — traffic stays local, so this rule doesn't block the proxy.

---

## Part 20: Coolify

Coolify is a self-hosted PaaS for deploying apps and managing servers via Docker. It runs alongside the existing stack with NPM as its reverse proxy. Coolify's built-in Traefik proxy is disabled so it doesn't conflict with NPM on ports 80/443.

### 20.1 Create Directories

```bash
mkdir -p ~/marlboro/services/coolify/{app,postgres,redis,ssh}
chmod 700 ~/marlboro/services/coolify/ssh
sudo mkdir -p /data/coolify/source
sudo chown $USER:$USER /data/coolify/source
```

The `/data/coolify/source` path is a fixed host path Coolify hard-codes internally — it must exist outside the repo directory.

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

In AdGuard Home → **Filters → DNS Rewrites → Add DNS Rewrite**:
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

**btrfs snapshots:**

```bash
sudo btrfs subvolume snapshot -r /mnt/tank /mnt/tank/.snapshots/$(date +%Y-%m-%d)
sudo btrfs subvolume list /mnt/tank
```

**Sync credentials from 1Password:**

```bash
cd ~/marlboro && ./setup_script.sh && docker compose up -d
```

**Upgrade Ubuntu to 26.04 LTS (April 2026):**

```bash
sudo do-release-upgrade
```
