#!/usr/bin/env bash
# Builds vendor/ghostty/macos/GhosttyKit.xcframework (libghostty for macOS, which the
# app links) and vendor/ghostty/zig-out/lib/libghostty-vt.a (the terminal engine
# ternd links; Rust builds need it, see crates/tern/build.rs).
#
# Zig's own package fetcher has been flaky here (TLS failures, stalls), so this
# downloads every dependency with curl into .zig-deps/<hash>/, checks each against
# the hash its build.zig.zon pins (scripts/fetch-zig-package.py, using Zig's own
# hashing) and builds with `zig build --system`, which never touches the network.
#
# Needs: zig matching vendor/ghostty's minimum_zig_version (brew install zig),
# and Xcode's Metal toolchain (xcodebuild -downloadComponent MetalToolchain).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY="$ROOT/vendor/ghostty"
DEPS="$ROOT/.zig-deps"
DL="$DEPS/.downloads"
mkdir -p "$DL"
REQUIRED_ZIG="$(sed -n 's/.*minimum_zig_version = "\([^"]*\)".*/\1/p' "$GHOSTTY/build.zig.zon")"
if [ "$(zig version)" != "$REQUIRED_ZIG" ]; then
  echo "Ghostty needs Zig $REQUIRED_ZIG exactly (package hashes depend on it); found $(zig version)" >&2
  exit 1
fi

# Resolve the dependency tree breadth-first: each fetched package's own
# build.zig.zon can name more dependencies.
fetch_round() {
  python3 -I - "$GHOSTTY" "$DEPS" <<'EOF'
import glob, os, re, sys
ghostty, deps = sys.argv[1], sys.argv[2]
zons = glob.glob(f"{ghostty}/**/build.zig.zon", recursive=True) + glob.glob(f"{deps}/*/build.zig.zon")
seen = {}
for f in zons:
    text = open(f).read()
    for url, h in re.findall(r'\.url\s*=\s*"([^"]+)"\s*,\s*\.hash\s*=\s*"([^"]+)"', text):
        # Only packages fetch-zig-package.py verified count as present.
        if not (os.path.isdir(os.path.join(deps, h)) and os.path.isfile(os.path.join(deps, ".verified", h))):
            seen[h] = url
for h, u in seen.items():
    print(h, u)
EOF
}

while true; do
  missing="$(fetch_round)"
  [ -z "$missing" ] && break
  while read -r hash url; do
    python3 -I "$ROOT/scripts/fetch-zig-package.py" "$hash" "$url" "$DEPS" < /dev/null
  done <<< "$missing"
done

cd "$GHOSTTY"
zig build --system "$DEPS" \
  -Doptimize=ReleaseFast \
  -Demit-xcframework=true \
  -Demit-macos-app=false \
  -Demit-docs=false \
  -Dxcframework-target=native
test -f "$GHOSTTY/zig-out/lib/libghostty-vt.a" || { echo "zig build made no libghostty-vt.a" >&2; exit 1; }
echo "built $GHOSTTY/macos/GhosttyKit.xcframework and $GHOSTTY/zig-out/lib/libghostty-vt.a"
