#!/usr/bin/env python3
"""Restart the Valheim server nightly, but only while nobody is on it (README 24.17).

Restarting *is* the update: the egg's image runs `steamcmd +app_update` on every
container start (AUTO_UPDATE=1), the dedicated server has no in-place updater,
and it takes no stdin commands. Valheim then refuses any client newer than the
server, so a box that is never restarted eventually locks everyone out.

The panel's own scheduler can do a nightly restart, but its only condition is
`only_when_online` — it cannot see players, so it would happily kick a late
session and drop up to BACKUP_INTERVAL (1800s) of world state. This does the
same restart with that one extra condition, which is why the panel schedule was
removed rather than left running alongside it: two triggers would restart twice.

Player count comes from the server's own console line, printed every 10 minutes:

    09/12/2026 19:28:54:  Connections 0 ZDOS:66156  sent:0 recv:0

Nothing else reports it. Pterodactyl has no game-query support at all, so
neither the panel API nor Wings knows how many people are connected.

Every unknown counts as "someone might be on": a stale line, an unparseable one,
an unreachable Wings, a server that is not running. A skipped night costs
nothing — whenever the server does start, it updates — while a wrong restart
lands on live players.
"""
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

UUID = os.environ["VALHEIM_UUID"]
WINGS = os.environ.get("WINGS_URL", "http://wings:8092")
WINGS_CONFIG = os.environ.get("WINGS_CONFIG", "/etc/pterodactyl/config.yml")
POLL = int(os.environ.get("POLL_SECONDS", "300"))
# Local wall time (the container's TZ), and how long past it to keep retrying
# when players are on. The window must not cross midnight.
RESTART_AT = os.environ.get("RESTART_AT", "03:00")
WINDOW = int(os.environ.get("WINDOW_MINUTES", "180"))
# The console prints its connection count every 10 minutes, so anything older
# than this is a line left over from before a restart or a stall — not evidence
# that the server is empty now.
MAX_AGE = int(os.environ.get("MAX_LINE_AGE_SECONDS", "1500"))
DOC = os.environ.get("DOC_ROOT", "/srv")
PORT = int(os.environ.get("HTTP_PORT", "8098"))

STATE = os.path.join(DOC, "autoupdate.json")
# The game logs in UTC regardless of the container's TZ, and Wings prefixes
# nothing to the line, so the timestamp is parsed straight out of it.
CONN_RE = re.compile(r"(\d\d/\d\d/\d{4} \d\d:\d\d:\d\d): +Connections (\d+)")


def log(msg):
    print(msg, flush=True)


def wings_token():
    """Read Wings' node token from its own config rather than duplicating it
    into .env — same reasoning (and same mount) as the join-code watcher."""
    with open(WINGS_CONFIG) as fh:
        for line in fh:
            if line.startswith("token:"):
                return line.split(":", 1)[1].strip()
    raise SystemExit(f"no token in {WINGS_CONFIG}")


def wings_call(token, path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        f"{WINGS}{path}",
        data=data,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
            **({"Content-Type": "application/json"} if data else {}),
        },
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        body = resp.read()
        return json.loads(body) if body else {}


def server_state(token):
    """running / starting / stopping / offline."""
    return wings_call(token, f"/api/servers/{UUID}").get("state", "unknown")


def connections(token):
    """(players, seconds since that line) from the newest Connections line, or
    (None, None) when the log window holds none — which happens on a server that
    just booted, or a busy one whose chatter has pushed it out of Wings' ~100
    line buffer."""
    lines = wings_call(token, f"/api/servers/{UUID}/logs?size=100").get("data", [])
    hits = [m for line in lines for m in [CONN_RE.search(line)] if m]
    if not hits:
        return None, None
    stamp, count = hits[-1].groups()
    seen = datetime.strptime(stamp, "%m/%d/%Y %H:%M:%S").replace(tzinfo=timezone.utc)
    return int(count), (datetime.now(timezone.utc) - seen).total_seconds()


def restart(token):
    wings_call(token, f"/api/servers/{UUID}/power", {"action": "restart"})


def load_state():
    try:
        with open(STATE) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def save_state(state, status, done_for=None):
    """Publish what happened. `done_for` is the date this night is finished for
    — set only once the server has been restarted or the window has closed, so a
    container recreate mid-window resumes instead of restarting a second time."""
    if done_for:
        state["done_for"] = done_for
    state["status"] = status
    state["updated"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    tmp = STATE + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(state, fh)
    os.replace(tmp, STATE)
    return state


def tick(token, state):
    now = datetime.now().astimezone()
    today = now.date().isoformat()
    if state.get("done_for") == today:
        return

    hour, minute = (int(part) for part in RESTART_AT.split(":"))
    opens = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if now < opens:
        return
    if now > opens + timedelta(minutes=WINDOW):
        # Two ways to land here: players held the window open all night, or this
        # container simply started after it closed. Only the first is a skipped
        # update, so they are reported apart.
        waited = str(state.get("status", "")).startswith("waiting")
        note = ("skipped: players on all window" if waited
                else "idle: today's window already passed")
        log(note)
        save_state(state, note, done_for=today)
        return

    state_now = server_state(token)
    if state_now != "running":
        # Nothing to restart, and nothing to miss: a stopped server runs
        # SteamCMD whenever it is next started.
        log(f"server is {state_now} - it will update on its next start")
        save_state(state, f"skipped: server {state_now}", done_for=today)
        return

    players, age = connections(token)
    if players is None:
        log("no Connections line in the log window - not restarting")
        return
    if age > MAX_AGE:
        log(f"newest Connections line is {age:.0f}s old - not restarting")
        return
    if players:
        log(f"{players} player(s) online - retrying in {POLL}s")
        save_state(state, f"waiting: {players} online")
        return

    restart(token)
    log("server empty - restart sent (SteamCMD runs on the way back up)")
    save_state(state, "restarted while empty", done_for=today)


class QuietHandler(SimpleHTTPRequestHandler):
    """Glance polls the status file on its own interval; logging every hit would
    bury the handful of lines here that matter."""

    def log_message(self, *args):
        pass


def serve():
    """Status file for the Glance monitor. No published port — Glance reaches it
    by container name on the homelab network."""
    handler = partial(QuietHandler, directory=DOC)
    ThreadingHTTPServer(("", PORT), handler).serve_forever()


def main():
    token = wings_token()
    threading.Thread(target=serve, daemon=True).start()
    state = load_state()
    if "status" not in state:
        # Make the endpoint 200 before the first night, so a fresh deploy does
        # not look like a dead service to Glance.
        state = save_state(state, "idle")
    log(f"guarding {UUID}: restart at {RESTART_AT} local when empty, "
        f"retrying up to {WINDOW}m, polling every {POLL}s")

    while True:
        try:
            tick(token, state)
        except (urllib.error.URLError, OSError, ValueError) as exc:
            # Wings restarts, the game server is often simply off, and neither
            # is worth crashing over - the next poll picks it up.
            log(f"check failed: {exc}")
        time.sleep(POLL)


if __name__ == "__main__":
    sys.exit(main())
