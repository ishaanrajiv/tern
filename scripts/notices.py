#!/usr/bin/env python3
"""Writes THIRD_PARTY_NOTICES.md: the licenses of everything Tern.app ships.

Run after scripts/build-ghostty.sh (it reads the license files from .zig-deps/)
and again whenever vendor/ghostty or Cargo.lock changes:

    python3 scripts/notices.py

The Ghostty list below is what libghostty links on macOS, checked against the
symbols in GhosttyKit.xcframework. Linux-only packages (GTK, Wayland, HarfBuzz,
fontconfig, OpenGL) aren't in it. Recheck it after a Ghostty bump:

    nm -gU vendor/ghostty/macos/GhosttyKit.xcframework/*/libghostty-internal.a
"""

import glob
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GHOSTTY = os.path.join(ROOT, "vendor/ghostty")
DEPS = os.path.join(ROOT, ".zig-deps")
OUT = os.path.join(ROOT, "THIRD_PARTY_NOTICES.md")


def zig_deps():
    """Ghostty's dependency name -> its folder in .zig-deps/."""
    found = {}
    zons = [os.path.join(GHOSTTY, "build.zig.zon")] + glob.glob(f"{GHOSTTY}/pkg/*/build.zig.zon")
    for zon in zons:
        text = open(zon).read()
        for name, h in re.findall(
            r'\.([A-Za-z_0-9]+)\s*=\s*\.\{\s*(?://[^\n]*\n\s*)*\.url\s*=\s*"[^"]+"\s*,\s*\.hash\s*=\s*"([^"]+)"', text
        ):
            found.setdefault(name, os.path.join(DEPS, h))
    return found


def mit(holder):
    return f"""MIT License

Copyright (c) {holder}

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""


def leading_comment(path):
    """The license comment at the top of a C header, without the comment markers."""
    text = open(path, encoding="utf-8", errors="replace").read()
    block = text[text.index("/*") + 2 : text.index("*/")]
    return "\n".join(re.sub(r"^\s*\*? ?", "", line).rstrip() for line in block.splitlines()).strip() + "\n"


# (name, source, license, how it ships, license text: ("zig", dep, file) |
# ("ghostty", file) | ("text", str) | ("header", dep, file))
GHOSTTY_PARTS = [
    ("Ghostty (libghostty, libghostty-vt, shell integration, terminfo)", "https://github.com/ghostty-org/ghostty",
     "MIT", "linked into the app and `ternd`; resources", ("ghostty", "LICENSE")),
    ("libxev", "https://github.com/mitchellh/libxev", "MIT", "linked", ("zig", "libxev", "LICENSE")),
    ("zig-objc", "https://github.com/mitchellh/zig-objc", "MIT", "linked", ("zig", "zig_objc", "LICENSE")),
    ("uucode", "https://github.com/jacobsandlund/uucode", "MIT", "linked into the app and `ternd`",
     ("zig", "uucode", "LICENSE.md")),
    ("z2d", "https://github.com/vancluever/z2d", "MPL-2.0", "linked", ("zig", "z2d", "LICENSE")),
    ("libvaxis", "https://github.com/rockorager/libvaxis", "MIT", "linked", ("zig", "vaxis", "LICENSE")),
    ("zf", "https://github.com/natecraddock/zf", "MIT", "linked", ("zig", "zf", "LICENSE")),
    ("Oniguruma", "https://github.com/kkos/oniguruma", "BSD-2-Clause", "linked",
     ("zig", "oniguruma", "COPYING")),
    ("simdutf", "https://github.com/simdutf/simdutf", "MIT OR Apache-2.0", "linked into the app and `ternd`",
     ("text", mit("2021 The simdutf authors"))),
    ("Highway", "https://github.com/google/highway", "Apache-2.0 OR BSD-3-Clause",
     "linked into the app and `ternd`", ("zig", "highway", "LICENSE-BSD3")),
    ("FreeType", "https://freetype.org", "FTL", "linked", ("zig", "freetype", "docs/FTL.TXT")),
    ("libpng", "http://www.libpng.org/pub/png/libpng.html", "libpng-2.0", "linked",
     ("zig", "libpng", "LICENSE")),
    ("zlib", "https://zlib.net", "Zlib", "linked", ("zig", "zlib", "LICENSE")),
    ("Wuffs", "https://github.com/google/wuffs", "MIT OR Apache-2.0", "linked",
     ("zig", "wuffs", "LICENSE")),
    ("glslang", "https://github.com/KhronosGroup/glslang", "BSD-3-Clause and others (see text)",
     "linked", ("zig", "glslang", "LICENSE.txt")),
    ("SPIRV-Cross", "https://github.com/KhronosGroup/SPIRV-Cross", "Apache-2.0", "linked",
     ("zig", "spirv_cross", "LICENSE")),
    ("Dear ImGui", "https://github.com/ocornut/imgui", "MIT", "linked", ("zig", "imgui", "LICENSE.txt")),
    ("Dear Bindings", "https://github.com/dearimgui/dear_bindings", "MIT", "linked",
     ("text", mit("2021-2026 Ben Carter"))),
    ("sentry-native", "https://github.com/getsentry/sentry-native", "MIT", "linked",
     ("zig", "sentry", "LICENSE")),
    ("MPack (in sentry-native)", "https://github.com/ludocode/mpack", "MIT", "linked",
     ("header", "sentry", "vendor/mpack.h")),
    ("Breakpad", "https://chromium.googlesource.com/breakpad/breakpad", "BSD-3-Clause", "linked",
     ("zig", "breakpad", "LICENSE")),
    ("stb_image, stb_image_resize, stb_sprintf", "https://github.com/nothings/stb",
     "MIT OR public domain", "linked", ("text", mit("2017 Sean Barrett"))),
    ("GNU libintl (gettext 0.24)", "https://www.gnu.org/software/gettext/", "LGPL-2.1-or-later",
     "linked", ("zig", "gettext", "gettext-runtime/intl/COPYING.LIB")),
    ("JetBrains Mono", "https://github.com/JetBrains/JetBrainsMono", "OFL-1.1", "embedded font",
     ("zig", "jetbrains_mono", "OFL.txt")),
    ("Nerd Fonts Symbols Only", "https://github.com/ryanoasis/nerd-fonts", "MIT", "embedded font",
     ("zig", "nerd_fonts_symbols_only", "LICENSE")),
    ("iTerm2 Color Schemes (Ghostty themes)", "https://github.com/mbadolato/iTerm2-Color-Schemes",
     "MIT", "resources", ("text", mit("2011 to Present Mark Badolato"))),
]


def license_text(spec, deps):
    kind = spec[0]
    if kind == "text":
        return spec[1]
    if kind == "ghostty":
        return open(os.path.join(GHOSTTY, spec[1])).read()
    if spec[1] not in deps:
        sys.exit(f"Ghostty no longer names a dependency {spec[1]!r}; update scripts/notices.py")
    path = os.path.join(deps[spec[1]], spec[2])
    if not os.path.exists(path):
        sys.exit(f"missing {path}: run scripts/build-ghostty.sh first")
    if kind == "header":
        return leading_comment(path)
    return open(path, encoding="utf-8", errors="replace").read()


def rust_crates():
    """(name, version, license, repository, crate dir) for every crate linked into tern and ternd."""
    tree = subprocess.run(
        ["cargo", "tree", "--manifest-path", os.path.join(ROOT, "Cargo.toml"),
         "-e", "normal,no-proc-macro", "--prefix", "none", "--format", "{p}"],
        check=True, capture_output=True, text=True,
    ).stdout
    wanted = {tuple(line.split()[:2]) for line in tree.splitlines() if line.strip()}
    meta = json.loads(subprocess.run(
        ["cargo", "metadata", "--format-version", "1", "--manifest-path", os.path.join(ROOT, "Cargo.toml")],
        check=True, capture_output=True, text=True,
    ).stdout)
    crates = []
    for p in meta["packages"]:
        if p["source"] is None or (p["name"], "v" + p["version"]) not in wanted:
            continue
        crates.append((p["name"], p["version"], p["license"] or "", p.get("repository") or "",
                       os.path.dirname(p["manifest_path"])))
    return sorted(crates)


def crate_license(name, version, spdx, crate_dir):
    """The crate's own license file; MIT (or the non-Apache option) where it offers a choice."""
    files = sorted(os.listdir(crate_dir))
    for pattern in [r"LICEN[CS]E[-_.]?MIT", r"LICEN[CS]E[-_.]?ZLIB", r"UNLICENSE", r"COPYING", r"LICEN[CS]E(\.md|\.txt)?$"]:
        for f in files:
            if re.match(pattern, f, re.I):
                text = open(os.path.join(crate_dir, f), encoding="utf-8", errors="replace").read()
                if "Apache License" in text and "Version 2.0" in text and "MIT" in spdx:
                    continue
                return text
    sys.exit(f"no license file in {crate_dir} ({name} {version}, {spdx}); add one to scripts/notices.py")


def fence(text):
    return "```text\n" + text.rstrip() + "\n```\n"


def main():
    deps = zig_deps()
    out = [
        "# Third-party notices\n",
        "Generated by `scripts/notices.py`; don't edit by hand.\n",
        "tern itself is MIT-licensed (see `LICENSE`). Tern.app also contains the software below,",
        "under the licenses that follow. Where a project offers a choice of licenses, tern takes",
        "the MIT option (BSD-3-Clause for Highway), and that is the text reproduced here.\n",
        "Source code for tern, and for Ghostty with every library below, is available from",
        "<https://github.com/ishaanrajiv/tern> (Ghostty is the `vendor/ghostty` submodule, and",
        "`scripts/build-ghostty.sh` fetches its dependencies). That also covers the LGPL's",
        "requirement for GNU libintl: you can rebuild Tern.app against a modified libintl from it,",
        "and the MPL's for z2d, whose source is at <https://github.com/vancluever/z2d>.\n",
        "## Contents\n",
        "| Component | License | In Tern.app |",
        "|---|---|---|",
    ]
    for name, url, spdx, ships, _ in GHOSTTY_PARTS:
        out.append(f"| [{name}]({url}) | {spdx} | {ships} |")
    crates = rust_crates()
    for name, version, spdx, repo, _ in crates:
        link = f"[{name} {version}]({repo})" if repo else f"{name} {version}"
        out.append(f"| {link} | {spdx} | linked into `tern`, `ternd` |")
    out.append("")
    out.append("## Ghostty and its libraries\n")
    for name, url, spdx, _, spec in GHOSTTY_PARTS:
        out.append(f"### {name}\n\n<{url}> · {spdx}\n")
        out.append(fence(license_text(spec, deps)))
    out.append("## Rust crates\n")
    for name, version, spdx, repo, crate_dir in crates:
        out.append(f"### {name} {version}\n\n{('<' + repo + '> · ') if repo else ''}{spdx}\n")
        out.append(fence(crate_license(name, version, spdx, crate_dir)))
    with open(OUT, "w") as f:
        f.write("\n".join(out))
    print(f"wrote {OUT} ({len(GHOSTTY_PARTS)} Ghostty parts, {len(crates)} crates)")


if __name__ == "__main__":
    main()
