# Contributing to tern

tern is a personal project in early alpha, with one maintainer. Issues are welcome and are the
fastest way to get something changed. Pull requests are welcome too, but for anything bigger than
a small fix, open an issue first so the work fits how the app is put together.

Before reporting a bug, check [Known gaps](README.md#known-gaps). Report security problems
privately, as [SECURITY.md](SECURITY.md) describes.

## Building and checking

[Build](README.md#build) in the README lists the requirements: Xcode with the Metal toolchain,
Rust, Python 3 and the exact Zig version `vendor/ghostty` pins. The first
`scripts/build-ghostty.sh` takes a while: it verifies every Zig dependency against its pinned hash,
then builds libghostty.

Run the full checks before a pull request:

```sh
./scripts/check.sh
```

That runs the Rust tests, the build scripts' Python tests, Clippy with warnings denied, a Swift
build that fails on new warnings, and the Swift tests. [AGENTS.md](AGENTS.md) has the repository
map, the constraints to preserve, and how to test against a private daemon without touching your
own sessions.

## Changes

- One topic per pull request. Say what changed and how you tested it.
- Add a regression test for changes to the protocol, layout recovery, terminal snapshots or other
  nontrivial behaviour.
- Update the README when behaviour changes.
- Match the surrounding code. The Rust isn't run through rustfmt; keep its style instead.
- A protocol change has to agree between the Rust definitions and the Swift client; bump `PROTOCOL`
  in `crates/tern/src/lib.rs` when an older peer would misread it.
- A new dependency needs a reason in the pull request, an MIT-compatible licence, and
  `THIRD_PARTY_NOTICES.md` regenerated with `python3 scripts/notices.py`.
