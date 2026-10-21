#!/usr/bin/env bash
# Builds build/Tern.app: Swift UI + libghostty, with the Rust tern/ternd binaries inside.
# Needs vendor/ghostty/macos/GhosttyKit.xcframework (see scripts/build-ghostty.sh).
#
#   --install   also copy it to ~/Applications/Tern.app. Run tern from there: macOS
#               refuses notification permission to apps run from a build folder.
#   --debug     debug Swift build
#   --dist      build to run on other Macs: sign with Developer ID and the hardened
#               runtime, notarize, staple, and write build/Tern.zip. Needs a
#               "Developer ID Application" certificate and a notarytool keychain
#               profile named tern (override with TERN_NOTARY_PROFILE):
#                 xcrun notarytool store-credentials tern --apple-id <email> --team-id <TEAMID>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG=release
INSTALL=0
DIST=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --debug) CONFIG=debug ;;
        --dist) DIST=1 ;;
        *) echo "unknown option $arg" >&2; exit 2 ;;
    esac
done
if [ "$DIST" = 1 ] && [ "$CONFIG" = debug ]; then
    echo "--dist and --debug don't mix" >&2; exit 2
fi

identity() {
    security find-identity -v -p codesigning 2>/dev/null | sed -n "s/.*\"\($1: .*\)\"/\1/p" | head -1
}
if [ "$DIST" = 1 ]; then
    IDENTITY="${TERN_SIGN_IDENTITY:-$(identity "Developer ID Application")}"
    if [ -z "$IDENTITY" ]; then
        echo "no Developer ID Application certificate in the keychain (Xcode > Settings > Accounts > Manage Certificates)" >&2
        exit 1
    fi
    PROFILE="${TERN_NOTARY_PROFILE:-tern}"
    # Fail before the long build, not after it.
    if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
        echo "no notarytool profile \"$PROFILE\"; see the header of $0" >&2
        exit 1
    fi
else
    # macOS only lets properly signed apps ask for notification permission, so sign
    # with an Apple Development identity when there is one (override with
    # TERN_SIGN_IDENTITY; "-" means ad-hoc, which works for everything else).
    IDENTITY="${TERN_SIGN_IDENTITY:-$(identity "Apple Development")}"
fi

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
# The licenses of everything bundled above; regenerate with scripts/notices.py.
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/"
# Tern.icon has light and dark variants (macOS 26+); actool also writes Tern.icns for older macOS.
xcrun actool "$ROOT/app/Tern.icon" --compile "$APP/Contents/Resources" --app-icon Tern \
    --platform macosx --minimum-deployment-target 14.0 \
    --output-partial-info-plist "$(mktemp -t tern-icon)" >/dev/null

# Sign the helpers first, then the bundle that seals them. Notarization needs the
# hardened runtime and a secure timestamp on every executable.
SIGN=(codesign --force --sign "${IDENTITY:--}")
[ "$DIST" = 1 ] && SIGN+=(--options runtime --timestamp)
"${SIGN[@]}" "$APP/Contents/Helpers/tern" "$APP/Contents/Helpers/ternd" >/dev/null
"${SIGN[@]}" "$APP" >/dev/null
codesign --verify --strict --deep "$APP"
echo "built $APP (signed: ${IDENTITY:-ad-hoc})"

if [ "$DIST" = 1 ]; then
    ZIP="$ROOT/build/Tern.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "notarizing (usually a few minutes)..."
    # On a rejection, `xcrun notarytool log <id> --keychain-profile tern` says why.
    xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$APP"
    # Re-zip so the copy you hand out carries the stapled ticket and opens offline.
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    spctl --assess --type execute -vv "$APP"
    echo "ready to copy: $ZIP"
fi

if [ "$INSTALL" = 1 ]; then
    # Replace, don't overwrite in place: a running ternd keeps its old binary until restarted.
    DEST="$HOME/Applications/Tern.app"
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    echo "installed $DEST"
fi
