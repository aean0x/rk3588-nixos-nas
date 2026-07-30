"""gbrain-reflex — proactive GBrain pointer injection (pre_llm_call).

Reads a flake-owned static alias index (no gbrain CLI / no network) and injects
up to three compact page pointers into the **user message** so the agent can
open them via MCP get_page/query. Fail-open: any error returns None.
"""

from __future__ import annotations

import json
import logging
import os
import re
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

logger = logging.getLogger(__name__)

# Cap injected context so we do not bloat the turn.
_MAX_POINTERS = 3
_MAX_CONTEXT_BYTES = 1500
_MIN_MESSAGE_CHARS = 4

# Logistics-only messages that never need brain pointers.
_TRIVIAL_RE = re.compile(
    r"^(ok|okay|k|yes|y|no|n|thanks|thank you|thx|ty|ping|pong|hi|hello|"
    r"hey|sup|gm|gn|test|yo|sure|yep|nope|cool|got it|ack|lgtm|"
    r"\+1|-1|👍|🙏|✅|❌)[\s!.?]*$",
    re.IGNORECASE,
)

_INDEX_CANDIDATES = (
    "GBRAIN_POINTER_INDEX",  # env var name, resolved at load
    "/data/workspace/gbrain-pointer-index.json",
    "/var/lib/hermes/workspace/gbrain-pointer-index.json",
)

# (mtime, path, entries) — entries is list of dicts with aliases/slug/synopsis
_index_cache: Optional[Tuple[float, str, List[Dict[str, Any]]]] = None
# Precomputed match table: list of (alias_cf, pattern, entry) longest-first
_match_table: Optional[List[Tuple[str, re.Pattern[str], Dict[str, Any]]]] = None
_match_table_key: Optional[str] = None


def register(ctx: Any) -> None:
    """Hermes plugin entry point."""
    ctx.register_hook("pre_llm_call", on_pre_llm_call)
    logger.debug("gbrain-reflex: registered pre_llm_call hook")


def on_pre_llm_call(*, user_message: Any = None, **kwargs: Any) -> Optional[Dict[str, str]]:
    """Inject compact GBrain pointers when aliases match the user turn."""
    try:
        text = _normalize_user_message(user_message)
        if not text or len(text.strip()) < _MIN_MESSAGE_CHARS:
            return None
        if _TRIVIAL_RE.match(text.strip()):
            return None

        entries = _load_index()
        if not entries:
            return None

        hits = _match_pointers(text, entries)
        if not hits:
            return None

        context = _format_context(hits)
        if not context:
            return None
        return {"context": context}
    except Exception as exc:
        logger.debug("gbrain-reflex: fail-open on error: %s", exc, exc_info=True)
        return None


def _normalize_user_message(user_message: Any) -> str:
    """Coerce multimodal or structured user messages to plain text."""
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
                # OpenAI-style content parts: {"type":"text","text":"..."}
                t = item.get("text") or item.get("content") or ""
                if isinstance(t, str) and t:
                    parts.append(t)
            else:
                s = str(item).strip()
                if s:
                    parts.append(s)
        return "\n".join(parts)
    if isinstance(user_message, dict):
        t = user_message.get("text") or user_message.get("content") or ""
        if isinstance(t, str):
            return t
        if isinstance(t, list):
            return _normalize_user_message(t)
    return str(user_message)


def _resolve_index_path() -> Optional[Path]:
    env_path = os.environ.get("GBRAIN_POINTER_INDEX", "").strip()
    candidates: List[str] = []
    if env_path:
        candidates.append(env_path)
    candidates.extend(
        p
        for p in _INDEX_CANDIDATES
        if p != "GBRAIN_POINTER_INDEX"
    )
    for raw in candidates:
        try:
            path = Path(raw)
            if path.is_file():
                return path
        except Exception as exc:
            logger.debug("gbrain-reflex: skip index candidate %r: %s", raw, exc)
            continue
    return None


def _load_index() -> List[Dict[str, Any]]:
    """Load pointer index with mtime-based cache (no network / no gbrain CLI)."""
    global _index_cache, _match_table, _match_table_key

    path = _resolve_index_path()
    if path is None:
        return []

    try:
        mtime = path.stat().st_mtime
    except OSError as exc:
        logger.debug("gbrain-reflex: cannot stat index %s: %s", path, exc)
        return []

    cache_key = str(path)
    if (
        _index_cache is not None
        and _index_cache[0] == mtime
        and _index_cache[1] == cache_key
    ):
        return _index_cache[2]

    try:
        raw = path.read_text(encoding="utf-8")
        data = json.loads(raw)
    except Exception as exc:
        logger.debug("gbrain-reflex: failed to read index %s: %s", path, exc)
        return []

    if not isinstance(data, list):
        logger.debug("gbrain-reflex: index is not a list: %s", path)
        return []

    entries: List[Dict[str, Any]] = []
    for item in data:
        if not isinstance(item, dict):
            continue
        slug = item.get("slug")
        aliases = item.get("aliases")
        if not isinstance(slug, str) or not slug.strip():
            continue
        if not isinstance(aliases, list) or not aliases:
            continue
        clean_aliases = [
            a.strip() for a in aliases if isinstance(a, str) and a.strip()
        ]
        if not clean_aliases:
            continue
        synopsis = item.get("synopsis") or ""
        if not isinstance(synopsis, str):
            synopsis = str(synopsis)
        entries.append(
            {
                "aliases": clean_aliases,
                "slug": slug.strip(),
                "synopsis": synopsis.strip(),
            }
        )

    _index_cache = (mtime, cache_key, entries)
    _match_table = None
    _match_table_key = None
    # Touch for debugging freshness without logging content.
    logger.debug(
        "gbrain-reflex: loaded %d index entries from %s (mtime=%s)",
        len(entries),
        path,
        time.ctime(mtime),
    )
    return entries


def _build_match_table(
    entries: Sequence[Dict[str, Any]],
) -> List[Tuple[str, re.Pattern[str], Dict[str, Any]]]:
    """Build longest-alias-first match table with whole-word/phrase patterns."""
    pairs: List[Tuple[str, Dict[str, Any]]] = []
    for entry in entries:
        for alias in entry["aliases"]:
            pairs.append((alias, entry))
    # Prefer longer aliases so "mail triage" wins over "mail" if both exist.
    pairs.sort(key=lambda p: len(p[0]), reverse=True)

    table: List[Tuple[str, re.Pattern[str], Dict[str, Any]]] = []
    for alias, entry in pairs:
        alias_cf = alias.casefold()
        # Word-boundary match for multi-word / alphanumeric aliases.
        # Escape regex metacharacters; treat whitespace flexibly inside phrases.
        escaped = re.escape(alias_cf)
        escaped = re.sub(r"\\\s+", r"\\s+", escaped)
        # Use lookaround so punctuation does not block ("maton," / "GBrain?").
        pattern = re.compile(
            rf"(?<![\w/]){escaped}(?![\w/])",
            re.IGNORECASE,
        )
        table.append((alias_cf, pattern, entry))
    return table


def _match_pointers(
    text: str,
    entries: Sequence[Dict[str, Any]],
) -> List[Dict[str, Any]]:
    """Return up to _MAX_POINTERS unique slug hits, longer aliases first."""
    global _match_table, _match_table_key

    # Invalidate table if entry set identity changed (path/mtime already handled).
    key = str(id(entries))
    if _match_table is None or _match_table_key != key:
        _match_table = _build_match_table(entries)
        _match_table_key = key

    text_cf = text.casefold()
    hits: List[Dict[str, Any]] = []
    seen_slugs: set[str] = set()

    for _alias_cf, pattern, entry in _match_table:
        slug = entry["slug"]
        if slug in seen_slugs:
            continue
        if pattern.search(text_cf):
            seen_slugs.add(slug)
            hits.append(entry)
            if len(hits) >= _MAX_POINTERS:
                break
    return hits


def _format_context(hits: Sequence[Dict[str, Any]]) -> str:
    """Render compact pointer block; trim to _MAX_CONTEXT_BYTES if needed."""
    lines = ["## GBrain pointers"]
    for entry in hits:
        # Prefer a readable name: first alias capitalized lightly, else slug.
        name = entry["aliases"][0]
        name_disp = name[0].upper() + name[1:] if name else entry["slug"]
        synopsis = entry.get("synopsis") or ""
        if synopsis:
            lines.append(f"- **{name_disp}** → `{entry['slug']}` — {synopsis}")
        else:
            lines.append(f"- **{name_disp}** → `{entry['slug']}`")
    lines.append(
        "Open with MCP get_page/query when the entity is the subject."
    )
    context = "\n".join(lines)
    raw = context.encode("utf-8")
    if len(raw) <= _MAX_CONTEXT_BYTES:
        return context
    # Drop trailing pointer lines until under budget (keep header + footer).
    body = lines[1:-1]
    footer = lines[-1]
    header = lines[0]
    while body:
        candidate = "\n".join([header, *body, footer])
        if len(candidate.encode("utf-8")) <= _MAX_CONTEXT_BYTES:
            return candidate
        body.pop()
    return ""
