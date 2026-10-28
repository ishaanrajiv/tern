# Working on tern

tern is an early-alpha macOS terminal for coding agents. Read `README.md` for user-facing
behaviour, shortcuts, build instructions and known gaps. Keep it current when behaviour changes.

## Repository map

- `app/` is a SwiftPM app using AppKit and SwiftUI, linked to libghostty. It requires Swift 6.2
  and builds in Swift 6 language mode with default `MainActor` isolation.
- `app/Sources/Tern/Workspace.swift` owns folders, tabs, split panes, session state and layout
  persistence. `TernClient.swift` communicates with the daemon.
- `TerminalView.swift` and `GhosttyApp.swift` connect the UI to libghostty. `Commands.swift`
  supplies both the menu bar and command palette.
- `Shortcuts.swift` declares every app shortcut: stable id, title, menu, default keys and
  the rules that keep ⌃/⌥ keys for the terminal. Add or change bindings there, then regenerate
  the README's Keys table with `TERN_UPDATE_README=1 swift test --package-path app`.
- `SidebarView.swift`, `ContentHeader.swift` and `AgentLogos.swift` draw session status.
  Keep status meanings consistent across rows, collapsed folders and the content header.
- `crates/tern/` contains the Rust `tern` CLI and `ternd` daemon. `src/lib.rs` defines the shared
  protocol; `src/bin/tern.rs` is the CLI; `src/bin/ternd/` owns PTYs and screen persistence.
- `crates/tern/src/hooks.rs`, `shell.rs` and `usage.rs` handle agent hooks, shell integration
  and usage limits.
- `vendor/ghostty/` is a git submodule. Read its applicable `AGENTS.md` files before changing it.
- `scripts/` contains builds, checks and third-party notice generation. `build/`, `target/`,
  `app/.build/` and `.zig-deps/` are generated output or caches.

## Build and validation

Run commands from the repository root unless a command specifies otherwise.

```sh
# First build, or after updating Ghostty. Requires the pinned Zig and Xcode Metal toolchain.
git submodule update --init
./scripts/build-ghostty.sh

# Build build/Tern.app without replacing the installed app.
./scripts/build-app.sh

# Full code checks.
./scripts/check.sh
```

`scripts/check.sh` runs Rust tests, the build scripts' Python tests, Clippy with warnings denied,
a Swift build that rejects new warnings except those in `DebugHooks.swift`, and Swift tests. It needs the built
`vendor/ghostty/macos/GhosttyKit.xcframework`. For focused checks:

```sh
cargo test
cargo clippy --all-targets -- -D warnings
swift build --package-path app
swift test --package-path app
```

Add regression tests for changes to protocol handling, layout recovery, terminal snapshots or
other nontrivial behaviour. Existing Rust tests live beside the implementation; Swift tests live
in `app/Tests/TernTests/`. Documentation-only changes need a diff and link review rather than a
full app build. Report which checks ran and any that could not run.

`./scripts/build-app.sh --debug` selects a debug Swift build. `--install` replaces
`~/Applications/Tern.app`. `--dist` signs with Developer ID, notarizes and writes a versioned ZIP
and checksum under `build/`. Use it when a distribution build is requested.
See the README for signing setup.

## Constraints to preserve

- Terminal input and output flow through a libghostty surface and the `tern attach` relay.
  `ternd` owns the PTYs under launchd so quitting the app does not end sessions.
- Protocol changes must agree across Rust definitions and the Swift client. Bump `PROTOCOL` in
  `crates/tern/src/lib.rs` when an older peer would misread a request, reply or frame. Preserve
  the startup handshake and daemon mismatch handling.
- Layout loading tolerates partially invalid files and keeps backups. Preserve that recovery
  behaviour when changing persistence. A daemon restart restores saved screens but ends running
  processes; do not treat it as a harmless app restart.
- AppKit and workspace changes belong on the main actor. Keep blocking process, network and
  filesystem work off the UI thread, and respect Swift 6 concurrency checks.
- Agent hook installation and removal must preserve unrelated user configuration. Usage polling
  must not refresh Claude Code's authentication token.
- App shortcuts take precedence over terminal bindings. Preserve confirmation for multiline
  pastes without bracketed paste and for terminal clipboard access.
- The CLI belongs in the app's `Contents/Helpers`, because `tern` and `Tern` collide on
  case-insensitive filesystems.
- After changing Ghostty or Rust dependencies, regenerate `THIRD_PARTY_NOTICES.md` with
  `python3 scripts/notices.py` after fetching the dependencies it reads.

## Isolated UI and daemon checks

Use a private `TERN_RUNTIME_DIR` for experiments that create sessions or restart the daemon. Keep
its path short, under roughly 100 characters, because Unix socket paths have a fixed limit.
Both the app and CLI must use the same value. This isolates layout, debug files and the binary
link, leaves installed agent hooks alone, and spawns a private daemon without launchd.

`TERN_DEBUG=1` enables the controls documented at the top of `DebugHooks.swift` in debug builds
(`swift build`, `./scripts/build-app.sh --debug`); release builds compile them out. `SIGUSR1` saves
window screenshots under the runtime directory's `debug/` folder. `SIGUSR2` reads `debug/command`
and runs a palette command or a supported keyboard or mouse action. Use the private app's PID.
Avoid restarting or killing the user's normal daemon during validation.
