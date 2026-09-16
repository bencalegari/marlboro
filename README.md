# Marlboro homelab

Docker Compose and host provisioning for a 2018 T2 Mac Mini running Ubuntu 26.04. Service definitions and ports are in `docker-compose.yml`; tracked application settings are under `services/`.

## Host assumptions

- Server address: `192.168.0.10`
- User and group ID: `1000:1000`
- Storage mount: `/mnt/tank`
- 1Password vault: `Private`
- Tailscale hostname: `marlboro.tail314238.ts.net`
- Docker data root: `/mnt/tank/docker`

Change the hard-coded values in `docker-compose.yml`, `setup_script.sh`, `setup_services.sh`, and `services/glance/config/glance.yml` before using this on another host.

Mount `/mnt/tank` before provisioning. The setup script configures Docker storage and DNS, the systemd mount dependency, and the `systemd-resolved` setting required by AdGuard.

## Provision

Run:

```bash
./setup_script.sh
```

The script installs its dependencies, prompts for 1Password sign-in and external credentials, configures the host, starts the stack, captures generated API keys, creates supported admin accounts, and reconciles service settings. Reboot if requested. It is safe to rerun.

Coolify is optional and excluded from the default stack:

```bash
docker compose --profile coolify up -d
```

## First-run work

Complete only the setup that applies:

- Router: use `192.168.0.10` for DNS and forward TCP ports 80 and 443 when public proxy hosts are required.
- Prowlarr: add indexers and assign the `flare` tag where FlareSolverr is required.
- Sonarr and Radarr: connect them to Jellyfin.
- Profilarr: connect Sonarr and Radarr, add Dictionarry, and sync the named profiles used in `setup_services.sh`.
- Bazarr: connect Sonarr and Radarr and add subtitle providers.
- Plex: add movie and TV libraries from `/media/movies` and `/media/tv`. Leave Plex DLNA disabled because Jellyfin also uses host networking.
- Seerr: connect Jellyfin, Sonarr, and Radarr.
- Immich, RomM, Uptime Kuma, and Sunshine: create their initial accounts. Pair Moonlight with Sunshine.

## SMS bridge

Configure the Twilio number's messaging webhook as:

```text
POST https://sms.marlboro-bc.duckdns.org/twilio/inbound
```

In Seerr, send a test from the webhook notification settings. Publish `services/sms-bridge/OPT-IN.md` and the required opt-in screenshot for carrier registration.

Only `/twilio/inbound` is exposed by the public SMS proxy host. `/seerr/hook` and `/healthz` remain internal.

## Pterodactyl

Import `services/pterodactyl/egg-valheim.json` and create the Valheim server with allocations `0.0.0.0:2456` and `0.0.0.0:2457`. Crossplay uses the PlayFab relay, so no router forward is required. The setup scripts create the administrator, client API key, IPv4-only game network, and reconcile crossplay and automatic updates.

`valheim-joincode` publishes new join codes to ntfy. `valheim-autoupdate` restarts the server at 03:00 only when no players are connected, retrying until 06:00. If `pterodactyl_nw` already has IPv6 enabled, stop the game server, remove that network, rerun `setup_services.sh`, and restart Wings.

Do not rotate `PTERO_APP_KEY`; it encrypts the Wings node token. Back up `services/pterodactyl/db`, `services/pterodactyl/panel-var`, and `/mnt/tank/pterodactyl` together.

## Tests

The SMS bridge has unit tests. No dependencies, no Docker:

```bash
python3 -m unittest discover -s tests/unit -b
```

They run on every push. `tests/e2e` provisions a disposable host and is triggered manually from the Actions tab.

## Operations

```bash
docker compose ps
docker compose logs -f SERVICE
docker compose pull
docker compose up -d
./setup_services.sh
```

Back up `/mnt/tank`, `.env`, and stateful directories under `services/` before changing pinned database or application versions. Keep the Pterodactyl panel and Wings versions compatible. After a Docker engine upgrade, update `DOCKER_API_VERSION` to the server API reported by `docker version`.
