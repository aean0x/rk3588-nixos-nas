"""gbrain-retrieval-reflex — ambient push-context for Hermes.

Under HTTP sole-owner (gbrain serve --http), resolve IPC sock is NOT bound
(upstream 0.42.x: startResolveIpcServer only on stdio). So ambient path is:

  user turn → HTTP MCP tools/call volunteer_context (Bearer token)
           → inject ## Brain pages… block into pre_llm_call context

Optional fast path: if .gbrain-resolve.sock exists, use resolve IPC first.

Never shells gbrain CLI; never opens PGLite itself.
"""

from __future__ import annotations

import json
import logging
import os
import re
import socket
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional

logger = logging.getLogger(__name__)

_MAX_POINTERS = int(os.environ.get("GBRAIN_RETRIEVAL_REFLEX_MAX_POINTERS", "3"))
_IPC_TIMEOUT_S = float(os.environ.get("GBRAIN_RESOLVE_IPC_TIMEOUT_S", "0.25"))
_HTTP_TIMEOUT_S = float(os.environ.get("GBRAIN_VOLUNTEER_HTTP_TIMEOUT_S", "2.5"))
_MAX_CONTEXT_BYTES = 1500
_MIN_MESSAGE_CHARS = 4

_MCP_URL = os.environ.get("GBRAIN_MCP_URL", "http://127.0.0.1:3131/mcp").strip()
_SOCK_NAME = ".gbrain-resolve.sock"

_TRIVIAL_RE = re.compile(
    r"^(ok|okay|k|yes|y|no|n|thanks|thank you|thx|ty|ping|pong|hi|hello|"
    r"hey|sup|gm|gn|test|yo|sure|yep|nope|cool|got it|ack|lgtm|"
    r"\+1|-1|👍|🙏|✅|❌)[\s!.?]*$",
    re.IGNORECASE,
)

_TOKEN_PATHS = (
    Path(os.environ["HOME"]) / ".gbrain" / "hermes-mcp.token"
    if os.environ.get("HOME")
    else None,
    Path("/var/lib/hermes/home/.gbrain/hermes-mcp.token"),
    Path("/home/hermes/.gbrain/hermes-mcp.token"),
)
_ENV_PATHS = (
    Path("/var/lib/hermes/.hermes/.env"),
    Path("/home/hermes/.hermes/.env"),
    Path(os.environ.get("HERMES_HOME", "")) / ".env" if os.environ.get("HERMES_HOME") else None,
)


def register(ctx: Any) -> None:
    ctx.register_hook("pre_llm_call", on_pre_llm_call)
    logger.info(
        "gbrain-retrieval-reflex: registered (http_timeout=%ss mcp=%s)",
        _HTTP_TIMEOUT_S,
        _MCP_URL,
    )


def on_pre_llm_call(*, user_message: Any = None, **kwargs: Any) -> Optional[Dict[str, str]]:
    try:
        text = _normalize_user_message(user_message)
        if not text or len(text.strip()) < _MIN_MESSAGE_CHARS:
            return None
        if _TRIVIAL_RE.match(text.strip()):
            return None

        # HTTP sole-owner: volunteer_context (entity push), then query fallback.
        # After reimport, aliases may be thin — volunteer often returns [] while
        # hybrid query still finds pages (capitalization / confidence gate).
        pages = _volunteer_via_http(text)
        if not pages:
            pages = _query_via_http(text)
        if pages:
            context = _format_pages(pages)
            if context:
                return {"context": context}

        # Optional IPC if sock exists (stdio serve builds only).
        sock = _resolve_socket_path()
        if sock is not None:
            block = _resolve_via_ipc(sock, _extract_candidates_light(text))
            if block:
                context = _format_block(block)
                if context:
                    return {"context": context}

        return None
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


def _read_bearer_token() -> str:
    for p in _TOKEN_PATHS:
        if p is None:
            continue
        try:
            if p.is_file():
                tok = p.read_text(encoding="utf-8").strip()
                if tok:
                    return tok
        except OSError:
            continue
    for p in _ENV_PATHS:
        if p is None:
            continue
        try:
            if not p.is_file():
                continue
            for line in p.read_text(encoding="utf-8", errors="replace").splitlines():
                if line.startswith("GBRAIN_REMOTE_TOKEN="):
                    tok = line.split("=", 1)[1].strip().strip('"').strip("'")
                    if tok:
                        return tok
        except OSError:
            continue
    return ""


def _parse_sse_json(raw: str) -> Optional[Dict[str, Any]]:
    """Parse streamable-HTTP / SSE body for first JSON-RPC object."""
    raw = raw.strip()
    if not raw:
        return None
    # SSE: lines "data: {...}"
    if "data:" in raw:
        for line in raw.splitlines():
            line = line.strip()
            if line.startswith("data:"):
                payload = line[5:].strip()
                if payload and payload != "[DONE]":
                    try:
                        return json.loads(payload)
                    except json.JSONDecodeError:
                        continue
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return None


def _mcp_http_call(method: str, params: Dict[str, Any], *, req_id: int = 1) -> Optional[Dict[str, Any]]:
    token = _read_bearer_token()
    if not token:
        logger.debug("gbrain-retrieval-reflex: no bearer token")
        return None
    body = {"jsonrpc": "2.0", "id": req_id, "method": method, "params": params}
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    }
    try:
        req = urllib.request.Request(
            _MCP_URL,
            data=json.dumps(body).encode("utf-8"),
            headers=headers,
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=_HTTP_TIMEOUT_S) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
        return _parse_sse_json(raw)
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError) as exc:
        logger.debug("gbrain-retrieval-reflex: http miss: %s", exc)
        return None


def _tools_call_text(name: str, arguments: Dict[str, Any]) -> Optional[str]:
    msg = _mcp_http_call(
        "tools/call",
        {"name": name, "arguments": arguments},
        req_id=3,
    )
    if not msg or not isinstance(msg, dict) or msg.get("error"):
        if msg and msg.get("error"):
            logger.debug("gbrain-retrieval-reflex: %s error: %s", name, msg.get("error"))
        return None
    result = msg.get("result") or {}
    if not isinstance(result, dict):
        return None
    content = result.get("content")
    if isinstance(content, list):
        parts = []
        for part in content:
            if isinstance(part, dict) and part.get("type") == "text":
                parts.append(part.get("text") or "")
        return "".join(parts)
    return None


def _volunteer_via_http(user_text: str) -> List[Dict[str, Any]]:
    """Call volunteer_context over HTTP MCP. [] if empty or transport fail."""
    window = user_text.strip()
    if not window.startswith("user:") and not window.startswith("assistant:"):
        window = f"user: {window}"
    text_blob = _tools_call_text(
        "volunteer_context",
        {"window": window, "max_pages": _MAX_POINTERS},
    )
    if not text_blob:
        return []
    try:
        data = json.loads(text_blob)
    except json.JSONDecodeError:
        return []
    if not isinstance(data, dict):
        return []
    pages = data.get("pages")
    return pages if isinstance(pages, list) else []


def _query_via_http(user_text: str) -> List[Dict[str, Any]]:
    """Hybrid query fallback when volunteer returns no entity hits."""
    q = user_text.strip()
    if len(q) > 200:
        q = q[:200]
    text_blob = _tools_call_text(
        "query",
        {"query": q, "limit": _MAX_POINTERS},
    )
    if not text_blob:
        return []
    try:
        data = json.loads(text_blob)
    except json.JSONDecodeError:
        return []
    # query may return list of hits or {results: [...]}
    hits: List[Any]
    if isinstance(data, list):
        hits = data
    elif isinstance(data, dict):
        hits = data.get("results") or data.get("hits") or data.get("pages") or []
    else:
        return []
    pages: List[Dict[str, Any]] = []
    for h in hits:
        if not isinstance(h, dict):
            continue
        slug = h.get("slug") or ""
        if not slug:
            continue
        pages.append(
            {
                "display": h.get("title") or slug,
                "slug": slug,
                "synopsis": (h.get("chunk_text") or h.get("snippet") or "")[:160],
                "confidence": h.get("score") or h.get("confidence"),
            }
        )
        if len(pages) >= _MAX_POINTERS:
            break
    return pages


def _format_pages(pages: List[Dict[str, Any]]) -> str:
    if not pages:
        return ""
    lines = [
        "## Brain pages (ambient push)",
        "GBrain surface for this turn (volunteer_context and/or query). "
        "Open with MCP `get_page` before relying on details — do not answer from MEMORY alone.",
        "",
    ]
    for p in pages[:_MAX_POINTERS]:
        if not isinstance(p, dict):
            continue
        display = p.get("display") or p.get("slug") or "?"
        slug = p.get("slug") or ""
        syn = p.get("synopsis") or p.get("rationale") or ""
        conf = p.get("confidence")
        conf_s = f" conf={conf}" if conf is not None else ""
        syn_s = f" — {syn}" if syn else ""
        lines.append(f"- **{display}** → `{slug}`{syn_s}{conf_s}")
    lines.append("Use MCP `get_page` on salient slugs; never shell `gbrain` CLI.")
    context = "\n".join(lines)
    raw = context.encode("utf-8")
    if len(raw) <= _MAX_CONTEXT_BYTES:
        return context
    body = lines[3:-1]
    while body and len("\n".join(lines[:3] + body + lines[-1:]).encode("utf-8")) > _MAX_CONTEXT_BYTES:
        body.pop()
    return "\n".join(lines[:3] + body + [lines[-1]])


# ── Optional resolve IPC (stdio serve only) ───────────────────────────────


def _extract_candidates_light(text: str) -> List[Dict[str, str]]:
    """Minimal candidates for IPC path only."""
    out: List[Dict[str, str]] = []
    for m in re.finditer(r"[A-ZÀ-ÖØ-Þ][\w'’\-]{1,40}", text):
        s = m.group(0)
        out.append({"display": s, "query": s})
        if len(out) >= 8:
            break
    return out


def _socket_candidates() -> List[Path]:
    paths: List[Path] = []
    env = os.environ.get("GBRAIN_RESOLVE_SOCKET", "").strip()
    if env:
        paths.append(Path(env))
    home = os.environ.get("HOME") or ""
    bases = []
    if home:
        bases.append(Path(home) / ".gbrain")
    bases.extend(
        [
            Path("/home/hermes/.gbrain"),
            Path("/var/lib/hermes/home/.gbrain"),
        ]
    )
    for base in bases:
        paths.append(base / "brain.pglite" / _SOCK_NAME)
        paths.append(base / _SOCK_NAME)
    seen = set()
    uniq: List[Path] = []
    for p in paths:
        k = str(p)
        if k not in seen:
            seen.add(k)
            uniq.append(p)
    return uniq


def _resolve_socket_path() -> Optional[Path]:
    for p in _socket_candidates():
        try:
            if p.exists():
                return p
        except OSError:
            continue
    return None


def _resolve_via_ipc(
    sock_path: Path, candidates: List[Dict[str, str]]
) -> Optional[Dict[str, Any]]:
    if not candidates:
        return None
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
            return block if isinstance(block, dict) else None
    except (OSError, socket.timeout, json.JSONDecodeError, ValueError) as exc:
        logger.debug("gbrain-retrieval-reflex: ipc miss: %s", exc)
        return None


def _format_block(block: Dict[str, Any]) -> str:
    text = block.get("text")
    if isinstance(text, str) and text.strip():
        return text.strip()[: _MAX_CONTEXT_BYTES]
    pointers = block.get("pointers") or []
    if not isinstance(pointers, list):
        return ""
    pages = []
    for p in pointers:
        if isinstance(p, dict):
            pages.append(p)
    return _format_pages(pages)
