#!/usr/bin/env python3
"""Install K811 agent-light hooks without replacing existing agent hooks."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

DEFAULT_APP = Path("/Applications/K811 Studio.app")
AGENT_SOURCES = ("claude", "codex", "opencode", "hermes")


def hook_group(command: str, matcher: str | None = None) -> dict:
    group = {
        "hooks": [
            {
                "type": "command",
                "command": command,
                "timeout": 5,
            }
        ]
    }
    if matcher is not None:
        group["matcher"] = matcher
    return group


def contains_command(groups: object, marker: str) -> bool:
    if not isinstance(groups, list):
        return False
    for group in groups:
        if not isinstance(group, dict):
            continue
        for handler in group.get("hooks", []):
            if isinstance(handler, dict) and marker in str(handler.get("command", "")):
                return True
    return False


def merge_hook(config: dict, event: str, group: dict, marker: str) -> bool:
    hooks = config.setdefault("hooks", {})
    groups = hooks.setdefault(event, [])
    if contains_command(groups, marker):
        return False
    groups.append(group)
    return True


def load_json(path: Path) -> dict:
    if not path.exists():
        return {}
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return value


def write_json_atomically(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = path.stat().st_mode & 0o777 if path.exists() else 0o600
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False) as temporary:
        json.dump(value, temporary, ensure_ascii=False, indent=2, sort_keys=False)
        temporary.write("\n")
        temporary_path = Path(temporary.name)
    os.chmod(temporary_path, mode)
    os.replace(temporary_path, path)


def write_text_atomically(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False) as temporary:
        temporary.write(value)
        temporary_path = Path(temporary.name)
    os.chmod(temporary_path, 0o600)
    os.replace(temporary_path, path)


def opencode_plugin(helper: Path) -> str:
    helper_literal = json.dumps(str(helper))
    return f'''// Managed by K811 Studio's install-agent-hooks.py.
const helper = {helper_literal}

function sessionID(event) {{
  const properties = event.properties ?? {{}}
  return properties.sessionID
    ?? properties.sessionId
    ?? properties.session?.id
    ?? properties.info?.id
}}

async function emit(kind, event) {{
  const args = [helper, "emit", "--source", "opencode", "--event", kind]
  const session = sessionID(event)
  if (session) args.push("--session", String(session))
  const child = Bun.spawn(args, {{ stdout: "ignore", stderr: "ignore" }})
  await child.exited
}}

export const K811AgentLight = async () => ({{
  event: async ({{ event }}) => {{
    switch (event.type) {{
      case "session.idle":
        await emit("completed", event)
        break
      case "session.error":
        await emit("failure", event)
        break
      case "permission.asked":
        await emit("approval", event)
        break
      case "permission.replied":
        await emit("clear", event)
        break
      case "session.status":
        if (event.properties?.status?.type === "busy") {{
          await emit("clear", event)
        }}
        break
    }}
  }},
}})
'''


def main() -> int:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--apply", action="store_true", help="write hook configuration")
    mode.add_argument("--dry-run", action="store_true", help="preview only (default)")
    parser.add_argument("--app", type=Path, default=DEFAULT_APP)
    parser.add_argument("--hermes", type=Path, help="Hermes CLI path (default: discover on PATH)")
    parser.add_argument(
        "--source",
        action="append",
        choices=AGENT_SOURCES,
        help="install only this source (repeatable; default: all)",
    )
    args = parser.parse_args()
    selected_sources = set(args.source or AGENT_SOURCES)

    helper = args.app / "Contents/Helpers/k811-agent-event"
    if not helper.is_file() or not os.access(helper, os.X_OK):
        parser.error(f"missing executable helper: {helper}")

    hermes = args.hermes or (Path(command) if (command := shutil.which("hermes")) else None)
    if args.apply and "hermes" in selected_sources and hermes is None:
        parser.error("Hermes CLI was not found on PATH; pass --hermes")

    repository_root = Path(__file__).resolve().parents[1]
    hermes_source = repository_root / "integrations/hermes/k811-agent-light"
    hermes_files = {
        name: (hermes_source / name).read_text(encoding="utf-8")
        for name in ("plugin.yaml", "__init__.py")
    }

    home = Path.home()
    hermes_home = Path(os.environ.get("HERMES_HOME", home / ".hermes")).expanduser()
    claude_path = home / ".claude/settings.json"
    codex_path = home / ".codex/hooks.json"
    opencode_path = home / ".config/opencode/plugins/k811-agent-light.js"
    hermes_path = hermes_home / "plugins/k811-agent-light"
    marker = "k811-agent-event"

    claude = load_json(claude_path)
    claude_command = f"'{helper}' hook claude"
    claude_changes = []
    claude_specs = [
        (
            "Notification",
            hook_group(
                claude_command,
                "^(idle_prompt|agent_completed|permission_prompt|elicitation_dialog|agent_needs_input|elicitation_complete|elicitation_response)$",
            ),
        ),
        ("UserPromptSubmit", hook_group(claude_command)),
        ("SessionStart", hook_group(claude_command)),
        ("StopFailure", hook_group(claude_command)),
    ]
    if "claude" in selected_sources:
        for event, group in claude_specs:
            if merge_hook(claude, event, group, marker):
                claude_changes.append(event)

    codex = load_json(codex_path)
    codex_command = f"'{helper}' hook codex"
    codex_changes = []
    if "codex" in selected_sources:
        for event in ["PermissionRequest", "UserPromptSubmit", "SessionStart", "Stop"]:
            if merge_hook(codex, event, hook_group(codex_command), marker):
                codex_changes.append(event)

    plugin_contents = opencode_plugin(helper)
    opencode_changed = "opencode" in selected_sources and (
        not opencode_path.exists() or opencode_path.read_text() != plugin_contents
    )
    hermes_changed = "hermes" in selected_sources and any(
        not (hermes_path / name).exists()
        or (hermes_path / name).read_text(encoding="utf-8") != contents
        for name, contents in hermes_files.items()
    )

    receipt = {
        "apply": bool(args.apply),
        "selected_sources": sorted(selected_sources),
        "claude": {"path": str(claude_path), "events_added": claude_changes},
        "codex": {
            "path": str(codex_path),
            "events_added": codex_changes,
            "requires_hook_trust_review": bool(codex_changes),
        },
        "opencode": {"path": str(opencode_path), "changed": opencode_changed},
        "hermes": {
            "path": str(hermes_path),
            "changed": hermes_changed,
            "enable_command": [
                str(hermes) if hermes is not None else "hermes",
                "plugins",
                "enable",
                "--no-allow-tool-override",
                "k811-agent-light",
            ],
            "restart_required": True,
        },
    }

    if args.apply:
        if claude_changes:
            write_json_atomically(claude_path, claude)
        if codex_changes:
            write_json_atomically(codex_path, codex)
        if opencode_changed:
            opencode_path.parent.mkdir(parents=True, exist_ok=True)
            opencode_path.write_text(plugin_contents)
            os.chmod(opencode_path, 0o600)
        if "hermes" in selected_sources:
            if hermes_changed:
                for name, contents in hermes_files.items():
                    write_text_atomically(hermes_path / name, contents)
            subprocess.run(
                [
                    str(hermes),
                    "plugins",
                    "enable",
                    "--no-allow-tool-override",
                    "k811-agent-light",
                ],
                check=True,
                capture_output=True,
                text=True,
            )

    print(json.dumps(receipt, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
