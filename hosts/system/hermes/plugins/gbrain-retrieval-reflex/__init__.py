"""gbrain-retrieval-reflex — ambient push-context via gbrain resolve IPC.

Implements the host side of gbrain's retrieval-reflex channel for Hermes
(MCP client of `gbrain serve`):

  user turn → extractCandidates (entity salience) → resolve IPC
    → inject pointer block (name → slug → synopsis)

The live `gbrain serve` process owns PGLite and listens on
`$database_path/.gbrain-resolve.sock` (see garrytan/gbrain
`src/core/context/resolve-ipc.ts` + `docs/guides/push-context.md`).

This never shells the `gbrain` CLI and never opens PGLite itself.

If the socket is missing (serve not up, non-PGLite, old gbrain), fail-open
with a short MCP `volunteer_context` nudge so the agent can still pull
native pointers.
"""

from __future__ import annotations

import json
import logging
import os
import re
import socket
import unicodedata
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

logger = logging.getLogger(__name__)

_MAX_POINTERS = int(os.environ.get("GBRAIN_RETRIEVAL_REFLEX_MAX_POINTERS", "3"))
_MAX_CANDIDATES = 12
_IPC_TIMEOUT_S = float(os.environ.get("GBRAIN_RESOLVE_IPC_TIMEOUT_S", "0.25"))
_MAX_CONTEXT_BYTES = 1500
_MIN_MESSAGE_CHARS = 4

_TRIVIAL_RE = re.compile(
    r"^(ok|okay|k|yes|y|no|n|thanks|thank you|thx|ty|ping|pong|hi|hello|"
    r"hey|sup|gm|gn|test|yo|sure|yep|nope|cool|got it|ack|lgtm|"
    r"\+1|-1|👍|🙏|✅|❌)[\s!.?]*$",
    re.IGNORECASE,
)

# Entity salience (mirror of gbrain entity-salience.ts — precision-biased).
_STOPWORDS = frozenset(
    {
        "i", "i'm", "i've", "i'll", "you", "you're", "he", "she", "it", "it's",
        "we", "we're", "they", "they're", "me", "him", "her", "us", "them",
        "my", "your", "his", "their", "our", "mine", "yours", "hers", "theirs",
        "ours", "this", "that", "these", "those", "who", "whom",
        "the", "a", "an", "and", "or", "but", "so", "if", "as", "at", "by",
        "for", "in", "of", "on", "to", "up", "with", "from", "into", "over",
        "than", "then", "also", "just",
        "what", "when", "where", "why", "how", "which", "whose",
        "can", "could", "should", "would", "will", "shall", "may", "might",
        "must", "do", "does", "did", "is", "are", "am", "was", "were", "be",
        "been", "being", "has", "have", "had",
        "hi", "hey", "hello", "thanks", "thank", "please", "yes", "no", "ok",
        "okay", "sure", "maybe", "well", "oh", "let", "let's", "lets",
    }
)
_COMMON_WORDS = frozenset(
    {
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
        "sunday", "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december",
        "today", "tomorrow", "yesterday", "now", "soon", "later", "tonight",
        "morning", "afternoon", "evening", "week", "month", "year", "meeting",
        "call", "note", "task", "here", "there", "every", "some", "any", "all",
        "one", "two", "three", "first", "last", "next", "new", "old", "good",
        "bad", "great", "nice", "thing", "something", "anything",
    }
)
_HANDLE_RE = re.compile(r"@([A-Za-z0-9_]{2,})")
# Capitalized runs (unicode letter classes approximated via \w with UNICODE).
_CAP_TOKEN = r"[A-ZÀ-ÖØ-Þ][\w'’\-]*(?:\.[A-Za-zÀ-ÖØ-öø-ÿ][\w'’\-]*)*"
_CAP_RUN_RE = re.compile(rf"{_CAP_TOKEN}(?:\s+{_CAP_TOKEN}){{0,3}}")

_SOCK_NAME = ".gbrain-resolve.sock"


def register(ctx: Any) -> None:
    ctx.register_hook("pre_llm_call", on_pre_llm_call)
    logger.info(
        "gbrain-retrieval-reflex: registered (max_pointers=%s ipc_timeout=%ss)",
        _MAX_POINTERS,
        _IPC_TIMEOUT_S,
    )


def on_pre_llm_call(*, user_message: Any = None, **kwargs: Any) -> Optional[Dict[str, str]]:
    try:
        text = _normalize_user_message(user_message)
        if not text or len(text.strip()) < _MIN_MESSAGE_CHARS:
            return None
        if _TRIVIAL_RE.match(text.strip()):
            return None

        candidates = _extract_candidates(text)
        if not candidates:
            return None

        sock = _resolve_socket_path()
        if sock is None:
            return {"context": _mcp_fallback_nudge(text)}

        block = _resolve_via_ipc(sock, candidates)
        if block is None:
            return {"context": _mcp_fallback_nudge(text)}

        context = _format_block(block)
        if not context:
            return None
        return {"context": context}
    except Exception as exc:
        logger.debug("gbrain-retrieval-reflex: fail-open: %s", exc, exc_info=True)
        return None


def _normalize_user_message(user_message: Any) -> str:
    if user_message is None:
        return ""
    if isinstance(user_message, str):
        return user_message
    if isinstance(user_message, list):
        parts: List[str] = []
        for item in user_message:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, dict):
                t = item.get("text") or item.get("content") or ""
                if isinstance(t, str) and t:
                    parts.append(t)
        return "\n".join(parts)
    if isinstance(user_message, dict):
        t = user_message.get("text") or user_message.get("content") or ""
        if isinstance(t, str):
            return t
        if isinstance(t, list):
            return _normalize_user_message(t)
    return str(user_message)


def _normalize_alias(raw: str) -> str:
    if not isinstance(raw, str):
        return ""
    s = unicodedata.normalize("NFKC", raw).lower()
    s = re.sub(r"[\s\u00a0]+", " ", s).strip()
    s = re.sub(r"^[\"'`\[(]+", "", s)
    s = re.sub(r"[\"'`\])]+$", "", s).strip()
    return s


def _strip_possessive(s: str) -> str:
    return re.sub(r"['’]s$", "", s, flags=re.I).replace("’", "'").rstrip("'")


def _is_sentence_start(text: str, idx: int) -> bool:
    i = idx - 1
    while i >= 0 and text[i].isspace():
        i -= 1
    if i < 0:
        return True
    return text[i] in '.!?:;\n\r•-([\'"“'


def _extract_candidates(text: str) -> List[Dict[str, str]]:
    """Port of gbrain extractCandidates — display + query for resolve IPC."""
    acc: Dict[str, Dict[str, Any]] = {}
    order = 0

    def consider(raw_display: str, raw_query: str, mid_sentence: bool) -> None:
        nonlocal order
        display = raw_display.strip()
        query = _strip_possessive(raw_query.strip())
        if not query:
            return
        norm = _normalize_alias(query)
        if not norm:
            return
        existing = acc.get(norm)
        if existing:
            if mid_sentence:
                existing["seen_mid"] = True
            return
        acc[norm] = {
            "display": display,
            "query": query,
            "multi": bool(re.search(r"\s", query)),
            "seen_mid": mid_sentence,
            "order": order,
        }
        order += 1

    for m in _HANDLE_RE.finditer(text):
        handle = m.group(1)
        consider(f"@{handle}", handle, True)

    for m in _CAP_RUN_RE.finditer(text):
        surface = m.group(0)
        consider(surface, surface, not _is_sentence_start(text, m.start()))

    out: List[Dict[str, str]] = []
    for c in sorted(acc.values(), key=lambda x: x["order"]):
        lc = c["query"].lower()
        if not c["multi"]:
            if len(c["query"]) < 2:
                continue
            if re.match(r"^[0-9][0-9.,]*$", c["query"]):
                continue
            if lc in _STOPWORDS:
                continue
            if lc in _COMMON_WORDS and not c["seen_mid"]:
                continue
        out.append({"display": c["display"], "query": c["query"]})
        if len(out) >= _MAX_CANDIDATES:
            break
    return out


def _socket_candidates() -> List[Path]:
    env = os.environ.get("GBRAIN_RESOLVE_SOCKET", "").strip()
    paths: List[Path] = []
    if env:
        paths.append(Path(env))
    home = os.environ.get("HOME") or ""
    gbrain_home = os.environ.get("GBRAIN_HOME", "").strip()
    bases = []
    if gbrain_home:
        bases.append(Path(gbrain_home))
    if home:
        bases.append(Path(home) / ".gbrain")
    bases.extend(
        [
            Path("/home/hermes/.gbrain"),
            Path("/var/lib/hermes/home/.gbrain"),
            Path("/data/home/.gbrain"),
        ]
    )
    # database_path is usually the pglite dir; socket lives inside it.
    db_names = ("brain.pglite", "pglite", ".")
    for base in bases:
        for name in db_names:
            d = base if name == "." else base / name
            paths.append(d / _SOCK_NAME)
    # de-dupe preserving order
    seen = set()
    uniq: List[Path] = []
    for p in paths:
        key = str(p)
        if key in seen:
            continue
        seen.add(key)
        uniq.append(p)
    return uniq


def _resolve_socket_path() -> Optional[Path]:
    for p in _socket_candidates():
        try:
            if p.is_socket() or (p.exists() and p.stat().st_size >= 0 and p.is_file() is False):
                # is_socket preferred; some platforms report socket as exists
                if p.exists():
                    return p
        except OSError:
            continue
        try:
            if p.exists():
                return p
        except OSError:
            continue
    return None


def _resolve_via_ipc(
    sock_path: Path, candidates: List[Dict[str, str]]
) -> Optional[Dict[str, Any]]:
    """NDJSON request/response against gbrain resolve IPC. Fail-soft → None."""
    req = {
        "candidates": candidates,
        "maxPointers": _MAX_POINTERS,
        "suppression": "slug-only",
    }
    payload = (json.dumps(req) + "\n").encode("utf-8")
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(_IPC_TIMEOUT_S)
            sock.connect(str(sock_path))
            sock.sendall(payload)
            buf = b""
            while b"\n" not in buf and len(buf) < 256 * 1024:
                chunk = sock.recv(8192)
                if not chunk:
                    break
                buf += chunk
            if b"\n" not in buf:
                return None
            line = buf.split(b"\n", 1)[0].decode("utf-8", errors="replace")
            resp = json.loads(line)
            if not isinstance(resp, dict) or not resp.get("ok"):
                return None
            block = resp.get("block")
            if not block:
                return None
            if isinstance(block, dict):
                return block
            return None
    except (OSError, socket.timeout, json.JSONDecodeError, ValueError) as exc:
        logger.debug("gbrain-retrieval-reflex: ipc miss: %s", exc)
        return None


def _format_block(block: Dict[str, Any]) -> str:
    """Prefer gbrain-rendered text; else format pointers like renderPointerBlock."""
    text = block.get("text")
    if isinstance(text, str) and text.strip():
        context = text.strip()
    else:
        pointers = block.get("pointers") or []
        if not isinstance(pointers, list) or not pointers:
            return ""
        lines = [
            "## Brain pages mentioned this turn",
            "You referenced entities with existing brain pages. Open the page "
            "before relying on details — do not answer from memory.",
            "",
        ]
        for p in pointers[:_MAX_POINTERS]:
            if not isinstance(p, dict):
                continue
            display = p.get("display") or p.get("slug") or "?"
            slug = p.get("slug") or ""
            syn = p.get("synopsis") or ""
            syn_s = f" — {syn}" if syn else ""
            lines.append(
                f"- **{display}** → `{slug}`{syn_s} "
                "(use get_page before relying on details)"
            )
        context = "\n".join(lines)

    # Always append MCP ladder for full window / follow-up.
    footer = (
        "\nOpen with MCP `get_page`. For rolling multi-turn push, also call "
        "MCP `volunteer_context` with a short user:/assistant: window."
    )
    context = context + footer
    raw = context.encode("utf-8")
    if len(raw) <= _MAX_CONTEXT_BYTES:
        return context
    # Truncate pointer lines only.
    lines = context.split("\n")
    while lines and len("\n".join(lines).encode("utf-8")) > _MAX_CONTEXT_BYTES:
        # drop last pointer-ish line before footer
        if len(lines) <= 4:
            break
        lines.pop(-2) if lines[-1].startswith("Open with") else lines.pop()
    return "\n".join(lines)


def _mcp_fallback_nudge(user_text: str) -> str:
    """When resolve IPC is down: instruct agent to use native MCP op."""
    window = user_text.strip()
    if len(window) > 400:
        window = window[:400] + "…"
    return (
        "## GBrain push-context (resolve IPC unavailable)\n"
        "Call MCP `volunteer_context` with a `window` of recent turns "
        f"(include this user message). Example window line:\n"
        f"user: {window}\n"
        "Then `get_page` on volunteered slugs before answering from MEMORY. "
        "Never shell the `gbrain` CLI while serve is up."
    )
