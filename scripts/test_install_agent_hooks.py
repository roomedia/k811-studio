from __future__ import annotations

import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "scripts/install-agent-hooks.py"


def fake_app(root: Path) -> Path:
    app = root / "K811 Studio.app"
    helper = app / "Contents/Helpers/k811-agent-event"
    helper.parent.mkdir(parents=True)
    helper.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    helper.chmod(helper.stat().st_mode | stat.S_IXUSR)
    return app


class InstallAgentHooksTests(unittest.TestCase):
    def test_installs_every_source_idempotently(self) -> None:
        with tempfile.TemporaryDirectory(prefix="k811-hook-installer-") as directory:
            root = Path(directory)
            home = root / "home"
            app = fake_app(root)

            environment = dict(os.environ)
            environment["HOME"] = str(home)
            command = [str(INSTALLER), "--app", str(app)]

            preview = subprocess.run(
                [*command, "--dry-run"],
                check=True,
                capture_output=True,
                text=True,
                env=environment,
            )
            preview_receipt = json.loads(preview.stdout)
            self.assertFalse(preview_receipt["apply"])
            self.assertTrue(preview_receipt["opencode"]["changed"])
            self.assertFalse((home / ".claude").exists())
            self.assertFalse((home / ".codex").exists())

            applied = subprocess.run(
                [*command, "--apply"],
                check=True,
                capture_output=True,
                text=True,
                env=environment,
            )
            applied_receipt = json.loads(applied.stdout)
            self.assertTrue(applied_receipt["apply"])
            self.assertEqual(
                ["Notification", "UserPromptSubmit", "SessionStart", "SessionEnd", "Stop", "StopFailure"],
                applied_receipt["claude"]["events_added"],
            )
            self.assertEqual(
                ["PermissionRequest", "UserPromptSubmit", "SessionStart", "Stop"],
                applied_receipt["codex"]["events_added"],
            )
            self.assertTrue((home / ".config/opencode/plugins/k811-agent-light.js").is_file())

            repeated = subprocess.run(
                [*command, "--apply"],
                check=True,
                capture_output=True,
                text=True,
                env=environment,
            )
            repeated_receipt = json.loads(repeated.stdout)
            self.assertEqual([], repeated_receipt["claude"]["events_added"])
            self.assertEqual([], repeated_receipt["codex"]["events_added"])
            self.assertFalse(repeated_receipt["opencode"]["changed"])

    def test_source_scope_does_not_mutate_other_agent_configs(self) -> None:
        with tempfile.TemporaryDirectory(prefix="k811-hook-scope-") as directory:
            root = Path(directory)
            home = root / "home"
            app = fake_app(root)
            environment = dict(os.environ)
            environment["HOME"] = str(home)

            result = subprocess.run(
                [
                    str(INSTALLER),
                    "--app",
                    str(app),
                    "--source",
                    "opencode",
                    "--apply",
                ],
                check=True,
                capture_output=True,
                text=True,
                env=environment,
            )
            receipt = json.loads(result.stdout)
            self.assertEqual(["opencode"], receipt["selected_sources"])
            self.assertTrue((home / ".config/opencode/plugins/k811-agent-light.js").is_file())
            self.assertFalse((home / ".claude").exists())
            self.assertFalse((home / ".codex").exists())

    def test_hermes_is_no_longer_an_installable_source(self) -> None:
        with tempfile.TemporaryDirectory(prefix="k811-hook-hermes-") as directory:
            root = Path(directory)
            app = fake_app(root)
            environment = dict(os.environ)
            environment["HOME"] = str(root / "home")

            result = subprocess.run(
                [str(INSTALLER), "--app", str(app), "--source", "hermes", "--dry-run"],
                capture_output=True,
                text=True,
                env=environment,
            )
            self.assertNotEqual(0, result.returncode)
            self.assertIn("hermes", result.stderr)


if __name__ == "__main__":
    unittest.main()
