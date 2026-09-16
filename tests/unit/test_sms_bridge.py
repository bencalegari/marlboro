#!/usr/bin/env python3
"""Unit tests for the SMS bridge.

Stdlib only, no network, no Docker:

    python3 -m unittest discover -s tests/unit

Seerr is stubbed at `bridge.call_seerr`, Twilio at `bridge.send_sms`, and each
test gets a throwaway SQLite file.
"""

import json
import os
import sys
import tempfile
import time
import unittest
import urllib.error
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

# bridge.py reads its configuration at import time.
os.environ.setdefault("SMS_DB", "/nonexistent/set-per-test.db")
os.environ.setdefault("SMS_ALLOWLIST", "+15551230000=ben, 555-123-0001=alice")
os.environ.setdefault("SMS_BRIDGE_PUBLIC_URL", "https://sms.example.test/twilio/inbound")
os.environ.setdefault("SMS_BRIDGE_HOOK_SECRET", "hook-secret")

sys.path.insert(0, str(REPO_ROOT / "services" / "sms-bridge"))
import bridge  # noqa: E402

PHONE, NAME = "+15551230000", "ben"
SEERR_USER_ID = 7

MOVIE = {"tmdbId": 1, "mediaType": "movie", "title": "Heat", "year": "1995", "status": None}


def series(tmdb_id, title, status, year="2024"):
    return {"tmdbId": tmdb_id, "mediaType": "tv", "title": title, "year": year, "status": status}


class FakeSeerr:
    """Minimal stand-in for the Seerr endpoints the bridge calls."""

    def __init__(self):
        self.results = []
        self.tv_detail = {}
        self.requests = []
        self.tv_error = None
        self.request_error = None

    def set_search(self, *rows):
        self.results = [
            {
                "id": r["tmdbId"],
                "mediaType": r["mediaType"],
                "name" if r["mediaType"] == "tv" else "title": r["title"],
                "firstAirDate" if r["mediaType"] == "tv" else "releaseDate": f"{r['year']}-01-01",
                "mediaInfo": {"status": r["status"]} if r["status"] else {},
            }
            for r in rows
        ]

    def set_seasons(self, aired, taken):
        """aired: {season: episode_count}. taken: {season: media status}."""
        self.tv_detail = {
            "seasons": [{"seasonNumber": n, "episodeCount": c} for n, c in sorted(aired.items())],
            "mediaInfo": {"seasons": [{"seasonNumber": n, "status": s} for n, s in sorted(taken.items())]},
        }

    def __call__(self, method, path, body=None, _retried=False):
        if path.startswith("/api/v1/search"):
            return {"results": self.results}
        if path.startswith("/api/v1/tv/"):
            if self.tv_error:
                raise self.tv_error
            return self.tv_detail
        if path.startswith("/api/v1/user"):
            return {"results": [{"id": SEERR_USER_ID, "displayName": NAME}]}
        if path == "/api/v1/request":
            if self.request_error:
                raise self.request_error
            self.requests.append(body)
            return {"id": 4242}
        raise AssertionError(f"unexpected Seerr call: {method} {path}")


class _HTTPError(urllib.error.HTTPError):
    """HTTPError whose read() can be called more than once."""

    def __init__(self, code, body):
        super().__init__("http://seerr/api/v1/request", code, "error", {}, None)
        self._body = body

    def read(self, *_):
        return self._body


class BridgeTestCase(unittest.TestCase):
    """Fresh database and a stubbed Seerr per test."""

    def setUp(self):
        handle, path = tempfile.mkstemp(suffix=".db")
        os.close(handle)
        self.addCleanup(self._remove_db, path)
        bridge.DB_PATH = path
        bridge.init_db()

        self.seerr = FakeSeerr()
        self._real_call = bridge.call_seerr
        bridge.call_seerr = self.seerr
        self.addCleanup(setattr, bridge, "call_seerr", self._real_call)
        bridge._users_cache.update({"at": 0, "rows": []})

    def _remove_db(self, path):
        for suffix in ("", "-wal", "-shm"):
            try:
                os.unlink(path + suffix)
            except FileNotFoundError:
                pass

    def text(self, message, phone=PHONE, name=NAME):
        return bridge.handle_text(phone, name, message)

    def last_request(self):
        self.assertTrue(self.seerr.requests, "no request was posted to Seerr")
        return self.seerr.requests[-1]


class SeasonFormattingTests(unittest.TestCase):
    def test_fmt_seasons_compacts_runs(self):
        self.assertEqual(bridge.fmt_seasons([1, 2, 3, 5, 7, 8]), "1-3, 5, 7-8")
        self.assertEqual(bridge.fmt_seasons([4]), "4")
        self.assertEqual(bridge.fmt_seasons([3, 3, 2]), "2-3")
        self.assertEqual(bridge.fmt_seasons([]), "")

    def test_parse_accepts_single_range_list_and_all(self):
        self.assertEqual(bridge.parse_season_pick("3", [3, 4]), [3])
        self.assertEqual(bridge.parse_season_pick("3-5", [3, 4]), [3, 4, 5])
        self.assertEqual(bridge.parse_season_pick("4,3", [3, 4]), [3, 4])
        self.assertEqual(bridge.parse_season_pick(" 4 , 3 ", [3, 4]), [3, 4])
        self.assertEqual(bridge.parse_season_pick("2, 4-6", [2]), [2, 4, 5, 6])
        self.assertEqual(bridge.parse_season_pick("All", [3, 4]), [3, 4])
        self.assertEqual(bridge.parse_season_pick("all", [3, 4]), [3, 4])

    def test_parse_tolerates_reversed_range(self):
        self.assertEqual(bridge.parse_season_pick("4-2", []), [2, 3, 4])

    def test_parse_rejects_non_picks(self):
        for text in ("season three", "s3", "-", "3-", "", "3 4", "Breaking Bad"):
            self.assertIsNone(bridge.parse_season_pick(text, [3]), f"{text!r} parsed as a pick")


class OpenSeasonTests(BridgeTestCase):
    def test_skips_specials_unaired_and_taken_seasons(self):
        self.seerr.set_seasons(
            aired={0: 4, 1: 8, 2: 10, 3: 10, 4: 10, 5: 0},
            taken={1: bridge.ST_AVAILABLE, 2: bridge.ST_PROCESSING},
        )
        self.assertEqual(bridge.tv_open_seasons(235970), [3, 4])

    def test_pending_and_partial_seasons_count_as_taken(self):
        self.seerr.set_seasons(
            aired={1: 8, 2: 8, 3: 8},
            taken={1: bridge.ST_PENDING, 2: bridge.ST_PARTIAL},
        )
        self.assertEqual(bridge.tv_open_seasons(1), [3])

    def test_unknown_season_status_is_still_open(self):
        self.seerr.set_seasons(aired={1: 8}, taken={1: 1})
        self.assertEqual(bridge.tv_open_seasons(1), [1])


class TitleSearchTests(BridgeTestCase):
    def test_numbered_list_offered_for_multiple_hits(self):
        self.seerr.set_search(
            series(235970, "The Secret Lives of Mormon Wives", bridge.ST_PARTIAL),
            series(999, "The Secret Lives of Mormon Wives: Orange", None, year="2026"),
        )
        reply = self.text("Secret lives of Mormon wives")
        self.assertEqual(
            reply.splitlines(),
            [
                "1. The Secret Lives of Mormon Wives (2024) [series]",
                "2. The Secret Lives of Mormon Wives: Orange (2026) [series]",
                "Reply 1-2 to request.",
            ],
        )

    def test_no_results(self):
        self.assertEqual(
            self.text("zzzz"), 'Nothing found for "zzzz". Try the exact title.'
        )

    def test_search_outage(self):
        self.seerr.tv_error = None
        bridge.call_seerr = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("down"))
        self.assertEqual(self.text("Heat"), "Search is down right now. Try again in a bit.")

    def test_help_and_optout_keywords(self):
        self.assertEqual(self.text("HELP"), bridge.HELP_TEXT)
        self.assertIsNone(self.text("STOP"))

    def test_number_without_a_session(self):
        self.assertEqual(self.text("1"), "That pick expired. Text a title to search again.")

    def test_number_outside_the_list(self):
        self.seerr.set_search(MOVIE, series(999, "Heat: The Series", None))
        self.text("Heat")
        self.assertEqual(self.text("9"), "Pick 1-2, or text a title to search again.")


class MovieRequestTests(BridgeTestCase):
    def setUp(self):
        super().setUp()
        self.seerr.set_search(MOVIE)

    def test_single_unrequested_movie(self):
        self.text("Heat")
        self.assertEqual(
            self.text("1"), "Requested Heat. You'll get a text when it's on Jellyfin."
        )
        self.assertEqual(
            self.last_request(),
            {"mediaType": "movie", "mediaId": 1, "userId": SEERR_USER_ID},
        )

    def test_available_movie_short_circuits_without_a_list(self):
        self.seerr.set_search({**MOVIE, "status": bridge.ST_AVAILABLE})
        self.assertEqual(self.text("Heat"), "Heat is already on Jellyfin.")
        self.assertEqual(self.seerr.requests, [])

    def test_requested_movie_is_not_re_requested(self):
        self.seerr.set_search(
            {**MOVIE, "status": bridge.ST_PROCESSING}, series(999, "Heat: The Series", None)
        )
        self.text("Heat")
        self.assertEqual(
            self.text("1"), "Heat is already requested — you'll get a text when it lands."
        )
        self.assertEqual(self.seerr.requests, [])

    def test_unlinked_account(self):
        bridge._users_cache.update({"at": time.time(), "rows": []})
        self.text("Heat")
        self.assertEqual(self.text("1"), "Your account isn't linked yet. Ping Ben.")

    def test_seerr_conflict(self):
        self.seerr.request_error = _HTTPError(409, b"already exists")
        self.text("Heat")
        self.assertEqual(self.text("1"), "Heat is already requested.")

    def test_seerr_failure(self):
        self.seerr.request_error = _HTTPError(500, b"boom")
        self.text("Heat")
        self.assertEqual(self.text("1"), "Couldn't request Heat. Ben will have to look.")

    def test_request_is_recorded_for_the_ready_notification(self):
        self.text("Heat")
        self.text("1")
        with bridge.db() as c:
            row = c.execute("SELECT phone, title, notified_at FROM req WHERE request_id=4242").fetchone()
        self.assertEqual((row["phone"], row["title"], row["notified_at"]), (PHONE, "Heat", None))


class SeriesSeasonTests(BridgeTestCase):
    """A series Seerr already knows about offers its unrequested seasons."""

    TITLE = "The Secret Lives of Mormon Wives"

    def setUp(self):
        super().setUp()
        self.seerr.set_search(series(235970, self.TITLE, bridge.ST_PARTIAL))
        # S1 downloaded, S2 downloading, S3/S4 never requested, S5 unaired.
        self.seerr.set_seasons(
            aired={0: 4, 1: 8, 2: 10, 3: 10, 4: 10, 5: 0},
            taken={1: bridge.ST_AVAILABLE, 2: bridge.ST_PROCESSING},
        )

    def offer(self):
        self.seerr.requests.clear()
        self.text(self.TITLE)
        return self.text("1")

    def test_offer_lists_only_open_seasons(self):
        self.assertEqual(
            self.offer(),
            f"{self.TITLE}: seasons 3-4 aren't requested yet.\n"
            "Reply which to add (e.g. 2, 2-4, 2,4) or ALL.",
        )
        self.assertEqual(self.seerr.requests, [])

    def test_offer_fits_in_one_text(self):
        body, _ = bridge.compose_sms(PHONE, self.offer())
        self.assertLessEqual(len(body), bridge.SMS_CHARACTER_LIMIT)

    def test_offer_survives_a_long_season_list(self):
        self.seerr.set_seasons(aired={n: 10 for n in range(1, 31)}, taken={})
        self.assertIn("seasons 1-30 aren't requested yet", self.offer())

    def test_single_season(self):
        self.offer()
        self.assertEqual(
            self.text("3"),
            f"Requested {self.TITLE} S3. You'll get a text when it's on Jellyfin.",
        )
        self.assertEqual(self.last_request()["seasons"], [3])

    def test_range(self):
        self.offer()
        self.assertEqual(
            self.text("3-4"),
            f"Requested {self.TITLE} S3-4. You'll get a text when it's on Jellyfin.",
        )
        self.assertEqual(self.last_request()["seasons"], [3, 4])

    def test_comma_list(self):
        self.offer()
        self.text("4,3")
        self.assertEqual(self.last_request()["seasons"], [3, 4])

    def test_all(self):
        self.offer()
        self.assertEqual(
            self.text("ALL"),
            f"Requested {self.TITLE} S3-4. You'll get a text when it's on Jellyfin.",
        )
        self.assertEqual(self.last_request()["seasons"], [3, 4])

    def test_season_request_is_recorded_with_its_seasons(self):
        self.offer()
        self.text("3-4")
        with bridge.db() as c:
            title = c.execute("SELECT title FROM req WHERE request_id=4242").fetchone()["title"]
        self.assertEqual(title, f"{self.TITLE} S3-4")

    def test_session_clears_after_a_successful_pick(self):
        self.offer()
        self.text("3")
        self.assertIsNone(bridge.get_active_session(PHONE))

    def test_closed_seasons_are_refused_without_losing_the_session(self):
        self.offer()
        self.assertEqual(
            self.text("1,2"),
            f"Only seasons 3-4 can be added for {self.TITLE}. Reply those numbers or ALL.",
        )
        self.assertEqual(self.seerr.requests, [])
        self.assertEqual(bridge.get_active_session(PHONE)["kind"], "seasons")

    def test_range_is_clipped_to_open_seasons(self):
        self.offer()
        self.text("1-9")
        self.assertEqual(self.last_request()["seasons"], [3, 4])

    def test_a_new_title_during_a_season_session_searches_again(self):
        self.offer()
        self.assertEqual(
            self.text(self.TITLE).splitlines()[-1], "Reply 1 to request."
        )
        self.assertEqual(self.seerr.requests, [])

    def test_fully_requested_series_says_so(self):
        self.seerr.set_seasons(aired={1: 8}, taken={1: bridge.ST_PROCESSING})
        self.assertEqual(
            self.offer(),
            f"{self.TITLE} is already requested — you'll get a text when it lands.",
        )

    def test_fully_available_series_says_so(self):
        self.seerr.set_search(series(235970, self.TITLE, bridge.ST_AVAILABLE))
        self.seerr.set_seasons(aired={1: 8}, taken={1: bridge.ST_AVAILABLE})
        self.assertEqual(self.text(self.TITLE), f"{self.TITLE} is already on Jellyfin.")

    def test_available_series_with_a_newly_aired_season_offers_it(self):
        self.seerr.set_search(series(235970, self.TITLE, bridge.ST_AVAILABLE))
        self.seerr.set_seasons(aired={1: 8, 2: 9}, taken={1: bridge.ST_AVAILABLE})
        self.assertIn("seasons 2 aren't requested yet", self.text(self.TITLE))

    def test_season_lookup_failure_falls_back_to_the_plain_message(self):
        self.seerr.tv_error = RuntimeError("seerr down")
        self.assertEqual(
            self.offer(),
            f"{self.TITLE} is already requested — you'll get a text when it lands.",
        )

    def test_unrequested_series_asks_for_every_season(self):
        self.seerr.set_search(series(999, "Brand New Show", None))
        self.text("Brand New Show")
        self.assertEqual(
            self.text("1"),
            "Requested Brand New Show. You'll get a text when it's on Jellyfin.",
        )
        self.assertEqual(self.last_request()["seasons"], "all")


class SessionTests(BridgeTestCase):
    def test_expired_session_is_dropped(self):
        bridge.put_session(PHONE, {"kind": "titles", "choices": [MOVIE]})
        with bridge.db() as c:
            c.execute(
                "UPDATE session SET ts=? WHERE phone=?",
                (int(time.time()) - bridge.SESSION_TTL_SECONDS - 1, PHONE),
            )
        self.assertIsNone(bridge.get_active_session(PHONE))

    def test_list_shaped_session_from_an_older_build_still_resolves(self):
        with bridge.db() as c:
            c.execute(
                "INSERT INTO session(phone, ts, choices) VALUES(?,?,?)",
                (PHONE, int(time.time()), json.dumps([MOVIE])),
            )
        self.assertEqual(bridge.get_active_session(PHONE), {"kind": "titles", "choices": [MOVIE]})
        self.assertEqual(
            self.text("1"), "Requested Heat. You'll get a text when it's on Jellyfin."
        )

    def test_sessions_are_per_phone(self):
        bridge.put_session(PHONE, {"kind": "titles", "choices": [MOVIE]})
        self.assertIsNone(bridge.get_active_session("+15551230001"))


class ComposeTests(BridgeTestCase):
    def test_brand_prefix_and_opt_out_on_first_contact(self):
        body, disclosing = bridge.compose_sms(PHONE, "Requested Heat.")
        self.assertTrue(disclosing)
        self.assertEqual(body, f"{bridge.BRAND}: Requested Heat.\n{bridge.OPT_OUT}")

    def test_opt_out_is_not_repeated_within_the_interval(self):
        bridge.mark_disclosed(PHONE)
        body, disclosing = bridge.compose_sms(PHONE, "Requested Heat.")
        self.assertFalse(disclosing)
        self.assertNotIn(bridge.OPT_OUT, body)

    def test_opt_out_is_not_duplicated_when_the_body_already_has_it(self):
        body, _ = bridge.compose_sms(PHONE, bridge.HELP_TEXT)
        self.assertEqual(body.count(bridge.OPT_OUT), 1)

    def test_long_body_is_truncated_within_the_limit(self):
        body, _ = bridge.compose_sms(PHONE, "x" * 500)
        self.assertLessEqual(len(body), bridge.SMS_CHARACTER_LIMIT)
        self.assertTrue(body.endswith(f"...\n{bridge.OPT_OUT}"))


class RateLimitTests(BridgeTestCase):
    def test_inbound_rate_limit(self):
        for _ in range(bridge.RATE_LIMIT):
            self.assertTrue(bridge.rate_ok(PHONE))
        self.assertFalse(bridge.rate_ok(PHONE))
        self.assertTrue(bridge.rate_ok("+15551230001"))

    def test_daily_send_cap_is_shared(self):
        for _ in range(bridge.DAILY_CAP):
            self.assertTrue(bridge.reserve_daily_send_slot())
        self.assertFalse(bridge.reserve_daily_send_slot())


class SeerrHookTests(BridgeTestCase):
    def setUp(self):
        super().setUp()
        self.sent = []
        real_send = bridge.send_sms
        bridge.send_sms = lambda to, body: (self.sent.append((to, body)), True)[1]
        self.addCleanup(setattr, bridge, "send_sms", real_send)

    def record_request(self, rid=4242, title="Heat", notified_at=None):
        with bridge.db() as c:
            c.execute(
                "INSERT INTO req(request_id, phone, title, ts, notified_at) VALUES(?,?,?,?,?)",
                (rid, PHONE, title, int(time.time()), notified_at),
            )

    def hook(self, ntype, rid=4242, subject="Subject", username=None):
        bridge.handle_seerr_hook(
            {
                "notification_type": ntype,
                "subject": subject,
                "request": {"request_id": rid, "requestedBy_username": username},
            }
        )

    def test_available_notification_uses_the_stored_title(self):
        self.record_request(title="The Secret Lives of Mormon Wives S3-4")
        self.hook("MEDIA_AVAILABLE")
        self.assertEqual(
            self.sent, [(PHONE, "The Secret Lives of Mormon Wives S3-4 is ready on Jellyfin.")]
        )

    def test_notification_is_sent_once(self):
        self.record_request()
        self.hook("MEDIA_AVAILABLE")
        self.hook("MEDIA_AVAILABLE")
        self.assertEqual(len(self.sent), 1)

    def test_unknown_request_falls_back_to_the_allowlist_name(self):
        self.hook("MEDIA_AVAILABLE", rid=None, subject="Heat", username="ben")
        self.assertEqual(self.sent, [(PHONE, "Heat is ready on Jellyfin.")])

    def test_unknown_requester_is_skipped(self):
        self.hook("MEDIA_AVAILABLE", rid=None, subject="Heat", username="nobody")
        self.assertEqual(self.sent, [])

    def test_failure_and_decline_notifications(self):
        self.record_request(rid=1, title="Heat")
        self.hook("MEDIA_FAILED", rid=1)
        self.record_request(rid=2, title="Ronin")
        self.hook("MEDIA_DECLINED", rid=2)
        self.assertEqual(
            [body for _, body in self.sent],
            ["Heat failed to download. Ben will have to look.", "Ronin was declined."],
        )

    def test_test_and_unrelated_notifications_send_nothing(self):
        self.record_request()
        self.hook("TEST_NOTIFICATION")
        self.hook("MEDIA_PENDING")
        self.assertEqual(self.sent, [])


if __name__ == "__main__":
    unittest.main()
