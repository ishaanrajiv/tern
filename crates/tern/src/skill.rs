//! The agent skill: a SKILL.md that teaches Claude Code and Codex to drive tern's panes with
//! the CLI. Set Up in Settings installs it with the hooks, in `~/.claude/skills/tern/` and
//! `~/.codex/skills/tern/`. tern only ever writes or removes a file it wrote itself.

use std::path::PathBuf;

use anyhow::{bail, Result};

/// In every file tern writes, so it never replaces or deletes one that's yours.
const MARK: &str = "<!-- Installed by tern. Set Up in tern's Settings replaces this file. -->";

pub fn path(agent: &str) -> Result<PathBuf> {
    let home = std::env::var_os("HOME").map(PathBuf::from).ok_or_else(|| anyhow::anyhow!("HOME not set"))?;
    Ok(match agent {
        "claude" => home.join(".claude/skills/tern/SKILL.md"),
        "codex" => home.join(".codex/skills/tern/SKILL.md"),
        _ => bail!("unknown agent {agent} (expected claude or codex)"),
    })
}

/// The skill, calling the CLI by its stable path so it works without tern on PATH.
pub fn text(tern: &str) -> String {
    let t = crate::shell_quote(tern);
    format!(r#"---
name: tern
description: Drive the tern terminal's panes from inside it. Use when TERN_SESSION_ID is set and you want to run a server, watcher or long command beside you, read what another pane printed, wait for a command or another agent to finish, or open a tab for a folder.
---

{MARK}

You are running in a pane of tern, a terminal for coding agents, and its CLI controls the panes.
Run it by its full path, {t}, which works whether or not `tern` is on PATH; the examples
below shorten it to `tern`. Commands act on your own pane by default; `--pane ID|NAME` or
`--tab ID|NAME` picks another. New panes stay in the background unless you pass `--focus`, so you
don't take the user's view.

Run something beside you and read it later:

```sh
tern split down --name server -- 'npm run dev'      # prints the new pane's id
tern wait --pane server --text 'ready|listening' --timeout 60
tern capture --pane server --lines 40
```

Run a command in its own pane and get its output and exit code back, as if it ran here:

```sh
tern run -- cargo test
```

Type into a pane, wait for its shell, and read the last command's output:

```sh
tern send --pane server 'curl -s localhost:3000/health'
tern wait --pane server --prompt --timeout 30
tern capture --pane server --last-command
```

Other commands:

- `tern tab DIR --name NAME [-- CMD]` opens a tab for a folder.
- `tern wait --pane NAME --state done|needs-you|failed` waits for an agent in another pane.
- `tern close --pane NAME` ends a pane you opened.
- `tern ls --json` lists windows, folders, tabs, splits and each pane's session.
- `tern watch --json --event command-failed` streams events until interrupted.

Exit codes: 2 for bad arguments, 3 when no pane matches, 4 when a name matches several, 5 on a
timeout; `run` exits with its command's code. Name the panes you open, close them when you're done
with them, and never send keystrokes to a pane the user is working in unless they asked.
"#)
}

/// Whether tern's skill is there, and as this tern would write it.
pub fn status(agent: &str, tern: &str) -> Result<(bool, bool)> {
    let installed = std::fs::read_to_string(path(agent)?).ok().filter(|t| t.contains(MARK));
    Ok((installed.is_some(), installed.as_deref() == Some(text(tern).as_str())))
}

/// Writes the skill unless a SKILL.md tern didn't write is in the way; false then.
pub fn install(agent: &str, tern: &str) -> Result<bool> {
    let path = path(agent)?;
    if std::fs::read_to_string(&path).is_ok_and(|t| !t.contains(MARK)) {
        return Ok(false);
    }
    std::fs::create_dir_all(path.parent().unwrap())?;
    std::fs::write(&path, text(tern))?;
    Ok(true)
}

/// Removes tern's skill, and its folder if nothing else is in it.
pub fn uninstall(agent: &str) -> Result<()> {
    let path = path(agent)?;
    if std::fs::read_to_string(&path).is_ok_and(|t| t.contains(MARK)) {
        std::fs::remove_file(&path)?;
        let _ = std::fs::remove_dir(path.parent().unwrap());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn with_home(f: impl FnOnce(&std::path::Path)) {
        let _guard = crate::TEST_ENV.lock().unwrap_or_else(|e| e.into_inner());
        let old = std::env::var_os("HOME");
        let dir = std::env::temp_dir().join(format!("tern-skill-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::env::set_var("HOME", &dir);
        f(&dir);
        match old { Some(h) => std::env::set_var("HOME", h), None => std::env::remove_var("HOME") }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn installs_updates_and_removes_only_its_own_skill() {
        with_home(|home| {
            let tern = "/Users/x/Library/Application Support/tern/bin/tern";
            assert_eq!(status("claude", tern).unwrap(), (false, false));
            assert!(install("claude", tern).unwrap());
            assert_eq!(status("claude", tern).unwrap(), (true, true));
            let written = std::fs::read_to_string(home.join(".claude/skills/tern/SKILL.md")).unwrap();
            assert!(written.starts_with("---\nname: tern\n"));
            assert!(written.contains("full path, '/Users/x/Library/Application Support/tern/bin/tern', which"));
            assert!(written.contains("\ntern split down --name server"));
            // A tern elsewhere makes it out of date, and installing again brings it up to date.
            assert_eq!(status("claude", "/opt/tern").unwrap(), (true, false));
            uninstall("claude").unwrap();
            assert!(!home.join(".claude/skills/tern").exists());
        });
    }

    #[test]
    fn a_skill_of_yours_by_that_name_is_left_alone() {
        with_home(|home| {
            let mine = home.join(".codex/skills/tern/SKILL.md");
            std::fs::create_dir_all(mine.parent().unwrap()).unwrap();
            std::fs::write(&mine, "my own notes").unwrap();
            assert!(!install("codex", "/opt/tern").unwrap());
            uninstall("codex").unwrap();
            assert_eq!(std::fs::read_to_string(&mine).unwrap(), "my own notes");
            assert_eq!(status("codex", "/opt/tern").unwrap(), (false, false));
        });
    }
}
