#!/usr/bin/env bash
# Builds tern and ternd for Linux devices, for the app to install on them over SSH:
# build/remote/linux-x86_64/ and build/remote/linux-aarch64/. scripts/build-app.sh bundles
# them into Tern.app/Contents/Resources/remote/. Runs on a Mac or on Linux.
#
# The binaries are static (musl), so they run on any Linux distribution. libghostty-vt for
# each target comes from scripts/build-ghostty.sh --vt-linux, which this runs when it's
# missing; Rust links with rust-lld, which rustup ships, so no other toolchain is needed.
#
# Needs: rustup's Rust with the musl targets (this adds them when rustup is present) and
# the Zig that scripts/build-ghostty.sh needs.
#
#   scripts/build-remote.sh [x86_64|aarch64]...   (default: both)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCHS=("$@")
[ ${#ARCHS[@]} -eq 0 ] && ARCHS=(x86_64 aarch64)

for ARCH in "${ARCHS[@]}"; do
    case "$ARCH" in
        x86_64|aarch64) ;;
        *) echo "unknown architecture $ARCH (x86_64 or aarch64)" >&2; exit 2 ;;
    esac
    TARGET="$ARCH-unknown-linux-musl"
    if [ ! -f "$ROOT/vendor/ghostty/zig-out/$TARGET/lib/libghostty-vt.a" ]; then
        "$ROOT/scripts/build-ghostty.sh" --vt-linux "$ARCH"
    fi
    if command -v rustup >/dev/null && ! rustup target list --installed | grep -qx "$TARGET"; then
        rustup target add "$TARGET"
    fi
    VAR="CARGO_TARGET_$(echo "$TARGET" | tr 'a-z-' 'A-Z_')_LINKER"
    # Stripped: these are copied to every device over SSH.
    env "$VAR=${!VAR:-rust-lld}" CARGO_PROFILE_RELEASE_STRIP=symbols \
        cargo build --release --locked --target "$TARGET" --manifest-path "$ROOT/Cargo.toml"
    OUT="$ROOT/build/remote/linux-$ARCH"
    rm -rf "$OUT"
    mkdir -p "$OUT"
    cp "$ROOT/target/$TARGET/release/tern" "$ROOT/target/$TARGET/release/ternd" "$OUT/"
    echo "built $OUT"
done
