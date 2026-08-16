"""Pure unit tests for secret-handoff. Stock CPython — no Hermes, no CDP."""

from __future__ import annotations

import json
import sys
import time
import types
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import handoff as h  # noqa: E402


def _install_clarify(fn) -> None:
    tools_mod = sys.modules.get("tools")
    if tools_mod is None:
        tools_mod = types.ModuleType("tools")
        sys.modules["tools"] = tools_mod
    clarify_mod = types.ModuleType("tools.clarify_tool")
    clarify_mod.clarify_tool = fn
    sys.modules["tools.clarify_tool"] = clarify_mod
    setattr(tools_mod, "clarify_tool", clarify_mod)


class ClassifyAndPlaceholder(unittest.TestCase):
    def test_classify_inject(self) -> None:
        self.assertEqual(h.classify_reply("hunter2"), "inject")
        self.assertEqual(h.classify_reply("  hunter2  "), "inject")

    def test_classify_cancel(self) -> None:
        for text in ("", "   ", None, "cancel", "Cancel", "n", "N", "no", "NO"):
            self.assertEqual(h.classify_reply(text), "cancel", text)

    def test_classify_ignore_slash(self) -> None:
        self.assertEqual(h.classify_reply("/stop"), "ignore")
        self.assertEqual(h.classify_reply("/new"), "ignore")

    def test_placeholders(self) -> None:
        self.assertEqual(
            h.placeholder_for("axs", "received"),
            "[secret received for axs]",
        )
        self.assertEqual(h.placeholder_for("axs", "cancelled"), "[secret cancelled]")
        self.assertEqual(h.placeholder_for("axs", "failed"), "[secret handoff failed]")
        self.assertEqual(
            h.placeholder_for("", "received"),
            "[secret received for site]",
        )


class ShouldIntercept(unittest.TestCase):
    def setUp(self) -> None:
        self.now = 1_700_000_000.0
        self.pending = {"service": "axs", "created_at": self.now - 10}

    def test_no_pending(self) -> None:
        self.assertFalse(h.should_intercept("pw", None, self.now))

    def test_expired(self) -> None:
        old = {"service": "axs", "created_at": self.now - h.PENDING_TTL_S - 1}
        self.assertFalse(h.should_intercept("pw", old, self.now))

    def test_slash_not_intercepted(self) -> None:
        self.assertFalse(h.should_intercept("/stop", self.pending, self.now))

    def test_fresh_password(self) -> None:
        self.assertTrue(h.should_intercept("pw", self.pending, self.now))

    def test_empty_still_intercepted_for_cancel(self) -> None:
        self.assertTrue(h.should_intercept("", self.pending, self.now))

    def test_bad_created_at(self) -> None:
        self.assertFalse(h.should_intercept("pw", {"service": "axs"}, self.now))


class ProcessInbound(unittest.TestCase):
    def setUp(self) -> None:
        self.now = time.time()
        self.pending = {"service": "gmail", "created_at": self.now}

    def test_inject_rewrite_hides_secret(self) -> None:
        secret = "s3cret-P@ssw0rd!"
        seen: list[str] = []

        def inject_fn(text: str, pending: dict) -> tuple[bool, str]:
            seen.append(text)
            return True, "injected"

        out = h.process_inbound(
            secret, self.pending, now=self.now, inject_fn=inject_fn
        )
        self.assertIsNotNone(out)
        assert out is not None
        self.assertEqual(out["action"], "rewrite")
        self.assertEqual(out["text"], "[secret received for gmail]")
        self.assertNotIn(secret, json.dumps(out))
        self.assertEqual(seen, [secret])

    def test_inject_failure_still_rewrites(self) -> None:
        secret = "leaky-password-xyz"

        def inject_fn(text: str, pending: dict) -> tuple[bool, str]:
            raise RuntimeError("cdp down")

        out = h.process_inbound(
            secret, self.pending, now=self.now, inject_fn=inject_fn
        )
        self.assertEqual(out, {"action": "rewrite", "text": "[secret handoff failed]"})
        self.assertNotIn(secret, json.dumps(out))

    def test_cancel(self) -> None:
        out = h.process_inbound("cancel", self.pending, now=self.now)
        self.assertEqual(out, {"action": "rewrite", "text": "[secret cancelled]"})

    def test_slash_returns_none(self) -> None:
        self.assertIsNone(h.process_inbound("/reset", self.pending, now=self.now))

    def test_audio_only_empty_leaves_pending(self) -> None:
        self.assertIsNone(
            h.process_inbound("", self.pending, now=self.now, has_audio=True)
        )

    def test_audio_transcript_not_used_as_secret(self) -> None:
        secret = "spoken-password"
        called = {"n": 0}

        def inject_fn(text: str, pending: dict) -> tuple[bool, str]:
            called["n"] += 1
            return True, "injected"

        out = h.process_inbound(
            secret, self.pending, now=self.now, has_audio=True, inject_fn=inject_fn
        )
        self.assertIsNone(out)
        self.assertEqual(called["n"], 0)


class PickTargetAndCdpUrl(unittest.TestCase):
    def test_pick_explicit_target(self) -> None:
        targets = [
            {"id": "a", "type": "page"},
            {"id": "b", "type": "page", "attached": True},
        ]
        picked = h.pick_target(targets, target_id="a")
        assert picked is not None
        self.assertEqual(picked["id"], "a")

    def test_pick_frame_id_prefers_iframe(self) -> None:
        targets = [
            {"id": "page", "type": "page"},
            {"id": "ifr", "type": "iframe"},
        ]
        picked = h.pick_target(targets, frame_id="ifr")
        assert picked is not None
        self.assertEqual(picked["id"], "ifr")

    def test_pick_attached_page(self) -> None:
        targets = [
            {"id": "bg", "type": "background_page"},
            {"id": "p1", "type": "page"},
            {"id": "p2", "type": "page", "attached": True},
        ]
        picked = h.pick_target(targets)
        assert picked is not None
        self.assertEqual(picked["id"], "p2")

    def test_resolve_cdp_explicit_wins(self) -> None:
        self.assertEqual(
            h.resolve_cdp_http_base("ws://10.0.0.8:9333/devtools/browser/abc"),
            "http://10.0.0.8:9333",
        )

    def test_resolve_cdp_env(self) -> None:
        with patch.dict("os.environ", {"BROWSER_CDP_URL": "http://127.0.0.1:9222"}):
            self.assertEqual(h.resolve_cdp_http_base(None), "http://127.0.0.1:9222")


class NeverReturnsSecret(unittest.TestCase):
    def setUp(self) -> None:
        h.reset_state()

    def tearDown(self) -> None:
        h.reset_state()

    def test_hook_rewrite_and_tool_json_omit_secret(self) -> None:
        secret = "NEVER-LEAK-THIS-PASSWORD"
        now = time.time()
        pending = {
            "service": "axs",
            "created_at": now,
            "target_id": "tab-1",
        }

        def inject_fn(text: str, meta: dict) -> tuple[bool, str]:
            self.assertEqual(text, secret)
            return True, "injected"

        rewrite = h.process_inbound(secret, pending, now=now, inject_fn=inject_fn)
        assert rewrite is not None
        blob = json.dumps(rewrite)
        self.assertNotIn(secret, blob)
        self.assertIn("[secret received for axs]", blob)

        # Tool path: hook stored a result; clarify returns the placeholder.
        h.store_result(
            "sess",
            {"status": "ok", "service": "axs", "detail": "injected"},
        )
        h.set_pending(
            "sess",
            {"service": "axs", "created_at": now},
        )

        def fake_clarify(**_kwargs):
            return json.dumps(
                {
                    "question": "x",
                    "choices_offered": None,
                    "user_response": "[secret received for axs]",
                }
            )

        with patch.object(h, "resolve_session_key_for_tool", return_value="sess"):
            _install_clarify(fake_clarify)
            out = h.handle_request_secret({"service": "axs"}, callback=lambda *_a, **_k: "")
        data = json.loads(out)
        self.assertEqual(data["status"], "ok")
        self.assertEqual(data["service"], "axs")
        self.assertNotIn(secret, out)
        self.assertNotIn(secret, json.dumps(data))

    def test_cli_tool_path_injects_then_omits_secret(self) -> None:
        secret = "cli-only-password-zzz"
        captured: list[str] = []

        def fake_clarify(**_kwargs):
            return json.dumps({"user_response": secret})

        def fake_inject(text: str, **_kwargs) -> tuple[bool, str]:
            captured.append(text)
            return True, "injected"

        with (
            patch.object(h, "resolve_session_key_for_tool", return_value="cli"),
            patch.object(h, "inject_secret", side_effect=fake_inject),
        ):
            _install_clarify(fake_clarify)
            out = h.handle_request_secret(
                {"service": "ticketmaster"},
                callback=lambda *_a, **_k: secret,
            )
        data = json.loads(out)
        self.assertEqual(data["status"], "ok")
        self.assertEqual(data["service"], "ticketmaster")
        self.assertEqual(data["detail"], "injected")
        self.assertEqual(captured, [secret])
        self.assertNotIn(secret, out)

    def test_hook_consumed_failure_rewrites(self) -> None:
        secret = "another-secret-value"
        event = type("E", (), {"text": secret, "source": object(), "message_type": "text"})()
        h.set_pending(
            "gw",
            {"service": "bank", "created_at": time.time()},
        )
        with (
            patch.object(h, "resolve_session_key", return_value="gw"),
            patch.object(h, "inject_secret", side_effect=RuntimeError("boom")),
        ):
            out = h.on_pre_gateway_dispatch(event=event, source=event.source)
        assert out is not None
        self.assertEqual(out["action"], "rewrite")
        self.assertEqual(out["text"], "[secret handoff failed]")
        self.assertNotIn(secret, json.dumps(out))
        self.assertIsNone(h.peek_pending("gw"))


class EventAudio(unittest.TestCase):
    def test_voice_type(self) -> None:
        event = type("E", (), {"message_type": "voice", "media_types": []})()
        self.assertTrue(h.event_has_audio(event))

    def test_text_not_audio(self) -> None:
        event = type("E", (), {"message_type": "text", "media_types": []})()
        self.assertFalse(h.event_has_audio(event))


if __name__ == "__main__":
    unittest.main()
