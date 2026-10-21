# Contributing to tern

tern is a personal project that has been open sourced. It is not a product with a roadmap, and the
author is the only maintainer, so pull requests are welcome but rarely merged quickly. Issues are
the faster route to a change.

## Before you start

- **Check the [known gaps](README.md#known-gaps)** in the README. Notifications do not work on a
  locally built app, and there are open questions about ⌘C and ⌘V inside Codex. If your problem is
  one of those, it is already known.
- **Small fixes are easiest.** A typo, a missing test or a clearer error message usually goes
  straight in.
- **Bigger changes**: open an issue first and say what you have in mind. This avoids work that does
  not fit how the app is put together.

## Building

You need Xcode (with the Metal toolchain), Rust, and the exact Zig version `vendor/ghostty` pins.
The README's [Build](README.md#build) section has the commands; `scripts/build-ghostty.sh` takes a
while the first time, because it builds libghostty from source.

To work on the daemon without building the app:

```bash
cargo test
cargo build --release
```

## Checks

```bash
cargo clippy --all-targets -- -D warnings
cargo test
python3 -m unittest discover -s scripts/tests
```

The Swift side is checked by building it:

```bash
swift build -c release --package-path app
```

The Rust code is not rustfmt-formatted, and `cargo fmt` is not one of the checks: the style here
keeps calls and chains on one long line rather than wrapping them, and running rustfmt over the
tree would rewrite most of it. Match the surrounding code instead.

## Style

The code is commented in the same voice as the rest of the project: say what the code does and why,
in plain words, and skip the obvious. Match the surrounding code rather than importing habits from
elsewhere. Comments earn their place by explaining something a reader would otherwise have to work
out.

- Swift: four-space indent, no `self.` where it is not needed, types in `PascalCase`.
- Rust: `snake_case`, `anyhow::Context` for errors that need a sentence.

## Commit messages

One thing per commit, and the subject says what changed rather than how. Explain why in the body
when the reason is not obvious from the diff.

## Adding a dependency

The app embeds Ghostty and links a handful of Rust crates, so every dependency is also a licensing
and notice question. If you add one:

1. Say so in the pull request, and say why the standard library or what is already there will not do.
2. Run `python3 scripts/notices.py` to regenerate `THIRD_PARTY_NOTICES.md`.
3. Check the licence is compatible with tern's MIT licence, and that the licence text is included.

## Pull requests

- One topic per pull request.
- Say what you changed and how you tested it.
- If it changes the app's behaviour, say so in the pull request description. The README is usually
  the place that has to change too.

## Reporting bugs

Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.yml). A version, a macOS version and
the output of `tern --version` (or the app's About box) help more than anything.

If the bug is a security issue, do not open a public issue. See [SECURITY.md](SECURITY.md).
