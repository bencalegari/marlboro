#!/usr/bin/env python3
"""Capture the Valheim join code and republish it with what else players need
to get in (README 24.15).

The join code exists in exactly one place: a single console line printed at boot,

    Session "Valhymen" registered with join code 362087

and it changes on every restart. Pterodactyl's client API has no log endpoint at
all, and Wings' /logs route returns only the last ~100 lines - roughly two hours
on an idle server, minutes on a busy one - so the only way to keep the code is to
notice it while it is still inside that window and store it.

The server name and password are not in the log at all; they come from Wings'
server configuration, which carries the egg's resolved environment. Reading them
there rather than from .env keeps the panel the single source of truth: change
the password in the panel and the dashboard follows on the next poll.

State is written for the Glance tile, and a new code is pushed to ntfy. Both are
idempotent: a restart producing the same code sends no second notification.
"""
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.request
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

UUID = os.environ["VALHEIM_UUID"]
WINGS = os.environ.get("WINGS_URL", "http://wings:8092")
NTFY = os.environ.get("NTFY_URL", "http://ntfy:80")
TOPIC = os.environ.get("NTFY_TOPIC", "valheim")
POLL = int(os.environ.get("POLL_SECONDS", "60"))
DOC = os.environ.get("DOC_ROOT", "/srv")
PORT = int(os.environ.get("HTTP_PORT", "8099"))
WINGS_CONFIG = os.environ.get("WINGS_CONFIG", "/etc/pterodactyl/config.yml")

STATE = os.path.join(DOC, "joincode.json")
CODE_RE = re.compile(r"registered with join code (\d+)")
NET_ERRORS = (urllib.error.URLError, OSError, ValueError)


def log(msg):
    print(msg, flush=True)


def wings_token():
    """Read Wings' node token from its own config rather than duplicating it
    into .env, so a token rotation needs no second edit here. Hand-parsed: the
    file is flat YAML at this level and pyyaml would be the only dependency."""
    with open(WINGS_CONFIG) as fh:
        for line in fh:
            if line.startswith("token:"):
                return line.split(":", 1)[1].strip()
    raise SystemExit(f"no token in {WINGS_CONFIG}")


def wings_get(token, path):
    req = urllib.request.Request(
        f"{WINGS}/api/servers/{UUID}{path}",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.load(resp)


def latest_code(token):
    lines = wings_get(token, "/logs?size=100").get("data", [])
    codes = [m.group(1) for line in lines for m in [CODE_RE.search(line)] if m]
    return codes[-1] if codes else None


def server_env(token):
    env = wings_get(token, "").get("configuration", {}).get("environment", {})
    return {"server": env.get("SERVER_NAME", ""), "password": env.get("PASSWORD", "")}


def push(doc):
    body = f"Join code {doc['code']}"
    if doc.get("password"):
        body += f"\nPassword {doc['password']}"
    req = urllib.request.Request(
        f"{NTFY}/{TOPIC}",
        data=body.encode(),
        headers={"Title": "Valheim join code", "Tags": "video_game"},
    )
    urllib.request.urlopen(req, timeout=15).close()


def load_state():
    """Survive a restart of this container without re-notifying."""
    try:
        with open(STATE) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def store(doc):
    doc = dict(doc, captured=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    tmp = STATE + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(doc, fh)
    os.replace(tmp, STATE)
    return doc


class QuietHandler(SimpleHTTPRequestHandler):
    """Glance polls this file on its own cache interval; logging every hit would
    bury the only lines here that matter. Overridden on the class, not on the
    partial - a partial takes attributes without passing them to the handler."""

    def log_message(self, *args):
        pass


def serve():
    """Static file server for the Glance tile. No published port - Glance
    reaches it by container name on the homelab network."""
    handler = partial(QuietHandler, directory=DOC)
    ThreadingHTTPServer(("", PORT), handler).serve_forever()


def main():
    token = wings_token()
    threading.Thread(target=serve, daemon=True).start()
    state = load_state()
    log(f"watching {UUID} every {POLL}s (known code: {state.get('code') or 'none'})")

    while True:
        # Wings restarts, and the game server is often simply off. Neither is
        # worth crashing over; the next poll picks it up. Anything that fails
        # falls back to what is already published rather than blanking the tile.
        fresh = dict(state)
        try:
            fresh.update(server_env(token))
        except NET_ERRORS as exc:
            log(f"wings config poll failed: {exc}")
        try:
            fresh["code"] = latest_code(token) or state.get("code")
        except NET_ERRORS as exc:
            log(f"wings log poll failed: {exc}")

        changed = {k: v for k, v in fresh.items() if state.get(k) != v and k != "captured"}
        if changed:
            new_code = "code" in changed
            state = store(fresh)
            # Only a new code is worth a notification. A password edit in the
            # panel reaches the tile silently.
            if new_code:
                try:
                    push(state)
                except NET_ERRORS as exc:
                    log(f"ntfy push failed for {state['code']}: {exc}")
            log(f"published {sorted(changed)} at {state['captured']}")

        time.sleep(POLL)


if __name__ == "__main__":
    sys.exit(main())
