# Security

## Reporting a vulnerability

Please don't open a public issue for a security problem. Report it privately through GitHub's
[private vulnerability reporting](https://github.com/ishaanrajiv/tern/security/advisories/new).

Say what you found, how to reproduce it, and what it gives an attacker. tern is maintained by one
person in their spare time, so replies can take a few days. Fixes ship in a new release, and the
advisory names it.

Only the latest release and `main` get fixes.

## What tern protects

tern is a single-user tool: it runs on your Mac, as you. The issues that matter most cross a
boundary you didn't intend: another account on the Mac reading or typing into your terminals, a
file outside tern's folder being written or removed, or a crafted value from an agent, a saved
layout or a config file running as a command.

`ternd` owns your shells and what they print. It listens on a unix socket in
`~/Library/Application Support/tern`, and:

- keeps that folder `0700` and the files in it `0600`, creating it that way and repairing looser
  modes each time it starts. It doesn't follow symlinks inside the folder, and refuses to start if
  the folder itself is a symlink or belongs to another user;
- creates the socket `0600` and checks every connection's user id against its own;
- accepts only session ids that are plain file names (letters, digits, `-`, `_`, `.`; at most 128
  bytes), so no request reaches a path outside the folder;
- caps request lines and client frames at 1 MiB each, and disconnects a client that falls 8 MiB
  behind instead of buffering its output.

The app and `tern` quote agent conversation ids and tern's own path before typing or installing
them as shell commands. Release builds leave out the debug harness that drives the app through
signals.

## Out of scope

- **Anything already running as you.** It can read your files and your terminal directly; tern
  isn't a sandbox.
- **What tern stores in plain text.** Saved screens, typed commands, the layout and launch preset
  environment values live unencrypted in tern's folder, protected by file permissions only. See
  [Privacy](README.md#privacy).
- **Claude Code, Codex and Ghostty.** Report problems in those to their projects. Terminal parsing
  and rendering come from [Ghostty](https://github.com/ghostty-org/ghostty).
