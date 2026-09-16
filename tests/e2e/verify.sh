#!/usr/bin/env bash

set -euo pipefail
trap 'printf "Verification failed at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

for service in $MARLBORO_COMPOSE_SERVICES; do
  docker inspect "$service" >/dev/null
  [ "$(docker inspect --format '{{.State.Running}}' "$service")" = "true" ]
  health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$service")
  [ -z "$health" ] || [ "$health" = "healthy" ]
done

[ "$(docker info --format '{{.DockerRootDir}}')" = "/mnt/tank/docker" ]
grep -q '^RequiresMountsFor=/mnt/tank$' /etc/systemd/system/docker.service.d/wait-for-tank.conf
grep -q '^DNSStubListener=no$' /etc/systemd/resolved.conf.d/adguard.conf

while IFS= read -r name; do
  grep -q "^$name=.[^[:space:]]*" .env
done <<'EOF'
IMMICH_DB_PASSWORD
QBIT_PASSWORD
PTERO_APP_KEY
PTERO_DB_PASSWORD
EOF

if [[ " $MARLBORO_COMPOSE_SERVICES " == *" jellyfin "* ]]; then
  grep -q '^SONARR_API_KEY=.[^[:space:]]*' .env
  grep -q '^RADARR_API_KEY=.[^[:space:]]*' .env
  curl -fsS http://localhost:8096/System/Info/Public | jq -e '.StartupWizardCompleted == true' >/dev/null
  sudo python3 - <<'PY'
import yaml

with open("services/adguard/conf/AdGuardHome.yaml") as handle:
    config = yaml.safe_load(handle)
assert config["http"]["address"].endswith(":3001")
assert config["users"]
PY
fi

if [[ " $MARLBORO_COMPOSE_SERVICES " == *" portainer "* ]]; then
  [ "$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:9000/api/users/admin/check)" = "204" ]
  docker compose exec -T --user 1000:1000 forgejo forgejo admin user list | grep -q ben
  curl -fsS http://localhost:8085/api/settings | jq -e '.settings.metrics.status_threshold == 1' >/dev/null
  jq -e '.["Marlboro NAS - Pterodactyl Client API"].api_token | length > 0' "$OP_MOCK_STORE" >/dev/null
fi

docker compose config --quiet
