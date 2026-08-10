"""model-router — 3-tier cost routing for rocknas Hermes.

T1  deepseek / deepseek-v4-flash   cheap daily driver (old T1+T2)
T2  deepseek / deepseek-v4-pro     coding, review, design (old T3+T4)
T3  xai-oauth / grok-4.5           high-stakes only (old T5)

No Hermes/WebUI core file edits. Live switch uses AIAgent.switch_model via
the same hermes_cli.model_switch resolver as /model (native providers, not
OpenRouter slugs). Agent capture is a register()-time monkeypatch so
gateway/WebUI have a live handle — same class of workaround as
tool-call-coherency.

Does not write SOUL.md.
"""
from __future__ import annotations

import logging
import re
import threading
from typing import Any

logger = logging.getLogger("plugins.model-router")

TIERS: dict[int, dict[str, Any]] = {
    1: {
        "label": "T1 Flash",
        "model": "deepseek-v4-flash",
        "provider": "deepseek",
        "role": "cheap daily driver",
    },
    2: {
        "label": "T2 Pro",
        "model": "deepseek-v4-pro",
        "provider": "deepseek",
        "role": "coding, review, architecture",
    },
    3: {
        "label": "T3 Grok",
        "model": "grok-4.5",
        "provider": "xai-oauth",
        "role": "high-stakes reasoning only",
    },
}

# Never auto-escalate onto Grok. Classification can still pick T3.
_ESCALATE_MAX = 2
_ESCALATION_ERROR_THRESHOLD = 2

_SKIP_PLATFORMS = frozenset({"cron"})

_TIER_RE = re.compile(r"(?:^|(?<=\s)|(?<=\())[tT]([1-3])(?:\b|(?=\)))")
_TIER_WORD_RE = re.compile(r"(?:^|(?<=\s)|(?<=\())tier\s*([1-3])", re.IGNORECASE)
_ACK_RE = re.compile(
    r"^(ok|okay|thanks|thank you|thx|got it|understood|sure|yes|no|yep|nope|"
    r"alright|cool|great|nice|perfect|done|noted|ack|hello|hi|hey)"
    r"[!?.]*$",
    re.IGNORECASE,
)

_CLASSIFIER = """\
You assign a single routing tier (1-3) for the user's message.

1 = Flash: short acks, status, titles, day-to-day Q&A, docs, file ops, standard coding/research
2 = Pro: debugging, code review, large-doc synthesis, architecture, migration, multi-step design
3 = Grok: security/crypto, algorithmic optimization, financial modelling, high-stakes work with many interacting constraints

Rules:
- When unsure between two tiers, pick the LOWER one
- Tier 3 is rare. Do not use it for ordinary planning or coding.
- Respond with ONLY a digit: 1, 2, or 3.
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
_manager = None
_patched = False


def _norm(s: str) -> str:
    return (s or "").strip().lower()


def _same_route(agent: Any, model: str, provider: str) -> bool:
    return _norm(getattr(agent, "model", "")) == _norm(model) and _norm(
        getattr(agent, "provider", "")
    ) == _norm(provider)


def bind_agent(session_id: str, agent: Any) -> None:
    if agent is None:
        return
    global _last_bound
    with _lock:
        if session_id:
            _live_agents[session_id] = agent
        _last_bound = (session_id or "", agent)


def _get_agent(session_id: str = "") -> Any | None:
    with _lock:
        if session_id and session_id in _live_agents:
            return _live_agents[session_id]
        bound = _last_bound
    if _manager is not None:
        try:
            cli = getattr(_manager, "_cli_ref", None)
            agent = getattr(cli, "agent", None) if cli else None
            if agent is not None:
                if not session_id:
                    return agent
                if (getattr(agent, "session_id", "") or "") == session_id:
                    return agent
        except Exception:
            pass
    if not session_id and bound is not None:
        return bound[1]
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
        sid = getattr(self, "session_id", None) or ""
        if sid:
            bind_agent(sid, self)

    wrapped_init._model_router_wrapped = True  # type: ignore[attr-defined]
    run_agent.AIAgent.__init__ = wrapped_init  # type: ignore[method-assign]

    orig_run = run_agent.AIAgent.run_conversation

    def wrapped_run(self, *args, **kwargs):
        sid = getattr(self, "session_id", None) or ""
        if sid:
            bind_agent(sid, self)
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
        result = resolve_switch(
            raw_input=model,
            current_provider=getattr(agent, "provider", "") or "",
            current_model=getattr(agent, "model", "") or "",
            current_base_url=getattr(agent, "base_url", "") or "",
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

    try:
        agent.switch_model(
            result.new_model,
            result.target_provider,
            result.api_key or "",
            result.base_url or "",
            result.api_mode or "",
        )
    except Exception as exc:
        logger.warning("model-router: switch_model T%d failed: %s", tier, exc)
        return False

    # switch_model does not touch reasoning_config. Grok's effort must not
    # leak onto Flash/Pro (wasted tokens or provider 400s).
    if tier in (1, 2):
        agent.reasoning_config = None

    logger.info(
        "model-router: applied %s → %s / %s",
        meta["label"],
        result.target_provider,
        result.new_model,
    )
    return True


def _detect_explicit_tier(msg: str) -> int | None:
    mentions = {int(m) for m in _TIER_RE.findall(msg)}
    mentions |= {int(m) for m in _TIER_WORD_RE.findall(msg)}
    if len(mentions) >= 3:
        return None
    if mentions:
        return max(mentions)
    return None


def _classify(user_message: str, history: list) -> int:
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
        messages.append({"role": "user", "content": user_message[:800]})
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
    except Exception as exc:
        logger.warning("model-router: classifier failed (%s) — default T1", exc)
    return 1


def _target_tier(session_id: str, msg: str, history: list) -> int:
    with _lock:
        cached = _last_msg.get(session_id)
        is_new = cached is None or cached[0] != msg
    if not is_new:
        with _lock:
            return _last_tier.get(session_id, 1)

    with _lock:
        _tool_errors[session_id] = 0
        _escalated[session_id] = False

    explicit = _detect_explicit_tier(msg)
    if explicit is not None:
        tier = explicit
    elif _ACK_RE.match(msg.strip()) and len(msg.split()) <= 6:
        tier = 1
    else:
        tier = _classify(msg, history)

    with _lock:
        _last_msg[session_id] = (msg, tier)
        _base_tier[session_id] = tier
        _last_tier[session_id] = tier
        _pending[session_id] = tier
    return tier


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
    if _should_skip(platform, kwargs):
        return
    sid = session_id or ""
    agent = _get_agent(sid)
    if agent is not None and sid:
        bind_agent(sid, agent)

    with _lock:
        pinned = _pinned.get(sid, False)
    if pinned:
        return

    msg = (user_message or "").strip()
    if not msg:
        return

    tier = _target_tier(sid, msg, conversation_history or [])
    agent = _get_agent(sid)
    if agent is None:
        # Concession: first API call of this turn may still be Grok.
        logger.info(
            "model-router: T%d classified, no live agent yet — will apply on next API call",
            tier,
        )
        return
    if _apply_tier(agent, tier):
        with _lock:
            _pending.pop(sid, None)


def on_pre_api_request(*, session_id: str = "", platform: str = "", **kwargs: Any) -> None:
    if _should_skip(platform, kwargs):
        return
    sid = session_id or ""
    with _lock:
        if _pinned.get(sid, False):
            return
        pending = _pending.get(sid)
        current = _last_tier.get(sid)
    target = pending or current
    if not target:
        return
    agent = _get_agent(sid)
    if agent is None:
        return
    if _apply_tier(agent, target):
        with _lock:
            _pending.pop(sid, None)


def on_post_tool_call(
    *,
    tool_name: str = "",
    result: str | None = None,
    session_id: str = "",
    **kwargs: Any,
) -> None:
    sid = session_id or ""
    if not sid:
        return
    with _lock:
        if _pinned.get(sid, False):
            return

    is_error = False
    if result is not None:
        head = result[:500].lower()
        if (
            '"error"' in head
            or '"failed"' in head
            or result.startswith("Error")
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

    if is_error and count >= _ESCALATION_ERROR_THRESHOLD and current < _ESCALATE_MAX:
        new_tier = min(current + 1, _ESCALATE_MAX)
        with _lock:
            _last_tier[sid] = new_tier
            _pending[sid] = new_tier
            _tool_errors[sid] = 0
            _escalated[sid] = True
        agent = _get_agent(sid)
        if agent is not None:
            _apply_tier(agent, new_tier)
            with _lock:
                _pending.pop(sid, None)
        logger.info("model-router: auto-escalate T%d→T%d after tool errors", current, new_tier)


def on_post_llm_call(*, session_id: str = "", model: str = "", **kwargs: Any) -> None:
    sid = session_id or ""
    agent = _get_agent(sid)
    if agent is None:
        return
    with _lock:
        if _pinned.get(sid, False):
            return
        was = _escalated.get(sid, False)
        base = _base_tier.get(sid, 1)
        current = _last_tier.get(sid, 1)
    if was and current > base:
        with _lock:
            _escalated[sid] = False
            _last_tier[sid] = base
            _pending[sid] = base
        _apply_tier(agent, base)
        with _lock:
            _pending.pop(sid, None)


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
    if was:
        return "Auto routing resumed. Next turn is classified on Flash."
    return "Auto routing already active."


def register(ctx: Any) -> None:
    global _manager
    _manager = getattr(ctx, "_manager", None)
    _install_agent_capture()
    ctx.register_hook("pre_llm_call", on_pre_llm_call)
    ctx.register_hook("pre_api_request", on_pre_api_request)
    ctx.register_hook("post_tool_call", on_post_tool_call)
    ctx.register_hook("post_llm_call", on_post_llm_call)
    ctx.register_command("t1", lambda args: _cmd_pin(args, 1), "Pin session to T1 DeepSeek Flash")
    ctx.register_command("t2", lambda args: _cmd_pin(args, 2), "Pin session to T2 DeepSeek Pro")
    ctx.register_command("t3", lambda args: _cmd_pin(args, 3), "Pin session to T3 Grok 4.5")
    ctx.register_command("auto", _cmd_auto, "Resume model-router auto routing")
    logger.info(
        "model-router: T1 flash / T2 pro / T3 grok | /t1 /t2 /t3 /auto | no SOUL writes"
    )
