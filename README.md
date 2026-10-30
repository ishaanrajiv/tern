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
  under `~/dev`). ⌘T opens a tab in the current folder, ⌥⌘T opens one in a new git worktree.
  Ordinary new tabs inherit the focused pane's directory; **New Tab at Project Root** starts at the folder root.
  Tabs name themselves after what they run: an agent's conversation name (Claude Code's title, or
  what `/rename` set; Codex's thread name), the command running now, or the last
  one that ran for a few seconds (`npm run dev` sticks, `git status` doesn't). A tab outside its
  folder's root goes by its subfolder; one with nothing to go by is a dimmed "Shell". Double-click
  or ⌘R to rename.
- **Windows.** ⌘⇧N opens another window. Move a tab or pane to a new window from the Window menu,
  or move a tab to the next window. Each window remembers its layout and position. Settings →
  General can enable Control-Option-Space to show or hide tern.
  Worktree removal waits until no window or detached tab uses it.
- **Commands and output.** zsh, bash and fish report prompt and command boundaries. ⌘⇧↑ / ⌘⇧↓
  jump between prompts. The Edit menu copies or selects the last command's output in a text window,
  or searches retained output with case and regular-expression controls. ⌘⇧F searches all sessions.
  The header says how the last command ended only when it's worth saying: a failure ("Command not
  found", "Failed") or a run of ten seconds or more ("Done in 2m 14s").
  File → Export Scrollback… opens selectable output with Find, Save and Open in Editor actions.
- **Files and images.** Drop Finder files, or copy them in Finder and paste, to type their quoted
  full paths. ⌘-click a local `path:line:column` diagnostic, or select a path and choose Edit → Open
  Selected File in Editor. Choose the editor in Settings → General. **Paste Image as File Path** saves a private PNG and pastes its quoted path;
  programs supporting Kitty clipboard requests can also read image MIME types directly.
- **Recovery.** File → Detach Tab leaves its processes running. Detached Sessions… reattaches them.
  Reopen Closed Tab restores a recently closed layout. Processes deliberately stopped by closing a
  tab return as fresh shells; reopening cannot undo their termination. Closing a window while
  others remain detaches its tabs. Quitting preserves all open windows and sessions.
- **Agent status.** Claude Code and Codex report whether they're working, waiting for you, or done.
  So can any program that speaks the [OSC 7501](https://www.superlogical.com/rex/docs/build/program-status)
  program status protocol, such as a build or deploy script: it gets a rounded-square glyph, its
  progress as a ring, and its message in the header. ⌘J jumps across windows to the next tab that
  needs you, and the Dock badge counts the waiting ones.
- **Usage limits.** The foot of the sidebar shows each agent's 5-hour and weekly limits.
- **Persistent sessions.** A daemon owns the shells, so quitting tern leaves them running. After a
  reboot or daemon restart, panes come back with their old screens and agent conversations resume.
- **Splits, Find and links.** ⌘D splits panes, ⌘F searches scrollback, ⌘-click opens URLs. Each
  pane's header shows what runs there and where, with split and close buttons; panes other than the
  focused one are dimmed. Closing a pane focuses the one before it. Transitions are short and become fades with Reduce Motion on.
- **Quick settings.** ⌘⇧, (tern → Quick Settings…) changes the theme,
  text size, cursor, notifications and more without leaving the keyboard: ←/→ change the selected
  value, and the theme list previews each theme as you move through it (Esc puts yours back).
- **SSH.** File → Connect over SSH… uses your own SSH config and can reattach to a named tmux
  session on the host.
- **Launch presets.** File → Project Launch Presets… saves a folder's tabs, splits, startup
  commands and environment variables, and recreates them later.
- **Updates.** One card at the foot of the sidebar covers tern, ternd, Claude Code and Codex.
  The most urgent row shows in full, outlined in amber when it needs you; the others follow as
  one line each with their main action. Offers have Remind Me Tomorrow and Skip This Version.
  Settings → Updates lists every version and the options below.
  - *tern* checks GitHub releases every six hours, then downloads and verifies a new one in the
    background (checksum, archive paths, signing team, Gatekeeper). Once verified it offers
    Restart to Update, or installs when tern quits. Sessions keep running in ternd either way.
  - *ternd* is never restarted without you. Its row names the programs a restart would end, and
    When Idle restarts it once nothing is running: every shell is back at its prompt and no
    agent update is in progress. An incompatible ternd also asks with a sheet.
  - *Claude Code and Codex* update with their own updater (Homebrew's for a cask install) in a
    hidden session, never a tab. The row quotes the updater's question or last error, and its
    console opens by itself when the updater asks something or fails, with Stop while it runs
    and Retry after a failure. A success closes it. An update still running when
    tern quits carries on in ternd and reappears at the next launch. tern warns when a second copy
    on PATH would keep running the old version.
- **Native controls.** The terminal has a context menu and exposes visible text and selection to
  accessibility tools. tern → Secure Keyboard Entry protects keyboard input while tern is active.

### Agent status

| Glyph | Meaning |
|---|---|
| Amber, bold name, tinted row | Needs you: a permission prompt or a question |
| Blue | Working |
| Red, bold name | Failed, and you haven't looked yet (reported over OSC 7501) |
| Text-coloured, bold name | Done, and you haven't looked yet |
| Grey | Idle |
| Faint | Dormant, or waiting to be reopened after a restart |

For accurate states, open Settings (⌘,) and click **Set Up** for Claude Code and Codex. This adds
a `tern hook` command to `~/.claude/settings.json` and `~/.codex/hooks.json`, and a `tern` skill
in each agent's `skills/tern/` that teaches it the [pane commands](#driving-panes-from-an-agent-or-script).
**Remove** takes them out again without touching your other settings, and a skill of your own by
that name is left alone. In Codex, run `/hooks` once to trust them. Without
hooks, tern guesses each agent's state from its output.

Codex usage limits come from its session logs. Claude Code limits come from its status line, and
optionally (Settings → Agents, off by default) from Anthropic's API using the sign-in Claude Code
keeps in the Keychain, read with `/usr/bin/security` as Claude Code reads it, so tern updates
don't bring back a Keychain prompt. If macOS refuses, the setting stays on and Settings offers
Try Again. tern never refreshes that token.

## Keys

⌘/ (Help → Keyboard Shortcuts) shows these in the app, with any overrides applied.

<!-- keys:start -->
| Keys | Action |
|---|---|
| ⇧⌘P | Command palette and session search across windows |
| ⌘J / ⇧⌘J | Next / previous tab needing attention |
| ⌘N / ⇧⌘N | Open a folder / new window |
| ⌘O | Browse for a folder in Finder |
| ⇧⌘K | Connect over SSH |
| ⌘T / ⌥⌘T | New tab / new tab in its own worktree |
| ⌘D / ⇧⌘D | Split right / split down |
| ⌘1–9 / ⌃⌘1–9 | Folder / tab within the folder |
| ⌘[ / ⌘] | Previous / next pane |
| ⇧⌘[ / ⇧⌘], ⌃⇧⇥ / ⌃⇥ | Previous / next tab |
| ⌥⌘[ / ⌥⌘] | Previous / next folder |
| ⌥⌘ + arrows | Move focus between panes |
| ⌃⌘ + arrows | Resize the focused pane |
| ⌃⌘= | Equalize panes |
| ⇧⌘↩, ⌘↩ | Zoom the focused pane |
| ⌃⌘[ / ⌃⌘] | Swap pane with previous / next |
| ⌃⇧⌘[ / ⌃⇧⌘] | Move tab earlier / later |
| ⌘W / ⇧⌘W / ⌥⌘W | Close pane / tab / folder |
| ⇧⌘T | Reopen closed tab |
| ⌘F / ⌘G / ⇧⌘G | Find, next / previous match |
| ⌘E | Find the selection |
| ⌥⌘F / ⇧⌘F | Advanced find / search output across sessions |
| ⇧⌘C | Copy the last command's output |
| ⇧⌘S | Export scrollback |
| ⇧⌘O | Open the selected file in your editor |
| ⌥⌘V | Paste a clipboard image as a file path |
| ⇧⌘↑ / ⇧⌘↓ | Previous / next prompt |
| ⌘R | Rename tab |
| ⌃⌘S, ⌘\ | Toggle sidebar |
| ⌘K | Clear screen |
| ⌘= / ⌘- / ⌘0 | Text size |
| ⌘, / ⇧⌘, | Settings / quick settings |
| ⌘/ | Keyboard shortcuts cheat sheet |
| ⌃⌥Space | Show or hide tern from any app, once enabled in Settings → General |
<!-- keys:end -->

tern's shortcuts take priority over terminal bindings. All of them use ⌘ (⌃⇥ aside), so ⌃ and ⌥
keys always reach the terminal and the agent in it. To rebind one, add a line such as
`New Tab = cmd+shift+y` (or `= none`) under Settings → Terminal → App shortcuts. tern ignores an
override that clashes with another command or with a macOS shortcut. Ghostty key bindings go under
Terminal bindings.
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

Add `~/Library/Application Support/tern/bin` to your shell's `PATH` to use the stable CLI link
that tern maintains. The CLI can open a folder in the running app:

```sh
tern .
tern open ~/dev/project --window
tern open . --split right -- cargo test
tern open . --command 'npm run dev'
```

`--` preserves the following command's individual arguments; `--command` accepts a shell command.
Finder's Services menu also offers **Open in tern**. External `tern://open?path=/absolute/path` URLs
open folders and cannot execute commands.

### Driving panes from an agent or script

ternd keeps every window's layout, so an agent can open and drive panes with the app open or
quit. Inside a tern pane, commands act on that pane by default; `--pane ID|NAME|@focused` or
`--tab ID|NAME` picks another.

```sh
tern split down --name tests -- cargo test --watch   # prints the new pane's id
tern tab ~/dev/api --name server -- 'npm run dev'
tern send --pane server 'curl -s localhost:3000/health'
tern wait --pane server --text 'listening on' --timeout 30
tern wait --pane tests --prompt                    # back at a prompt, nothing typed since
tern capture --pane tests --last-command
tern run -- cargo clippy                           # prints its output, exits with its code
tern close --pane server
tern ls --json                                     # windows, folders, tabs, splits and sessions
```

New panes start in the background unless given `--focus`, and the pane header names the agent
that opened one. `wait` also takes `--exit` and `--state idle|working|needs-you|done|failed`.
Exit codes: 2 for bad arguments, 3 when no pane or tab matches, 4 when a name matches more than
one, 5 on a timeout. `run` exits with its command's code.

### Events

`tern watch` prints what happens in your panes as it happens; `--json` gives one object a line,
and `--event` and `--pane` narrow it. The events are `needs-you`, `working`, `done` and `failed`
(an agent's hooks or a program's OSC 7501 report), `command-done` and `command-failed` (a shell
command, not counting ⌃C), `bell`, `start` and `exit`.

To run a command on an event, add `on-<event>` lines to `~/.config/tern/config`. ternd runs
them, so they work with the app quit:

```sh
# ~/.config/tern/config
on-needs-you = say "$TERN_AGENT needs you"
on-command-failed = osascript -e "display notification \"$TERN_COMMAND exited $TERN_EXIT_CODE\""
```

Each command runs through `/bin/sh` in your home folder with `TERN_EVENT`, `TERN_PANE`,
`TERN_FOLDER`, `TERN_AGENT`, `TERN_PROGRAM`, `TERN_MESSAGE`, `TERN_COMMAND`, `TERN_EXIT_CODE`
and `TERN_DURATION_MS` set where they apply, and the whole event as `TERN_EVENT_JSON`. A key can
repeat to run several commands; an empty value drops the ones before it. A private instance reads
`config` in its `TERN_RUNTIME_DIR` instead.

### Notifications while you're away

ternd can push to your phone through [ntfy](https://ntfy.sh) while you're away from the Mac: tern
isn't the app in front, and the screen is locked or there has been no input for two minutes.

```sh
# ~/.config/tern/config
notify-ntfy = https://ntfy.sh/a-topic-only-you-know
notify-events = needs-you, done, failed     # the default
away-after = 120                            # seconds without input
```

Only a title is sent, like "Claude Code needs you · api", never what the agent asked or a
command line. Install the ntfy app and subscribe to the same topic. `on-<event>` commands also get
`TERN_AWAY=1` while you're away, for any other service.

Set `TERN_RUNTIME_DIR` to a short path (under about 100 characters) to run a private instance for
testing. It keeps its own layout and spawns its own daemon without launchd.

## Known gaps

- A reboot or ternd restart ends running processes. Screens come back, and the command that was
  running is typed at the prompt but not run. Full-screen programs like vim aren't saved while
  they're open.
- Upgrading ternd ends the processes in your tabs.
- When the CLI changes a window's layout at the same moment as you do, the CLI's change wins and
  yours is undone.
- A turn that ends without a Stop hook (an API error, or Esc while the model is writing) sends no
  "done" event. tern treats an agent that has been silent for five seconds as finished.
- **Notifications don't work.** macOS refuses tern's permission request without showing a prompt.
  A minimal test app gets the same refusal, so the cause seems to be how macOS treats locally built
  apps. The Dock badge, Dock bounce and ⌘J still work.
- **⌘C and ⌘V don't work inside Codex.** They work in a plain shell, and the keys do reach tern.
  The cause is unknown.
- File-link clicking recognises whitespace-delimited paths. Select paths containing spaces and
  use Open Selected File in Editor. Line navigation requires the chosen editor's URL support.
- Inline terminal images render while attached, but the VT formatter does not preserve image
  pixels on reattachment. Image clipboard input and saved PNG paths are independent of this.
- Command-output capture keeps up to 4 MiB per completed command. Output documents/search retrieve
  up to 8 MiB per session and report truncation. Retained history is byte-limited at page granularity.
- Bash integrations with an existing DEBUG trap keep that trap. On the system's older bash this
  can limit command-start detection. Fish integration still needs interactive verification here.
- The update installer supports the symlink-free Apple Silicon bundles produced by this repo.
  Unsigned/ad-hoc builds need a signed release installed manually before using in-app updates.

## Privacy

tern has no account and no telemetry. It reaches the network to check npm for agent updates,
to check and download GitHub releases (every six hours unless you turn it off in Settings → Updates),
to fetch Claude Code usage limits if you turn that on, and for SSH connections and commands you run.

Everything else stays unencrypted in `~/Library/Application Support/tern`: the layout, launch presets
(environment values in plain text), saved screens, typed commands, usage numbers, pasted PNGs, exported output, staged updates and ternd's log.
Saved image and output files remain until you remove them from that folder.
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
