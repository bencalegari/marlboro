#!/usr/bin/env python3
"""sms-bridge — text a title to request it in Seerr, get a text when it lands in Jellyfin.

Three routes, stdlib only (no pip, no build step — it runs on a stock python image
with this file bind-mounted, same shape as every other service in this stack):

  POST /twilio/inbound   Twilio delivers an inbound SMS here. This is the ONLY route
                         reachable from the internet (NPM 404s everything else on the
                         public hostname). Twilio-signature gated.
  POST /seerr/hook       Seerr's webhook notification agent fires here on
                         MEDIA_AVAILABLE / MEDIA_FAILED / MEDIA_DECLINED.
                         Bearer-secret gated, LAN/tailnet only.
  GET  /healthz          Liveness, for Glance's monitor widget + the compose healthcheck.

Conversation is deliberately tiny — a title in, a numbered list back, a number in, done.
See README "SMS Requests" for the Twilio account/verification steps, which are the only
part of this that can't be scripted.
"""

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


# ─── Config ──────────────────────────────────────────────────────────────────
# docker-compose passes a var that's absent from .env as an EMPTY STRING, not as
# unset — so os.environ.get(name, default) hands back "" and the default never
# applies. env()/env_int() treat blank as absent, which is what every caller wants.
def env(name, default=""):
    return os.environ.get(name, "").strip() or default


def env_int(name, default):
    try:
        return int(env(name, str(default)))
    except ValueError:
        log(f"WARN: {name} is not a number — falling back to {default}")
        return default


LISTEN_PORT = env_int("SMS_BRIDGE_PORT", 8080)
DB_PATH = env("SMS_DB", "/app/data/bridge.db")

TWILIO_SID = env("TWILIO_ACCOUNT_SID")
TWILIO_TOKEN = env("TWILIO_AUTH_TOKEN")
# Normalized below via norm_phone: Twilio rejects a From that isn't E.164 (error
# 21212), and a number pasted out of the console without its leading "+" is easy to
# miss because it looks fine in .env.
TWILIO_FROM_RAW = env("TWILIO_FROM_NUMBER")

# Twilio signs the PUBLIC url it requested. Behind NPM this process only ever sees the
# internal one, so the url used for signature verification MUST come from config and
# never from Host / X-Forwarded-*. Getting this wrong either 403s everything or, worse,
# validates forgeries against an attacker-controlled Host header.
PUBLIC_URL = env("SMS_BRIDGE_PUBLIC_URL")

HOOK_SECRET = env("SMS_BRIDGE_HOOK_SECRET")
SEERR_URL = env("SEERR_URL", "http://seerr:5055").rstrip("/")
SEERR_SETTINGS = env("SEERR_SETTINGS", "/seerr-settings.json")

# Spend guards. Worst case an allowlisted phone can cost is RATE_LIMIT texts an hour,
# and the whole bridge can't exceed DAILY_CAP sends a day no matter what happens.
RATE_LIMIT = env_int("SMS_RATE_LIMIT", 12)      # inbound msgs / phone / hr
DAILY_CAP = env_int("SMS_DAILY_CAP", 100)       # outbound sends / day
SESSION_TTL = 15 * 60                           # pick-a-number window
MAX_CHOICES = 3
SMS_MAX = 320                                   # 2 GSM-7 segments

# Every outbound text is branded, so a recipient can always tell who is texting them.
# An unidentified sender is a standard toll-free-verification flag, and it's also just
# the decent thing to do for a number nobody has saved as a contact.
BRAND = env("SMS_BRAND", "Marlboro Media")
# Opt-out disclosure. Twilio's Advanced Opt-Out handles the STOP keyword itself at the
# number level — this is only the *disclosure*, so it goes on the first message of a
# conversation and not on every one. Repeating it would burn an SMS segment per text
# for no compliance gain.
OPT_OUT = "Reply STOP to opt out."
DISCLOSE_EVERY = 30 * 86400                     # re-disclose if a number goes quiet this long

# Carrier keyword handling. The number has NO Messaging Service attached (verified via
# the API), so Twilio's Advanced Opt-Out is not in play and these words arrive here as
# ordinary inbound messages. Left unhandled, "HELP" is treated as a search query and
# answers with movie titles — "Send Help (2026)", "The Help (2011)" — which is useless
# and reads as non-compliant to a reviewer testing the number.
#
# STOP and friends: stay SILENT. Twilio enforces opt-out account-wide (a send to an
# opted-out number fails with 21610), so replying would either double up on the platform
# or contradict it. Carrier-reserved words win over titles here, which does mean a film
# literally called "Cancel" can't be found by exact title. Correct trade.
HELP_KEYWORDS = {"help", "info"}
OPTOUT_KEYWORDS = {"stop", "stopall", "unsubscribe", "cancel", "end", "quit",
                   "start", "unstop", "yes"}
# Kept GSM-7 clean (no em dash) so it stays 2 segments — see compose().
HELP_TEXT = (
    "Text a movie or TV title to request it. You'll get a numbered list; reply with a "
    "number, and another text when it's ready to watch. Msg & data rates may apply. "
    "Reply STOP to opt out. Help: lap.rapper_3o@icloud.com"
)

# Seerr's MediaStatus enum (server/constants/media.ts).
ST_PENDING, ST_PROCESSING, ST_PARTIAL, ST_AVAILABLE = 2, 3, 4, 5


# ─── Phone numbers ───────────────────────────────────────────────────────────
def norm_phone(raw):
    """Best-effort E.164. Twilio already sends E.164; the allowlist may not."""
    d = re.sub(r"\D", "", raw or "")
    if not d:
        return ""
    if len(d) == 10:
        d = "1" + d
    return "+" + d


def parse_allowlist(raw):
    """'+15035550142=bcalegari,+15035550143=mom' -> ({phone: name}, {name_lower: phone})

    Names are Seerr *display names*, not numeric ids — ids churn, and Seerr's webhook
    reports requestedBy_username as request.requestedBy.displayName. Same reasoning as
    configure_seerr resolving quality profiles by name.
    """
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


ALLOW, ALLOW_BY_NAME = parse_allowlist(env("SMS_ALLOWLIST"))
TWILIO_FROM = norm_phone(TWILIO_FROM_RAW) if TWILIO_FROM_RAW else ""


# ─── State ───────────────────────────────────────────────────────────────────
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


def send_budget_ok():
    """Reserve one outbound send. False once the daily cap is hit."""
    now = int(time.time())
    with db() as c:
        c.execute("DELETE FROM outbox WHERE ts < ?", (now - 86400,))
        n = c.execute("SELECT COUNT(*) n FROM outbox").fetchone()["n"]
        if n >= DAILY_CAP:
            return False
        c.execute("INSERT INTO outbox(ts) VALUES(?)", (now,))
    return True


def disclosure_due(phone):
    """Has this number been told how to opt out recently?"""
    with db() as c:
        row = c.execute("SELECT ts FROM disclosed WHERE phone=?", (phone,)).fetchone()
    return not row or row["ts"] < int(time.time()) - DISCLOSE_EVERY


def mark_disclosed(phone):
    with db() as c:
        c.execute(
            "INSERT INTO disclosed(phone, ts) VALUES(?,?) "
            "ON CONFLICT(phone) DO UPDATE SET ts=excluded.ts",
            (phone, int(time.time())),
        )


def put_session(phone, choices):
    with db() as c:
        c.execute(
            "INSERT INTO session(phone, ts, choices) VALUES(?,?,?) "
            "ON CONFLICT(phone) DO UPDATE SET ts=excluded.ts, choices=excluded.choices",
            (phone, int(time.time()), json.dumps(choices)),
        )


def get_session(phone):
    """Read without consuming, so "1" then "2" both work off one search."""
    now = int(time.time())
    with db() as c:
        c.execute("DELETE FROM session WHERE ts < ?", (now - SESSION_TTL,))
        row = c.execute("SELECT choices FROM session WHERE phone=?", (phone,)).fetchone()
    return json.loads(row["choices"]) if row else None


# ─── Seerr ───────────────────────────────────────────────────────────────────
_seerr_key = None
_users_cache = {"at": 0, "rows": []}
_lock = threading.Lock()


def seerr_key(force=False):
    """Read the API key out of Seerr's own settings.json (bind-mounted read-only).

    Mirrors seerr_key() in setup_services.sh — no separate 1Password item to drift.
    Re-read on force so a rotated key self-heals without a restart.
    """
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


def seerr(method, path, body=None, _retried=False):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        f"{SEERR_URL}{path}",
        data=data,
        method=method,
        headers={"X-Api-Key": seerr_key(), "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        if e.code == 401 and not _retried:
            seerr_key(force=True)
            return seerr(method, path, body, _retried=True)
        raise


def seerr_user_id(name):
    """Resolve an allowlist name to a Seerr user id.

    Matches displayName / username / jellyfinUsername case-insensitively: a
    Jellyfin-linked account has username=None and only carries jellyfinUsername,
    so matching one field alone silently fails to resolve real users.
    """
    with _lock:
        if time.time() - _users_cache["at"] > 300:
            try:
                _users_cache["rows"] = seerr("GET", "/api/v1/user?take=200").get("results", [])
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
    results = seerr("GET", f"/api/v1/search?query={q}&page=1").get("results", [])
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


def create_request(choice, user_id):
    body = {"mediaType": choice["mediaType"], "mediaId": choice["tmdbId"], "userId": user_id}
    if choice["mediaType"] == "tv":
        body["seasons"] = "all"
    return seerr("POST", "/api/v1/request", body)


# ─── Twilio ──────────────────────────────────────────────────────────────────
def valid_signature(params, signature):
    """Twilio's scheme: base64(hmac_sha1(auth_token, url + sorted k+v concatenated))."""
    if not (TWILIO_TOKEN and PUBLIC_URL and signature):
        return False
    payload = PUBLIC_URL + "".join(k + params[k] for k in sorted(params))
    mac = hmac.new(TWILIO_TOKEN.encode(), payload.encode("utf-8"), hashlib.sha1).digest()
    return hmac.compare_digest(base64.b64encode(mac).decode(), signature)


def compose(phone, body):
    """Brand the text and, on the first message of a conversation, disclose opt-out.

    Returns (text, disclosing). The caller marks the disclosure as delivered only
    after the send actually succeeds — otherwise a dropped message would burn the
    one text that was supposed to carry the notice.

    The body, not the prefix/suffix, absorbs any truncation: the whole point of both
    additions is that they survive to the handset. Ellipsis is "..." rather than "…"
    on purpose — a single non-GSM-7 character flips the entire message to UCS-2 and
    halves how much fits in a segment.
    """
    prefix = f"{BRAND}: " if BRAND else ""
    disclosing = disclosure_due(phone)
    # HELP_TEXT already carries the notice inline; appending it again would print
    # "Reply STOP to opt out." twice. Still counts as disclosed.
    suffix = f"\n{OPT_OUT}" if disclosing and OPT_OUT not in body else ""
    room = SMS_MAX - len(prefix) - len(suffix)
    if len(body) > room:
        body = body[: max(0, room - 3)].rstrip() + "..."
    return prefix + body + suffix, disclosing


def send_sms(to, body):
    """Outbound REST send. Only ever called with an allowlisted number."""
    if to not in ALLOW:
        log(f"REFUSED: outbound to non-allowlisted {to}")
        return False
    if not send_budget_ok():
        log(f"REFUSED: daily send cap ({DAILY_CAP}) reached, dropping text to {to}")
        return False
    body, disclosing = compose(to, body)
    data = urllib.parse.urlencode({"To": to, "From": TWILIO_FROM, "Body": body[:SMS_MAX]}).encode()
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
    esc = saxutils.escape(body[:SMS_MAX])
    return f'<?xml version="1.0" encoding="UTF-8"?><Response><Message>{esc}</Message></Response>'


# ─── Conversation ────────────────────────────────────────────────────────────
def fmt_choice(i, c):
    kind = "movie" if c["mediaType"] == "movie" else "series"
    title = c["title"][:40]
    year = f" ({c['year']})" if c["year"] else ""
    return f"{i}. {title}{year} [{kind}]"


def handle_text(phone, name, text):
    """Returns the reply body, or None to stay silent."""
    text = (text or "").strip()
    if not text:
        return None

    # Carrier keywords before anything else, so they can never fall through to search.
    word = re.sub(r"[^a-z]", "", text.lower())
    if word in OPTOUT_KEYWORDS:
        log(f"keyword {word!r} from {phone} — Twilio owns opt-out state, staying silent")
        return None
    if word in HELP_KEYWORDS:
        return HELP_TEXT

    # A bare number is a pick against the last search — but only inside the TTL.
    if text.isdigit():
        choices = get_session(phone)
        if not choices:
            return "That pick expired. Text a title to search again."
        idx = int(text)
        if not 1 <= idx <= len(choices):
            return f"Pick 1-{len(choices)}, or text a title to search again."
        return do_request(phone, name, choices[idx - 1])

    try:
        choices = search(text)
    except Exception as e:
        log(f"ERROR: search {text!r} failed: {e}")
        return "Search is down right now. Try again in a bit."

    if not choices:
        return f'Nothing found for "{text[:60]}". Try the exact title.'

    # Single exact-ish hit that's already there — skip the pick step entirely.
    if len(choices) == 1 and choices[0]["status"] == ST_AVAILABLE:
        return f"{choices[0]['title']} is already on Jellyfin."

    put_session(phone, choices)
    lines = [fmt_choice(i, c) for i, c in enumerate(choices, 1)]
    return "\n".join(lines) + f"\nReply 1-{len(choices)} to request."


def do_request(phone, name, choice):
    label = choice["title"]
    if choice["status"] == ST_AVAILABLE:
        return f"{label} is already on Jellyfin."
    if choice["status"] in (ST_PENDING, ST_PROCESSING, ST_PARTIAL):
        return f"{label} is already requested — you'll get a text when it lands."

    user_id = seerr_user_id(name)
    if user_id is None:
        log(f"ERROR: allowlist name {name!r} matches no Seerr user")
        return "Your account isn't linked yet. Ping Ben."

    try:
        res = create_request(choice, user_id)
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


# ─── Seerr webhook ───────────────────────────────────────────────────────────
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

    # Requests made in the Seerr web UI have no row here — fall back to the requester's
    # display name so those get a text too.
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


# ─── HTTP ────────────────────────────────────────────────────────────────────
class Handler(BaseHTTPRequestHandler):
    server_version = "sms-bridge"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # quieter default access log
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

        if not valid_signature(params, sig):
            log(f"REJECTED: bad Twilio signature from {params.get('From', '?')}")
            return self._respond(403, b"forbidden")

        phone = norm_phone(params.get("From", ""))
        name = ALLOW.get(phone)
        if not name:
            # Silence, not an error page: never text back a number we don't know.
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
        if not send_budget_ok():
            log(f"REFUSED: daily send cap ({DAILY_CAP}) reached, dropping reply to {phone}")
            return self._respond(204)
        reply, disclosing = compose(phone, reply)
        # Handing the TwiML back IS the send — Twilio delivers it from here. Log it:
        # without this line a successful reply is invisible, so "no log after recv" is
        # ambiguous between "we replied and Twilio couldn't deliver it" and "we never
        # replied at all" — which is exactly the wrong thing to have to guess about.
        if disclosing:
            mark_disclosed(phone)
        log(f"reply -> {phone}: {reply[:100]!r}")
        return self._respond(200, twiml(reply).encode(), "text/xml; charset=utf-8")

    def seerr_hook(self):
        # 404 rather than 403 on a bad secret — don't confirm the route exists.
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
        # Keep serving /healthz so the container doesn't crashloop before 1Password is
        # populated — but be loud, because nothing will actually work.
        log(f"WARN: unset env: {', '.join(missing)} — SMS will not function")

    # Credential *shape* checks. Twilio has two kinds of credential and only one of
    # them can validate a webhook signature: the Account SID (AC...) plus the Account
    # Auth Token, both on the console home page. An API Key (SK... + its secret)
    # authenticates REST calls but signs nothing, so pairing it here rejects every
    # inbound message with "bad Twilio signature" — which reads like a URL problem and
    # isn't. Catch it at boot instead of one confusing message at a time.
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
