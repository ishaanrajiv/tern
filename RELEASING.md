# Releasing

tern is versioned as `MAJOR.MINOR.PATCH`, starting at `0.0.1`. The version lives in three places and
must agree:

| Where | File |
|---|---|
| The app | `app/Info.plist` → `CFBundleShortVersionString` |
| The CLI and daemon | `crates/tern/Cargo.toml` → `version` (and `Cargo.lock`) |
| The zip name | read from the app's `Info.plist` by `scripts/build-app.sh` |

`git tag` names the release. The tag and the version must match: `v0.0.1` for `0.0.1`.

Keep `CFBundleVersion` in `app/Info.plist` increasing when you ship another build of the same
app version, so macOS can tell them apart.

## What a release needs

1. **A Developer ID Application certificate** in the keychain, and a notarytool profile. Without
   them the app cannot be signed for anyone else's Mac, and Gatekeeper will refuse it.

   ```bash
   security find-identity -v -p codesigning
   xcrun notarytool store-credentials tern --apple-id <email> --team-id <TEAMID>
   ```

2. **A clean tree** on `main`, with the submodule pinned:

   ```bash
   git submodule update --init
   git status
   ```

3. **Fresh notices.** If the Ghostty submodule or the Rust dependencies moved since the last
   release:

   ```bash
   python3 scripts/notices.py
   ```

## Building

```bash
./scripts/build-ghostty.sh
./scripts/build-app.sh --dist
```

`--dist` signs with the Developer ID identity, enables the hardened runtime, notarizes the zip,
staples the ticket to the app, re-zips it so the copy you hand out opens offline, and writes:

```
build/Tern-<version>-macos-<arch>.zip
build/Tern-<version>-macos-<arch>.zip.sha256
```

It fails early, before the long build, if the certificate or the notarytool profile is missing.

Check the result before publishing it:

```bash
spctl --assess --type execute -vv build/Tern.app
codesign --verify --strict --deep build/Tern.app
```

## Publishing

```bash
git tag -a v0.0.1 -m "tern 0.0.1"
git push origin main --tags
gh release create v0.0.1 \
  build/Tern-0.0.1-macos-arm64.zip \
  build/Tern-0.0.1-macos-arm64.zip.sha256 \
  --title "tern 0.0.1" \
  --notes-file notes.md
```

Put the download and the checksum in the release notes, and say plainly what is broken. tern is
alpha software; a note that says which parts still misbehave is worth more than a feature list.

Apple notarization takes a few minutes and can reject a build. If it does:

```bash
xcrun notarytool log <submission-id> --keychain-profile tern
```

## Afterwards

- The README's **Known gaps** should describe the version you shipped.
- The **Privacy** section must list every network call the release makes. If a release adds one,
  that section changes in the same pull request.
