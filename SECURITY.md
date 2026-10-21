# Security

## Reporting a vulnerability

Please **do not open a public issue** for a security problem. Report it privately instead:

- Use GitHub's [private vulnerability reporting](https://github.com/ishaanrajiv/tern/security/advisories/new)
  on this repository, if it is enabled for you.
- Or email the maintainer. The address is on the [GitHub profile](https://github.com/ishaanrajiv).

Include what you found, how to reproduce it, and what an attacker would get out of it. You should get
a reply within a few days. Fixes are released as a new version, and the advisory says which.

tern is a single-user tool: it runs on your machine, as you, and talks to your own daemon over a
unix socket. Most of its attack surface is therefore "something else running as you", which already
has your shell. Issues that matter most are the ones that cross a boundary you did not intend:
another local account reading your terminal, a file somewhere else on disk being written by accident,
or something you installed running with more reach than it should.

## What the daemon protects

`ternd` owns your shells and their output. It is reachable only through a unix socket in
`~/Library/Application Support/tern`, which is:

- inside a directory created `0700`, repaired on every start of the daemon;
- a socket file created `0600`;
- checked on every connection: the peer's user id must be the daemon's own.

The daemon refuses to start if the runtime directory has been replaced by a symlink, and it will not
follow symlinks inside it. Session ids, which are also file names, are restricted to characters that
cannot escape the directory.

Saved screens live in the same directory and can hold whatever you scrolled past. They are not
encrypted.

## Out of scope

- **Anything running as you.** A process with your permissions can read your files, run your
  commands and reach your shell. tern does not try to be a sandbox.
- **Claude Code and Codex.** They are their own projects with their own security. tern reads their
  hooks' output and, if you turn it on, reads Claude Code's sign-in from the Keychain. See
  [Privacy](README.md#privacy).
- **Ghostty.** The terminal rendering comes from
  [Ghostty](https://github.com/ghostty-org/ghostty); report anything in that area upstream.
