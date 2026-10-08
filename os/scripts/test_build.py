#!/usr/bin/env python3
"""Host-side regression checks; no Docker daemon or compiler is required."""
import json
import gzip
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


OS = Path(__file__).resolve().parents[1]


class DockerKernelTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="elixirssi build ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.checkout = self.root / "checkout with spaces"
        (self.checkout / "scripts").mkdir(parents=True)
        shutil.copy(OS / "scripts/docker-kernel.sh", self.checkout / "scripts")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.calls = self.root / "calls.jsonl"
        docker = self.bin / "docker"
        docker.write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            "with open(os.environ['DOCKER_CALLS'], 'a') as log:\n"
            "    log.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            "sys.exit(int(os.environ.get('FAIL_' + sys.argv[1].upper(), '0')))\n"
        )
        docker.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        DOCKER_CALLS=str(self.calls), ALPINE_VERSION="3.22",
                        LINUX_URL="https://example.invalid/linux", LINUX_BRANCH="test")

    def run_wrapper(self, **env):
        return subprocess.run(["sh", str(self.checkout / "scripts/docker-kernel.sh")],
                              env=dict(self.env, **env), capture_output=True, text=True)

    def read_calls(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

    def test_build_failure_does_not_start_compiler(self):
        self.assertEqual(self.run_wrapper(FAIL_BUILD="19").returncode, 19)
        self.assertEqual([call[0] for call in self.read_calls()], ["build"])

    def test_container_failure_reaches_make_caller(self):
        self.assertEqual(self.run_wrapper(FAIL_RUN="37").returncode, 37)
        self.assertEqual([call[0] for call in self.read_calls()], ["build", "run"])

    def test_arm64_mounts_and_cache_survive_spaces_and_repeated_runs(self):
        for _ in range(2):
            result = self.run_wrapper()
            self.assertEqual(result.returncode, 0, result.stderr)
        first, second = self.read_calls()[1::2]
        self.assertEqual(first, second)
        self.assertIn("linux/arm64", first)
        self.assertIn(f"{self.checkout.resolve()}:/os", first)
        self.assertEqual(sum(arg.startswith("elixirssi-kernel-") and
                             arg.endswith(":/kernel") for arg in first), 1)
        self.assertIn("SSI_KERNEL_JOBS", first)


class InitramfsTests(unittest.TestCase):
    @unittest.skipUnless((OS / "build/ssi-initramfs.cpio.gz").exists(), "run make first")
    def test_case_distinct_modules_and_their_dependencies_are_preserved(self):
        data = gzip.decompress((OS / "build/ssi-initramfs.cpio.gz").read_bytes())
        files = {}
        offset = 0
        while True:
            header = data[offset:offset + 110]
            self.assertIn(header[:6], (b"070701", b"070702"))
            size = int(header[54:62], 16)
            name_size = int(header[94:102], 16)
            start = offset + 110
            name = data[start:start + name_size - 1].decode().lstrip("/")
            offset = (start + name_size + 3) & ~3
            if name == "TRAILER!!!":
                break
            files[name] = data[offset:offset + size]
            offset = (offset + size + 3) & ~3

        def module(basename):
            matches = [path for path in files if path.endswith("/" + basename)]
            self.assertEqual(len(matches), 1, basename)
            return files[matches[0]]

        # These two Linux modules collide on a default macOS filesystem.
        self.assertNotEqual(module("xt_RATEEST.ko"), module("xt_rateest.ko"))
        indexes = [path for path in files if path.endswith("/modules.dep")]
        self.assertEqual(len(indexes), 1)
        prefix = indexes[0].rsplit("/", 1)[0]
        for line in files[indexes[0]].decode().splitlines():
            owner, dependencies = line.split(":", 1)
            for name in [owner, *dependencies.split()]:
                self.assertIn(f"{prefix}/{name}", files)


if __name__ == "__main__":
    unittest.main()
