#!/usr/bin/env python3
"""Adversarial tests for LocalWrap's helper trust boundary."""

from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import os
import signal
import subprocess
import tempfile
import time
import unittest
from unittest import mock
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "localwrap-helper"
loader = importlib.machinery.SourceFileLoader("localwrap_helper", str(HELPER))
spec = importlib.util.spec_from_loader(loader.name, loader)
assert spec is not None
helper = importlib.util.module_from_spec(spec)
loader.exec_module(helper)


def manifest(project: dict | None = None) -> dict:
    return {
        "localwrap": 1,
        "name": "Test",
        "projects": [project or {
            "id": "web",
            "name": "Web",
            "path": ".",
            "command": "python3 server.py",
            "port": 4301,
            "url": "http://127.0.0.1:4301",
        }],
    }


class HelperTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        (self.root / "server.py").write_text("print('ok')\n", encoding="utf-8")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_manifest(self, value: dict) -> Path:
        path = self.root / "localwrap.json"
        path.write_text(json.dumps(value), encoding="utf-8")
        return path

    def test_numeric_loopback_only(self) -> None:
        value = manifest()
        value["projects"][0]["url"] = "http://localhost:4301"
        self.write_manifest(value)
        with self.assertRaisesRegex(helper.LocalWrapError, "numeric loopback"):
            helper.parse_manifest(self.root)
        value["projects"][0]["url"] = "http://[::1]:4301"
        self.write_manifest(value)
        _, parsed = helper.parse_manifest(self.root)
        self.assertEqual(parsed["projects"][0]["url"], "http://[::1]:4301")

    def test_dangerous_command_shapes_are_rejected(self) -> None:
        rejected = [
            "npx vite", "npm exec vite", "deno run app.ts", "python3 -c pass",
            "node -e pass", "npm run dev -- --evil", "bash server.sh",
        ]
        for command in rejected:
            with self.subTest(command=command):
                with self.assertRaises(helper.LocalWrapError):
                    helper.parse_command(command)
        self.assertEqual(helper.parse_command("npm run dev"), ["npm", "run", "dev"])
        self.assertEqual(helper.parse_command("python3 server.py"), ["python3", "server.py"])

    def test_repository_symlink_cannot_select_outside_cwd(self) -> None:
        outside = Path(self.temporary.name).parent / f"outside-{os.getpid()}"
        outside.mkdir(exist_ok=True)
        try:
            (self.root / "escape").symlink_to(outside, target_is_directory=True)
            value = manifest()
            value["projects"][0]["path"] = "escape"
            self.write_manifest(value)
            with self.assertRaisesRegex(helper.LocalWrapError, "outside the repository"):
                helper.parse_manifest(self.root)
        finally:
            outside.rmdir()

    def test_interpreter_script_symlink_cannot_escape(self) -> None:
        outside = Path(self.temporary.name).parent / f"outside-script-{os.getpid()}.py"
        outside.write_text("print('outside')\n", encoding="utf-8")
        try:
            (self.root / "linked.py").symlink_to(outside)
            value = manifest()
            value["projects"][0]["command"] = "python3 linked.py"
            self.write_manifest(value)
            with self.assertRaisesRegex(helper.LocalWrapError, "without following links"):
                helper.launch_plan(self.root, "web")
        finally:
            outside.unlink()

    def test_manifest_limits_apply_before_materialization(self) -> None:
        path = self.root / "localwrap.json"
        path.write_bytes(b" " * (helper.MAX_MANIFEST_BYTES + 1))
        with self.assertRaisesRegex(helper.LocalWrapError, "byte limit"):
            helper.parse_manifest(self.root)
        path.write_text("[" * (helper.MAX_JSON_DEPTH + 1) + "]" * (helper.MAX_JSON_DEPTH + 1), encoding="utf-8")
        with self.assertRaisesRegex(helper.LocalWrapError, "depth limit"):
            helper.parse_manifest(self.root)
        value = manifest()
        value["projects"] = value["projects"] * (helper.MAX_PROJECTS + 1)
        self.write_manifest(value)
        with self.assertRaisesRegex(helper.LocalWrapError, "project limit"):
            helper.parse_manifest(self.root)

    def test_schema_and_string_limits_are_enforced(self) -> None:
        value = manifest()
        value["unknown"] = True
        self.write_manifest(value)
        with self.assertRaisesRegex(helper.LocalWrapError, "unknown field"):
            helper.parse_manifest(self.root)
        value = manifest()
        value["projects"][0]["name"] = "x" * (helper.MAX_NAME + 1)
        self.write_manifest(value)
        with self.assertRaisesRegex(helper.LocalWrapError, "character limit"):
            helper.parse_manifest(self.root)
        value = manifest()
        value["projects"][0]["dependsOn"] = [f"p{i}" for i in range(helper.MAX_DEPENDENCIES + 1)]
        self.write_manifest(value)
        with self.assertRaisesRegex(helper.LocalWrapError, "dependency limit"):
            helper.parse_manifest(self.root)

    def test_exact_origin_change_invalidates_confirmation(self) -> None:
        (self.root / "package.json").write_text(
            json.dumps({"scripts": {
                "predev": "python3 prepare.py", "dev": "vite --host 127.0.0.1",
                "postdev": "python3 cleanup.py",
            }}), encoding="utf-8"
        )
        value = manifest()
        value["projects"][0]["command"] = "npm run dev"
        self.write_manifest(value)
        first = helper.launch_plan(self.root, "web")
        self.assertIn("vite --host", first["reviewDetail"])
        self.assertIn("predev", first["reviewDetail"])
        self.assertIn("postdev", first["reviewDetail"])
        (self.root / "package.json").write_text(
            json.dumps({"scripts": {"dev": "vite --host 127.0.0.1 --strictPort"}}), encoding="utf-8"
        )
        second = helper.launch_plan(self.root, "web")
        self.assertNotEqual(first["fingerprint"], second["fingerprint"])

    def test_interpreter_script_content_change_invalidates_confirmation(self) -> None:
        self.write_manifest(manifest())
        first = helper.launch_plan(self.root, "web")
        self.assertIn("sha256", first["reviewDetail"])
        (self.root / "server.py").write_text("print('changed')\n", encoding="utf-8")
        second = helper.launch_plan(self.root, "web")
        self.assertNotEqual(first["fingerprint"], second["fingerprint"])

    def test_manifest_fields_and_digest_share_one_read_snapshot(self) -> None:
        path = self.write_manifest(manifest())
        original = path.read_bytes()
        real_decode = helper.decode_json

        def replace_after_read(raw: bytes, label: str):
            if label == "workspace manifest":
                changed = manifest()
                changed["projects"][0]["name"] = "Changed after held read"
                path.write_text(json.dumps(changed), encoding="utf-8")
            return real_decode(raw, label)

        with mock.patch.object(helper, "decode_json", side_effect=replace_after_read):
            plan = helper.launch_plan(self.root, "web")
        self.assertEqual(plan["projectName"], "Web")
        self.assertEqual(plan["origins"][0]["sha256"], helper.bytes_digest(original))

    def test_package_fields_and_digest_share_one_read_snapshot(self) -> None:
        package_path = self.root / "package.json"
        original = json.dumps({"scripts": {"dev": "printf original > result.txt"}}).encode()
        package_path.write_bytes(original)
        value = manifest()
        value["projects"][0]["command"] = "npm run dev"
        self.write_manifest(value)
        real_decode = helper.decode_json

        def replace_after_read(raw: bytes, label: str):
            if label == "package.json":
                package_path.write_text(
                    json.dumps({"scripts": {"dev": "printf changed > result.txt"}}),
                    encoding="utf-8",
                )
            return real_decode(raw, label)

        with mock.patch.object(helper, "decode_json", side_effect=replace_after_read):
            plan = helper.launch_plan(self.root, "web")
        package_origin = plan["origins"][1]
        self.assertEqual(package_origin["scripts"][0]["value"], "printf original > result.txt")
        self.assertEqual(package_origin["sha256"], helper.bytes_digest(original))

    def test_interpreter_executes_sealed_snapshot_after_path_mutation(self) -> None:
        (self.root / "local_value.py").write_text("VALUE = 'reviewed'\n", encoding="utf-8")
        (self.root / "server.py").write_text(
            "from pathlib import Path\nfrom local_value import VALUE\n"
            "assert Path(__file__).name == 'server.py'\nPath('result.txt').write_text(VALUE)\n",
            encoding="utf-8",
        )
        self.write_manifest(manifest())
        reviewed = helper.launch_plan(self.root, "web")
        real_prepare = helper.prepare_launch

        def swap_after_prepare(root: Path, project_id: str):
            plan, prepared = real_prepare(root, project_id)
            (self.root / "server.py").write_text(
                "from pathlib import Path\nPath('result.txt').write_text('unreviewed')\n",
                encoding="utf-8",
            )
            return plan, prepared

        with mock.patch.object(helper, "prepare_launch", side_effect=swap_after_prepare):
            with self.assertRaises(SystemExit) as result:
                helper.command_run(str(self.root), "web", reviewed["fingerprint"])
        self.assertEqual(result.exception.code, 0)
        self.assertEqual((self.root / "result.txt").read_text(), "reviewed")

    def test_working_directory_descriptor_survives_path_replacement(self) -> None:
        app = self.root / "app"
        app.mkdir()
        (app / "server.py").write_text(
            "from pathlib import Path\nPath('result.txt').write_text('reviewed')\n",
            encoding="utf-8",
        )
        value = manifest()
        value["projects"][0]["path"] = "app"
        self.write_manifest(value)
        reviewed = helper.launch_plan(self.root, "web")
        real_prepare = helper.prepare_launch
        displaced = self.root / "reviewed-app"

        def swap_after_prepare(root: Path, project_id: str):
            plan, prepared = real_prepare(root, project_id)
            app.rename(displaced)
            app.mkdir()
            (app / "server.py").write_text("raise SystemExit('unreviewed')\n", encoding="utf-8")
            return plan, prepared

        with mock.patch.object(helper, "prepare_launch", side_effect=swap_after_prepare):
            with self.assertRaises(SystemExit) as result:
                helper.command_run(str(self.root), "web", reviewed["fingerprint"])
        self.assertEqual(result.exception.code, 0)
        self.assertEqual((displaced / "result.txt").read_text(), "reviewed")
        self.assertFalse((app / "result.txt").exists())

    def test_node_snapshot_preserves_module_path_semantics(self) -> None:
        (self.root / "local-value.js").write_text(
            "module.exports = 'reviewed';\n", encoding="utf-8"
        )
        (self.root / "server.js").write_text(
            "const fs = require('fs'); const value = require('./local-value'); "
            "if (!__filename.endsWith('/server.js')) process.exit(9); "
            "fs.writeFileSync('result.txt', value);\n",
            encoding="utf-8",
        )
        value = manifest()
        value["projects"][0]["command"] = "node server.js"
        self.write_manifest(value)
        reviewed = helper.launch_plan(self.root, "web")
        real_prepare = helper.prepare_launch

        def swap_after_prepare(root: Path, project_id: str):
            plan, prepared = real_prepare(root, project_id)
            (self.root / "server.js").write_text("process.exit(8);\n", encoding="utf-8")
            return plan, prepared

        with mock.patch.object(helper, "prepare_launch", side_effect=swap_after_prepare):
            with self.assertRaises(SystemExit) as result:
                helper.command_run(str(self.root), "web", reviewed["fingerprint"])
        self.assertEqual(result.exception.code, 0)
        self.assertEqual((self.root / "result.txt").read_text(), "reviewed")

    def test_package_execution_never_reopens_changed_package_json(self) -> None:
        package_path = self.root / "package.json"
        package_path.write_text(
            json.dumps({"scripts": {"dev": "printf reviewed > result.txt"}}), encoding="utf-8"
        )
        value = manifest()
        value["projects"][0]["command"] = "npm run dev"
        self.write_manifest(value)
        reviewed = helper.launch_plan(self.root, "web")
        real_prepare = helper.prepare_launch

        def swap_after_prepare(root: Path, project_id: str):
            plan, prepared = real_prepare(root, project_id)
            package_path.write_text(
                json.dumps({"scripts": {"dev": "printf unreviewed > result.txt"}}),
                encoding="utf-8",
            )
            return plan, prepared

        with mock.patch.object(helper, "prepare_launch", side_effect=swap_after_prepare):
            with self.assertRaises(SystemExit) as result:
                helper.command_run(str(self.root), "web", reviewed["fingerprint"])
        self.assertEqual(result.exception.code, 0)
        self.assertEqual((self.root / "result.txt").read_text(), "reviewed")

    def test_config_is_bounded_deduplicated_and_atomically_written(self) -> None:
        config_path = self.root / "config" / "repositories.json"
        config = {"repositories": [str(self.root)], "notifications": False, "openOnReady": False}
        helper.atomic_write_json(config_path, config)
        self.assertEqual(helper.load_config(config_path)["repositories"], [str(self.root)])
        mode = config_path.stat().st_mode & 0o777
        self.assertEqual(mode, 0o600)
        config_path.write_bytes(b" " * (helper.MAX_CONFIG_BYTES + 1))
        with self.assertRaisesRegex(helper.LocalWrapError, "byte limit"):
            helper.load_config(config_path)

    def test_stale_configured_repository_remains_removable(self) -> None:
        config_path = self.root / "config" / "repositories.json"
        missing = self.root / "later-deleted"
        helper.atomic_write_json(config_path, {
            "repositories": [str(missing)], "notifications": False, "openOnReady": False,
        })
        loaded = helper.load_config(config_path)
        self.assertEqual(loaded["repositories"], [str(missing)])
        loaded["repositories"] = [
            item for item in loaded["repositories"] if item != helper.configured_path(str(missing))
        ]
        helper.atomic_write_json(config_path, loaded)
        self.assertEqual(helper.load_config(config_path)["repositories"], [])

    def test_install_noreplace_refuses_concurrent_destination_without_nesting(self) -> None:
        parent = self.root / ".config" / "omarchy" / "plugins"
        parent.mkdir(parents=True)
        staging = parent / ".io.github.tcballard.localwrap.stage.test"
        staging.mkdir()
        (staging / "manifest.json").write_text(
            json.dumps({"id": "io.github.tcballard.localwrap"}), encoding="utf-8"
        )
        target = parent / "io.github.tcballard.localwrap"
        real_rename = helper.renameat2

        def create_destination_then_rename(*args):
            target.mkdir()
            (target / "attacker.txt").write_text("preserve", encoding="utf-8")
            return real_rename(*args)

        with mock.patch.dict(os.environ, {"HOME": str(self.root)}):
            with mock.patch.object(helper, "renameat2", side_effect=create_destination_then_rename):
                with self.assertRaisesRegex(helper.LocalWrapError, "destination appeared"):
                    helper.command_install_swap(str(staging), str(target), "0")
        self.assertTrue(staging.is_dir())
        self.assertEqual((target / "attacker.txt").read_text(), "preserve")
        self.assertFalse((target / staging.name).exists())

    def test_install_exchange_restores_prior_target_when_new_target_is_displaced(self) -> None:
        parent = self.root / ".config" / "omarchy" / "plugins"
        parent.mkdir(parents=True)
        staging = parent / ".io.github.tcballard.localwrap.stage.exchange"
        staging.mkdir()
        (staging / "manifest.json").write_text(
            json.dumps({"id": "io.github.tcballard.localwrap", "version": "new"}), encoding="utf-8"
        )
        target = parent / "io.github.tcballard.localwrap"
        target.mkdir()
        (target / "manifest.json").write_text(
            json.dumps({"id": "io.github.tcballard.localwrap", "version": "old"}), encoding="utf-8"
        )
        (target / "prior.txt").write_text("prior", encoding="utf-8")
        displaced_new = parent / "new-install-displaced"
        real_rename = helper.renameat2
        calls = 0

        def displace_after_exchange(*args):
            nonlocal calls
            calls += 1
            result = real_rename(*args)
            if calls == 1:
                target.rename(displaced_new)
                target.mkdir()
                (target / "attacker.txt").write_text("attacker", encoding="utf-8")
            return result

        with mock.patch.dict(os.environ, {"HOME": str(self.root)}):
            with mock.patch.object(helper, "renameat2", side_effect=displace_after_exchange):
                with self.assertRaisesRegex(helper.LocalWrapError, "prior installation was restored"):
                    helper.command_install_swap(str(staging), str(target), "1")
        self.assertEqual(calls, 2)
        self.assertEqual((target / "prior.txt").read_text(), "prior")
        self.assertEqual((staging / "attacker.txt").read_text(), "attacker")
        self.assertTrue((displaced_new / "manifest.json").is_file())

    def test_output_is_capped_before_qml_receives_it(self) -> None:
        (self.root / "server.py").write_text(
            "import sys\nsys.stdout.write('x' * 1000000)\nsys.stdout.flush()\n", encoding="utf-8"
        )
        self.write_manifest(manifest())
        plan = helper.launch_plan(self.root, "web")
        result = subprocess.run(
            [str(HELPER), "run", str(self.root), "web", plan["fingerprint"]],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertLessEqual(len(result.stdout), helper.MAX_OUTPUT_LINE + 1)

    def test_term_cleans_descendant_process_group(self) -> None:
        child_pid_file = self.root / "child.pid"
        (self.root / "server.py").write_text(
            "import pathlib, subprocess, sys, time\n"
            "child=subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])\n"
            f"pathlib.Path({str(child_pid_file)!r}).write_text(str(child.pid))\n"
            "time.sleep(60)\n",
            encoding="utf-8",
        )
        self.write_manifest(manifest())
        plan = helper.launch_plan(self.root, "web")
        process = subprocess.Popen(
            [str(HELPER), "run", str(self.root), "web", plan["fingerprint"]],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        deadline = time.monotonic() + 5
        while not child_pid_file.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertTrue(child_pid_file.exists())
        child_pid = int(child_pid_file.read_text())
        process.send_signal(signal.SIGTERM)
        process.wait(timeout=5)
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            try:
                os.kill(child_pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.05)
        else:
            self.fail("descendant survived helper TERM/deadline/KILL cleanup")

    def test_natural_parent_exit_also_cleans_descendants(self) -> None:
        child_pid_file = self.root / "orphan.pid"
        (self.root / "server.py").write_text(
            "import pathlib, subprocess, sys\n"
            "child=subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'], "
            "stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)\n"
            f"pathlib.Path({str(child_pid_file)!r}).write_text(str(child.pid))\n",
            encoding="utf-8",
        )
        self.write_manifest(manifest())
        plan = helper.launch_plan(self.root, "web")
        result = subprocess.run(
            [str(HELPER), "run", str(self.root), "web", plan["fingerprint"]],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=8, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        child_pid = int(child_pid_file.read_text())
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            try:
                os.kill(child_pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.05)
        else:
            self.fail("descendant survived natural parent exit cleanup")


if __name__ == "__main__":
    unittest.main()
