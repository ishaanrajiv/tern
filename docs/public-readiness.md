# Public-readiness review

Reviewed on 2026-10-23 against main `e8d20b5`.

Recommendation: keep the repository private during 0.0.1 preparation. No obvious
credential leak was found in the local tracked history, but the application still
has concrete runtime, input-validation and privacy issues. Publishing source and
distributing a signed binary are separate decisions. A private draft prerelease
can support maintainer testing while the follow-up work is tracked.

The GitHub API confirms that `ishaanrajiv/tern` is private, `main` is unprotected,
and no releases have been published. The security-feature metadata was unavailable;
this review does not infer that those features are enabled or disabled.

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

Keep visibility unchanged now. Prepare the signing setup and private release candidate,
then revisit public visibility after the runtime fixes, privacy/security documentation
and remaining remote-history review. The preserved changes and release sequence are
tracked in [the 0.0.1 release plan](0.0.1-release-plan.md).
