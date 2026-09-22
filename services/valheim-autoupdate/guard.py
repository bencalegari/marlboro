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
NTFY_URL = os.environ.get("NTFY_URL", "http://ntfy:80")
NTFY_TOPIC = os.environ.get("NTFY_TOPIC", "valheim")
STAMP_FILE = os.environ.get("STAMP_FILE", "/bepinex/.marlboro-mods")
BEPINEX_LOG = os.environ.get("BEPINEX_LOG", "/bepinex/LogOutput.log")
HEALTH_DELAY_SECONDS = int(os.environ.get("HEALTH_DELAY_SECONDS", "240"))
HEALTH_RETRIES = int(os.environ.get("HEALTH_RETRIES", "3"))

STATE_FILE = os.path.join(DOCUMENT_ROOT, "autoupdate.json")
CONN_RE = re.compile(r"(\d\d/\d\d/\d{4} \d\d:\d\d:\d\d): +Connections (\d+)")
BEPINEX_ERROR_RE = re.compile(r"^\[(?:Error|Fatal)\s*:\s*([^\]]+)\]")
# The game logs its own headless-rendering failures through BepInEx.
IGNORED_LOG_SOURCES = {"Unity Log"}
THUNDERSTORE_API = "https://thunderstore.io/api/experimental/package/{0}/{1}/"
THUNDERSTORE_PAGE = "https://thunderstore.io/c/valheim/p/{0}/{1}/"
THUNDERSTORE_AGENT = "marlboro-valheim-autoupdate"


NET_ERRORS = (urllib.error.URLError, OSError, ValueError)


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


def publish_to_ntfy(title, body, tags, priority=None):
    headers = {"Title": title, "Tags": tags}
    if priority:
        headers["Priority"] = priority
    req = urllib.request.Request(
        f"{NTFY_URL}/{NTFY_TOPIC}", data=body.encode(), headers=headers
    )
    urllib.request.urlopen(req, timeout=15).close()


def load_state():
    try:
        with open(STATE_FILE) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def write_state(state):
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(state, fh)
    os.replace(tmp, STATE_FILE)
    return state


def save_state(state, status, done_for=None):
    if done_for:
        state["done_for"] = done_for
    state["status"] = status
    state["updated"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    return write_state(state)


def read_installed_mods():
    mods = []
    with open(STAMP_FILE) as fh:
        for line in fh:
            parts = line.strip().split()
            if len(parts) == 2 and "/" in parts[0]:
                mods.append((parts[0], parts[1]))
    return mods


def version_tuple(value):
    return tuple(int(part) if part.isdigit() else 0 for part in value.split("."))


def latest_version(package):
    namespace, name = package.split("/", 1)
    req = urllib.request.Request(
        THUNDERSTORE_API.format(namespace, name),
        headers={"Accept": "application/json", "User-Agent": THUNDERSTORE_AGENT},
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.load(resp)["latest"]["version_number"]


def run_mod_version_check(state):
    today = datetime.now().astimezone().date().isoformat()
    if state.get("mods_checked_for") == today:
        return

    try:
        mods = read_installed_mods()
    except OSError as exc:
        log(f"cannot read {STAMP_FILE}: {exc}")
        return

    announced = state.setdefault("mod_updates", {})
    behind, stale, failed = [], 0, False
    for package, installed in mods:
        try:
            latest = latest_version(package)
        except NET_ERRORS as exc:
            log(f"could not check {package}: {exc}")
            failed = True
            continue
        if version_tuple(latest) <= version_tuple(installed):
            announced.pop(package, None)
            continue
        stale += 1
        if announced.get(package) != latest:
            behind.append((package, installed, latest))
        announced[package] = latest

    if behind:
        body = "\n".join(
            f"{package} {installed} -> {latest}\n"
            + THUNDERSTORE_PAGE.format(*package.split("/", 1))
            for package, installed, latest in behind
        )
        try:
            publish_to_ntfy("Valheim mod updates", body, "arrow_up")
            log(f"{len(behind)} mod update(s) available - pushed to ntfy")
        except NET_ERRORS as exc:
            log(f"ntfy push failed for mod updates: {exc}")
            for package, _, _ in behind:
                announced.pop(package, None)
            failed = True
    elif stale:
        log(f"{stale} mod update(s) available - already pushed")
    elif not failed:
        log("mods are at the newest published versions")

    if not failed:
        state["mods_checked_for"] = today
    write_state(state)


def run_health_check(state):
    due = state.get("health_due")
    if not due or time.time() < due:
        return

    # BepInEx truncates its log at startup, so the file is this boot alone --
    # but only once the new process has written it.
    restarted_at = due - HEALTH_DELAY_SECONDS
    try:
        written = os.path.getmtime(BEPINEX_LOG)
        with open(BEPINEX_LOG, errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        written, lines = 0, []

    if written < restarted_at:
        tries = state.get("health_tries", 0) + 1
        if tries <= HEALTH_RETRIES:
            state["health_tries"] = tries
            state["health_due"] = time.time() + HEALTH_DELAY_SECONDS
            log(f"BepInEx has not written its log yet - retry {tries}/{HEALTH_RETRIES}")
            write_state(state)
            return
        errors, headline = [], "BepInEx did not load on this boot"
    else:
        errors = [line for line in lines
                  if (match := BEPINEX_ERROR_RE.match(line))
                  and match.group(1).strip() not in IGNORED_LOG_SOURCES]
        started = any("Chainloader started" in line for line in lines)
        complete = any("Chainloader startup complete" in line for line in lines)
        if not errors and (complete or not started):
            state.pop("health_due", None)
            state.pop("health_tries", None)
            log("BepInEx loaded cleanly after the restart")
            write_state(state)
            return
        headline = ("Chainloader did not finish" if started and not complete
                    else "BepInEx reported errors")

    state.pop("health_due", None)
    state.pop("health_tries", None)
    body = "\n".join([headline] + [line.strip()[:200] for line in errors[:3]])
    try:
        publish_to_ntfy("Valheim mods failed to load", body, "warning", priority="high")
        log(f"mod health check failed: {headline}")
    except NET_ERRORS as exc:
        log(f"ntfy push failed for the mod health check: {exc}")
    write_state(state)


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
    state["health_due"] = time.time() + HEALTH_DELAY_SECONDS
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
            run_health_check(state)
            run_mod_version_check(state)
        except NET_ERRORS as exc:
            log(f"check failed: {exc}")
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    sys.exit(main())
