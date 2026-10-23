# tern

A macOS terminal built around coding agents. The sidebar shows which agent needs you, the keys are
Mac-native, and sessions survive quitting the app.

> [!WARNING]
> **Early alpha.** Expect rough edges,
> breaking changes, and settings or saved sessions that don't carry over. Get the
> [latest Apple Silicon prerelease](https://github.com/ishaanrajiv/tern/releases) or
> [build from source](#build). It targets macOS 14 or later, but hasn't been tested on 14 yet.

## Features

- **Folders and tabs.** The sidebar groups tabs by folder. ⌘N opens the folder picker (open
  folders, recent ones, [zoxide](https://github.com/ajeetdsouza/zoxide) history, and git repos
  under `~/dev`). ⌘T opens a tab in the current folder, ⌘⇧T opens one in a new git worktree.
  Tabs name themselves after what they run. Double-click or ⌘R to rename.
- **Agent status.** Claude Code and Codex report whether they're working, waiting for you, or done.
  ⌘J jumps to the next tab that needs you, and the Dock badge counts the waiting ones.
- **Usage limits.** The foot of the sidebar shows each agent's 5-hour and weekly limits.
- **Persistent sessions.** A daemon owns the shells, so quitting tern leaves them running. After a
  reboot or daemon restart, panes come back with their old screens and agent conversations resume.
- **Splits, Find and links.** ⌘D splits panes, ⌘F searches scrollback, ⌘-click opens URLs.
- **SSH.** File → Connect over SSH… uses your own SSH config and can reattach to a named tmux
  session on the host.
- **Launch presets.** File → Project Launch Presets… saves a folder's tabs, splits, startup
  commands and environment variables, and recreates them later.
- **Agent updates.** tern checks npm for newer Claude Code and Codex releases and offers to update.

### Agent status

| Glyph | Meaning |
|---|---|
| Amber, bold name, tinted row | Needs you: a permission prompt or a question |
| Blue | Working |
| Text-coloured, bold name | Done, and you haven't looked yet |
| Grey | Idle |
| Faint | Dormant, or waiting to be reopened after a restart |

For accurate states, open Settings (⌘,) and click **Set Up** for Claude Code and Codex. This adds
a `tern hook` command to `~/.claude/settings.json` and `~/.codex/hooks.json`, and **Remove** takes it
out again without touching your other settings. In Codex, run `/hooks` once to trust them. Without
hooks, tern guesses each agent's state from its output.

Codex usage limits come from its session logs. Claude Code limits come from its status line, and
optionally (Settings → Agents, off by default) from Anthropic's API using the sign-in Claude Code
keeps in the Keychain. tern never refreshes that token.

## Keys

| Keys | Action |
|---|---|
| ⌘K | Command palette |
| ⌘J | Next tab needing attention |
| ⌘N | Open a folder |
| ⌘T / ⌘⇧T | New tab / new tab in its own worktree |
| ⌘O | Browse for a folder in Finder |
| ⌘D / ⌘⇧D | Split right / split down |
| ⌘⌥ + arrows, ⌘[ / ⌘] | Move focus between panes |
| ⌘⌃ + arrows | Resize the focused pane |
| ⌘↩ | Zoom the focused pane |
| ⌘1–9 / ⌘⇧1–9 | Folder / tab within the folder |
| ⌘⇧[ / ⌘⇧], ⌃⇥ | Previous / next tab |
| ⌘W / ⌘⇧W / ⌘⌥W | Close pane / tab / folder |
| ⌘F, ⌘G / ⌘⇧G | Find, next / previous match |
| ⌘R | Rename tab |
| ⌘\ | Toggle sidebar |
| ⌘⇧K | Clear screen |
| ⌘= / ⌘- / ⌘0 | Text size |
| ⌘, | Settings |

tern's shortcuts take priority over terminal bindings. You can rebind both in Settings → Terminal.
Multiline pastes without bracketed paste, and clipboard access through escape codes, ask first.

## Build

You need Xcode with Swift 6.2 and the Metal toolchain, Rust, Python 3, curl, and the Zig version
named by `minimum_zig_version` in `vendor/ghostty/build.zig.zon` (currently `0.17.0`).

```bash
xcodebuild -downloadComponent MetalToolchain
```

```bash
git submodule update --init
```

```bash
./scripts/build-ghostty.sh
```

```bash
./scripts/build-app.sh --install
```

```bash
open ~/Applications/Tern.app
```

`build-app.sh` writes `build/Tern.app`. `--install` copies it to `~/Applications`, and `--debug`
makes a debug build. It signs with your Apple Development identity if you have one, or ad hoc.
Set `TERN_SIGN_IDENTITY` to pick another, or `-` for ad hoc.

`build-ghostty.sh` downloads and verifies Ghostty's Zig dependencies into `.zig-deps/`, then builds
offline. If a cached download fails verification, delete `.zig-deps/.downloads/<hash>.archive` and
run it again. After updating the submodule, regenerate ternd's bindings with
`scripts/vt-bindings.sh` (needs `cargo install bindgen-cli`) and the notices with
`python3 scripts/notices.py`.

Run all checks with:

```bash
./scripts/check.sh
```

### Distribution build

A signed, notarized build needs a Developer ID Application certificate and a notarytool profile:

```bash
xcrun notarytool store-credentials tern --apple-id <email> --team-id <TEAMID>
```

```bash
./scripts/build-app.sh --dist
```

This writes `build/Tern-<version>-macos-<arch>.zip` and a `.sha256` file. `TERN_NOTARY_PROFILE`
overrides the profile name. See [RELEASING.md](RELEASING.md) for release checks and the source
bundle.

## How it works

```
Tern.app (Swift, AppKit)
  └─ TerminalView ── libghostty surface (Zig, Metal)
       └─ child process: tern attach <session>      ← byte relay over a unix socket
                              │
ternd (Rust, launchd agent dev.tern.ternd)
  └─ owns each session's PTY + a headless libghostty-vt terminal
```

ternd runs under launchd because macOS kills an app's child processes when it quits. Its headless
terminal is Ghostty's own engine, so a reattaching pane gets back exactly what it showed. The log is
at `~/Library/Application Support/tern/ternd.log`.

The `tern` CLI lives in `Tern.app/Contents/Helpers`. Run it with no arguments to list its commands,
which include `ls`, `kill`, `hooks` and `daemon status|restart`.

Set `TERN_RUNTIME_DIR` to a short path (under about 100 characters) to run a private instance for
testing. It keeps its own layout and spawns its own daemon without launchd.

## Known gaps

- A reboot or ternd restart ends running processes. Screens come back, and the command that was
  running is typed at the prompt but not run. Full-screen programs like vim aren't saved while
  they're open.
- Upgrading ternd ends the processes in your tabs.
- A turn that ends without a Stop hook (an API error, or Esc while the model is writing) sends no
  "done" event. tern treats an agent that has been silent for five seconds as finished.
- **Notifications don't work.** macOS refuses tern's permission request without showing a prompt.
  A minimal test app gets the same refusal, so the cause seems to be how macOS treats locally built
  apps. The Dock badge, Dock bounce and ⌘J still work.
- **⌘C and ⌘V don't work inside Codex.** They work in a plain shell, and the keys do reach tern.
  The cause is unknown.
- Bare file paths with line numbers aren't detected as links yet.

## Privacy

tern has no account and no telemetry. It reaches the network only to check npm for agent updates,
to fetch Claude Code usage limits if you turn that on, and for SSH connections and commands you run.

Everything else stays unencrypted in `~/Library/Application Support/tern`: the layout, launch presets
(environment values in plain text), saved screens, typed commands, usage numbers and ternd's log.
ternd keeps that folder readable only by you, and its socket refuses other users. Setting up hooks
leaves a `.tern-backup` copy of each agent config it edits. See [SECURITY.md](SECURITY.md).

## Contributing

Issues and small pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md), and report
security problems privately as [SECURITY.md](SECURITY.md) describes.

## License

tern is released under the [MIT License](LICENSE). Tern.app also contains Ghostty's libghostty and
libghostty-vt (MIT) and the libraries and Rust crates they and tern use, listed with their licenses
in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Most are MIT, BSD, Apache-2.0 or zlib-style.
The exceptions are GNU libintl (LGPL-2.1-or-later) and z2d (MPL-2.0), both statically linked by
libghostty. Their source, and tern's, is available as the notices describe.

tern is not affiliated with Ghostty, Anthropic or OpenAI.
