#!/usr/bin/env python3
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

SERVER_UUID = os.environ["VALHEIM_UUID"]
WINGS_URL = os.environ.get("WINGS_URL", "http://wings:8092")
NTFY_URL = os.environ.get("NTFY_URL", "http://ntfy:80")
NTFY_TOPIC = os.environ.get("NTFY_TOPIC", "valheim")
POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "60"))
DOCUMENT_ROOT = os.environ.get("DOC_ROOT", "/srv")
HTTP_PORT = int(os.environ.get("HTTP_PORT", "8099"))
WINGS_CONFIG = os.environ.get("WINGS_CONFIG", "/etc/pterodactyl/config.yml")

STATE_FILE = os.path.join(DOCUMENT_ROOT, "joincode.json")
CODE_RE = re.compile(r"registered with join code (\d+)")
NET_ERRORS = (urllib.error.URLError, OSError, ValueError)


def log(msg):
    print(msg, flush=True)


def read_wings_token():
    with open(WINGS_CONFIG) as fh:
        for line in fh:
            if line.startswith("token:"):
                return line.split(":", 1)[1].strip()
    raise SystemExit(f"no token in {WINGS_CONFIG}")


def get_wings(token, path):
    req = urllib.request.Request(
        f"{WINGS_URL}/api/servers/{SERVER_UUID}{path}",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.load(resp)


def find_latest_join_code(token):
    lines = get_wings(token, "/logs?size=100").get("data", [])
    codes = [m.group(1) for line in lines for m in [CODE_RE.search(line)] if m]
    return codes[-1] if codes else None


def get_server_access(token):
    env = get_wings(token, "").get("configuration", {}).get("environment", {})
    return {"server": env.get("SERVER_NAME", ""), "password": env.get("PASSWORD", "")}


def publish_to_ntfy(doc):
    body = f"Join code {doc['code']}"
    if doc.get("password"):
        body += f"\nPassword {doc['password']}"
    req = urllib.request.Request(
        f"{NTFY_URL}/{NTFY_TOPIC}",
        data=body.encode(),
        headers={"Title": "Valheim join code", "Tags": "video_game"},
    )
    urllib.request.urlopen(req, timeout=15).close()


def load_state():
    try:
        with open(STATE_FILE) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def store_state(doc):
    doc = dict(doc, captured=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(doc, fh)
    os.replace(tmp, STATE_FILE)
    return doc


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
    log(f"watching {SERVER_UUID} every {POLL_SECONDS}s (known code: {state.get('code') or 'none'})")

    while True:
        fresh = dict(state)
        try:
            fresh.update(get_server_access(token))
        except NET_ERRORS as exc:
            log(f"wings config poll failed: {exc}")
        try:
            fresh["code"] = find_latest_join_code(token) or state.get("code")
        except NET_ERRORS as exc:
            log(f"wings log poll failed: {exc}")

        changed = {k: v for k, v in fresh.items() if state.get(k) != v and k != "captured"}
        if changed:
            new_code = "code" in changed
            state = store_state(fresh)
            if new_code:
                try:
                    publish_to_ntfy(state)
                except NET_ERRORS as exc:
                    log(f"ntfy push failed for {state['code']}: {exc}")
            log(f"published {sorted(changed)} at {state['captured']}")

        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    sys.exit(main())
