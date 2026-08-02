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
PLUGIN_SOURCE = ROOT / "integrations/hermes/k811-agent-light"


class InstallAgentHooksTests(unittest.TestCase):
    def test_installs_and_enables_hermes_plugin_idempotently(self) -> None:
        with tempfile.TemporaryDirectory(prefix="k811-hook-installer-") as directory:
            root = Path(directory)
            home = root / "home"
            app = root / "K811 Studio.app"
            helper = app / "Contents/Helpers/k811-agent-event"
            helper.parent.mkdir(parents=True)
            helper.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            helper.chmod(helper.stat().st_mode | stat.S_IXUSR)

            hermes_receipt = root / "hermes-args.json"
            fake_hermes = root / "hermes"
            fake_hermes.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, sys\n"
                "with open(os.environ['K811_TEST_HERMES_RECEIPT'], 'w') as output:\n"
                "    json.dump(sys.argv[1:], output)\n",
                encoding="utf-8",
            )
            fake_hermes.chmod(fake_hermes.stat().st_mode | stat.S_IXUSR)

            environment = dict(os.environ)
            environment.update(
                {
                    "HOME": str(home),
                    "HERMES_HOME": str(home / ".hermes"),
                    "K811_TEST_HERMES_RECEIPT": str(hermes_receipt),
                }
            )
            command = [
                str(INSTALLER),
                "--app",
                str(app),
                "--hermes",
                str(fake_hermes),
            ]

            preview = subprocess.run(
                [*command, "--dry-run"],
                check=True,
                capture_output=True,
                text=True,
                env=environment,
            )
            preview_receipt = json.loads(preview.stdout)
            self.assertFalse(preview_receipt["apply"])
            self.assertTrue(preview_receipt["hermes"]["changed"])
            self.assertFalse((home / ".hermes/plugins/k811-agent-light").exists())
            self.assertFalse(hermes_receipt.exists())

            applied = subprocess.run(
                [*command, "--apply"],
                check=True,
                capture_output=True,
                text=True,
                env=environment,
            )
            applied_receipt = json.loads(applied.stdout)
            self.assertTrue(applied_receipt["apply"])
            self.assertTrue(applied_receipt["hermes"]["changed"])
            self.assertEqual(
                ["plugins", "enable", "--no-allow-tool-override", "k811-agent-light"],
                json.loads(hermes_receipt.read_text(encoding="utf-8")),
            )

            installed = home / ".hermes/plugins/k811-agent-light"
            for name in ("plugin.yaml", "__init__.py"):
                self.assertEqual(
                    (PLUGIN_SOURCE / name).read_text(encoding="utf-8"),
                    (installed / name).read_text(encoding="utf-8"),
                )

            repeated = subprocess.run(
                [*command, "--apply"],
                check=True,
                capture_output=True,
                text=True,
                env=environment,
            )
            repeated_receipt = json.loads(repeated.stdout)
            self.assertFalse(repeated_receipt["hermes"]["changed"])
            self.assertEqual([], repeated_receipt["claude"]["events_added"])
            self.assertEqual([], repeated_receipt["codex"]["events_added"])
            self.assertFalse(repeated_receipt["opencode"]["changed"])

    def test_source_scope_does_not_mutate_other_agent_configs(self) -> None:
        with tempfile.TemporaryDirectory(prefix="k811-hook-scope-") as directory:
            root = Path(directory)
            home = root / "home"
            app = root / "K811 Studio.app"
            helper = app / "Contents/Helpers/k811-agent-event"
            helper.parent.mkdir(parents=True)
            helper.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            helper.chmod(helper.stat().st_mode | stat.S_IXUSR)

            fake_hermes = root / "hermes"
            fake_hermes.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            fake_hermes.chmod(fake_hermes.stat().st_mode | stat.S_IXUSR)
            environment = dict(os.environ)
            environment.update({"HOME": str(home), "HERMES_HOME": str(home / ".hermes")})

            result = subprocess.run(
                [
                    str(INSTALLER),
                    "--app",
                    str(app),
                    "--hermes",
                    str(fake_hermes),
                    "--source",
                    "hermes",
                    "--apply",
                ],
                check=True,
                capture_output=True,
                text=True,
                env=environment,
            )
            receipt = json.loads(result.stdout)
            self.assertEqual(["hermes"], receipt["selected_sources"])
            self.assertTrue((home / ".hermes/plugins/k811-agent-light/plugin.yaml").exists())
            self.assertFalse((home / ".claude").exists())
            self.assertFalse((home / ".codex").exists())
            self.assertFalse((home / ".config/opencode").exists())


if __name__ == "__main__":
    unittest.main()
