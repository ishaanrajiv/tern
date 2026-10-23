import importlib.util
import io
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("fetcher", Path(__file__).parents[1] / "fetch-zig-package.py")
fetcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fetcher)


class FetchTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.deps = Path(self.temporary.name)
        self.expected = "fixture-0.0.1-AbCd"
        (self.deps / ".downloads").mkdir()
        (self.deps / ".downloads" / (self.expected + ".archive")).write_bytes(b"archive fixture")
        self.real_run = subprocess.run
        # What the real package root holds; the fake Zig hashes only that folder right.
        self.root_marker = "src.txt"

    def fake_zig(self, args, **kwargs):
        if args[0] != "zig":
            return self.real_run(args, **kwargs)
        target = Path(args[-1])
        if target.is_dir():
            right = (target / self.root_marker).exists()
            return subprocess.CompletedProcess(args, 0, (self.expected if right else "other-hash") + "\n", "")
        archive = Path(kwargs["env"]["ZIG_GLOBAL_CACHE_DIR"]) / "p" / (self.expected + ".tar.gz")
        archive.parent.mkdir(parents=True, exist_ok=True)
        with tarfile.open(archive, "w:gz") as tar:
            data = b"verified source"
            info = tarfile.TarInfo(self.expected + "/upstream-root/src.txt")
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
        return subprocess.CompletedProcess(args, 0, self.expected + "\n", "")

    def fetch(self):
        fetcher.fetch(self.expected, "https://example.invalid/source.tar.gz", self.deps)

    def test_verified_package_replaces_incomplete_directory(self):
        destination = self.deps / self.expected
        destination.mkdir()
        (destination / "partial").touch()
        with patch.object(fetcher.subprocess, "run", side_effect=self.fake_zig):
            self.fetch()
        self.assertEqual((destination / "src.txt").read_text(), "verified source")
        self.assertFalse((destination / "partial").exists())
        self.assertTrue((self.deps / ".verified" / self.expected).is_file())
        self.assertEqual(list((self.deps / ".downloads").glob("fetch-*")), [])

    def test_wrong_hash_keeps_existing_directory_and_no_marker(self):
        destination = self.deps / self.expected
        destination.mkdir()
        (destination / "partial").touch()
        with patch.object(fetcher.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "wrong-hash\n", "")):
            with self.assertRaisesRegex(ValueError, "hash mismatch"):
                self.fetch()
        self.assertTrue((destination / "partial").exists())
        self.assertFalse((self.deps / ".verified" / self.expected).exists())
        self.assertEqual(list((self.deps / ".downloads").glob("fetch-*")), [])

    def test_failed_extraction_never_publishes_package(self):
        with patch.object(fetcher.subprocess, "run", side_effect=self.fake_zig), \
                patch.object(fetcher, "unpack", side_effect=fetcher.tarfile.ReadError("truncated")):
            with self.assertRaises(fetcher.tarfile.TarError):
                self.fetch()
        self.assertFalse((self.deps / self.expected).exists())
        self.assertFalse((self.deps / ".verified" / self.expected).exists())

    def test_wrong_extracted_layout_never_publishes_package(self):
        calls = 0
        def wrong_layout(args, **kwargs):
            nonlocal calls
            if args[0] == "zig":
                calls += 1
                if calls >= 2:
                    return subprocess.CompletedProcess(args, 0, "wrong-layout\n", "")
            return self.fake_zig(args, **kwargs)
        with patch.object(fetcher.subprocess, "run", side_effect=wrong_layout):
            with self.assertRaisesRegex(ValueError, "extracted package hash mismatch"):
                self.fetch()
        self.assertFalse((self.deps / self.expected).exists())
        self.assertFalse((self.deps / ".verified" / self.expected).exists())

    def test_tgz_is_hashed_under_the_name_zig_expects(self):
        # Ghostty depends on a .tgz archive; Zig only recognises .tar.gz.
        seen = []

        def fake_zig(args, **kwargs):
            if args[0] == "zig":
                seen.append(str(args[-1]))
            return self.fake_zig(args, **kwargs)

        with patch.object(fetcher.subprocess, "run", side_effect=fake_zig):
            fetcher.fetch(self.expected, "https://example.invalid/source.tgz", self.deps)
        # The archive first, then what was unpacked from it.
        self.assertTrue(seen[0].endswith(".tar.gz"), seen[0])
        self.assertTrue((self.deps / self.expected / "src.txt").exists())

    def test_apple_double_files_are_kept_as_files(self):
        # Archives made on a Mac carry ._ files; Zig hashes them, so they must survive unpacking.
        self.root_marker = "._OFL.txt"

        def fake_zig(args, **kwargs):
            if args[0] != "zig" or Path(args[-1]).is_dir():
                return self.fake_zig(args, **kwargs)
            archive = Path(kwargs["env"]["ZIG_GLOBAL_CACHE_DIR"]) / "p" / (self.expected + ".tar.gz")
            archive.parent.mkdir(parents=True, exist_ok=True)
            with tarfile.open(archive, "w:gz") as tar:
                for name, data in [("OFL.txt", b"licence"), ("._OFL.txt", b"\x00\x05\x16\x07metadata")]:
                    info = tarfile.TarInfo(self.expected + "/" + name)
                    info.size = len(data)
                    tar.addfile(info, io.BytesIO(data))
            return subprocess.CompletedProcess(args, 0, self.expected + "\n", "")

        with patch.object(fetcher.subprocess, "run", side_effect=fake_zig):
            self.fetch()
        self.assertTrue((self.deps / self.expected / "._OFL.txt").is_file())
        self.assertTrue((self.deps / self.expected / "OFL.txt").is_file())

    def test_a_package_that_is_one_folder_is_not_descended_into(self):
        # When the unpacked root hashes right, its only folder stays a folder.
        self.root_marker = "upstream-root"
        with patch.object(fetcher.subprocess, "run", side_effect=self.fake_zig):
            self.fetch()
        self.assertTrue((self.deps / self.expected / "upstream-root" / "src.txt").exists())

    def test_rejects_hash_path_traversal(self):
        with self.assertRaisesRegex(ValueError, "invalid package hash"):
            fetcher.fetch("../victim", "https://example.invalid/source.tar.gz", self.deps)


if __name__ == "__main__":
    unittest.main()
