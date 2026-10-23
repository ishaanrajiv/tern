# tern

A macOS terminal built around coding agents: a sidebar that shows which agent needs you,
Mac-native keys, and sessions that survive quitting the app.

> [!WARNING]
> **Early alpha.** tern is a personal project, built for its author's own use and not yet tried by
> anyone else. Expect rough edges, breaking changes between commits, and settings or saved sessions
> that don't carry over. Download the [latest Apple Silicon prerelease](https://github.com/ishaanrajiv/tern/releases)
> or [build from source](#build). It targets macOS 14 or later; testing on macOS 14 is still
> outstanding.

One window holds a sidebar of folders and their tabs, split panes, a ⌘K command palette and a
Mac-native keymap. Claude Code and Codex report whether they're working, waiting for you, or done,
and ⌘J takes you to the next one needing attention. The Dock badge counts agents waiting for you.
Notification banners are implemented but currently blocked by a macOS permission issue; see
[Known gaps](#known-gaps).

## Folders and tabs

The sidebar is organized by folder, not by window. Each header is a folder; the tabs under it start
there.

- **⌘N opens a folder.** The picker lists the folders already open (choosing one jumps to it), then
  recent ones (tern's own history first, then [zoxide](https://github.com/ajeetdsouza/zoxide)'s if
  it's installed), then git repositories under `~/dev` (configurable in Settings). Typing ranks them
  all; typing a path (`/`, `~`, `.`) lists what's there, and ⇥ completes it, also from any selected
  folder. ⌘↩ opens the choice in a new worktree, and ⌘O browses in Finder. tern starts with the
  picker when nothing is open.
- **⌘T opens a tab in the current folder**, in the folder itself. Worktree tabs (⌘⇧T) sit under their
  repository's header with the worktree's name beside them.
- A tab is named after what it runs: an agent's task, the command in the foreground (`npm run dev`),
  or the last one that ran (`git status`). A shell that hasn't run anything is **Tab 1**, **Tab 2**…:
  the lowest number free in its folder when it opened, kept while it lives. Trivial
  commands (`cd`, `ls`, `clear`) don't rename it. To name it yourself, double-click it or press ⌘R
  and edit the name in place: ↩ saves, Esc cancels, and saving it empty goes back to the automatic
  name. Hovering a tab shows ✕ to close it.
- A tab that `cd`s somewhere else stays under its folder and shows where it is in grey.
- A subfolder of an open folder gets its own header. A folder closes with its last tab.
- **⌘1–9 picks a folder** (at the tab you last used there), **⌘⇧1–9 a tab** within it. Folders stay
  in the order you opened them, so these keep meaning the same thing; drag a header to reorder, or
  choose **Most recent first** in Settings. Holding ⌘ labels the folders with their numbers, ⌘⇧
  the tabs.
- Collapse a folder by clicking its header. A collapsed header shows its agents and its most urgent
  state; hovering any header shows **+** for a new tab there.

## Search, links, and pane management

⌘F opens Find for the focused terminal pane. Matches are highlighted in the scrollback, with a
result count. ⌘G and ⌘⇧G move forward and backward; Return and Shift-Return do the same while
editing the query. ⌘E uses the selection as the query. Esc or Done closes Find and returns focus
to the terminal. Switching panes closes the old pane's find bar.

Command-click a detected URL or OSC 8 hyperlink to open it with the system's default application.
Supported destinations are HTTP, HTTPS, mail, local file URLs, SSH, VS Code and Cursor URLs.
Unsupported schemes are ignored. Bare paths with line numbers are not yet detected as editor links.

Drag tabs to reorder them or move them onto another folder header. The tab's context menu also has
Move to Folder. The palette and menu offer Move Tab Earlier/Later, Swap Pane with Previous/Next,
Move Pane to New Tab, Move Pane to Next Tab, and Equalize Panes. Moving a pane preserves its running
session. Move Pane to Next Tab needs at least two panes in the source tab and another tab in the
same folder with the same worktree ownership. ⌘⌃←/→ shrink/grow pane width, and ⌘⌃↓/↑ shrink/grow
pane height. Resizing changes the nearest matching divider, with limits of 10% and 90%.

## Project launch presets

Choose **Project Launch Presets…** in File or the palette. Capture Current Project copies the
current folder's tabs, split layouts and pane directories. Give it a name, edit each pane's startup
command and environment variables, and save it. Environment entries use `KEY=value`, one per line.
Saved Presets loads an existing preset for editing, launching, or deletion.

Launch creates fresh tabs and sessions, including panes in background tabs, then runs the configured
commands. It does not rerun commands in existing sessions. Capturing does not infer startup commands
from running programs, copy agent conversations, or create new worktrees. Review the commands before
launching. Presets may contain secrets in their environment values and are stored as local JSON at
`~/Library/Application Support/tern/launch-presets.json`. A malformed or newer-version file is left
unchanged and cannot be overwritten through the editor.

## SSH and remote sessions

Choose **Connect over SSH…** in File or the palette. Enter an SSH host alias or `user@host`, a remote
folder, and optionally a tmux session name. SSH uses your existing config, keys and agent; configure
ports and jump hosts in `~/.ssh/config`. Password and host-key prompts appear in the terminal.
Tern uses `xterm-256color` for these connections so the remote host does not need Ghostty's terminfo.

With a tmux name, Tern runs `tmux new-session -A` on the host. Opening the same connection reattaches
to that session after a disconnect. The host must have tmux installed. Multiple connections to the
same tmux name share its session. Without tmux, remote process survival depends on the remote shell
and server. Tern never stores passwords or changes SSH configuration.

Remote connections are saved with the layout. A live local SSH process survives quitting Tern;
a missing local session reconnects when reopened. Splitting a remote pane opens another connection
with the same settings. Capture its project as a preset to save and reuse connections, remote startup
commands, and environment variables. Startup commands in a named tmux session run only when tmux
creates that session. Existing tmux sessions keep their original command and environment.

The header shows the configured remote host and folder. It does not track subsequent remote `cd`s
or remote branches. Local agent hooks and usage polling do not provide remote agent status. These
connections do not deploy a remote Tern daemon or install remote hooks.

## Agent status

Each tab shows a status glyph, its name and the time since its last activity. The glyph is Claude's
spark for Claude Code, OpenAI's mark for Codex, or a circle for a shell. Its colour tells you the state:

| Appearance | Meaning |
|---|---|
| Amber glyph, bold name, amber row tint and rail | Needs you: a permission prompt or a question. The folder header counts these. |
| Blue glyph | Working. By default, a spinner replaces the age at the end of the row. |
| Text-coloured glyph, bold name | Done, and you haven't looked yet. A shell uses a solid dot. |
| Grey glyph | Idle. A shell uses a hollow ring. |
| Faint glyph | Dormant: no recent activity, or waiting to be reopened after a restart. |

Settings → Appearance → Sidebar lets you replace the trailing spinner with a turning glyph.
Collapsed folder headers and the header above the terminal use the same status glyphs. A tab with
split panes shows its most urgent pane's state. In zsh, a shell tab becomes done when its command
finishes, rather than whenever it prints output.

Sessions running an agent are named after its task (the title Claude Code and Codex give the terminal).
The header above the terminal shows the session, its folder and branch, its status, and what the agent
is asking.

To get these states, open Settings (⌘,) and click **Set Up** for Claude Code and Codex. tern adds a
`tern hook` command to `~/.claude/settings.json` and `~/.codex/hooks.json`; outside tern it exits
immediately, and **Remove** takes it out again, leaving the rest of the file as it was. Codex asks you
to trust new hooks once: run `/hooks` inside Codex. When a newer tern listens to more events, it
updates hooks you already set up at launch (never adding them where you haven't). Without hooks, tern
still recognizes the agents and guesses their state from their output.

When an agent needs you in a session you aren't looking at, the Dock bounces and its badge shows
how many are waiting. ⌘J jumps to whatever needs you first, then whatever finished. Notification
banners, when macOS grants permission, can also take you there when clicked.

### Usage limits

The foot of the sidebar shows how much of each subscription limit is used: one row per agent, with
two rings (outer: the 5-hour window, inner: the week) and the same two figures as percentages. Both
turn amber at 80%, and hovering shows when each window resets. A window past its reset reads 0% until
the agent reports again.

- **Codex** logs its limits in its session files (`~/.codex/sessions/…/rollout-*.jsonl`); tern reads
  the newest.
- **Claude Code**, if you turn on Settings → Agents → Read Claude account usage (off by default):
  every 5 minutes tern reads the sign-in Claude Code keeps in the Keychain (macOS asks once; choose
  Always Allow) and sends it to Anthropic's API for the numbers `/usage` shows. This works wherever
  Claude Code runs, the desktop app included. tern never refreshes that token, so it can't sign Claude
  Code out; an expired one waits for Claude Code to renew it. Deny the prompt, or turn the setting
  off, and tern stops asking.
- Claude Code also passes its limits to its status line command, so setting up Claude Code's hooks
  sets `statusLine` to `tern statusline`. That records them to `usage/claude.json` and prints nothing;
  when it is newer than the account's answer (Claude Code ran in a terminal since), the sidebar uses
  it. If you already had a status line, tern keeps it in `claude-statusline.json`, runs it after
  recording, and shows what it prints; **Remove** puts it back.

### Updates

tern compares `claude --version` and `codex --version` (run through your login shell, so the ones a
tab would run) with the newest release on npm (for Claude Code, the `autoUpdatesChannel` you chose),
five seconds after launch and every six hours. When one is behind, the sidebar offers it: **Update**
opens a tab in Home that runs `claude update` or `codex update`, and **Not Now** hides the offer until
a newer version comes out. Settings → Agents lists both versions with **Check Now**, and the palette
has "Update Claude Code" and "Update Codex".

## Keys

| Keys | Action |
|---|---|
| ⌘K | Command palette: every command, plus jump to any tab |
| ⌘J | Next tab needing attention: waiting on you, then finished, then unread output |
| ⌘N | Open a folder (picker) |
| ⌘T | New tab in the current folder |
| ⌘⇧T | New tab in its own git worktree |
| ⌘O | Browse for a folder in Finder |
| ⌘D / ⌘⇧D | Split right / split down |
| ⌘⌥ + arrows, ⌘[ / ⌘] | Move focus between panes |
| ⌘↩ | Zoom the focused pane (in the picker: open in a new worktree) |
| ⌘1–9 | Folder 1–9 |
| ⌘⇧1–9 | Tab 1–9 in the current folder |
| ⌘⇧[ / ⌘⇧], ⌃⇥ | Previous / next tab |
| ⌘W / ⌘⇧W / ⌘⌥W | Close pane / tab / folder (asks first if something is running) |
| ⌘R | Rename tab |
| ⌘\ | Toggle sidebar |
| ⌘⇧K | Clear screen |
| ⌘= / ⌘- / ⌘0 | Text size |
| ⌘, | Settings |

The menu bar and the palette are built from one list of commands in `Commands.swift`.
tern's shortcuts take priority over terminal key bindings.

Pasting several lines into a program that hasn't turned on bracketed paste (a plain shell would run
each line) asks first, with a preview. A program that wants to read or set the clipboard through
escape codes asks too.

## Settings

Four panes: General (folders, tabs), Appearance (theme and sidebar), Terminal (text, input and bindings), Agents (Claude Code and Codex integrations, usage limits, notifications and resume).
All panes use a compact, consistent window size and scroll when needed. Terminal settings have
separate Text & input, App shortcuts and Terminal bindings pages, with Save and Apply always visible.

- **Terminal**: font family, font size, scrollback bytes, cursor style, Option as Alt, Ghostty terminal
  bindings, and app shortcuts. Save and Apply validates the configuration and updates existing
  surfaces. App shortcuts use exact palette titles, such as `New Tab = cmd+shift+y`; terminal
  bindings use Ghostty syntax, such as `ctrl+shift+c=copy_to_clipboard`. Conflicting app shortcuts
  are rejected. Fixed folder/tab number shortcuts remain reserved. Settings are saved in
  `terminal-settings.json` beside the layout and override Ghostty's corresponding options.
  Until you save Terminal settings, your existing Ghostty values remain in use. The daemon retains
  at most 10,000 history rows across reattach, independently of the surface's byte limit.
  Reload Ghostty Config reloads the external config and reports its errors; the palette also has
  Reload Configuration.
- **Theme**: Graphite (default), Midnight, Ember, Paper, or Ghostty, which keeps the colours from your
  Ghostty config and builds the sidebar around them. A theme colours the chrome and the terminal
  (background, foreground, cursor, selection, ANSI 16) on top of your Ghostty config, so fonts and
  keys still come from it. The palette has the same choices ("Theme: …"); a change applies at once.
- **While working**: a spinner at the end of the row (default), or a turning status glyph. With the
  spinner, agent logos stay still; with the turning glyph, the age stays visible.
- **Folder order**: as opened (default), or most recent first.
- **Find repositories in** (`~/dev`): the folders the picker searches for git repositories, three
  levels deep. Add Folder… adds one; a folder that no longer exists is marked "not found".
- **Worktrees** (off by default): in a git folder, ⌘T gives each new tab its own worktree at
  `<repo>-worktrees/session-N` on a new branch `tern/session-N`, so parallel agents don't edit the
  same checkout. ⌘⇧T does this regardless. Closing such a tab asks whether to remove its
  worktree (Keep is the default when it has uncommitted changes); the branch is always kept.
- **Resume agents after a restart** (on): sessions survive quitting tern but not a reboot. If a
  session that was running Claude Code or Codex is gone when tern starts, its pane opens a fresh shell
  in the same folder and runs `claude --resume <id>` or `codex resume <id>`. This needs the hooks,
  which supply the conversation id.
- **Notifications** for "needs you" and "done", each on by default.

## Architecture

```
Tern.app (Swift, AppKit)
  └─ TerminalView ── libghostty surface (Zig, Metal)       ← every keystroke and frame
       └─ child process: tern attach <session>              ← byte relay over a unix socket
                              │
ternd (Rust, launchd agent dev.tern.ternd)
  └─ owns each session's PTY + a headless libghostty-vt terminal
     so sessions outlive the app and repaint on reattach
```

- `crates/tern`: the `tern` CLI and the `ternd` daemon, plus the protocol in `src/lib.rs`
  (one JSON request line, then length-prefixed binary frames). ternd lives in `src/bin/ternd/`:
  `session.rs` (PTYs, attach, agent reports), `screen.rs` (snapshots), `saved.rs` (screens on disk),
  `vt/` (libghostty-vt, linked statically; `scripts/vt-bindings.sh` regenerates its bindings).
  Because the headless terminal is Ghostty's own engine, a reattaching pane gets back what it showed,
  with the program's modes (bracketed paste, mouse, kitty keyboard flags) and links. Saved screens
  start with a format version and keep colours but not modes.
- Privacy of the runtime folder: `~/Library/Application Support/tern` holds terminal output, typed
  commands, the layout and launch presets (their environment values in plain text), so ternd keeps
  it and everything in it readable only by you (folders `0700`, files `0600`, the socket too) and
  repairs looser modes on start; symlinks inside it, such as `bin/tern`, are left alone. ternd
  refuses connections from any other user, session ids that aren't plain file names, request lines
  over 1 MiB and input frames over 1 MiB. A client that falls 8 MiB behind is disconnected and
  reattaches from the screen. Programs in your tabs still get your usual umask.
- Versions: the app says `hello` to ternd at launch. ternd answers with its protocol number and a
  hash of its binary. When the installed ternd is newer than the running one, tern offers to restart
  it, and warns when the running one speaks an older protocol. Restarting ends the programs in your
  tabs, but their screens come back and agent conversations resume. You can also restart from the
  palette (**Restart ternd**) or with `tern daemon restart`.
- `app/`: SwiftPM app that links `GhosttyKit.xcframework`. `Workspace.swift` holds the model
  (folders → tabs → split tree, each pane a ternd session), saved to `~/Library/Application Support/tern/layout.json`.
  The layout is versioned and loaded forgivingly: a part that doesn't decode is skipped, not the
  whole file. If anything was skipped, or the file comes from another layout version, the original
  is kept beside it as `layout-<reason>-<time>.json` (the last five are kept).
  ternd's `watch` stream supplies live data for each session: cwd, foreground process, branch,
  title, unread output, bells, and the agent's reported state.
- Tab names: for zsh, ternd points `ZDOTDIR` at its own `.zshenv` (in `~/Library/Application
  Support/tern/zsh`), which restores yours, sources your `.zshenv`, and adds a `preexec` hook that
  writes each command line to `commands/<session>`; your other startup files load as usual.
  Ghostty's shell integration works the same way. Other shells are named from the foreground
  process's argv (`crates/tern/src/shell.rs`). A `precmd` hook touches `commands/<session>.done`
  when a command finishes: a shell tab you aren't looking at shows as done then, not on any output.
- Agent hooks (`crates/tern/src/hooks.rs`) run `tern hook claude|codex`, which maps the hook event
  to a state and sends it to ternd for the session named by `TERN_SESSION_ID`. ternd recognizes the
  agents themselves by executable path and argv (Claude Code's binary is named after its version, and
  Codex runs under node), and drops a report once the shell is back in the foreground.
- `vendor/ghostty`: Ghostty as a git submodule (MIT). It provides libghostty for the app and
  libghostty-vt for ternd.

## Build

Requirements:

- Xcode with Swift 6.2 or later and the Metal toolchain. The app builds in Swift 6 language mode.
- Rust and Cargo.
- Zig matching `minimum_zig_version` in `vendor/ghostty/build.zig.zon`, currently `0.17.0`.
- Python 3 and curl for Ghostty's dependency downloads.

Install Zig, then check `zig version` against the submodule's requirement. If Homebrew supplies a
different version, install the matching Zig toolchain before building.

```bash
brew install zig
```

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

`build-app.sh` writes `build/Tern.app` and signs it with your Apple Development identity if you have
one, and ad-hoc otherwise. `--install` also copies it to `~/Applications`; a running ternd keeps
working through the swap. Omit `--install` to build without installing, or add `--debug` for a debug
Swift build. Set `TERN_SIGN_IDENTITY` to choose a signing identity, or `-` for ad-hoc signing.

`build-ghostty.sh` downloads Ghostty's Zig dependencies with curl, checks each archive and its
unpacked files against the hash Ghostty pins (using Zig's own hashing, so the exact Zig version is
required), moves them into `.zig-deps/` and builds offline with `zig build --system`, because Zig's
own fetcher was unreliable here. Checked packages are marked in `.zig-deps/.verified` and not
checked again. If a cached download fails the check, delete
`.zig-deps/.downloads/<hash>.archive` and run the script again.
It builds libghostty for the current Mac's architecture and `zig-out/lib/libghostty-vt.a`, which
ternd links statically; Cargo builds fail with a pointer to this script until it exists.

ternd's Rust bindings to libghostty-vt are checked in. After updating the submodule, regenerate
them with `scripts/vt-bindings.sh` (needs `cargo install bindgen-cli`).

### Distribution build

Prereleases for Apple Silicon are on the [Releases page](https://github.com/ishaanrajiv/tern/releases).
[RELEASING.md](RELEASING.md) describes how they're built, checked and published. The
[public-readiness review](docs/public-readiness.md) records the security fixes made before the
repository was opened.

To build a signed, notarized copy for another Mac, you need a **Developer ID Application**
certificate and a notarytool Keychain profile. Store the credentials once:

```bash
xcrun notarytool store-credentials tern --apple-id <email> --team-id <TEAMID>
```

Then build:

```bash
./scripts/build-app.sh --dist
```

This enables the hardened runtime, notarizes the app, staples and validates its ticket,
and writes `build/Tern-<version>-macos-<arch>.zip` with a `.sha256` checksum file.
`TERN_NOTARY_PROFILE` overrides the default profile name `tern`.
You can combine `--dist` with `--install`, but not `--debug`.

From a clean, committed checkout with Ghostty's dependency sources fetched, create the
complete source bundle with `python3 scripts/package-source.py`. It writes
`build/Tern-<version>-source.tar.gz` and its `.sha256` file, including the pinned Ghostty
source, native dependency sources, vendored Rust crates and rebuild instructions.
See [RELEASING.md](RELEASING.md) for checks and draft release preparation.

### Third-party notices

`build-app.sh` puts `LICENSE` and `THIRD_PARTY_NOTICES.md` in the app's `Contents/Resources`. After
updating the Ghostty submodule or the Rust dependencies, regenerate the notices (it reads the license
files from `.zig-deps/` and the cargo registry):

```bash
python3 scripts/notices.py
```

## Checks

```bash
./scripts/check.sh
```

Runs the Rust tests, clippy with warnings as errors, the Swift build (failing on new warnings) and
the Swift tests in `app/Tests`.

## CLI

```
tern attach [--cwd DIR] [--cmd CMD] [--init LINE] <id>
                                           relay this terminal to a session (creates it if needed;
                                           --init types LINE into the new session's shell)
tern ls [--json]                           list sessions
tern kill <id>                             hang up a session
tern bench [n]                             keystroke round trip: direct PTY vs through ternd
tern hooks [status|install|uninstall|link] [claude|codex]
                                           manage agent hooks (what Settings does)
tern hook claude|codex                     run by the agents' hooks; reads the event on stdin
tern statusline                            Claude Code's status line: records its usage limits
tern daemon [status|restart]               the running ternd against this tern's (JSON); restart
                                           saves screens, stops it and starts this build's
```

`ternd` starts on demand as the launchd agent `dev.tern.ternd`; its log is
`~/Library/Application Support/tern/ternd.log`. Set `TERN_RUNTIME_DIR` (path under ~100
characters) to run a private instance for tests: the app keeps its layout, debug files (debug
builds only) and `bin/tern` link there, leaves installed agent hooks alone and doesn't take focus at launch; the
daemon is spawned directly, without launchd.

## Spike results (M1)

- **Relay latency:** about 20µs added at p50 and about 40µs at p99, measured by
  `tern bench` on Apple Silicon. A 120Hz frame is 8,333µs.
- **Persistence:** quitting the app leaves the shells running, and relaunching reattaches
  every live session with its screen restored.
- **Gotchas found along the way:**
  - macOS kills processes an app spawned when the app quits, even after `setsid`, so ternd
    runs under launchd.
  - `tern` and `Tern` collide on a case-insensitive filesystem, so the CLI ships in
    `Contents/Helpers`.

## Todo

- **Notifications** (open; see Known gaps).
- **Upgrading ternd without ending sessions** (hand the PTYs to the new daemon). Screens already
  come back after a restart, and panes reconnect on their own; the processes in them don't survive.

## Known gaps

- Sessions survive the app quitting. A reboot or a ternd restart ends the processes, but not what
  they showed: ternd saves each screen (every 15s while it changes, and when it's told to quit), and
  a pane that comes back shows its old screen, colours and links included, under a "restored" rule. The
  command that was running is typed at the prompt, not run. Agent conversations resume (see
  Settings). Full-screen programs (vim, htop) aren't saved while they're up; the screen from before
  they started is.
- A turn that ends without a Stop hook has no "done" event. Pressing Esc during a tool call reports
  one (Claude Code's `PostToolUseFailure` with `is_interrupt`); an API error, or Esc while the model
  is writing, doesn't. tern treats a working agent that has been silent for five seconds as finished.
- Without hooks, "unread" means any output or bell in a session you aren't looking at.
- **Open: notifications don't work yet.** macOS refuses tern's permission request without a prompt
  (`UNErrorDomain` 1, "Notifications are not allowed for this application"). This still happens with
  an Apple Development signature and when run from `~/Applications`. A minimal test app showed the
  same refusal, so the cause is in how macOS treats locally built apps, not in tern's code. The Dock
  badge, Dock bounce and ⌘J don't depend on notifications and work.
- **Open: ⌘C/⌘V don't work inside Codex.** They work in a plain shell tab, and the debug log shows
  both keys reaching tern's Copy and Paste either way. Codex turns on bracketed paste, focus
  reporting and the kitty keyboard protocol, not mouse capture. Untested guesses: Codex's redraws
  clear the selection before ⌘C, an image on the clipboard pastes nothing (tern only hands Ghostty
  text), or a long paste shows as Codex's short placeholder. To narrow it down, try it in the Codex
  tab of a debug build (`build-app.sh --debug`, launched with `TERN_DEBUG=1`) with logging in `TerminalView.copy`/`paste` and the clipboard
  callbacks in `GhosttyApp.swift`.

## Privacy

tern has no account and no telemetry. It reaches the network only for these:

- **Agent updates.** tern asks the npm registry for the newest Claude Code and Codex versions, five
  seconds after launch and every six hours. The request names the package, nothing about you.
- **Claude Code's usage limits, if you turn them on** (Settings → Agents, off by default). tern
  reads Claude Code's sign-in from the Keychain and sends it to Anthropic's API to fetch your limits.
- **What you ask for.** SSH connections you open, and the commands in your launch presets and tabs,
  run as you with your own configuration.

Everything else stays on your Mac in `~/Library/Application Support/tern`: the layout, launch
presets (environment values in plain text), saved screens (whatever you scrolled past), the commands
typed in each tab, recorded usage numbers, and ternd's log. None of it is encrypted. ternd keeps the
folder readable only by you, and its socket refuses other users. See [SECURITY.md](SECURITY.md).

Setting up an agent's hooks in Settings writes to that agent's own config: `~/.claude/settings.json`
(hooks and the status line, keeping yours to run after it) or `~/.codex/hooks.json`. tern keeps
your other entries, follows a symlinked config to its real file, keeps its permissions and leaves a
`.tern-backup` copy beside it. **Remove** takes tern's entries out and puts back the status line you
had.

## Contributing

Issues and small pull requests are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md). Report security
problems privately as [SECURITY.md](SECURITY.md) describes.

## License

tern is released under the [MIT License](LICENSE).

Tern.app also contains [Ghostty](https://github.com/ghostty-org/ghostty)'s libghostty (MIT, in the
app) and libghostty-vt (MIT, in `ternd`) and the libraries they link, the fonts it embeds, and the Rust crates in `tern` and `ternd`.
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) lists each one with its license. Almost all are
MIT, BSD, Apache-2.0 or zlib-style. The exceptions are GNU libintl (LGPL-2.1-or-later) and z2d
(MPL-2.0), both statically linked by libghostty; their source, and tern's, is available as the notices
describe.

tern is not affiliated with Ghostty, Anthropic or OpenAI. Claude Code and Codex are their owners'
products.
