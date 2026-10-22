# Releasing tern

The first release is the private `0.0.1` prerelease for Apple Silicon. Prepare subsequent
candidates as drafts and record their validation and remaining gaps before publication.
Repository visibility is a separate decision; see
[the public-readiness review](docs/public-readiness.md).

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

Expected outputs:

- `build/Tern-0.0.1-macos-arm64.zip`
- `build/Tern-0.0.1-macos-arm64.zip.sha256`
- `build/Tern-0.0.1-source.tar.gz`
- `build/Tern-0.0.1-source.tar.gz.sha256`

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
Use [the release notes](docs/0.0.1-release-notes.md) and add the commit, notarization outcome,
checks actually performed, and any remaining checks. Verify the uploaded asset digests.
Keep the release in draft while separate-Mac or quarantine testing is outstanding.

Before publishing, test a quarantined download on a separate Mac, including macOS 14 if
that version is claimed as tested. Check shell and Codex copy/paste, splits, find,
quit/relaunch reattachment, layout recovery, hooks, agent status, presets and SSH. Daemon
restart ends running processes, so any restart test must use only the private daemon.
Public binary distribution also requires the unresolved runtime fixes in the review.
