# Releasing tern

Releases are Apple Silicon prereleases, published on GitHub with their release notes in
`docs/<version>-release-notes.md`. Prepare each candidate as a draft and record its validation
and remaining gaps before publishing it.

## One-time setup

Install a Developer ID Application certificate and its private key in this Mac's Keychain.
Save notarization credentials once with the interactive command:

```sh
xcrun notarytool store-credentials tern
```

The password belongs in the secure prompt. No credentials or private keys belong in the
repository. `TERN_SIGN_IDENTITY` and `TERN_NOTARY_PROFILE` override the selected signing
identity and the default `tern` Keychain profile.

## Prepare and build

Use an arm64 Mac with the Xcode, Metal, Swift, Rust and pinned Zig requirements from
README.md. Keep the Ghostty submodule at the recorded commit and build it first if needed.
The app and Rust package versions must agree with the intended tag, and `CFBundleVersion`
must increase for later distributed builds of the same version.

Commit the release changes and run:

```sh
./scripts/check.sh
./scripts/build-app.sh --dist
python3 scripts/package-source.py
```

The source packager requires a clean tree and the fetched native dependency sources.
It records tern and Ghostty commits, vendors the locked Rust crates, and excludes build
outputs, compiler caches, Git metadata and the download cache. It includes `SOURCE_BUILD.md`
with toolchain details and instructions for rebuilding the app against modified dependency
sources. Retain these sources alongside the binary and review `THIRD_PARTY_NOTICES.md`.

Expected outputs, for version `X.Y.Z`:

- `build/Tern-X.Y.Z-macos-arm64.zip`
- `build/Tern-X.Y.Z-macos-arm64.zip.sha256`
- `build/Tern-X.Y.Z-source.tar.gz`
- `build/Tern-X.Y.Z-source.tar.gz.sha256`

The distribution build signs the helpers and app with hardened runtime and secure
timestamps, submits to Apple, staples and validates the ticket, assesses the app with
Gatekeeper, and computes the checksum from the final ZIP. It does not install the app
unless `--install` is supplied.

## Verify and upload

Check the versions, native architecture, all signatures, stapled ticket and checksums.
Extract the source archive and verify the included Rust crates work offline after building
the native library. Smoke-test with a short private `TERN_RUNTIME_DIR`, preserving the
maintainer's installed app, normal daemon and real hooks.

Upload all four assets to a GitHub draft prerelease targeting the exact tested commit.
Use that version's release notes and add the commit, notarization outcome,
checks actually performed, and any remaining checks. Verify the uploaded asset digests.
Publish it as a prerelease, and list in its notes every check below that hasn't been done.

Test a quarantined download on a separate Mac, including macOS 14 before claiming that
version as tested. Check shell and Codex copy/paste, splits, find,
quit/relaunch reattachment, layout recovery, hooks, agent status, presets and SSH. Daemon
restart ends running processes, so any restart test must use only the private daemon.
