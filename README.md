# tern

A macOS terminal built around coding agents: a sidebar that shows which agent needs you,
Mac-native keys, and sessions that survive quitting the app.

Status: **v0.1, feature-complete for a first review**. One window holds a sidebar of projects and
sessions, split panes, a ⌘K command palette and a Mac-native keymap. Claude Code and Codex report
whether they're working, waiting for you, or done, and tern notifies you and takes you there with ⌘J.

## Agent status

Each session in the sidebar is one line: its name, how long since it last did something, and a status:

| Icon | Meaning |
|---|---|
| spinner | Working |
| amber ring | Needs you: a permission prompt or a question. The project header counts these. |
| filled check, bold name | Done, and you haven't looked yet |
| faint check | Done or idle |
| moon | Nothing for a day |

Sessions running an agent are named after its task (the title Claude Code and Codex give the terminal).
The header above the terminal shows the session, its folder and branch, its status, and what the agent
is asking.

To get these states, open Settings (⌘,) and click **Set Up** for Claude Code and Codex. tern adds a
`tern hook` command to `~/.claude/settings.json` and `~/.codex/hooks.json`; outside tern it exits
immediately, and **Remove** takes it out again, leaving the rest of the file as it was. Codex asks you
to trust new hooks once: run `/hooks` inside Codex. Without hooks, tern still recognizes the agents
and guesses their state from their output.

When an agent needs you or finishes in a session you aren't looking at, you get a notification
(click it to go there), the Dock icon shows how many are waiting, and ⌘J jumps to the next one:
whatever needs you first, then whatever finished.

## Keys

| Keys | Action |
|---|---|
| ⌘K | Command palette: every command, plus jump to any session |
| ⌘J | Next session needing attention: waiting on you, then finished, then unread output |
| ⌘T (or ⌘N) | New session in the current project |
| ⌘⇧T | New session in its own git worktree |
| ⌘O | Open a folder as a project |
| ⌘D / ⌘⇧D | Split right / split down |
| ⌘⌥ + arrows, ⌘[ / ⌘] | Move focus between panes |
| ⌘↩ | Zoom the focused pane |
| ⌘1–9, ⌘⇧[ / ⌘⇧], ⌃⇥ | Switch session |
| ⌘W / ⌘⇧W | Close pane / close session (asks first if something is running) |
| ⌘R | Rename session |
| ⌘\ | Toggle sidebar |
| ⌘⇧K | Clear screen |
| ⌘= / ⌘- / ⌘0 | Text size |
| ⌘, | Settings |

The menu bar and the palette are built from one list of commands in `Commands.swift`.
tern's shortcuts take priority over terminal key bindings.

## Settings

- **Worktrees** (off by default): in a git project, ⌘T gives each new session its own worktree at
  `<repo>-worktrees/session-N` on a new branch `tern/session-N`, so parallel agents don't edit the
  same checkout. ⌘⇧T does this regardless. tern never deletes worktrees; remove them with
  `git worktree remove` when you're done.
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
  └─ owns each session's PTY + a headless vt100 screen
     so sessions outlive the app and repaint on reattach
```

- `crates/tern`: the `tern` CLI and the `ternd` daemon, plus the protocol in `src/lib.rs`
  (one JSON request line, then length-prefixed binary frames).
- `app/`: SwiftPM app that links `GhosttyKit.xcframework`. `Workspace.swift` holds the model
  (projects → sessions → split tree), saved to `~/Library/Application Support/tern/layout.json`.
  ternd's `watch` stream supplies live data for each session: cwd, foreground process, branch,
  title, unread output, bells, and the agent's reported state.
- Agent hooks (`crates/tern/src/hooks.rs`) run `tern hook claude|codex`, which maps the hook event
  to a state and sends it to ternd for the session named by `TERN_SESSION_ID`. ternd recognizes the
  agents themselves by executable path and argv (Claude Code's binary is named after its version, and
  Codex runs under node), and drops a report once the shell is back in the foreground.
- `vendor/ghostty`: Ghostty as a git submodule (MIT). It only provides libghostty.

## Build

Requirements: Xcode with the Metal toolchain, Rust, and the Zig version Ghostty pins.

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
./scripts/build-app.sh
```

```bash
./scripts/build-app.sh --install
```

```bash
open ~/Applications/Tern.app
```

`build-app.sh` signs the app with your Apple Development identity if you have one, and ad-hoc
otherwise. `--install` copies it to `~/Applications`; a running ternd keeps working through the
swap.

`build-ghostty.sh` downloads Ghostty's Zig dependencies with curl into `.zig-deps/` and builds
offline with `zig build --system`, because Zig's own fetcher was unreliable here.

## CLI

```
tern attach [--cwd DIR] [--cmd CMD] [--init LINE] <id>
                                           relay this terminal to a session (creates it if needed;
                                           --init types LINE into the new session's shell)
tern ls [--json]                           list sessions
tern kill <id>                             hang up a session
tern bench [n]                             keystroke round trip: direct PTY vs through ternd
tern hooks [status|install|uninstall] [claude|codex]
                                           manage agent hooks (what Settings does)
tern hook claude|codex                     run by the agents' hooks; reads the event on stdin
```

`ternd` starts on demand as the launchd agent `dev.tern.ternd`; its log is
`~/Library/Application Support/tern/ternd.log`. Set `TERN_RUNTIME_DIR` (path under ~100
characters) to run a private daemon for tests; that one is spawned directly, without launchd.

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

- **Agent CLI updates.** Notice when Claude Code or Codex is behind (Codex keeps
  `~/.codex/version.json`; Claude Code has `claude update`) and offer a one-click update in tern.
  An outdated CLI fails in confusing ways: Codex 0.154 rejected a model with "not supported".
- **Notifications** (open; see Known gaps).
- **Usage-limit rings** for Claude Code and Codex.
- **Upgrading ternd without ending sessions** (hand the PTYs to the new daemon).

## Known gaps

- Reattach restores scrollback as plain text: colors in history are dropped, while the
  visible screen keeps them.
- Sessions survive the app quitting, but not a reboot. Agent conversations resume (see Settings);
  other programs don't.
- Restarting ternd (for example, after upgrading it) ends running sessions.
- A turn that ends without a Stop hook (an API error, or rejecting a permission prompt) has no
  "done" event. tern treats a working agent that has been silent for five seconds as finished.
- Without hooks, "unread" means any output or bell in a session you aren't looking at.
- **Open: notifications don't work yet.** macOS refuses tern's permission request without a prompt
  (`UNErrorDomain` 1, "Notifications are not allowed for this application"). This still happens with
  an Apple Development signature and when run from `~/Applications`. A minimal test app showed the
  same refusal, so the cause is in how macOS treats locally built apps, not in tern's code. The Dock
  badge, Dock bounce and ⌘J don't depend on notifications and work.
