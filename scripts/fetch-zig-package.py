#!/usr/bin/env python3
"""Fetch one pinned Zig package, verify its content hash, then publish it atomically.

Uses curl for HTTPS, but Zig itself for package hashing and archive normalization.
Unmarked directories from the old fetcher are never trusted.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit


def fetch(expected, url, deps):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", expected):
        raise ValueError("invalid package hash")
    deps = Path(deps).resolve()
    downloads = deps / ".downloads"
    downloads.mkdir(parents=True, exist_ok=True)
    destination = deps / expected
    marker = deps / ".verified" / expected
    if destination.is_dir() and marker.is_file():
        return
    # Everything stays on one filesystem so the final rename is atomic.
    with tempfile.TemporaryDirectory(prefix="fetch-", dir=downloads) as temporary:
        stage = Path(temporary)
        if url.startswith("git+https://github.com/"):
            repo, commit = url[4:].rsplit("#", 1)
            repo = repo.removesuffix(".git")
            url = f"{repo}/archive/{commit}.tar.gz"
        if url.startswith("git+"):
            repo, commit = url[4:].rsplit("#", 1)
            source = stage / "source"
            subprocess.run(["git", "clone", "--no-checkout", repo, str(source)], check=True)
            subprocess.run(["git", "-C", str(source), "checkout", "--detach", commit], check=True)
            shutil.rmtree(source / ".git")
        else:
            path = urlsplit(url).path.lower()
            suffix = next((s for s in (".tar.gz", ".tar.xz", ".tar.zst", ".tar", ".zip") if path.endswith(s)), None)
            if suffix is None:
                raise ValueError(f"unsupported archive URL: {url}")
            source = stage / ("source" + suffix)
            # Reuse existing downloads, but verify them just like a fresh download.
            cached = downloads / (expected + ".archive")
            if cached.is_file():
                shutil.copyfile(cached, source)
            else:
                subprocess.run(["curl", "-fsSL", "--retry", "3", "-o", str(source), url], check=True)
        cache = stage / "cache"
        env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(cache), ZIG_LOCAL_CACHE_DIR=str(stage / "local-cache"))
        actual = subprocess.run(["zig", "fetch", str(source)], env=env, cwd=stage,
                                check=True, text=True, capture_output=True).stdout.strip()
        if actual != expected:
            raise ValueError(f"package hash mismatch: expected {expected}, got {actual!r}")
        # Zig 0.17 caches a normalized, filtered archive rooted at the package hash.
        package = stage / "package"
        package.mkdir()
        subprocess.run(["tar", "xf", str(cache / "p" / (expected + ".tar.gz")),
                        "-C", str(package), "--strip-components=1"], check=True)
        # Rehash the installed layout too, rather than relying on cache tar layout.
        entries = list(package.iterdir())
        installed = entries[0] if len(entries) == 1 and entries[0].is_dir() else package
        installed_hash = subprocess.run(["zig", "fetch", str(installed)], env=env, cwd=stage,
                                        check=True, text=True, capture_output=True).stdout.strip()
        if installed_hash != expected:
            raise ValueError(f"extracted package hash mismatch: expected {expected}, got {installed_hash!r}")
        marker.unlink(missing_ok=True)
        if destination.is_symlink():
            destination.unlink()
        elif destination.exists():
            shutil.rmtree(destination)
        installed.rename(destination)
        marker.parent.mkdir(exist_ok=True)
        marker.touch()
    print(f"verified {expected}")


if __name__ == "__main__":
    try:
        fetch(*sys.argv[1:])
    except (ValueError, subprocess.CalledProcessError) as error:
        print(error, file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr, file=sys.stderr)
        sys.exit(1)
