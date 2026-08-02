from __future__ import annotations

import importlib.util
import json
import os
import stat
import tempfile
import unittest
from pathlib import Path

PLUGIN_PATH = Path(__file__).with_name("__init__.py")
SPEC = importlib.util.spec_from_file_location("k811_agent_light", PLUGIN_PATH)
assert SPEC is not None and SPEC.loader is not None
plugin = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(plugin)


class FakeContext:
    def __init__(self) -> None:
        self.hooks = []

    def register_hook(self, name, callback) -> None:
        self.hooks.append((name, callback))


class K811AgentLightPluginTests(unittest.TestCase):
    def test_register_exposes_only_declared_lifecycle_hooks(self) -> None:
        context = FakeContext()
        plugin.register(context)
        self.assertEqual(list(plugin.EVENTS), [name for name, _ in context.hooks])

    def test_payload_forwards_only_lifecycle_identity_and_final_response(self) -> None:
        pre_payload = plugin._payload_for_event(
            "pre_llm_call",
            {"session_id": "session-1", "user_message": "private prompt", "tools": ["terminal"]},
        )
        self.assertEqual(
            {"hook_event_name": "pre_llm_call", "session_id": "session-1", "extra": {}},
            pre_payload,
        )

        post_payload = plugin._payload_for_event(
            "post_llm_call",
            {
                "session_id": "session-1",
                "user_message": "private prompt",
                "assistant_response": "끝났어?",
            },
        )
        self.assertEqual(
            {
                "hook_event_name": "post_llm_call",
                "session_id": "session-1",
                "extra": {"assistant_response": "끝났어?"},
            },
            post_payload,
        )
        self.assertNotIn("user_message", json.dumps(post_payload, ensure_ascii=False))

    def test_hook_invokes_helper_with_hermes_protocol(self) -> None:
        with tempfile.TemporaryDirectory(prefix="k811-hermes-plugin-") as directory:
            directory_path = Path(directory)
            receipt = directory_path / "receipt.json"
            helper = directory_path / "helper.py"
            helper.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, sys\n"
                "payload = json.load(sys.stdin)\n"
                "with open(os.environ['K811_TEST_RECEIPT'], 'w') as output:\n"
                "    json.dump({'args': sys.argv[1:], 'payload': payload}, output)\n"
                "print('{}')\n",
                encoding="utf-8",
            )
            helper.chmod(helper.stat().st_mode | stat.S_IXUSR)

            previous_helper = os.environ.get("K811_AGENT_EVENT_HELPER")
            previous_receipt = os.environ.get("K811_TEST_RECEIPT")
            os.environ["K811_AGENT_EVENT_HELPER"] = str(helper)
            os.environ["K811_TEST_RECEIPT"] = str(receipt)
            try:
                plugin._make_hook("pre_approval_request")(
                    session_key="approval-session",
                    command="private command",
                )
            finally:
                if previous_helper is None:
                    os.environ.pop("K811_AGENT_EVENT_HELPER", None)
                else:
                    os.environ["K811_AGENT_EVENT_HELPER"] = previous_helper
                if previous_receipt is None:
                    os.environ.pop("K811_TEST_RECEIPT", None)
                else:
                    os.environ["K811_TEST_RECEIPT"] = previous_receipt

            captured = json.loads(receipt.read_text(encoding="utf-8"))
            self.assertEqual(["hook", "hermes"], captured["args"])
            self.assertEqual(
                {
                    "hook_event_name": "pre_approval_request",
                    "session_id": "approval-session",
                    "extra": {},
                },
                captured["payload"],
            )
            self.assertNotIn("private command", receipt.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
