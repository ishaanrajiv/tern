# Public-readiness review

Reviewed on 2026-10-23 against main `e8d20b5`.

Recommendation: keep the repository private during 0.0.1 preparation. No obvious
credential leak was found in the local tracked history, but the application still
has concrete runtime, input-validation and privacy issues. Publishing source and
distributing a signed binary are separate decisions. A private draft prerelease
can support maintainer testing while the follow-up work is tracked.

The initial GitHub API check confirmed that `ishaanrajiv/tern` was private, `main` was
unprotected, and no releases existed. The security-feature metadata was unavailable;
this review does not infer that those features are enabled or disabled. The maintainer
subsequently installed the signed app and authorized publication of the private
[v0.0.1 prerelease](https://github.com/ishaanrajiv/tern/releases/tag/v0.0.1) on 2026-10-23.
The issues below remain unresolved, and repository visibility is unchanged.

## Source and history

The read-only scan covered tracked files and all local refs, 32 commits including
the preserved release branches. It found no high-risk credential patterns, private
keys or credential-bearing file types. Personal names and email addresses appear
in normal authorship metadata. This is a pattern-based review, not a guarantee
that every kind of secret or private information is absent.

The repository has an MIT license, a pinned Ghostty submodule and bundled third-party
notices. The review did not independently scan the entire upstream Ghostty history.
Remote-only refs, GitHub Actions logs/artifacts, and every remote discussion were
not comprehensively scanned. Review these before changing visibility. GitHub makes
Actions history and logs public when a repository becomes public, and public forks
can remain public even if the original repository is later made private.

Reference: [GitHub's repository visibility documentation](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/managing-repository-settings/setting-repository-visibility).

## Application issues to resolve before broad distribution

| Finding | Evidence on main | Required outcome |
|---|---|---|
| Runtime directory and socket are not explicitly private; connections have no peer-UID verification | `crates/tern/src/bin/ternd/main.rs`, startup and `handle_conn` | Explicit private modes and same-user peer checks, with safe handling of existing directories and symlinks. The current host's runtime directory and socket were both observed at mode `0755`. |
| Unvalidated session IDs reach filesystem paths | `crates/tern/src/shell.rs`, `command_file`; `crates/tern/src/bin/ternd/session.rs`, `spawn_session` | Reject absolute paths, traversal and invalid names before reads/removals/writes. Saved-screen validation alone does not protect command files. |
| Unbounded protocol buffers and client queues | `crates/tern/src/lib.rs`, `read_frame`; `crates/tern/src/bin/ternd/session.rs`, `attach`; `app/Sources/Tern/TernClient.swift`, newline reader | Reject oversized messages before allocation and disconnect stalled clients without blocking session output or losing final output. |
| App resume IDs are interpolated into shell commands | `app/Sources/Tern/Workspace.swift`, `resumeCommand` | Quote the agent's conversation ID as data. The daemon's saved-screen path already quotes it and should retain that behavior. |
| Hook paths use double-quoted shell strings and configuration writes replace symlinks | `crates/tern/src/hooks.rs`, `command`, `statusline_command`, `write_config` | Safe shell quoting and config updates that preserve unrelated entries, user file modes and intentional symlinks. |
| Debug event-driving controls are included in release builds | `app/Sources/Tern/DebugHooks.swift` | Compile the harness only into debug builds; an environment variable should not activate it in a distributed app. |
| Claude account polling defaults to enabled | `app/Sources/Tern/Workspace.swift`, preference defaults; `app/Sources/Tern/AgentTools.swift`, `ClaudeAccount` | Explicit opt-in and a clear explanation of the Keychain credential and Anthropic request. Preserve the rule against refreshing the token. |
| Dependency downloads are not checked against their declared package hashes | `scripts/build-ghostty.sh` | Verify content and extracted package layout before trusting fetched sources. |

Repository privacy does not fix any of these application behaviors. Address them
before broad binary distribution, even if the source remains private.

### Status after the runtime hardening branch

All eight findings are addressed on `security/runtime-hardening`, adapted from the closed PRs
to current main rather than copied:

| Finding | Change | Tests |
|---|---|---|
| Runtime storage and peer UID | `prepare_runtime_dir` refuses a root that is a symlink or another user's, creates it `0700` and repairs the tree (`0700` folders, `0600` files) without following symlinks. ternd runs with umask `077`, sets the socket to `0600` and checks `getpeereid` on every connection. Sessions get the user's original umask back. | `runtime_storage_is_made_private_without_following_links`, `only_this_user_may_connect` |
| Session IDs | `valid_session_id` (plain file names, at most 128 bytes so suffixes fit) gates attach, kill and report before any file is touched. Saved screens and command files also check it themselves. | `session_ids_stay_file_names`, `ids_that_are_paths_are_refused_before_touching_files`, `command_files_stay_in_their_folder` |
| Protocol buffers and queues | Request lines are capped at 1 MiB and client frames at 1 MiB before allocation. Snapshots go out in 1 MiB frames; `tern attach` accepts up to 64 MiB for older daemons. Each client's queue holds 8 MiB; past that the client is hung up on and reattaches. The exit code follows the last output. Closing a client wakes its writer. The app's line reader stops at 16 MiB and no longer rescans its buffer. | `oversized_frames_are_refused_before_allocating`, `an_endless_request_line_is_cut_off`, `a_client_that_stops_reading_is_hung_up_on`, `the_exit_follows_the_last_output`, `closing_wakes_a_waiting_writer`, `testAnEndlessLineFromTheDaemonIsDropped` |
| App resume IDs | `Workspace.resumeCommand` quotes the conversation ID with `quoteShell`. | `testResumeCommandsTypeTheSessionIDAsData` |
| Hook quoting and config writes | Hook and status line commands single-quote the binary path. Older double-quoted entries are still recognised, so upgrades replace them. Writes go through symlinks to the real file, keep its mode, and put the backup beside it. An emptied Codex `hooks.json` is removed only if tern created it. | `hook_paths_are_quoted_for_the_shell`, `upgrading_from_double_quoted_hooks_replaces_them`, `symlinked_configs_are_written_through_and_keep_their_mode`, `an_empty_codex_file_the_user_made_is_kept` |
| Debug harness | `DebugHooks` is compiled only under `#if DEBUG`. A release binary contains none of its strings. | Checked with `strings` on debug and release builds |
| Claude account polling | Off by default. Settings explains the Keychain read and the request to Anthropic. A choice the user already saved is kept. | Manual review |
| Dependency downloads | `scripts/fetch-zig-package.py` hashes each archive, and then the extracted package, with the pinned Zig. It publishes a package only on a match, including `.tgz` sources. It unpacks with Python rather than macOS `tar`, which folds AppleDouble `._` files into extended attributes. That folding left the old fetcher's JetBrainsMono copy different from its pinned hash. `build-ghostty.sh` requires the exact Zig version and refetches anything without a verification marker. | `scripts/tests/test_fetch_zig_package.py`, plus a full `build-ghostty.sh` run against the real pinned dependencies |

Launch presets can store secrets in plaintext environment values. The README already
discloses this. Private runtime storage should cover presets as well as terminal
screens, commands, usage records and layout backups. The privacy documentation must
also cover npm version checks, optional Anthropic account requests, user-requested
SSH connections and the user's configured startup commands.

## Public project preparation

Add a security reporting route and truthful privacy documentation. Update the release
checklist and contributor instructions for Swift 6 and libghostty-vt. Add CI that builds
the pinned native dependency before checking Rust and Swift, and requires those checks
to pass. Consider branch protection after that workflow is established.

Issue templates, a PR template and a code of conduct from the old PR are useful
housekeeping. Their absence is not a security vulnerability and does not by itself
require keeping source private.

Before distributing the app, review the source/rebuild materials for bundled LGPL/MPL
components against `THIRD_PARTY_NOTICES.md`. GitHub's automatic source archive excludes
the Ghostty submodule and downloaded dependency sources, so it should not be described
as the complete dependency source package.

Notification banners, process loss on reboot or daemon restart, incomplete full-screen
screen persistence, heuristic agent completion and the documented Codex copy/paste issue
belong in release notes and smoke tests. They do not require hiding the source. Copy/paste
deserves investigation before distributing a terminal intended for coding agents.

## Next decision

The runtime findings above are fixed, merged in PR #4. On 2026-10-23 the remaining review
found nothing to hold back: the one Actions log, PRs #1 to #4 and the preserved branches hold
no credentials or personal paths, and there are no artifacts, issues or comments. `SECURITY.md`,
`CONTRIBUTING.md` and a README Privacy section were added. The repository was made public with
the 0.0.2 prerelease.

Still open: a CI workflow (it needs the pinned Zig and a Ghostty build on a macOS runner),
branch protection once CI exists, and the separate-Mac, macOS 14 and real-agent checks listed
in the release notes.

Earlier: keep visibility unchanged now. Prepare the signing setup and private release candidate,
then revisit public visibility after the runtime fixes, privacy/security documentation
and remaining remote-history review. The preserved changes and release sequence are
tracked in [the 0.0.1 release plan](0.0.1-release-plan.md).
