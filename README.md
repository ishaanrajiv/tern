# tern

A macOS terminal built around coding agents: a sidebar that shows which agent needs you,
Mac-native keys, and sessions that survive quitting the app.

Status: **v0.1, feature-complete for a first review**. One window holds a sidebar of folders and
their tabs, split panes, a ⌘K command palette and a Mac-native keymap. Claude Code and Codex report
whether they're working, waiting for you, or done, and tern notifies you and takes you there with ⌘J.

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
  commands (`cd`, `ls`, `clear`) don't rename it; ⌘R names it yourself.
- A tab that `cd`s somewhere else stays under its folder and shows where it is in grey.
- A subfolder of an open folder gets its own header. A folder closes with its last tab.
- **⌘1–9 picks a folder** (at the tab you last used there), **⌘⇧1–9 a tab** within it. Folders stay
  in the order you opened them, so these keep meaning the same thing; drag a header to reorder, or
  choose **Most recent first** in Settings. Holding ⌘ labels the folders with their numbers, ⌘⇧
  the tabs.
- Collapse a folder by clicking its header. A collapsed header shows its agents and its most urgent
  state; hovering any header shows **+** for a new tab there.

## Agent status

Each tab in the sidebar is one line: its status, its name, which agent runs in it (**C** for Claude
Code, **X** for Codex) and how long since it last did something:

| Icon | Meaning |
|---|---|
| turning arc | Working (blue for an agent) |
| amber ring with a dot | Needs you: a permission prompt or a question. The folder header counts these. |
| solid dot, bold name | Done, and you haven't looked yet |
| hollow ring | Done or idle |
| dashed ring | Not running: nothing for a day, or waiting to be reopened after a restart |

Sessions running an agent are named after its task (the title Claude Code and Codex give the terminal).
The header above the terminal shows the session, its folder and branch, its status, and what the agent
is asking.

To get these states, open Settings (⌘,) and click **Set Up** for Claude Code and Codex. tern adds a
`tern hook` command to `~/.claude/settings.json` and `~/.codex/hooks.json`; outside tern it exits
immediately, and **Remove** takes it out again, leaving the rest of the file as it was. Codex asks you
to trust new hooks once: run `/hooks` inside Codex. When a newer tern listens to more events, it
updates hooks you already set up at launch (never adding them where you haven't). Without hooks, tern
still recognizes the agents and guesses their state from their output.

When an agent needs you or finishes in a session you aren't looking at, you get a notification
(click it to go there), the Dock icon shows how many are waiting, and ⌘J jumps to the next one:
whatever needs you first, then whatever finished.

### Usage limits

The foot of the sidebar shows how much of each subscription limit is used: one row per agent, with
two rings (outer: the 5-hour window, inner: the week) and the same two figures as percentages. Both
turn amber at 80%, and hovering shows when each window resets. A window past its reset reads 0% until
the agent reports again.

- **Codex** logs its limits in its session files (`~/.codex/sessions/…/rollout-*.jsonl`); tern reads
  the newest.
- **Claude Code** passes them only to its status line command, so setting up Claude Code's hooks also
  sets `statusLine` to `tern statusline`. That records the limits to `usage/claude.json` and prints
  nothing. If you already had a status line, tern keeps it in `claude-statusline.json`, runs it after
  recording, and shows what it prints; **Remove** puts it back. The ring appears after Claude Code's
  next reply.

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

## Settings

Three panes: General (folders, tabs), Appearance (theme), Agents (hooks, versions, notifications, resume).

- **Theme**: Graphite (default), Midnight, Ember, Paper, or Ghostty, which keeps the colours from your
  Ghostty config and builds the sidebar around them. A theme colours the chrome and the terminal
  (background, foreground, cursor, selection, ANSI 16) on top of your Ghostty config, so fonts and
  keys still come from it. The palette has the same choices ("Theme: …"); a change applies at once.
- **Folder order**: as opened (default), or most recent first.
- **Find repositories in** (`~/dev`): comma-separated folders the picker searches for git
  repositories, three levels deep.
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
  └─ owns each session's PTY + a headless vt100 screen
     so sessions outlive the app and repaint on reattach
```

- `crates/tern`: the `tern` CLI and the `ternd` daemon, plus the protocol in `src/lib.rs`
  (one JSON request line, then length-prefixed binary frames).
- `app/`: SwiftPM app that links `GhosttyKit.xcframework`. `Workspace.swift` holds the model
  (folders → tabs → split tree, each pane a ternd session), saved to `~/Library/Application Support/tern/layout.json`.
  ternd's `watch` stream supplies live data for each session: cwd, foreground process, branch,
  title, unread output, bells, and the agent's reported state.
- Tab names: for zsh, ternd points `ZDOTDIR` at its own `.zshenv` (in `~/Library/Application
  Support/tern/zsh`), which restores yours, sources your `.zshenv`, and adds a `preexec` hook that
  writes each command line to `commands/<session>`; your other startup files load as usual.
  Ghostty's shell integration works the same way. Other shells are named from the foreground
  process's argv (`crates/tern/src/shell.rs`).
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
tern hooks [status|install|uninstall|link] [claude|codex]
                                           manage agent hooks (what Settings does)
tern hook claude|codex                     run by the agents' hooks; reads the event on stdin
tern statusline                            Claude Code's status line: records its usage limits
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

- **Notifications** (open; see Known gaps).
- **Upgrading ternd without ending sessions** (hand the PTYs to the new daemon). Screens already
  come back after a restart, and panes reconnect on their own; the processes in them don't survive.

## Known gaps

- Sessions survive the app quitting. A reboot or a ternd restart ends the processes, but not what
  they showed: ternd saves each screen (every 15s while it changes, and when it's told to quit), and
  a pane that comes back shows its old screen, colours included, under a "restored" rule. The
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
