#!/usr/bin/env python3
import base64
import hashlib
import hmac
import json
import os
import re
import sqlite3
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.sax.saxutils as saxutils
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

def log(msg):
    print(f"{time.strftime('%Y-%m-%dT%H:%M:%S%z')} {msg}", flush=True)


def env_value(name, default=""):
    return os.environ.get(name, "").strip() or default


def env_int(name, default):
    try:
        return int(env_value(name, str(default)))
    except ValueError:
        log(f"WARN: {name} is not a number — falling back to {default}")
        return default


LISTEN_PORT = env_int("SMS_BRIDGE_PORT", 8080)
DB_PATH = env_value("SMS_DB", "/app/data/bridge.db")

TWILIO_SID = env_value("TWILIO_ACCOUNT_SID")
TWILIO_TOKEN = env_value("TWILIO_AUTH_TOKEN")
TWILIO_FROM_RAW = env_value("TWILIO_FROM_NUMBER")

PUBLIC_URL = env_value("SMS_BRIDGE_PUBLIC_URL")

HOOK_SECRET = env_value("SMS_BRIDGE_HOOK_SECRET")
SEERR_URL = env_value("SEERR_URL", "http://seerr:5055").rstrip("/")
SEERR_SETTINGS = env_value("SEERR_SETTINGS", "/seerr-settings.json")

RATE_LIMIT = env_int("SMS_RATE_LIMIT", 12)
DAILY_CAP = env_int("SMS_DAILY_CAP", 100)
SESSION_TTL_SECONDS = 15 * 60
MAX_CHOICES = 3
SMS_CHARACTER_LIMIT = 320

BRAND = env_value("SMS_BRAND", "Marlboro Media")
OPT_OUT = "Reply STOP to opt out."
DISCLOSURE_INTERVAL_SECONDS = 30 * 86400

HELP_KEYWORDS = {"help", "info"}
OPTOUT_KEYWORDS = {"stop", "stopall", "unsubscribe", "cancel", "end", "quit",
                   "start", "unstop", "yes"}
HELP_TEXT = (
    "Text a movie or TV title to request it. You'll get a numbered list; reply with a "
    "number, and another text when it's ready to watch. Msg & data rates may apply. "
    "Reply STOP to opt out. Help: lap.rapper_3o@icloud.com"
)

ST_PENDING, ST_PROCESSING, ST_PARTIAL, ST_AVAILABLE = 2, 3, 4, 5


def norm_phone(raw):
    d = re.sub(r"\D", "", raw or "")
    if not d:
        return ""
    if len(d) == 10:
        d = "1" + d
    return "+" + d


def parse_allowlist(raw):
    fwd, rev = {}, {}
    for entry in (raw or "").split(","):
        entry = entry.strip()
        if not entry or "=" not in entry:
            continue
        phone, name = entry.split("=", 1)
        phone, name = norm_phone(phone), name.strip()
        if phone and name:
            fwd[phone] = name
            rev[name.lower()] = phone
    return fwd, rev


ALLOW, ALLOW_BY_NAME = parse_allowlist(env_value("SMS_ALLOWLIST"))
TWILIO_FROM = norm_phone(TWILIO_FROM_RAW) if TWILIO_FROM_RAW else ""


def db():
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    os.makedirs(os.path.dirname(DB_PATH) or ".", exist_ok=True)
    with db() as c:
        c.executescript(
            """
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS session(
              phone TEXT PRIMARY KEY, ts INTEGER NOT NULL, choices TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS req(
              request_id INTEGER PRIMARY KEY, phone TEXT NOT NULL, title TEXT,
              ts INTEGER NOT NULL, notified_at INTEGER);
            CREATE TABLE IF NOT EXISTS inbox(
              id INTEGER PRIMARY KEY AUTOINCREMENT, phone TEXT NOT NULL, ts INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS outbox(
              id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS disclosed(
              phone TEXT PRIMARY KEY, ts INTEGER NOT NULL);
            """
        )


def rate_ok(phone):
    now = int(time.time())
    with db() as c:
        c.execute("DELETE FROM inbox WHERE ts < ?", (now - 3600,))
        n = c.execute("SELECT COUNT(*) n FROM inbox WHERE phone=?", (phone,)).fetchone()["n"]
        if n >= RATE_LIMIT:
            return False
        c.execute("INSERT INTO inbox(phone, ts) VALUES(?,?)", (phone, now))
    return True


def reserve_daily_send_slot():
    now = int(time.time())
    with db() as c:
        c.execute("DELETE FROM outbox WHERE ts < ?", (now - 86400,))
        n = c.execute("SELECT COUNT(*) n FROM outbox").fetchone()["n"]
        if n >= DAILY_CAP:
            return False
        c.execute("INSERT INTO outbox(ts) VALUES(?)", (now,))
    return True


def disclosure_due(phone):
    with db() as c:
        row = c.execute("SELECT ts FROM disclosed WHERE phone=?", (phone,)).fetchone()
    return not row or row["ts"] < int(time.time()) - DISCLOSURE_INTERVAL_SECONDS


def mark_disclosed(phone):
    with db() as c:
        c.execute(
            "INSERT INTO disclosed(phone, ts) VALUES(?,?) "
            "ON CONFLICT(phone) DO UPDATE SET ts=excluded.ts",
            (phone, int(time.time())),
        )


def put_session(phone, state):
    """state is {"kind": "titles", "choices": [...]} or
    {"kind": "seasons", "choice": {...}, "seasons": [...]}."""
    with db() as c:
        c.execute(
            "INSERT INTO session(phone, ts, choices) VALUES(?,?,?) "
            "ON CONFLICT(phone) DO UPDATE SET ts=excluded.ts, choices=excluded.choices",
            (phone, int(time.time()), json.dumps(state)),
        )


def get_active_session(phone):
    now = int(time.time())
    with db() as c:
        c.execute("DELETE FROM session WHERE ts < ?", (now - SESSION_TTL_SECONDS,))
        row = c.execute("SELECT choices FROM session WHERE phone=?", (phone,)).fetchone()
    if not row:
        return None
    state = json.loads(row["choices"])
    if isinstance(state, list):  # session written before seasons existed
        state = {"kind": "titles", "choices": state}
    return state


def clear_session(phone):
    with db() as c:
        c.execute("DELETE FROM session WHERE phone=?", (phone,))


_seerr_key = None
_users_cache = {"at": 0, "rows": []}
_lock = threading.Lock()


def load_seerr_api_key(force=False):
    global _seerr_key
    if _seerr_key and not force:
        return _seerr_key
    try:
        with open(SEERR_SETTINGS) as f:
            _seerr_key = json.load(f)["main"]["apiKey"]
    except Exception as e:
        log(f"ERROR: cannot read Seerr API key from {SEERR_SETTINGS}: {e}")
        _seerr_key = ""
    return _seerr_key


def call_seerr(method, path, body=None, _retried=False):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        f"{SEERR_URL}{path}",
        data=data,
        method=method,
        headers={"X-Api-Key": load_seerr_api_key(), "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        if e.code == 401 and not _retried:
            load_seerr_api_key(force=True)
            return call_seerr(method, path, body, _retried=True)
        raise


def find_seerr_user_id(name):
    with _lock:
        if time.time() - _users_cache["at"] > 300:
            try:
                _users_cache["rows"] = call_seerr("GET", "/api/v1/user?take=200").get("results", [])
                _users_cache["at"] = time.time()
            except Exception as e:
                log(f"WARN: user list fetch failed: {e}")
        rows = list(_users_cache["rows"])
    target = name.lower()
    for u in rows:
        for field in ("displayName", "username", "jellyfinUsername"):
            if (u.get(field) or "").lower() == target:
                return u.get("id")
    return None


def search(query):
    q = urllib.parse.quote(query)
    results = call_seerr("GET", f"/api/v1/search?query={q}&page=1").get("results", [])
    out = []
    for r in results:
        if r.get("mediaType") not in ("movie", "tv"):
            continue
        date = r.get("releaseDate") or r.get("firstAirDate") or ""
        out.append(
            {
                "tmdbId": r.get("id"),
                "mediaType": r.get("mediaType"),
                "title": r.get("title") or r.get("name") or "?",
                "year": date[:4],
                "status": (r.get("mediaInfo") or {}).get("status"),
            }
        )
        if len(out) == MAX_CHOICES:
            break
    return out


def create_request(choice, user_id, seasons=None):
    body = {"mediaType": choice["mediaType"], "mediaId": choice["tmdbId"], "userId": user_id}
    if choice["mediaType"] == "tv":
        body["seasons"] = seasons or "all"
    return call_seerr("POST", "/api/v1/request", body)


def tv_open_seasons(tmdb_id):
    """Season numbers with aired episodes that nobody has requested yet."""
    detail = call_seerr("GET", f"/api/v1/tv/{tmdb_id}")
    taken = {
        s.get("seasonNumber"): s.get("status")
        for s in ((detail.get("mediaInfo") or {}).get("seasons") or [])
    }
    open_seasons = []
    for s in detail.get("seasons") or []:
        n = s.get("seasonNumber")
        if not n or not s.get("episodeCount"):  # skip specials (0) and unaired
            continue
        if taken.get(n) in (ST_PENDING, ST_PROCESSING, ST_PARTIAL, ST_AVAILABLE):
            continue
        open_seasons.append(n)
    return sorted(open_seasons)


def valid_twilio_signature(params, signature):
    if not (TWILIO_TOKEN and PUBLIC_URL and signature):
        return False
    payload = PUBLIC_URL + "".join(k + params[k] for k in sorted(params))
    mac = hmac.new(TWILIO_TOKEN.encode(), payload.encode("utf-8"), hashlib.sha1).digest()
    return hmac.compare_digest(base64.b64encode(mac).decode(), signature)


def compose_sms(phone, body):
    prefix = f"{BRAND}: " if BRAND else ""
    disclosing = disclosure_due(phone)
    suffix = f"\n{OPT_OUT}" if disclosing and OPT_OUT not in body else ""
    room = SMS_CHARACTER_LIMIT - len(prefix) - len(suffix)
    if len(body) > room:
        body = body[: max(0, room - 3)].rstrip() + "..."
    return prefix + body + suffix, disclosing


def send_sms(to, body):
    if to not in ALLOW:
        log(f"REFUSED: outbound to non-allowlisted {to}")
        return False
    if not reserve_daily_send_slot():
        log(f"REFUSED: daily send cap ({DAILY_CAP}) reached, dropping text to {to}")
        return False
    body, disclosing = compose_sms(to, body)
    data = urllib.parse.urlencode({"To": to, "From": TWILIO_FROM, "Body": body[:SMS_CHARACTER_LIMIT]}).encode()
    url = f"https://api.twilio.com/2010-04-01/Accounts/{TWILIO_SID}/Messages.json"
    auth = base64.b64encode(f"{TWILIO_SID}:{TWILIO_TOKEN}".encode()).decode()
    req = urllib.request.Request(
        url,
        data=data,
        method="POST",
        headers={
            "Authorization": f"Basic {auth}",
            "Content-Type": "application/x-www-form-urlencoded",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            r.read()
        if disclosing:
            mark_disclosed(to)
        log(f"sent -> {to}: {body[:60]!r}")
        return True
    except urllib.error.HTTPError as e:
        log(f"ERROR: Twilio send to {to} failed {e.code}: {e.read()[:300]!r}")
    except Exception as e:
        log(f"ERROR: Twilio send to {to} failed: {e}")
    return False


def twiml(body):
    esc = saxutils.escape(body[:SMS_CHARACTER_LIMIT])
    return f'<?xml version="1.0" encoding="UTF-8"?><Response><Message>{esc}</Message></Response>'


def fmt_choice(i, c):
    kind = "movie" if c["mediaType"] == "movie" else "series"
    title = c["title"][:40]
    year = f" ({c['year']})" if c["year"] else ""
    return f"{i}. {title}{year} [{kind}]"


def pick_range(n):
    return "1" if n == 1 else f"1-{n}"


def fmt_seasons(nums):
    """[1,2,3,5] -> "1-3, 5" so long season lists still fit one text."""
    nums = sorted(set(nums))
    parts, i = [], 0
    while i < len(nums):
        j = i
        while j + 1 < len(nums) and nums[j + 1] == nums[j] + 1:
            j += 1
        parts.append(str(nums[i]) if i == j else f"{nums[i]}-{nums[j]}")
        i = j + 1
    return ", ".join(parts)


def parse_season_pick(text, open_seasons):
    """Season numbers from "3", "3-5", "3,5", or "ALL". None if it isn't a pick."""
    text = text.strip()
    if re.fullmatch(r"all", text, re.I):
        return list(open_seasons)
    if not re.fullmatch(r"[\d\s,-]+", text):
        return None
    picked = set()
    for part in text.split(","):
        part = part.strip()
        if not part:
            continue
        span = re.fullmatch(r"(\d+)\s*-\s*(\d+)", part)
        if span:
            lo, hi = sorted((int(span.group(1)), int(span.group(2))))
            picked.update(range(lo, hi + 1))
        elif part.isdigit():
            picked.add(int(part))
        else:
            return None
    return sorted(picked)


def handle_text(phone, name, text):
    text = (text or "").strip()
    if not text:
        return None

    word = re.sub(r"[^a-z]", "", text.lower())
    if word in OPTOUT_KEYWORDS:
        log(f"keyword {word!r} from {phone} — Twilio owns opt-out state, staying silent")
        return None
    if word in HELP_KEYWORDS:
        return HELP_TEXT

    session = get_active_session(phone)
    if session and session["kind"] == "seasons":
        reply = handle_season_pick(phone, name, session, text)
        if reply is not None:
            return reply  # None means it wasn't a pick, so fall through to search
    elif text.isdigit():
        choices = session["choices"] if session else None
        if not choices:
            return "That pick expired. Text a title to search again."
        idx = int(text)
        if not 1 <= idx <= len(choices):
            return f"Pick {pick_range(len(choices))}, or text a title to search again."
        return do_request(phone, name, choices[idx - 1])

    try:
        choices = search(text)
    except Exception as e:
        log(f"ERROR: search {text!r} failed: {e}")
        return "Search is down right now. Try again in a bit."

    if not choices:
        return f'Nothing found for "{text[:60]}". Try the exact title.'

    if len(choices) == 1 and choices[0]["status"] == ST_AVAILABLE:
        return do_request(phone, name, choices[0])

    put_session(phone, {"kind": "titles", "choices": choices})
    lines = [fmt_choice(i, c) for i, c in enumerate(choices, 1)]
    return "\n".join(lines) + f"\nReply {pick_range(len(choices))} to request."


def nothing_left_msg(choice):
    if choice["status"] == ST_AVAILABLE:
        return f"{choice['title']} is already on Jellyfin."
    return f"{choice['title']} is already requested — you'll get a text when it lands."


def do_request(phone, name, choice):
    in_seerr = choice["status"] in (ST_PENDING, ST_PROCESSING, ST_PARTIAL, ST_AVAILABLE)
    if choice["mediaType"] == "tv" and in_seerr:
        return offer_seasons(phone, choice)
    if in_seerr:
        return nothing_left_msg(choice)
    return submit_request(phone, name, choice, None)


def offer_seasons(phone, choice):
    """A series Seerr already knows may still have seasons nobody asked for."""
    try:
        open_seasons = tv_open_seasons(choice["tmdbId"])
    except Exception as e:
        log(f"ERROR: season lookup for {choice['title']!r} failed: {e}")
        return nothing_left_msg(choice)
    if not open_seasons:
        return nothing_left_msg(choice)

    put_session(phone, {"kind": "seasons", "choice": choice, "seasons": open_seasons})
    return (
        f"{choice['title'][:40]}: seasons {fmt_seasons(open_seasons)} aren't requested yet.\n"
        "Reply which to add (e.g. 2, 2-4, 2,4) or ALL."
    )


def handle_season_pick(phone, name, session, text):
    choice, open_seasons = session["choice"], session["seasons"]
    picked = parse_season_pick(text, open_seasons)
    if picked is None:
        return None
    wanted = [n for n in picked if n in open_seasons]
    if not wanted:
        return (
            f"Only seasons {fmt_seasons(open_seasons)} can be added for "
            f"{choice['title'][:40]}. Reply those numbers or ALL."
        )
    clear_session(phone)
    return submit_request(phone, name, choice, wanted)


def submit_request(phone, name, choice, seasons):
    label = choice["title"]
    if seasons:
        label = f"{label} S{fmt_seasons(seasons)}"

    user_id = find_seerr_user_id(name)
    if user_id is None:
        log(f"ERROR: allowlist name {name!r} matches no Seerr user")
        return "Your account isn't linked yet. Ping Ben."

    try:
        res = create_request(choice, user_id, seasons)
    except urllib.error.HTTPError as e:
        detail = e.read()[:300].decode(errors="replace")
        log(f"ERROR: request {label!r} failed {e.code}: {detail}")
        if e.code == 409:
            return f"{label} is already requested."
        return f"Couldn't request {label}. Ben will have to look."
    except Exception as e:
        log(f"ERROR: request {label!r} failed: {e}")
        return f"Couldn't request {label}. Ben will have to look."

    rid = res.get("id")
    if rid is not None:
        with db() as c:
            c.execute(
                "INSERT OR REPLACE INTO req(request_id, phone, title, ts, notified_at) "
                "VALUES(?,?,?,?,NULL)",
                (int(rid), phone, label, int(time.time())),
            )
    log(f"requested {label!r} (request {rid}) for {name} <{phone}>")
    return f"Requested {label}. You'll get a text when it's on Jellyfin."


READY_MSG = {
    "MEDIA_AVAILABLE": "{title} is ready on Jellyfin.",
    "MEDIA_FAILED": "{title} failed to download. Ben will have to look.",
    "MEDIA_DECLINED": "{title} was declined.",
}


def handle_seerr_hook(payload):
    ntype = payload.get("notification_type") or ""
    if ntype == "TEST_NOTIFICATION":
        log("seerr hook: test notification OK")
        return
    if ntype not in READY_MSG:
        return

    request = payload.get("request") or {}
    title = payload.get("subject") or "Your request"
    rid = request.get("request_id")
    rid = int(rid) if str(rid).isdigit() else None

    phone, already = None, False
    if rid is not None:
        with db() as c:
            row = c.execute(
                "SELECT phone, title, notified_at FROM req WHERE request_id=?", (rid,)
            ).fetchone()
        if row:
            phone = row["phone"]
            title = row["title"] or title
            already = row["notified_at"] is not None

    if not phone:
        who = (request.get("requestedBy_username") or "").lower()
        phone = ALLOW_BY_NAME.get(who)

    if not phone:
        log(f"seerr hook: {ntype} for {title!r} — no allowlisted phone, skipping")
        return
    if already:
        log(f"seerr hook: {ntype} for {title!r} already texted, skipping")
        return

    if send_sms(phone, READY_MSG[ntype].format(title=title)) and rid is not None:
        with db() as c:
            c.execute("UPDATE req SET notified_at=? WHERE request_id=?", (int(time.time()), rid))


class Handler(BaseHTTPRequestHandler):
    server_version = "sms-bridge"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _respond(self, code, body=b"", ctype="text/plain; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _read_body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def do_GET(self):
        if urllib.parse.urlparse(self.path).path == "/healthz":
            return self._respond(200, b"ok")
        self._respond(404)

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/twilio/inbound":
            return self.twilio_inbound()
        if path == "/seerr/hook":
            return self.seerr_hook()
        self._respond(404)

    def twilio_inbound(self):
        raw = self._read_body().decode("utf-8", "replace")
        params = {k: v[0] for k, v in urllib.parse.parse_qs(raw, keep_blank_values=True).items()}
        sig = self.headers.get("X-Twilio-Signature", "")

        if not valid_twilio_signature(params, sig):
            log(f"REJECTED: bad Twilio signature from {params.get('From', '?')}")
            return self._respond(403, b"forbidden")

        phone = norm_phone(params.get("From", ""))
        name = ALLOW.get(phone)
        if not name:
            log(f"IGNORED: message from non-allowlisted {phone}")
            return self._respond(204)

        if not rate_ok(phone):
            log(f"IGNORED: {phone} over rate limit ({RATE_LIMIT}/hr)")
            return self._respond(204)

        body = params.get("Body", "")
        log(f"recv <- {name} <{phone}>: {body[:80]!r}")
        try:
            reply = handle_text(phone, name, body)
        except Exception as e:
            log(f"ERROR: handling {body[:60]!r} from {phone}: {e}")
            reply = "Something broke on my end. Try again."

        if reply is None:
            return self._respond(204)
        if not reserve_daily_send_slot():
            log(f"REFUSED: daily send cap ({DAILY_CAP}) reached, dropping reply to {phone}")
            return self._respond(204)
        reply, disclosing = compose_sms(phone, reply)
        if disclosing:
            mark_disclosed(phone)
        log(f"reply -> {phone}: {reply[:100]!r}")
        return self._respond(200, twiml(reply).encode(), "text/xml; charset=utf-8")

    def seerr_hook(self):
        expected = f"Bearer {HOOK_SECRET}"
        got = self.headers.get("Authorization", "")
        if not HOOK_SECRET or not hmac.compare_digest(got, expected):
            log("REJECTED: seerr hook with bad/missing secret")
            return self._respond(404)
        try:
            payload = json.loads(self._read_body() or b"{}")
        except Exception as e:
            log(f"ERROR: seerr hook bad JSON: {e}")
            return self._respond(400, b"bad json")
        try:
            handle_seerr_hook(payload)
        except Exception as e:
            log(f"ERROR: seerr hook handling failed: {e}")
        return self._respond(200, b"ok")


def main():
    missing = [
        n
        for n, v in (
            ("TWILIO_ACCOUNT_SID", TWILIO_SID),
            ("TWILIO_AUTH_TOKEN", TWILIO_TOKEN),
            ("TWILIO_FROM_NUMBER", TWILIO_FROM_RAW),
            ("SMS_BRIDGE_PUBLIC_URL", PUBLIC_URL),
            ("SMS_BRIDGE_HOOK_SECRET", HOOK_SECRET),
        )
        if not v
    ]
    if missing:
        log(f"WARN: unset env: {', '.join(missing)} — SMS will not function")

    if TWILIO_SID and not TWILIO_SID.startswith("AC"):
        log(f"WARN: TWILIO_ACCOUNT_SID starts with {TWILIO_SID[:2]!r}, not 'AC' — that's an "
            "API Key SID, not the Account SID. Webhook signature validation and outbound "
            "sends both need the ACCOUNT SID + ACCOUNT auth token (console home page).")
    if TWILIO_TOKEN and not re.fullmatch(r"[0-9a-f]{32}", TWILIO_TOKEN):
        log("WARN: TWILIO_AUTH_TOKEN is not 32 hex characters — that's the shape of an API "
            "Key secret, not an Account Auth Token. Signature validation will reject "
            "everything.")
    if not ALLOW:
        log("WARN: SMS_ALLOWLIST is empty — every inbound message will be ignored")

    init_db()
    log(f"listening on :{LISTEN_PORT} | allowlist: {len(ALLOW)} number(s) | "
        f"seerr: {SEERR_URL} | public: {PUBLIC_URL or '(unset)'}")
    ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler).serve_forever()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
