#!/usr/bin/env bash
# Builds build/Tern.app: Swift UI + libghostty, with the Rust tern/ternd binaries inside.
# Needs vendor/ghostty/macos/GhosttyKit.xcframework (see scripts/build-ghostty.sh).
#
#   --install   also copy it to ~/Applications/Tern.app. Run tern from there: macOS
#               refuses notification permission to apps run from a build folder.
#   --debug     debug Swift build
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG=release
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --debug) CONFIG=debug ;;
        *) echo "unknown option $arg" >&2; exit 2 ;;
    esac
done

cargo build --release --manifest-path "$ROOT/Cargo.toml"
swift build -c "$CONFIG" --package-path "$ROOT/app"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT/app" --show-bin-path)"

APP="$ROOT/build/Tern.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/Tern" "$APP/Contents/MacOS/Tern"
# Helpers/, not MacOS/: "tern" and "Tern" collide on a case-insensitive filesystem.
cp "$ROOT/target/release/tern" "$ROOT/target/release/ternd" "$APP/Contents/Helpers/"
cp -R "$ROOT/vendor/ghostty/zig-out/share/ghostty" "$ROOT/vendor/ghostty/zig-out/share/terminfo" "$APP/Contents/Resources/"
cp "$ROOT/app/Info.plist" "$APP/Contents/Info.plist"
# macOS only lets properly signed apps ask for notification permission, so sign
# with an Apple Development identity when there is one (override with
# TERN_SIGN_IDENTITY; "-" means ad-hoc, which works for everything else).
IDENTITY="${TERN_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1)}"
codesign --force --deep --sign "${IDENTITY:--}" "$APP" >/dev/null
echo "built $APP (signed: ${IDENTITY:-ad-hoc})"

if [ "$INSTALL" = 1 ]; then
    # Replace, don't overwrite in place: a running ternd keeps its old binary until restarted.
    DEST="$HOME/Applications/Tern.app"
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    echo "installed $DEST"
fi
