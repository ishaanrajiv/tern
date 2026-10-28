# Daily terminal implementation plan

Started 2026-10-28. Branch `codex/daily-terminal-parity`.
Single draft PR: https://github.com/ishaanrajiv/tern/pull/6

## Scope and status

Implementation is complete for the agreed scope. Remote workflow enhancements and
profiles/configuration are excluded. Existing SSH and launch presets are preserved.
The PR remains a draft for review and the manual release checks below.

The installed app was not replaced and the normal daemon was not restarted. App updates
are staged and require an explicit Install and Relaunch action. Updating the app does not
restart ternd or end its running processes.

## Milestones

- [x] 1. Files and launching: focused-directory tabs and an explicit project-root action,
  quoted file drops, image MIME requests and PNG-path paste, editor file/line links,
  `tern open` / `tern .`, tab/window/split command launches, Finder service and URL opens.
- [x] 2. Shell integration: zsh/bash/fish prompt and command marks, exit status and duration,
  prompt navigation, last-command output selection/copy, long background command alerts.
- [x] 3. History: shared daemon/surface byte retention, export/open scrollback, regex/case
  search and retained-output search across sessions. Search results select the matching line.
- [x] 4. Recovery: detach, detached-session browser, same-session reattachment and recently
  closed layout recovery. Deliberately stopped processes reopen as fresh shells.
- [x] 5. Windows: independent layouts/geometry, tab/pane movement, shared badges and notifications,
  global session palette/attention navigation, per-window focus and an opt-in system hotkey.
- [x] 6. Updates: GitHub release discovery, release notes, checksum/archive/signature/Gatekeeper
  verification, explicit staged installation/relaunch and separate daemon-upgrade deferral.
- [x] 7. Compatibility implementation and automated coverage: native context menu, accessibility
  text/selection, Secure Keyboard Entry, Unicode input/selection, existing full-screen and
  keyboard-protocol snapshot tests. Manual system-level checks remain below.
- [x] 8. Final integration: README, full checks, debug build, private smoke tests and diff review
  completed. Final validation/fix commit and PR description are updated on the same branch.

## Important implementation decisions

- Protocol is now 2. Rust and Swift agree on read_output and set_scrollback requests; existing
  hello/status handling and explicit daemon restart confirmation remain.
- Startup commands stay queued until a daemon session is observed. This prevents an immediate
  window move from consuming input before the original relay sends its attach request.
- Each window has one Workspace and its own layout file. windows.json records ownership and
  geometry. Each window retains its own backups. Duplicate saved ownership is skipped with a
  backup, and partially invalid catalogs
  retain usable records. The old layout.json remains the main window's file.
- Window closure transfers detached/recent recovery metadata to a surviving window. Explicitly
  detaching the last tab keeps an empty window available for recovery.
- Closing output documents and using Find routes to that document rather than the live terminal.
- Command capture is bounded at 4 MiB. Read-output replies are bounded at 8 MiB and report
  truncation. The app uses a larger bounded line reader for JSON-escaped output replies.
- File-link clicking handles whitespace-delimited diagnostics. Selected paths can contain spaces.
  Line navigation depends on the editor URL scheme. Image pixels are absent from VT replay;
  image clipboard requests and PNG-path paste are independent of that limitation.
- The updater accepts the symlink-free Apple Silicon bundles this repo produces. No new
  dependencies were added. An ad-hoc/unsigned app must first install a signed release manually.

## Validation record

- Full `./scripts/check.sh` passed with 59 Rust tests, Python script tests, Clippy with warnings
  denied, Swift build and 34 Swift tests. Final rerun passed.
- `./scripts/build-app.sh --debug` passed repeatedly. The final rebuild passed.
- Real zsh and system bash PTY tests verify user startup, prompt/command marks and exit status.
- New regression coverage includes launch quoting, external URL restrictions, source locations,
  window catalog recovery and independent backups, transfers, startup-command acknowledgment, detached metadata transfer,
  output regex/case matching, Unicode source-line ranges, archive safety and release versions.
- `python3 scripts/smoke-daily.py /tmp/tern-final` passed on a fresh private runtime. It checks
  three startup commands through immediate window moves, last-tab detachment, window closure,
  and reattachment with the same session ID. It uses the private debug PID and macOS signal names.
- Private UI checks verified pane movement, output document layout, global search results,
  Unicode text commits/capture and keyboard selection. The app exposed visible text/selection
  through its accessibility methods. Runtime actor warning in the launch monitor was fixed.
- Private daemon checks verified exact last-command text, exit code 1, and retained history
  after the app exited. Snapshot tests cover full-screen state, wide/combining characters,
  resize reflow, links and keyboard modes.
- Final daemon command-output conversion retained all 15,000 lines of a completed command
  without truncation in /tmp/tern-output-final.
- Saved four-tab private layout restored after app relaunch, with the daemon sessions alive.
- Synthetic output-document Cmd-F/Cmd-W checks were inconclusive: background key-window and
  modifier routing differ from live macOS input. The debug driver retains its original routing;
  verify these shortcuts with real input before release.
- 100-iteration private relay benchmark: direct p50 10.0 µs, ternd p50 34.5 µs, overhead 24.5 µs.
  This is a point measurement, not a before/after performance claim.
- Known existing warnings: deprecated screenshot API in DebugHooks, and Sendable captures in
  SecurityTests. The normal app's existing notification permission issue also reproduces here.

## Remaining manual release checks

- [ ] Fish interactive behavior, including custom prompts and an existing shell integration.
  Fish is not installed on this machine.
- [ ] Real-keyboard Find/Close in native output documents, including multiple output windows.
- [ ] Actual system IME/dead-key/input-source switching, VoiceOver navigation and automatic
  password-prompt secure input. Unicode commit and accessibility values were checked privately.
- [ ] Global hotkey registration alongside the user's other apps. Private instances deliberately
  do not register the system hotkey.
- [ ] Signed, notarized update download/install/relaunch on a disposable installation. No real
  installed application was replaced during this work.
- [ ] Finder service discovery on a normal signed installation, real editor line handoff,
  file/image drag and clipboard interoperability with each supported agent.
- [ ] Another Mac and macOS 14. Neither is available in this environment.

## Resume instructions

Read this file, AGENTS.md, README.md and git status first. Continue the existing branch and PR.
Do not reset uncommitted work or open another PR. The first checkpoint is e31b2b4; subsequent
fixes and this log are on the same branch. Keep manual checks distinct from automated checks.

Use a short private TERN_RUNTIME_DIR for all UI/daemon work. Build without --install. For UI
smoke tests launch build/Tern.app/Contents/MacOS/Tern with TERN_DEBUG=1 and the same runtime as
the CLI, then run `python3 scripts/smoke-daily.py <runtime>`. The harness adds test sessions and
leaves them alive for inspection. Debug screenshots and state.json are in <runtime>/debug/.

Compiler/PTY validation needs sandbox escalation here because SwiftPM caches/build sandbox and
/dev/tty are outside workspace permissions. Do not mistake those denials for product failures.

## Test processes and artifacts

All private app and daemon processes created for this work were stopped after validation.
Daemon cleanup verified the PID through each private socket's hello reply and checked the process
name before sending SIGTERM. Runtimes /tmp/tern-daily, /tmp/tern-parity, /tmp/tern-final,
/tmp/tern-bench and /tmp/tern-output-final retain layouts/screenshots for inspection. The normal
app PID was 35011 at the start of validation and was left alone. Never kill by process-name pattern.

Logs: /tmp/tern-final-check.log, /tmp/tern-swift-check.log and /tmp/tern-build.log. Screenshots and
private layouts remain under their runtime directories for inspection. The final checks and cleanup are recorded above.

## Work log

- 2026-10-28: recorded scope before implementation; implemented milestones with regression tests.
- 2026-10-28: checkpoint e31b2b4 pushed and draft PR #6 created with gh after the GitHub connector
  returned 403. An initial push rejection was resolved by verifying the matching public origin
  and connected account's admin/push permission.
- 2026-10-28: private tests found and fixed startup-command transfer, detached recovery transfer,
  initial catalog persistence and background timer actor isolation. Full checks and fresh-runtime
  smoke tests passed. Final validation and cleanup completed; PR remains a draft for manual release checks.

- 2026-10-28: final checks passed with 59 Rust and 34 Swift tests; final debug bundle built.
  Private processes were cleaned up. Independent window backups gained regression coverage.
