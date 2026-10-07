#!/usr/bin/env python3
"""Check Make dispatch, cleanup safety and emulator image selection without Docker."""
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import sys
import unittest
from unittest.mock import patch

OS = Path(__file__).resolve().parents[1]


class TargetTests(unittest.TestCase):
    def test_acceptance_reset_preserves_interactive_cards(self):
        import test_cluster as harness
        with tempfile.TemporaryDirectory() as temp, patch.dict(os.environ):
            with patch.object(harness, "OS", temp), patch.object(harness, "CLUSTER"), \
                 patch.object(harness, "QEMU"), patch.object(harness, "BOOT_TIMEOUT"):
                harness.use_cm5()
                state = Path(temp) / "build/cm5emu"
                tests = state / "tests"
                tests.mkdir(parents=True)
                user_card = state / "node1-original.img"
                test_card = tests / "node1-current.img"
                other_card = tests / "node2-current.img"
                for path in (user_card, test_card, other_card):
                    path.write_text("saved state")
                self.assertEqual(os.environ["SSI_CM5_STATE_DIR"], str(tests))
                harness.reset_node(1)
                self.assertTrue(user_card.exists())
                self.assertTrue(other_card.exists())
                self.assertFalse(test_card.exists())

    def test_docker_transport_preserves_argv_and_publishes_only_loopback(self):
        with tempfile.TemporaryDirectory(prefix="cm5 transport ") as temp:
            root = Path(temp)
            (root / "scripts").mkdir()
            shutil.copy(OS / "scripts/docker-emulator.sh", root / "scripts")
            binary = root / "docker"
            binary.write_text(f"#!{sys.executable}\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\n")
            binary.chmod(0o755)
            env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}", N="2")
            result = subprocess.run(["bash", str(root / "scripts/docker-emulator.sh"),
                                     "echo", "argument with spaces"], env=env,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            args = json.loads(result.stdout)
            self.assertEqual(args[-2:], ["echo", "argument with spaces"])
            ports = [args[i+1] for i, arg in enumerate(args) if arg == "-p"]
            self.assertEqual(len(ports), 6)
            self.assertTrue(all(port.startswith("127.0.0.1:") for port in ports))
            self.assertIn("127.0.0.1:8182:8182", ports)
            self.assertIn(f"{root.resolve()}:/os", args)
            self.assertTrue(any(arg.endswith(":/os/build/emulator") for arg in args))
            self.assertTrue(any(arg.endswith(":/os/build/cm5emu") for arg in args))

    def dry_run(self, target):
        result = subprocess.run(
            ["make", "-n", "-W", "scripts/mkimage-cm5.sh", target,
             "KERNEL_DOCKER=1", "MAKE=echo"], cwd=OS,
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_default_and_build_assemble_flashable_image(self):
        for target in ("all", "build"):
            self.assertIn("sh scripts/mkimage-cm5.sh", self.dry_run(target))

    def test_run_uses_cm5_and_virt_is_explicit(self):
        self.assertIn("scripts/ssi-cm5 run", self.dry_run("run"))
        self.assertNotIn("scripts/ssi-qemu run", self.dry_run("run"))
        self.assertIn("scripts/ssi-qemu run", self.dry_run("run-virt"))

    def test_test_includes_units_regressions_and_image_verifier(self):
        commands = self.dry_run("test")
        for expected in ("mix test", "scripts/test_build.py", "scripts/test_targets.py",
                         "scripts/verify_cm5.py"):
            self.assertIn(expected, commands)

    def test_root_exports_standard_targets(self):
        for target in ("build", "run", "test", "clean", "test-cm5", "run-virt"):
            result = subprocess.run(["make", "-n", target, "MAKE=echo"], cwd=OS.parent,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"-C os {target}", result.stdout)

    def test_clean_keeps_identity_disks_and_compiler_cache(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "toolchain").mkdir()
            shutil.copy(OS / "Makefile", root)
            shutil.copy(OS / "toolchain/versions.mk", root / "toolchain")
            kept = ("build/cm5/cluster.secret", "build/cm5emu/node1.img", "build/kernel/Image")
            removed = ("build/cm5/elixirssi-cm5.img", "build/cm5/elixirssi-cm5.img.zst",
                       "build/release/file", "build/ssi-initramfs.cpio.gz")
            for name in kept + removed:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("sentinel")
            subprocess.run(["make", "clean", "SSI_SRC="], cwd=root,
                           check=True, capture_output=True)
            for name in kept:
                self.assertEqual((root / name).read_text(), "sentinel")
            for name in removed:
                self.assertFalse((root / name).exists(), name)

    def test_new_image_gets_new_card_without_discarding_old_state(self):
        loader = importlib.machinery.SourceFileLoader("ssi_cm5_test", str(OS / "scripts/ssi-cm5"))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        module = importlib.util.module_from_spec(spec)
        loader.exec_module(module)
        with tempfile.TemporaryDirectory() as temp:
            module.DIR = temp
            module.IMAGE = str(Path(temp) / "base.img")
            Path(module.IMAGE).write_bytes(b"first image")
            def copy_card(args, **kwargs):
                shutil.copyfile(args[-2], args[-1])
            with patch.object(module.subprocess, "run", side_effect=copy_card):
                first = module.card(1)
                Path(first).write_bytes(b"user data")
                self.assertEqual(module.card(1), first)
                Path(module.IMAGE).write_bytes(b"second image")
                second = module.card(1)
                self.assertNotEqual(second, first)
                self.assertEqual(Path(first).read_bytes(), b"user data")
                self.assertEqual(Path(second).read_bytes(), b"second image")


if __name__ == "__main__":
    unittest.main()
