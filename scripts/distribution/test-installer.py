#!/usr/bin/env python3
"""Installer boundaries that do not require Docker or downloaded artifacts."""
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('installer', Path(__file__).with_name('install.py'))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class ExtractTests(unittest.TestCase):
    def test_parent_traversal_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with tarfile.open(root / 'input.tar', 'w') as tar:
                entry = tarfile.TarInfo('../escaped')
                entry.size = 4
                tar.addfile(entry, io.BytesIO(b'test'))
            with self.assertRaises(tarfile.FilterError):
                installer.extract(root / 'input.tar', root / 'destination')
            self.assertFalse((root / 'escaped').exists())

    def test_external_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with tarfile.open(root / 'input.tar', 'w') as tar:
                entry = tarfile.TarInfo('external')
                entry.type = tarfile.SYMTYPE
                entry.linkname = '/etc/passwd'
                tar.addfile(entry)
            with self.assertRaises(tarfile.FilterError):
                installer.extract(root / 'input.tar', root / 'destination')


if __name__ == '__main__':
    unittest.main()
