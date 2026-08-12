"""model-router — 3-tier cost routing for rocknas Hermes.

Collapsed from upstream open-world-project/model-router 5-tier map:
  old T1+light T2 → T1 Flash
  old T2+T3       → T2 Pro   (day-to-day coding/review/docs)
  old T4+T5       → T3 Grok  (architecture, high-stakes, final voice)

Policy:
  • Work loop runs on classified T1/T2 (or T3 when classified).
  • Multi-sentence user messages floor at T2 (classifier + deterministic).
  • Tool-error escalation may climb through T3 Grok and de-escalate back.
  • After any tool use this turn, subsequent API calls switch to Grok
    (synthesis / potential final).
  • If the turn still ends off-Grok (no-tool path), transform_llm_output
    polishes the draft once via Grok so the user-facing reply is Grok.
  • Manual /t1 /t2 /t3 pins win over auto final-voice.
  • Every pre_api_request re-heals half-switch (DeepSeek model on xAI host)
    caused by WebUI webui_credential_refresh — hooks never raise.

No Hermes/WebUI core file edits. Live switch uses AIAgent.switch_model via
the same hermes_cli.model_switch resolver as /model (native providers, not
OpenRouter slugs). Agent capture is deferred so register() cannot circular-
import run_agent.

Does not write SOUL.md.
"""
from __future__ import annotations

import logging
import os
import re
import threading
import time
from typing import Any

logger = logging.getLogger("plugins.model-router")


def _attach_file_handler() -> None:
    """Route routing decisions to their own file so they are greppable in one place.

    Without this, INFO-level routing logs only reach agent.log (per-session) and
    WARNING reaches errors.log; they never appear in gateway.log, which makes
    "did the router actually switch" hard to answer from the container logs.
    """
    if any(isinstance(h, logging.FileHandler) for h in logger.handlers):
        return
    hermes_home = os.environ.get("HERMES_HOME", os.path.expanduser("~/.hermes"))
    log_dir = os.path.join(hermes_home, "logs")
    os.makedirs(log_dir, exist_ok=True)
    handler = logging.FileHandler(os.path.join(log_dir, "model-router.log"))
    handler.setFormatter(
        logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s")
    )
    logger.addHandler(handler)
    logger.setLevel(logging.INFO)

TIERS: dict[int, dict[str, Any]] = {
    1: {
        "label": "T1 Flash",
        "model": "deepseek-v4-flash",
        "provider": "deepseek",
        "role": "fast triage + cheap helper",
        "best_for": [
            "Short acknowledgements",
            "Intent classification",
            "Status checks",
            "Title generation",
            "Trivial Q&A / look-ups",
        ],
    },
    2: {
        "label": "T2 Pro",
        "model": "deepseek-v4-pro",
        "provider": "deepseek",
        "role": "default workhorse — coding, review, docs",
        "best_for": [
            "Default day-to-day work",
            "Documentation and drafting",
            "Standard coding and research",
            "Debugging",
            "Code review",
            "Large-document synthesis",
            "Complex analysis",
        ],
    },
    3: {
        "label": "T3 Grok",
        "model": "grok-4.5",
        "provider": "xai-oauth",
        "role": "high-stakes + final user-facing voice",
        "best_for": [
            "Architecture",
            "Migration planning",
            "Complex multi-step design",
            "Nuanced code review",
            "Security-sensitive analysis",
            "Algorithmic optimization",
            "High-stakes reasoning",
            "Monetary transactions",
            "Final user-facing response",
        ],
    },
}

# Escalation may climb onto Grok; post_llm_call de-escalates back to base.
_ESCALATE_MAX = 3
_ESCALATION_ERROR_THRESHOLD = 2
_FINAL_TIER = 3

_SKIP_PLATFORMS = frozenset({"cron"})

_TIER_RE = re.compile(r"(?:^|(?<=\s)|(?<=\())[tT]([1-3])(?:\b|(?=\)))")
_TIER_WORD_RE = re.compile(r"(?:^|(?<=\s)|(?<=\())tier\s*([1-3])", re.IGNORECASE)
_ACK_RE = re.compile(
    r"^(ok|okay|thanks|thank you|thx|got it|understood|sure|yes|no|yep|nope|"
    r"alright|cool|great|nice|perfect|done|noted|ack|hello|hi|hey)"
    r"[!?.]*$",
    re.IGNORECASE,
)
# WebUI prefixes every user turn; strip before ack/length/sentence heuristics.
_WEBUI_WORKSPACE_RE = re.compile(
    r"^\[Workspace::v1:\s*[^\]]+\]\s*",
    re.IGNORECASE,
)
# Explicit pin-style requests only — bare "T1" inside a long critique is NOT a pin.
_EXPLICIT_REQ_RE = re.compile(
    r"(?:^|\s)(?:/t([1-3])\b|(?:use|pin|switch\s+to|run\s+(?:on|at)|please\s+use)\s+t([1-3])\b)",
    re.IGNORECASE,
)
_SENTENCE_SPLIT_RE = re.compile(r"[.!?]+\s+|\n+")


_CLASSIFIER = """\
You assign a single WORK routing tier (1-3) for the user's message.
(The final user-facing reply may still be polished by Grok separately.)

1 = Flash — short acks, status, titles, trivial look-ups, pure routing/triage
2 = Pro — day-to-day work: docs, standard coding/research, debugging, code review,
    large-doc synthesis, complex analysis, multi-file implementation
3 = Grok — old T4+T5 territory ONLY: architecture, migration planning, complex
    multi-step design, nuanced review with subtle failure modes, security/crypto,
    algorithmic optimization, financial modelling, high-stakes work with many
    interacting constraints. Also use 3 when the task is primarily judgment/
    synthesis with no clear cheap tool loop.

Rules:
- When unsure between 1 and 2, pick 2 for real work; pick 1 only for trivial turns.
- When unsure between 2 and 3, pick 2 unless architecture/security/high-stakes fits.
- Tier 3 is uncommon but not vanishingly rare — use it when T4/T5 of a 5-tier
  ladder would have been correct.
- if user message is >1 sentence, strongly consider T2.
- Multi-sentence questions, critiques, and follow-ups are real work (T2+), not
  triage — even when each sentence is short.
- Respond with ONLY a digit: 1, 2, or 3.
"""

_FINAL_VOICE_SYSTEM = """\
You are Archimedes' final voice (Grok). Rewrite the draft assistant reply for the user.
Preserve every fact, path, command, URL, code block, number, and decision exactly.
Improve clarity, structure, and voice. Do not invent new claims. Do not mention
models, tiers, routing, or that a draft existed. Output ONLY the final reply.
"""

_lock = threading.Lock()
_live_agents: dict[str, Any] = {}
_last_bound: tuple[str, Any] | None = None
_pinned: dict[str, bool] = {}
_last_tier: dict[str, int] = {}
_base_tier: dict[str, int] = {}
_last_msg: dict[str, tuple[str, int]] = {}
_tool_errors: dict[str, int] = {}
_escalated: dict[str, bool] = {}
_pending: dict[str, int] = {}  # classified but not yet applied
_tools_this_turn: dict[str, int] = {}
_user_msg: dict[str, str] = {}  # original user message for final-voice polish
_ack_turn: dict[str, bool] = {}
_manager = None
_patched = False


def _norm(s: str) -> str:
    return (s or "").strip().lower()


def _agent_base_url(agent: Any) -> str:
    """Prefer live client kwargs base — WebUI credential refresh can desync attrs."""
    if agent is None:
        return ""
    kw = getattr(agent, "_client_kwargs", None) or {}
    if isinstance(kw, dict):
        b = (kw.get("base_url") or "").strip()
        if b:
            return b
    return (getattr(agent, "base_url", "") or "").strip()


def _strip_platform_prefix(msg: str) -> str:
    return _WEBUI_WORKSPACE_RE.sub("", (msg or "").strip()).strip()


def _sentence_count(msg: str) -> int:
    text = _strip_platform_prefix(msg)
    if not text:
        return 0
    parts = [p.strip() for p in _SENTENCE_SPLIT_RE.split(text) if p.strip()]
    # No terminator still counts as one sentence if there is content.
    return max(1, len(parts)) if text else 0


def _base_url_matches_provider(base_url: str, provider: str) -> bool:
    """Detect half-switched agents (model name set, still on previous API host).

    Session 5db7c7178b08: model=deepseek-v4-flash + provider=deepseek but
    base_url still https://api.x.ai/v1 → non-retryable 404 from xAI.
    """
    base = _norm(base_url)
    prov = _norm(provider)
    if not base or not prov:
        return True  # unknown — let switch_model decide
    if prov in {"deepseek", "deepseek-chat"}:
        # Native DeepSeek must not ride the xAI host (or OpenRouter-only hosts).
        if "x.ai" in base or "xai" in base:
            return False
        if "deepseek" in base:
            return True
        # Other bases (custom proxy) — don't force reswitch.
        return True
    if prov in {"xai", "xai-oauth", "x-ai"}:
        if "deepseek.com" in base:
            return False
        if "x.ai" in base or "xai" in base:
            return True
        return True
    return True


def _same_route(agent: Any, model: str, provider: str) -> bool:
    if _norm(getattr(agent, "model", "")) != _norm(model):
        return False
    if _norm(getattr(agent, "provider", "")) != _norm(provider):
        return False
    base = _agent_base_url(agent)
    if not _base_url_matches_provider(base, provider):
        logger.warning(
            "model-router: half-switch detected model=%s provider=%s base_url=%s — re-applying",
            getattr(agent, "model", ""),
            getattr(agent, "provider", ""),
            base,
        )
        return False
    return True


def bind_agent(session_id: str, agent: Any) -> None:
    if agent is None:
        return
    global _last_bound
    sid = session_id or getattr(agent, "session_id", None) or ""
    with _lock:
        if sid:
            _live_agents[sid] = agent
        _last_bound = (sid, agent)


def _get_agent(session_id: str = "") -> Any | None:
    sid = session_id or ""
    with _lock:
        if sid and sid in _live_agents:
            return _live_agents[sid]
        bound = _last_bound
        live_items = list(_live_agents.items())

    def _ok(agent: Any) -> bool:
        if agent is None:
            return False
        if not sid:
            return True
        agent_sid = getattr(agent, "session_id", "") or ""
        return (not agent_sid) or agent_sid == sid

    if _manager is not None:
        try:
            cli = getattr(_manager, "_cli_ref", None)
            agent = getattr(cli, "agent", None) if cli else None
            if _ok(agent):
                bind_agent(sid, agent)
                return agent
        except Exception:
            pass

    if bound is not None and _ok(bound[1]):
        bind_agent(sid, bound[1])
        return bound[1]

    for mapped_sid, agent in live_items:
        if _ok(agent):
            bind_agent(sid or mapped_sid, agent)
            return agent
    return None


def _install_agent_capture() -> None:
    global _patched
    if _patched:
        return
    try:
        import run_agent
    except Exception as exc:
        logger.warning("model-router: cannot import run_agent for capture: %s", exc)
        return

    orig_init = run_agent.AIAgent.__init__
    if getattr(orig_init, "_model_router_wrapped", False):
        _patched = True
        return

    def wrapped_init(self, *args, **kwargs):
        orig_init(self, *args, **kwargs)
        bind_agent(getattr(self, "session_id", None) or "", self)

    wrapped_init._model_router_wrapped = True  # type: ignore[attr-defined]
    run_agent.AIAgent.__init__ = wrapped_init  # type: ignore[method-assign]

    orig_run = run_agent.AIAgent.run_conversation

    def wrapped_run(self, *args, **kwargs):
        bind_agent(getattr(self, "session_id", None) or "", self)
        return orig_run(self, *args, **kwargs)

    run_agent.AIAgent.run_conversation = wrapped_run  # type: ignore[method-assign]
    _patched = True
    logger.info("model-router: AIAgent capture installed")


def _apply_tier(agent: Any, tier: int) -> bool:
    meta = TIERS.get(tier)
    if not meta or agent is None:
        return False
    model = meta["model"]
    provider = meta["provider"]
    if _same_route(agent, model, provider):
        return True
    try:
        from hermes_cli.config import load_config
        from hermes_cli.model_switch import switch_model as resolve_switch
    except Exception as exc:
        logger.warning("model-router: model_switch import failed: %s", exc)
        return False

    try:
        cfg = load_config() or {}
        # When half-switched (DeepSeek name on xAI host), pass a neutral
        # current_base_url so resolve does not inherit the wrong host.
        cur_base = _agent_base_url(agent)
        cur_prov = getattr(agent, "provider", "") or ""
        if not _base_url_matches_provider(cur_base, provider):
            cur_base = ""
            cur_prov = provider
        result = resolve_switch(
            raw_input=model,
            current_provider=cur_prov,
            current_model=getattr(agent, "model", "") or "",
            current_base_url=cur_base,
            current_api_key=getattr(agent, "api_key", "") or "",
            is_global=False,
            explicit_provider=provider,
            user_providers=cfg.get("providers"),
            custom_providers=cfg.get("custom_providers"),
        )
    except Exception as exc:
        logger.warning("model-router: resolve T%d failed: %s", tier, exc)
        return False

    if not getattr(result, "success", False):
        logger.warning(
            "model-router: resolve T%d failed: %s",
            tier,
            getattr(result, "error_message", "unknown"),
        )
        return False

    resolved_base = (getattr(result, "base_url", None) or "").strip()
    resolved_prov = getattr(result, "target_provider", None) or provider
    if not resolved_base:
        logger.warning(
            "model-router: resolve T%d returned empty base_url for %s/%s",
            tier,
            resolved_prov,
            getattr(result, "new_model", model),
        )
        return False
    if not _base_url_matches_provider(resolved_base, resolved_prov):
        logger.warning(
            "model-router: resolve T%d host mismatch provider=%s base_url=%s",
            tier,
            resolved_prov,
            resolved_base,
        )
        return False

    try:
        agent.switch_model(
            result.new_model,
            resolved_prov,
            result.api_key or "",
            resolved_base,
            result.api_mode or "",
        )
    except Exception as exc:
        logger.warning("model-router: switch_model T%d failed: %s", tier, exc)
        return False

    # switch_model does not touch reasoning_config. Grok's effort must not
    # leak onto Flash/Pro (wasted tokens or provider 400s).
    if tier in (1, 2):
        agent.reasoning_config = None

    # Prefer agent attributes; fall back to what we just applied.
    live_model = getattr(agent, "model", "") or result.new_model
    live_prov = getattr(agent, "provider", "") or resolved_prov
    live_base = getattr(agent, "base_url", "") or resolved_base
    # Some hermes builds keep a nested client; best-effort read.
    try:
        client = getattr(agent, "client", None) or getattr(agent, "_client", None)
        client_base = getattr(client, "base_url", None) if client is not None else None
        if client_base is not None:
            live_base = str(client_base) or live_base
    except Exception:
        pass

    if _norm(live_model) != _norm(result.new_model) or _norm(live_prov) != _norm(
        resolved_prov
    ):
        logger.warning(
            "model-router: post-switch attrs mismatch want=%s/%s got=%s/%s",
            resolved_prov,
            result.new_model,
            live_prov,
            live_model,
        )
        return False
    if not _base_url_matches_provider(live_base, resolved_prov):
        logger.warning(
            "model-router: post-switch base_url still wrong for T%d: provider=%s base_url=%s",
            tier,
            resolved_prov,
            live_base,
        )
        return False

    logger.info(
        "model-router: applied %s → %s / %s (base=%s)",
        meta["label"],
        resolved_prov,
        result.new_model,
        live_base or "-",
    )
    return True


def _detect_explicit_tier(msg: str) -> int | None:
    """Only honor pin-style or short single-tier requests — not meta discussion."""
    text = _strip_platform_prefix(msg)
    reqs: set[int] = set()
    for m in _EXPLICIT_REQ_RE.finditer(text):
        g = m.group(1) or m.group(2)
        if g:
            reqs.add(int(g))
    if reqs:
        return max(reqs)

    mentions = {int(m) for m in _TIER_RE.findall(text)}
    mentions |= {int(m) for m in _TIER_WORD_RE.findall(text)}
    if len(mentions) != 1:
        return None
    # Short messages like "t2 please" / "T3" only.
    words = text.split()
    if len(words) <= 6:
        return next(iter(mentions))
    return None


def _classify(user_message: str, history: list) -> int:
    """Return 1-3. Fail-open to T2 (upstream default) — never silent T1 on errors."""
    try:
        from agent.auxiliary_client import call_llm

        context_turns = []
        n = 0
        for msg in reversed(history or []):
            if isinstance(msg, dict) and msg.get("role") == "assistant":
                content = msg.get("content", "")
                if isinstance(content, str) and content.strip():
                    context_turns.insert(0, content[:300])
                    n += 1
                    if n >= 2:
                        break
        messages = [{"role": "system", "content": _CLASSIFIER}]
        if context_turns:
            messages.append(
                {
                    "role": "user",
                    "content": "[Recent assistant context]\n" + "\n---\n".join(context_turns),
                }
            )
            messages.append({"role": "assistant", "content": "Understood."})
        payload = _strip_platform_prefix(user_message)[:800] or user_message[:800]
        messages.append({"role": "user", "content": payload})
        response = call_llm(
            task="triage_specifier",
            messages=messages,
            max_tokens=3,
            temperature=0.0,
        )
        raw = (response.choices[0].message.content or "").strip()
        digit = re.search(r"[1-3]", raw)
        if digit:
            return int(digit.group())
        logger.warning("model-router: classifier non-digit %r — default T2", raw[:40])
    except Exception as exc:
        logger.warning("model-router: classifier failed (%s) — default T2", exc)
    return 2


def _target_tier(session_id: str, msg: str, history: list) -> int:
    with _lock:
        cached = _last_msg.get(session_id)
        is_new = cached is None or cached[0] != msg
    if not is_new:
        with _lock:
            return _last_tier.get(session_id, 2)

    with _lock:
        _tool_errors[session_id] = 0
        _escalated[session_id] = False
        _tools_this_turn[session_id] = 0
        _user_msg[session_id] = msg
        _ack_turn[session_id] = False

    body = _strip_platform_prefix(msg)
    words = body.split()
    n_sent = _sentence_count(body)
    is_ack = bool(_ACK_RE.match(body) and len(words) <= 6)
    explicit = _detect_explicit_tier(msg)
    reason = "classify"
    if explicit is not None:
        tier = explicit
        reason = "explicit"
    elif is_ack:
        tier = 1
        reason = "ack"
    else:
        tier = _classify(msg, history)
        reason = "classify"
        # Deterministic floor: multi-sentence work is never T1.
        if tier < 2 and n_sent > 1:
            tier = 2
            reason = "classify+multi_sentence_floor"
        elif tier < 2 and len(words) > 12:
            tier = 2
            reason = "classify+length_floor"

    logger.info(
        "model-router: route T%d (%s) words=%d sentences=%d preview=%r",
        tier,
        reason,
        len(words),
        n_sent,
        body[:120],
    )

    with _lock:
        _last_msg[session_id] = (msg, tier)
        _base_tier[session_id] = tier
        _last_tier[session_id] = tier
        _pending[session_id] = tier
        _ack_turn[session_id] = is_ack and explicit is None
    return tier


def _is_grok_model(model: str | None) -> bool:
    m = _norm(model or "")
    return "grok" in m


def _messages_after_tools(messages: list | None) -> bool:
    if not messages:
        return False
    for msg in reversed(messages):
        if not isinstance(msg, dict):
            continue
        role = _norm(str(msg.get("role") or ""))
        if role in ("tool", "function"):
            return True
        if role in ("user", "assistant", "system"):
            return False
    return False


def _force_tier(session_id: str, tier: int, reason: str) -> None:
    """Apply tier and bookkeep; mark escalated when climbing above base."""
    with _lock:
        base = _base_tier.get(session_id, tier)
        prev = _last_tier.get(session_id, base)
        if tier > base:
            _escalated[session_id] = True
        _last_tier[session_id] = tier
        _pending[session_id] = tier
    if tier != prev:
        logger.info(
            "model-router: force %s (was T%d → T%d) — %s",
            TIERS[tier]["label"],
            prev,
            tier,
            reason,
        )
    agent = _get_agent(session_id)
    if agent is not None and _apply_tier(agent, tier):
        with _lock:
            _pending.pop(session_id, None)


def _extract_call_llm_text(response: Any) -> str:
    try:
        choices = getattr(response, "choices", None) or []
        if choices:
            msg = getattr(choices[0], "message", None)
            content = getattr(msg, "content", None) if msg is not None else None
            if isinstance(content, str) and content.strip():
                return content.strip()
            if isinstance(content, list):
                parts = []
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "text":
                        parts.append(str(block.get("text") or ""))
                    elif isinstance(block, str):
                        parts.append(block)
                joined = "".join(parts).strip()
                if joined:
                    return joined
    except Exception:
        pass
    if isinstance(response, dict):
        try:
            return (
                response["choices"][0]["message"]["content"] or ""
            ).strip()
        except Exception:
            pass
    return ""


def _grok_final_voice(session_id: str, draft: str) -> str | None:
    """One-shot Grok rewrite so the user-facing reply is always Grok voice."""
    draft = (draft or "").strip()
    if not draft:
        return None
    with _lock:
        user_msg = _user_msg.get(session_id, "")
        is_ack = _ack_turn.get(session_id, False)
        pinned = _pinned.get(session_id, False)
        last = _last_tier.get(session_id, 1)
    if pinned and last < _FINAL_TIER:
        return None
    if is_ack:
        return None
    # Already produced by Grok — don't double-bill.
    agent = _get_agent(session_id)
    live_model = getattr(agent, "model", "") if agent is not None else ""
    if _is_grok_model(live_model) or last >= _FINAL_TIER:
        return None

    try:
        from agent.auxiliary_client import call_llm

        meta = TIERS[_FINAL_TIER]
        response = call_llm(
            provider=meta["provider"],
            model=meta["model"],
            messages=[
                {"role": "system", "content": _FINAL_VOICE_SYSTEM},
                {
                    "role": "user",
                    "content": (
                        f"User request:\n{(user_msg or '')[:2000]}\n\n"
                        f"Draft reply:\n{draft[:12000]}"
                    ),
                },
            ],
            temperature=0.2,
            max_tokens=min(8192, max(512, len(draft) // 2 + 800)),
        )
        polished = _extract_call_llm_text(response)
        if polished and polished != draft:
            logger.info(
                "model-router: final voice Grok polish (%d→%d chars)",
                len(draft),
                len(polished),
            )
            with _lock:
                _last_tier[session_id] = _FINAL_TIER
            return polished
    except Exception as exc:
        logger.warning("model-router: final voice Grok polish failed: %s", exc)
    return None


def _should_skip(platform: str, kwargs: dict) -> bool:
    plat = (platform or "").strip().lower()
    if plat in _SKIP_PLATFORMS:
        return True
    parent = kwargs.get("parent_session_id") or ""
    if parent:
        return True
    return False


def on_pre_llm_call(
    *,
    user_message: str = "",
    conversation_history: list | None = None,
    model: str = "",
    session_id: str = "",
    platform: str = "",
    **kwargs: Any,
) -> None:
    try:
        if _should_skip(platform, kwargs):
            return
        sid = session_id or ""
        agent = _get_agent(sid)
        if agent is not None and sid:
            bind_agent(sid, agent)

        with _lock:
            pinned = _pinned.get(sid, False)
        if pinned:
            # Still heal half-switch on pinned sessions (WebUI credential refresh).
            if agent is not None:
                with _lock:
                    tier = _last_tier.get(sid) or _base_tier.get(sid) or 3
                _apply_tier(agent, tier)
            return

        msg = (user_message or "").strip()
        if not msg:
            # Empty hook payload still needs host/model coherence repair.
            if agent is not None:
                with _lock:
                    tier = _pending.get(sid) or _last_tier.get(sid) or _FINAL_TIER
                _apply_tier(agent, tier)
            return

        tier = _target_tier(sid, msg, conversation_history or [])
        agent = _get_agent(sid)
        if agent is None:
            logger.warning(
                "model-router: T%d classified, no live agent sid=%s — first call may be Grok",
                tier,
                sid or "-",
            )
            return
        if _apply_tier(agent, tier):
            with _lock:
                _pending.pop(sid, None)
        else:
            logger.warning(
                "model-router: T%d apply failed sid=%s model=%s provider=%s base=%s",
                tier,
                sid or "-",
                getattr(agent, "model", "") or "-",
                getattr(agent, "provider", "") or "-",
                _agent_base_url(agent) or "-",
            )
    except Exception as exc:
        logger.warning("model-router: on_pre_llm_call error: %s", exc, exc_info=True)


def on_pre_api_request(*, session_id: str = "", platform: str = "", **kwargs: Any) -> None:
    """Re-apply route every API call — WebUI credential_refresh half-switches mid-turn."""
    try:
        if _should_skip(platform, kwargs):
            return
        sid = session_id or ""
        with _lock:
            pinned = _pinned.get(sid, False)
            pending = _pending.get(sid)
            current = _last_tier.get(sid)
            tools_n = _tools_this_turn.get(sid, 0)

        agent = _get_agent(sid)
        if agent is not None and sid:
            bind_agent(sid, agent)

        if pinned:
            if agent is not None and current:
                _apply_tier(agent, current)
            return

        # Post-tool API calls: always Grok for synthesis / final.
        msgs = kwargs.get("request_messages") or kwargs.get("conversation_history")
        after_tools = tools_n > 0 or _messages_after_tools(msgs if isinstance(msgs, list) else None)
        if after_tools:
            _force_tier(sid, _FINAL_TIER, "post-tool synthesis → Grok")
            return

        target = pending or current
        if not target:
            # No classification yet — still heal deepseek-on-xAI wreckage.
            if agent is not None:
                prov = _norm(getattr(agent, "provider", "") or "")
                base = _agent_base_url(agent)
                if prov and not _base_url_matches_provider(base, prov):
                    # Prefer T2 heal for deepseek names, T3 for grok names.
                    m = _norm(getattr(agent, "model", "") or "")
                    heal = 3 if "grok" in m else 2 if "deepseek" in m else _FINAL_TIER
                    logger.warning(
                        "model-router: uncategorized half-switch heal→T%d model=%s base=%s",
                        heal,
                        m,
                        base,
                    )
                    _apply_tier(agent, heal)
            return
        if agent is None:
            return
        if _apply_tier(agent, target):
            with _lock:
                _pending.pop(sid, None)
    except Exception as exc:
        logger.warning("model-router: on_pre_api_request error: %s", exc, exc_info=True)


def on_post_tool_call(
    *,
    tool_name: str = "",
    result: str | None = None,
    session_id: str = "",
    **kwargs: Any,
) -> None:
    try:
        sid = session_id or ""
        if not sid:
            return
        with _lock:
            if _pinned.get(sid, False):
                return
            _tools_this_turn[sid] = _tools_this_turn.get(sid, 0) + 1

        is_error = False
        if result is not None:
            # Hook may pass dict/list/ToolResult — never slice non-str (TypeError: unhashable slice).
            if isinstance(result, str):
                head_src = result
            else:
                try:
                    import json as _json
                    head_src = _json.dumps(result, default=str)
                except Exception:
                    head_src = str(result)
            head = head_src[:500].lower()
            if (
                '"error"' in head
                or '"failed"' in head
                or head_src.startswith("Error")
                or ('"exit_code": ' in head and '"exit_code": 0' not in head and '"exit_code": null' not in head)
            ):
                is_error = True

        with _lock:
            if is_error:
                _tool_errors[sid] = _tool_errors.get(sid, 0) + 1
            else:
                _tool_errors[sid] = 0
            count = _tool_errors.get(sid, 0)
            current = _last_tier.get(sid, 1)

        # Tool-error escalation may climb onto Grok.
        if is_error and count >= _ESCALATION_ERROR_THRESHOLD and current < _ESCALATE_MAX:
            new_tier = min(current + 1, _ESCALATE_MAX)
            _force_tier(sid, new_tier, f"auto-escalate after {count} tool errors")
            with _lock:
                _tool_errors[sid] = 0
            logger.info("model-router: auto-escalate T%d→T%d after tool errors", current, new_tier)
            return

        # Even without errors: next API call after tools is Grok (final voice path).
        if current < _FINAL_TIER:
            _force_tier(sid, _FINAL_TIER, f"after tool {tool_name or '?'} → Grok final")
    except Exception as exc:
        logger.warning("model-router: on_post_tool_call error: %s", exc, exc_info=True)


def on_transform_llm_output(
    *,
    response_text: str = "",
    session_id: str = "",
    model: str = "",
    platform: str = "",
    **kwargs: Any,
) -> str | None:
    """If the turn still ends off-Grok, polish once so the user always hears Grok."""
    try:
        if _should_skip(platform, kwargs):
            return None
        sid = session_id or ""
        if not sid or not (response_text or "").strip():
            return None
        if _is_grok_model(model):
            return None
        return _grok_final_voice(sid, response_text)
    except Exception as exc:
        logger.warning("model-router: on_transform_llm_output error: %s", exc, exc_info=True)
        return None


def on_post_llm_call(*, session_id: str = "", model: str = "", **kwargs: Any) -> None:
    try:
        sid = session_id or ""
        agent = _get_agent(sid)
        if agent is None:
            return
        with _lock:
            if _pinned.get(sid, False):
                # Leave pin alone; clear per-turn counters.
                _tools_this_turn[sid] = 0
                return
            was = _escalated.get(sid, False)
            base = _base_tier.get(sid, 1)
            current = _last_tier.get(sid, 1)
            _tools_this_turn[sid] = 0

        # De-escalate bookkeeping back to work base, then rest on Grok (soul).
        if was and current > base:
            with _lock:
                _escalated[sid] = False
                _last_tier[sid] = base
                _pending[sid] = base
            logger.info(
                "model-router: de-escalate T%d→T%d (base), then rest on Grok",
                current,
                base,
            )

        # Resting state is always Grok so the lineage/default remains Grok between turns.
        # Next pre_llm_call re-classifies and downgrades for work.
        with _lock:
            _last_tier[sid] = _FINAL_TIER
            _pending[sid] = _FINAL_TIER
        if _apply_tier(agent, _FINAL_TIER):
            with _lock:
                _pending.pop(sid, None)
    except Exception as exc:
        logger.warning("model-router: on_post_llm_call error: %s", exc, exc_info=True)


def _cmd_pin(raw_args: str, tier: int) -> str:
    del raw_args
    agent = _get_agent("")
    sid = ""
    if agent is not None:
        sid = getattr(agent, "session_id", "") or ""
        bind_agent(sid, agent)
    if not sid:
        with _lock:
            if _last_bound is not None:
                sid = _last_bound[0]
    meta = TIERS[tier]
    with _lock:
        _pinned[sid] = True
        _last_tier[sid] = tier
        _base_tier[sid] = tier
        _pending[sid] = tier
        _ack_turn[sid] = False
    if agent is not None and _apply_tier(agent, tier):
        with _lock:
            _pending.pop(sid, None)
        return f"Pinned to {meta['label']} ({meta['provider']} / {meta['model']}). Auto-routing paused. /auto to resume."
    return (
        f"Pinned to {meta['label']} ({meta['provider']} / {meta['model']}). "
        "Will apply on the next turn if no live agent was bound."
    )


def _cmd_auto(raw_args: str) -> str:
    del raw_args
    agent = _get_agent("")
    sid = getattr(agent, "session_id", "") or "" if agent is not None else ""
    with _lock:
        was = _pinned.pop(sid, False)
        _last_msg.pop(sid, None)
        _ack_turn.pop(sid, None)
        _tools_this_turn.pop(sid, None)
    if was:
        return "Auto routing resumed. Next turn is classified on Flash."
    return "Auto routing already active."


def _deferred_install_capture() -> None:
    """Install the AIAgent capture once run_agent finishes importing."""
    for _ in range(10):
        try:
            _install_agent_capture()
            logger.info("model-router: AIAgent capture installed (attempt %d)", _ + 1)
            return
        except AttributeError:  # run_agent still initializing
            time.sleep(1.0)
        except Exception as exc:
            logger.warning("model-router: AIAgent capture install failed: %s", exc)
            return
    logger.warning("model-router: AIAgent capture NOT installed after retries (run_agent never ready)")


def register(ctx: Any) -> None:
    global _manager
    _manager = getattr(ctx, "_manager", None)
    _attach_file_handler()
    threading.Thread(target=_deferred_install_capture, daemon=True).start()
    ctx.register_hook("pre_llm_call", on_pre_llm_call)
    ctx.register_hook("pre_api_request", on_pre_api_request)
    ctx.register_hook("post_tool_call", on_post_tool_call)
    ctx.register_hook("transform_llm_output", on_transform_llm_output)
    ctx.register_hook("post_llm_call", on_post_llm_call)
    ctx.register_command("t1", lambda args: _cmd_pin(args, 1), "Pin session to T1 DeepSeek Flash")
    ctx.register_command("t2", lambda args: _cmd_pin(args, 2), "Pin session to T2 DeepSeek Pro")
    ctx.register_command("t3", lambda args: _cmd_pin(args, 3), "Pin session to T3 Grok 4.5")
    ctx.register_command("auto", _cmd_auto, "Resume model-router auto routing")
    logger.info(
        "model-router: T1 flash / T2 pro / T3 grok | final=Grok | escalate≤T3 | "
        "/t1 /t2 /t3 /auto | no SOUL writes"
    )
