#!/usr/bin/env python3
"""Package the committed release sources, native dependencies and vendored Rust crates."""

import hashlib
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def output(*args, cwd=ROOT):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def unpack_commit(repo, destination, temporary):
    archive = temporary / "commit.tar"
    subprocess.run(["git", "archive", "--format=tar", "-o", str(archive), "HEAD"], cwd=repo, check=True)
    destination.mkdir(parents=True, exist_ok=True)
    # Both archives come from this checkout's committed Git trees.
    subprocess.run(["tar", "xf", str(archive), "-C", str(destination)], check=True)


def source_filter(info):
    if any(part in {".git", ".zig-cache", "zig-out", "__pycache__"} for part in Path(info.name).parts):
        return None
    return info


def main():
    ghostty = ROOT / "vendor/ghostty"
    for repo in [ROOT, ghostty]:
        if output("git", "status", "--porcelain", cwd=repo):
            raise SystemExit("Commit or remove local changes before packaging: " + str(repo))
    commit = output("git", "rev-parse", "HEAD")
    ghostty_commit = output("git", "rev-parse", "HEAD", cwd=ghostty)
    pinned = output("git", "rev-parse", "HEAD:vendor/ghostty")
    if pinned != ghostty_commit:
        raise SystemExit("Ghostty checkout does not match the release's pinned submodule")
    with (ROOT / "app/Info.plist").open("rb") as file:
        version = plistlib.load(file)["CFBundleShortVersionString"]
    build = ROOT / "build"
    build.mkdir(exist_ok=True)
    name = "tern-" + version + "-source"
    destination = build / ("Tern-" + version + "-source.tar.gz")
    with tempfile.TemporaryDirectory(prefix="source-", dir=build) as temporary:
        temporary = Path(temporary)
        source = temporary / name
        unpack_commit(ROOT, source, temporary)
        unpack_commit(ghostty, source / "vendor/ghostty", temporary)
        (source / ".cargo").mkdir(exist_ok=True)
        config = subprocess.check_output(
            ["cargo", "vendor", "--locked", "--offline", "--versioned-dirs", "rust-vendor"],
            cwd=source, text=True,
        )
        (source / ".cargo/config.toml").write_text(config)
        dependencies = sorted(path for path in (ROOT / ".zig-deps").iterdir()
                              if not path.name.startswith(".") and path.is_dir())
        if not dependencies:
            raise SystemExit("No native dependency sources found; run scripts/build-ghostty.sh")
        tools = "\n".join(output(*command) for command in [
            ["rustc", "--version"], ["cargo", "--version"], ["swift", "--version"], ["zig", "version"],
        ])
        (source / "SOURCE_BUILD.md").write_text(
            "# Release source bundle\n\n"
            + "tern commit: `" + commit + "`\n\n"
            + "Ghostty commit: `" + ghostty_commit + "`\n\n"
            + "Toolchain used to package these sources:\n\n```text\n" + tools + "\n```\n\n"
            + "This archive includes the pinned Ghostty source, fetched native dependency sources\n"
            + "under `.zig-deps/`, and Rust crates under `rust-vendor/`. `.cargo/config.toml`\n"
            + "uses the vendored Rust crates. Read README.md for Xcode and Metal requirements.\n\n"
            + "Build Ghostty from these sources, including after modifying libintl or z2d:\n\n"
            + "```sh\ncd vendor/ghostty\nzig build --system ../../.zig-deps -Doptimize=ReleaseFast "
            + "-Demit-xcframework=true -Demit-macos-app=false -Demit-docs=false -Dxcframework-target=native\n"
            + "cd ../..\ncargo test --locked --offline\n./scripts/build-app.sh\n```\n\n"
            + "All compiler caches, Git metadata and prebuilt native libraries are excluded.\n"
            + "Signing a rebuilt app for distribution requires your own Developer ID identity;\n"
            + "a local build can use `TERN_SIGN_IDENTITY=- ./scripts/build-app.sh`.\n"
        )
        # Write outside the final name, so a failed run cannot leave a partial release asset.
        staged = temporary / destination.name
        with tarfile.open(staged, "w:gz", dereference=False) as archive:
            archive.add(source, arcname=name, filter=source_filter)
            for dependency in dependencies:
                archive.add(dependency, arcname=name + "/.zig-deps/" + dependency.name, filter=source_filter)
        shutil.move(str(staged), destination)
    checksum = hashlib.sha256()
    with destination.open("rb") as file:
        for block in iter(lambda: file.read(1024 * 1024), b""):
            checksum.update(block)
    destination.with_name(destination.name + ".sha256").write_text(checksum.hexdigest() + "  " + destination.name + "\n")
    print(destination)


if __name__ == "__main__":
    main()
