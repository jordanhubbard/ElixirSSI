#!/usr/bin/env python3
"""Negative tests for project receipt publication and freshness."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('verify_project', Path(__file__).with_name('verify-project.py'))
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)


class ReceiptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        (self.root / 'scripts').mkdir()
        shutil.copyfile(v.ROOT / v.RUNNER, self.root / v.RUNNER)
        (self.root / 'Makefile').write_text('build:\n\ttrue\n')
        (self.root / 'os').mkdir()
        (self.root / 'os/source.ex').write_text('original')
        (self.root / '.gitignore').write_text('os/build/\n')
        config = json.loads((v.ROOT / 'literate.project.json').read_text())
        config['test_receipt_policy']['runner_identity']['digest'] = v.file_digest(self.root / v.RUNNER).split(':')[1]
        v.atomic_json(self.root / 'literate.project.json', config)
        for name in v.ARTIFACTS:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'image fixture')

    def execute(self, fail=None, mutate=None):
        def run(argv, **kwargs):
            if argv[0] == 'make':
                kwargs['stdout'].write(b'test fixture only\n')
                if mutate and argv[1] == v.STAGES[-1]:
                    mutate()
                return subprocess.CompletedProcess(argv, 1 if argv[1] == fail else 0)
            return subprocess.CompletedProcess(argv, 0)
        with patch.object(v, 'authority', return_value='sha256:' + '1' * 64), patch.object(v.subprocess, 'run', side_effect=run):
            # check_output uses run too, so retain the real Git inventory implementation outside the patch.
            with patch.object(v, 'source_inventory', side_effect=self.inventory):
                v.update(self.root)

    def inventory(self, root):
        # The real Git command remains executable despite the test's intercepted stage runner.
        with patch.object(v.subprocess, 'run', self.real_run):
            return self.real_inventory(root)

    real_run = staticmethod(subprocess.run)
    real_inventory = staticmethod(v.source_inventory)

    def checked(self):
        with patch.object(v.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)):
            with patch.object(v, 'source_inventory', side_effect=self.inventory):
                v.check(self.root)

    def test_failed_rerun_removes_old_success(self):
        self.execute()
        with self.assertRaisesRegex(ValueError, 'make test failed'):
            self.execute(fail='test')
        self.assertFalse((self.root / v.RECEIPT).exists())

    def test_source_edit_and_new_source_reject_receipt(self):
        self.execute()
        (self.root / 'os/new.ex').write_text('untracked source')
        with self.assertRaisesRegex(ValueError, 'source changed'):
            self.checked()
        (self.root / 'os/new.ex').unlink()
        (self.root / 'os/source.ex').write_text('changed')
        with self.assertRaisesRegex(ValueError, 'source changed'):
            self.checked()

    def test_image_or_report_tampering_rejected(self):
        self.execute()
        image = self.root / v.ARTIFACTS[0]
        image.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'image changed'):
            self.checked()

        image.write_bytes(b'image fixture')
        report = v.read_json(self.root, v.REPORT)
        report['stages'][0]['exit_code'] = 1
        v.atomic_json(self.root / v.REPORT, report)
        with self.assertRaisesRegex(ValueError, 'report identity'):
            self.checked()

    def test_deleted_tracked_source_rejects_receipt_and_can_be_requalified(self):
        subprocess.run(['git', 'add', 'os/source.ex'], cwd=self.root, check=True)
        self.execute()
        (self.root / 'os/source.ex').unlink()
        with self.assertRaisesRegex(ValueError, 'source changed'):
            self.checked()
        self.execute()
        self.checked()

    def test_source_edit_during_run_never_publishes(self):
        with self.assertRaisesRegex(ValueError, 'changed during verification'):
            self.execute(mutate=lambda: (self.root / 'os/source.ex').write_text('racing edit'))
        self.assertFalse((self.root / v.RECEIPT).exists())


if __name__ == '__main__':
    unittest.main()
