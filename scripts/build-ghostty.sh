#!/usr/bin/env bash
# Builds vendor/ghostty/macos/GhosttyKit.xcframework (libghostty for macOS, which the
# app links) and vendor/ghostty/zig-out/lib/libghostty-vt.a (the terminal engine
# ternd links; Rust builds need it, see crates/tern/build.rs).
#
# Zig's own package fetcher has been flaky here (TLS failures, stalls), so this
# downloads every dependency with curl into .zig-deps/<hash>/ and builds with
# `zig build --system`, which never touches the network.
#
# Needs: zig matching vendor/ghostty's minimum_zig_version (brew install zig),
# and Xcode's Metal toolchain (xcodebuild -downloadComponent MetalToolchain).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY="$ROOT/vendor/ghostty"
DEPS="$ROOT/.zig-deps"
DL="$DEPS/.downloads"
mkdir -p "$DL"

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
        if not os.path.isdir(os.path.join(deps, h)):
            seen[h] = url
for h, u in seen.items():
    print(h, u)
EOF
}

while true; do
  missing="$(fetch_round)"
  [ -z "$missing" ] && break
  while read -r hash url; do
    case "$url" in
      git+https://github.com/*)
        # git+https://github.com/owner/repo(.git)#commit -> codeload tarball
        repo="${url#git+}"; commit="${repo##*#}"; repo="${repo%%#*}"; repo="${repo%.git}"
        url="$repo/archive/$commit.tar.gz" ;;
      git+*)
        repo="${url#git+}"; commit="${repo##*#}"; repo="${repo%%#*}"
        tmp="$DL/git-$hash"; rm -rf "$tmp"
        git clone -q "$repo" "$tmp" && git -C "$tmp" checkout -q "$commit"
        rm -rf "$tmp/.git"; mv "$tmp" "$DEPS/$hash"
        echo "fetched $hash (git)"; continue ;;
    esac
    file="$DL/$hash.archive"
    curl -fsSL --retry 3 -o "$file" "$url"
    mkdir -p "$DEPS/$hash"
    # Strip the single top-level directory most archives have.
    if [ "$(tar tf "$file" | cut -d/ -f1 | sort -u | wc -l | tr -d ' ')" = 1 ]; then
      tar xf "$file" -C "$DEPS/$hash" --strip-components=1
    else
      tar xf "$file" -C "$DEPS/$hash"
    fi
    echo "fetched $hash"
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
