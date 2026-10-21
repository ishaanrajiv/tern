# Releasing tern

The first release is `v0.0.1`, an early alpha for Apple Silicon on macOS 14 or later.
The app version in `app/Info.plist`, Rust package version, and `Cargo.lock` must agree.
Keep `CFBundleVersion` increasing when shipping another build of the same app version.

## Build and verify

Use a clean checkout with the Ghostty submodule initialized at its pinned commit. Install
the exact Zig version from its `build.zig.zon`, Rust, Python 3.9+, and Xcode with the Metal
toolchain and support for `.icon` assets. Build on Apple Silicon for the arm64 artifact.

```bash
git submodule update --init
./scripts/build-ghostty.sh
cargo test --locked
python3 -m unittest discover -s scripts/tests -v
```

Set up a Developer ID Application certificate and a notarytool keychain profile named
`tern`. `TERN_SIGN_IDENTITY` and `TERN_NOTARY_PROFILE` override these choices.

```bash
./scripts/build-app.sh --dist
```

This signs all executables with the hardened runtime, submits the app for notarization,
staples the ticket, checks Gatekeeper, and produces:

- `build/Tern-0.0.1-macos-arm64.zip`
- `build/Tern-0.0.1-macos-arm64.zip.sha256`

The scripts build for the host architecture. Do not call an arm64 artifact universal.
Building an Intel artifact requires an x86_64 build of the Swift app, Rust helpers, and
libghostty, followed by the same signing and notarization checks.

## Sources and notices

Regenerate `THIRD_PARTY_NOTICES.md` after changing Ghostty or Rust dependencies and include
it in the release app. The app statically links libintl, so preserve the exact library sources
and the code and build instructions needed to rebuild with a modified version.

Alongside the binary, publish a source archive containing the release's tracked tern files,
the pinned Ghostty checkout, fetched `.zig-deps/<hash>` source directories, and vendored Rust
crates. Include a Cargo source replacement config from `cargo vendor --locked` and record the
tern and Ghostty commit IDs. Exclude `.git`, compiler caches, download caches, and build outputs.
GitHub's automatic source archive omits submodule contents and fetched dependencies, so it does
not contain all these sources. Check an extracted copy by building with the documented toolchain
and a modified libintl before uploading the release assets. Keep this archive available with
the binary. See `THIRD_PARTY_NOTICES.md` for the library licenses.

## Smoke test and publish

Download the notarized zip onto a separate Mac so it has normal download quarantine.
Verify its checksum, unzip it, move the app to Applications, and open it without removing
quarantine attributes. Check terminal input, split panes, app quit and reattachment, agent
hook setup and removal, and the Dock badge. Test on macOS 14 before claiming that minimum
has been verified. Notification delivery remains a known limitation and belongs in the notes.

Tag the tested commit `v0.0.1`. Create a GitHub prerelease and attach the zip, checksum,
and complete source archive. Link the binary and source explicitly in the release notes.
Do not publish a locally signed or ad-hoc app as the notarized release.
