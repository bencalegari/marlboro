#!/usr/bin/env python3
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

SERVER_UUID = os.environ["VALHEIM_UUID"]
WINGS_URL = os.environ.get("WINGS_URL", "http://wings:8092")
WINGS_CONFIG = os.environ.get("WINGS_CONFIG", "/etc/pterodactyl/config.yml")
POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "300"))
RESTART_LOCAL_TIME = os.environ.get("RESTART_AT", "03:00")
RETRY_WINDOW_MINUTES = int(os.environ.get("WINDOW_MINUTES", "180"))
MAX_CONNECTION_LINE_AGE_SECONDS = int(os.environ.get("MAX_LINE_AGE_SECONDS", "1500"))
DOCUMENT_ROOT = os.environ.get("DOC_ROOT", "/srv")
HTTP_PORT = int(os.environ.get("HTTP_PORT", "8098"))

STATE_FILE = os.path.join(DOCUMENT_ROOT, "autoupdate.json")
CONN_RE = re.compile(r"(\d\d/\d\d/\d{4} \d\d:\d\d:\d\d): +Connections (\d+)")


def log(msg):
    print(msg, flush=True)


def read_wings_token():
    with open(WINGS_CONFIG) as fh:
        for line in fh:
            if line.startswith("token:"):
                return line.split(":", 1)[1].strip()
    raise SystemExit(f"no token in {WINGS_CONFIG}")


def wings_call(token, path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        f"{WINGS_URL}{path}",
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


def get_server_state(token):
    return wings_call(token, f"/api/servers/{SERVER_UUID}").get("state", "unknown")


def get_recent_connection_count(token):
    lines = wings_call(token, f"/api/servers/{SERVER_UUID}/logs?size=100").get("data", [])
    hits = [m for line in lines for m in [CONN_RE.search(line)] if m]
    if not hits:
        return None, None
    stamp, count = hits[-1].groups()
    seen = datetime.strptime(stamp, "%m/%d/%Y %H:%M:%S").replace(tzinfo=timezone.utc)
    return int(count), (datetime.now(timezone.utc) - seen).total_seconds()


def restart_server(token):
    wings_call(token, f"/api/servers/{SERVER_UUID}/power", {"action": "restart"})


def load_state():
    try:
        with open(STATE_FILE) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def save_state(state, status, done_for=None):
    if done_for:
        state["done_for"] = done_for
    state["status"] = status
    state["updated"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(state, fh)
    os.replace(tmp, STATE_FILE)
    return state


def run_scheduled_check(token, state):
    now = datetime.now().astimezone()
    today = now.date().isoformat()
    if state.get("done_for") == today:
        return

    hour, minute = (int(part) for part in RESTART_LOCAL_TIME.split(":"))
    opens = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if now < opens:
        return
    if now > opens + timedelta(minutes=RETRY_WINDOW_MINUTES):
        waited = str(state.get("status", "")).startswith("waiting")
        note = ("skipped: players on all window" if waited
                else "idle: today's window already passed")
        log(note)
        save_state(state, note, done_for=today)
        return

    state_now = get_server_state(token)
    if state_now != "running":
        log(f"server is {state_now} - it will update on its next start")
        save_state(state, f"skipped: server {state_now}", done_for=today)
        return

    players, age = get_recent_connection_count(token)
    if players is None:
        log("no Connections line in the log window - not restarting")
        return
    if age > MAX_CONNECTION_LINE_AGE_SECONDS:
        log(f"newest Connections line is {age:.0f}s old - not restarting")
        return
    if players:
        log(f"{players} player(s) online - retrying in {POLL_SECONDS}s")
        save_state(state, f"waiting: {players} online")
        return

    restart_server(token)
    log("server empty - restart sent (SteamCMD runs on the way back up)")
    save_state(state, "restarted while empty", done_for=today)


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def serve_state_file():
    handler = partial(QuietHandler, directory=DOCUMENT_ROOT)
    ThreadingHTTPServer(("", HTTP_PORT), handler).serve_forever()


def main():
    token = read_wings_token()
    threading.Thread(target=serve_state_file, daemon=True).start()
    state = load_state()
    if "status" not in state:
        state = save_state(state, "idle")
    log(f"guarding {SERVER_UUID}: restart at {RESTART_LOCAL_TIME} local when empty, "
        f"retrying up to {RETRY_WINDOW_MINUTES}m, polling every {POLL_SECONDS}s")

    while True:
        try:
            run_scheduled_check(token, state)
        except (urllib.error.URLError, OSError, ValueError) as exc:
            log(f"check failed: {exc}")
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    sys.exit(main())
