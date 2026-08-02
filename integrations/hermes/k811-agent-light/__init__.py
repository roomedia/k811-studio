"""Hermes lifecycle adapter for K811 Studio agent lighting."""

from __future__ import annotations

import json
import logging
import os
import subprocess
from pathlib import Path
from typing import Any, Callable

EVENTS = (
    "on_session_start",
    "pre_llm_call",
    "post_llm_call",
    "pre_approval_request",
    "post_approval_response",
    "api_request_error",
)
DEFAULT_HELPER = Path("/Applications/K811 Studio.app/Contents/Helpers/k811-agent-event")
LOGGER = logging.getLogger(__name__)


def _helper_path() -> Path:
    override = os.environ.get("K811_AGENT_EVENT_HELPER")
    return Path(override) if override else DEFAULT_HELPER


def _payload_for_event(event_name: str, kwargs: dict[str, Any]) -> dict[str, Any]:
    session_id = kwargs.get("session_id") or kwargs.get("session_key") or ""
    extra: dict[str, Any] = {}
    if event_name == "post_llm_call":
        response = kwargs.get("assistant_response")
        if isinstance(response, str):
            extra["assistant_response"] = response
    return {
        "hook_event_name": event_name,
        "session_id": str(session_id),
        "extra": extra,
    }


def _invoke_helper(event_name: str, kwargs: dict[str, Any]) -> None:
    helper = _helper_path()
    try:
        result = subprocess.run(
            [str(helper), "hook", "hermes"],
            input=json.dumps(_payload_for_event(event_name, kwargs), ensure_ascii=False),
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as error:
        LOGGER.warning("K811 agent light helper failed to run: %s", error)
        return

    stderr = result.stderr.strip()
    if result.returncode != 0 or stderr:
        detail = stderr[:400] or f"exit status {result.returncode}"
        LOGGER.warning("K811 agent light helper reported a failure: %s", detail)


def _make_hook(event_name: str) -> Callable[..., None]:
    def _hook(**kwargs: Any) -> None:
        _invoke_helper(event_name, kwargs)

    return _hook


def register(ctx: Any) -> None:
    for event_name in EVENTS:
        ctx.register_hook(event_name, _make_hook(event_name))
