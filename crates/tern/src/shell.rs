//! zsh integration: a preexec hook that writes each command line, as typed, to
//! a file per session, so a tab can be named after what it runs ("npm run dev").
//! Watching the foreground process alone misses quick commands like `git status`.
//! A precmd hook touches a second file each time a command finishes, which is when
//! a shell tab counts as done.
//!
//! zsh is pointed at our own ZDOTDIR, whose .zshenv puts the user's ZDOTDIR back,
//! sources their .zshenv and adds the hook; zsh then reads the rest of the user's
//! startup files as usual. Ghostty's shell integration works the same way.

use std::path::{Path, PathBuf};

use crate::runtime_dir;

const ZSHENV: &str = r#"# Written by ternd. Restores your ZDOTDIR, then records each command for tern's tab names.
if [[ -n "${TERN_ZDOTDIR+X}" ]]; then
    'builtin' 'export' ZDOTDIR="$TERN_ZDOTDIR"
    'builtin' 'unset' 'TERN_ZDOTDIR'
else
    'builtin' 'unset' 'ZDOTDIR'
fi
{
    'builtin' 'typeset' _tern_file="${ZDOTDIR-$HOME}/.zshenv"
    [[ ! -r "$_tern_file" ]] || 'builtin' 'source' '--' "$_tern_file"
} always {
    if [[ -o 'interactive' && -n "$TERN_COMMAND_FILE" ]]; then
        _tern_preexec() { _tern_ran=1; { 'builtin' 'print' -rn -- "$1" >| "$TERN_COMMAND_FILE" } 2>/dev/null }
        # Only after a command ran: not for the first prompt, or ↩ on an empty line.
        _tern_precmd() {
            [[ -n "$_tern_ran" ]] || 'builtin' 'return' 0
            _tern_ran=
            { 'builtin' 'print' -n >| "$TERN_COMMAND_FILE.done" } 2>/dev/null
        }
        'builtin' 'autoload' -Uz add-zsh-hook && add-zsh-hook preexec _tern_preexec && add-zsh-hook precmd _tern_precmd
    fi
    'builtin' 'unset' '_tern_file'
}
"#;

/// Writes the integration's .zshenv and returns its directory, for ZDOTDIR.
pub fn install_zsh() -> std::io::Result<PathBuf> {
    let dir = runtime_dir();
    let dir = std::path::absolute(&dir).unwrap_or(dir).join("zsh");
    std::fs::create_dir_all(&dir)?;
    std::fs::write(dir.join(".zshenv"), ZSHENV)?;
    Ok(dir)
}

pub fn is_zsh(shell: &str) -> bool {
    Path::new(shell).file_name().is_some_and(|n| n == "zsh")
}

/// Where a session's shell records its commands.
pub fn command_file(id: &str) -> PathBuf {
    let dir = runtime_dir();
    std::path::absolute(&dir).unwrap_or(dir).join("commands").join(id)
}

/// Touched by the session's shell each time a command finishes.
pub fn finished_file(id: &str) -> PathBuf {
    let mut path = command_file(id).into_os_string();
    path.push(".done");
    path.into()
}

/// When the session's shell last finished a command, in Unix milliseconds; 0 if it hasn't.
pub fn finished_ms(id: &str) -> u64 {
    std::fs::metadata(finished_file(id))
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0, |d| d.as_millis() as u64)
}

/// The last command line the session's shell ran, if the integration is active.
pub fn last_command(id: &str) -> Option<Option<String>> {
    std::fs::read_to_string(command_file(id)).ok().map(|text| telling(&text))
}

/// What a command line says about a tab: its last part that isn't trivial,
/// so `cd api && npm run dev` gives "npm run dev" and `ls` gives nothing.
pub fn telling(line: &str) -> Option<String> {
    let line = line.lines().map(str::trim).find(|l| !l.is_empty())?;
    let part = line
        .split("&&")
        .flat_map(|p| p.split("||"))
        .flat_map(|p| p.split(';'))
        .map(str::trim)
        .filter(|p| !is_trivial(p))
        .last()?;
    Some(part.chars().take(80).collect())
}

/// Commands that say nothing about what a tab is for, so they don't rename it.
pub fn is_trivial(command: &str) -> bool {
    let first = command.split_whitespace().next().unwrap_or("");
    matches!(
        first,
        "" | "cd" | "z" | "zi" | "ls" | "ll" | "la" | "l" | "eza" | "pwd" | "clear" | "cls" | "reset" | "exit"
            | "history" | "echo" | "which" | "type" | "true" | "false" | "source" | "." | "export" | "unset"
    )
}

#[cfg(test)]
mod tests {
    use super::telling;

    #[test]
    fn picks_the_telling_part() {
        assert_eq!(telling("cd api && npm run dev").as_deref(), Some("npm run dev"));
        assert_eq!(telling("ls -la"), None);
        assert_eq!(telling("git status; clear").as_deref(), Some("git status"));
        assert_eq!(telling("cargo test\n  --release").as_deref(), Some("cargo test"));
    }
}
