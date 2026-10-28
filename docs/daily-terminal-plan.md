# Daily terminal implementation plan

Started 2026-10-28. One branch, `codex/daily-terminal-parity`, and one PR.

## Scope

Build the daily-use terminal capabilities agreed in chat. Remote workflow enhancements and
profiles/configuration are excluded. Preserve existing SSH and launch presets. Do not restart
the normal daemon or replace the installed app while developing. Do not automatically install
an application update or end a user's sessions.

## Milestones

- [ ] 1. Files and launching: inherit the focused directory for ordinary new tabs, retain an
  explicit project-root action, file drops with shell quoting, image paste, editor file/line
  links, `tern open` / `tern .`, command/tab/split launch arguments, Finder services and URL opens.
- [ ] 2. Shell integration: zsh/bash/fish prompt marks, command boundaries, exit status and
  duration, navigate prompts, select/copy last output and ordinary command completion alerts.
- [ ] 3. History: one configurable daemon retention limit applied to new and existing sessions,
  export/open scrollback, stronger find controls and search output across sessions.
- [ ] 4. Recovery: detach without killing, list/reattach detached sessions, recently closed tab
  recovery with fresh sessions when needed. Preserve partial layout recovery and backups.
- [ ] 5. Windows: independent windows, move tabs/panes between windows, per-window geometry and
  layout recovery, correct menu routing/focus/status/badges. Global hotkey show/hide.
- [ ] 6. Updates: check GitHub releases, release notes, verified staged installation, explicit
  install/relaunch and daemon-upgrade deferral. Preserve active sessions until explicitly ended.
- [ ] 7. Compatibility: verify/fix selection, keyboard/IME, full-screen programs, protocol state
  across reattach, image behavior, accessibility and Secure Keyboard Entry.
- [ ] 8. Integration: README, complete checks, private runtime UI/daemon smoke tests, review diff,
  create and attach the single PR. Record limits honestly.

## Acceptance and verification

- Regression tests for parsing, protocol changes, shell quoting, shell integration, history,
  recovery and window ownership. Avoid tests that only mirror trivial implementation.
- `./scripts/check.sh` and `./scripts/build-app.sh --debug` before final PR.
- Private runtime under `/tmp` for daemon sessions and UI checks, always same environment in
  app and CLI. Record test PIDs and commands here. No normal daemon restart.
- Test layouts written by the previous version and partially invalid layouts. New peers must
  reject incompatible protocol versions rather than silently misread messages.
- Manual checks distinguish implemented, tested automatically, tested interactively and still
  requiring another Mac or an external environment.

## Resume instructions

Read this file, `AGENTS.md`, `README.md` and `git status` first. Continue this branch and the
existing PR if one is recorded below. Do not reset uncommitted work. Update this plan at every
milestone and before an interruption. Keep exact next steps, open design decisions, check results
and temporary runtime/process details current.

## Current checkpoint

- Baseline commit: `bee0f0a` on main. Working tree was clean before the plan.
- Current step: milestones 5/6 implementation and regression tests, then private UI checks.
- Existing features confirmed: palette searches sessions, tabs/folders reorder, panes move between
  tabs, splits inherit cwd, presets and basic SSH exist. Do not rebuild these.
- Existing limitations: app owns one window; zsh-only command recording; text-only clipboard;
  new tabs start at project root; daemon history fixed at 10,000 rows; no app update mechanism.
- Implemented milestone 1 source and regression tests, except `--window` routing awaits milestone 5.
  File-link clicking currently matches whitespace-delimited diagnostics, selected file paths can
  contain spaces. Image paste has both requested MIME support and an explicit PNG-path action.
- Implemented milestone 2/3 foundations: OSC 133 capture, shell scripts, protocol 2 read_output /
  set_scrollback, output document/search UI, prompt navigation and long command events.
- Checks: Rust 56 tests passed, Swift 25 tests passed after milestone 1. Later edits not checked yet.
  SwiftPM requires escalated `swift test --package-path app` because its build sandbox and caches
  are outside workspace permissions. Default build warning in DebugHooks and pre-existing
  SecurityTests Sendable warnings were observed. No test processes started. PR not created yet.
- Window/recovery source added: per-window workspaces and catalog, identity-preserving tab/pane
  transfer, detached session list, recently closed layout recovery, shared notifier, opt-in global
  hotkey, manual Secure Keyboard Entry. Catalog and recovery tests added.
- Real zsh/bash PTY regression test passed with startup and exit-status markers. `/dev/tty` tests
  need escalated cargo test; sandbox denial is separate from shell behavior. Fish is not installed.
- Updater source added: manual GitHub release discovery, SHA-256 and ZIP validation, same-team
  Developer ID and Gatekeeper checks, staged explicit install/relaunch using launchd, no daemon
  restart. Needs compile/tests and review; no update installed.
- Full `scripts/check.sh` passed (59 Rust tests, 31 Swift tests, script tests, Clippy, Swift build).
  Debug app bundle built and signed. New follow-up tests increased Swift count to 32, passing.
- Private runtime `/tmp/tern-daily`; daemon PID is in its `ternd.pid`. Current private debug app
  PID 46990 in exec session 97767. A prior non-debug test app PID 46426 and debug PID 46615 were
  stopped. Installed app PID 35011 was left alone. Do not kill by process name.
- Private checks passed for CLI open, two-window creation, tab/pane movement, exact last-command
  text + exit code, and history after app exit. Runtime actor warning in AppOpenMonitor was fixed
  with explicit @Sendable and rebuilt; no repeat observed.
- UI smoke exposed startup-command loss on immediate movement and recovery metadata loss when
  a detached tab's window closes. Both fixed with passing regression tests; Swift count is 33.
  Explicit detach now keeps an empty window available for reattachment. Output documents route
  Cmd-W/Find to their own window rather than the terminal behind them. Debug screenshots now
  include machine-readable private window/surface state.
- Retained-output export window visually verified. Output search now cancels superseded jobs.
  Duplicate saved session ownership across windows is skipped with a backup before rewriting.
- Next: test latest fixes, rebuild/relaunch private app, repeat immediate movement and detach /
  reattach / layout restoration, inspect output/search UI, then final review and PR. README updated.
  No PR or commits yet; all work remains on the same branch.

## Work log

- 2026-10-28: recorded scope and milestones before implementation.
