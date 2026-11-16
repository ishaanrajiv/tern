//! Shell integration: a preexec hook that writes each command line, as typed, to
//! a file per session, so a tab can be named after what it runs ("npm run dev").
//! A command keeps the name once it has run a few seconds; `git status` shows only
//! while it runs. Watching the foreground process alone would miss the command line.
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
        _tern_preexec() { 'builtin' 'printf' '\033]133;C\007' > /dev/tty; _tern_ran=1; { 'builtin' 'print' -rn -- "$1" >| "$TERN_COMMAND_FILE" } 2>/dev/null }
        # Only after a command ran: not for the first prompt, or ↩ on an empty line.
        _tern_precmd() {
            local _tern_status=$?
            if [[ -n "$_tern_ran" ]]; then
                'builtin' 'printf' '\033]133;D;%s\007' "$_tern_status" > /dev/tty
                _tern_ran=
                { 'builtin' 'print' -n >| "$TERN_COMMAND_FILE.done" } 2>/dev/null
            fi
            'builtin' 'printf' '\033]133;A\007' > /dev/tty
            [[ "$PS1" == *$'\e]133;B'* ]] || PS1+=$'%{\e]133;B\a%}'
            return $_tern_status
        }
        'builtin' 'autoload' -Uz add-zsh-hook && add-zsh-hook preexec _tern_preexec && add-zsh-hook precmd _tern_precmd
    fi
    'builtin' 'unset' '_tern_file'
}
"#;

const BASHRC: &str = r#"# Tern starts this interactive shell with the user's login startup sequence.
[[ -r /etc/profile ]] && source /etc/profile
for _tern_profile in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
    if [[ -r "$_tern_profile" ]]; then source "$_tern_profile"; break; fi
done
unset _tern_profile
_tern_running=
_tern_before() {
    [[ -n "$_tern_running" ]] && return
    _tern_running=1
    printf '\033]133;C\007'
    local _tern_line=${1:-}
    if [[ -z "$_tern_line" ]]; then
        _tern_line=$(LC_ALL=C HISTTIMEFORMAT= builtin history 1)
        _tern_line=${_tern_line#*[[:digit:]][* ] }
    fi
    printf '%s' "${_tern_line:-$BASH_COMMAND}" > "$TERN_COMMAND_FILE"
}
_tern_prompt() {
    local _tern_status=$?
    if [[ -n "$_tern_running" ]]; then
        printf '\033]133;D;%s\007' "$_tern_status" > /dev/tty
        : > "$TERN_COMMAND_FILE.done"
    fi
    printf '\033]133;A\007' > /dev/tty
    [[ "$PS1" == *$'\e]133;B'* ]] || PS1+=$'\[\e]133;B\a\]'
    _tern_running=
    return "$_tern_status"
}
# Cooperate with bash-preexec when installed. Otherwise preserve the user's DEBUG
# trap and use PS0 on modern bash, or a guarded DEBUG trap on the system bash.
if declare -p preexec_functions >/dev/null 2>&1; then
    preexec_functions+=(_tern_before)
    precmd_functions+=(_tern_prompt)
else
    _tern_user_prompt=("${PROMPT_COMMAND[@]}")
    _tern_prompt_chain() {
        local _tern_status=$?
        # Finish the command before a user's prompt hook writes its own output.
        (exit "$_tern_status")
        _tern_prompt
        local _tern_command
        for _tern_command in "${_tern_user_prompt[@]}"; do
            (exit "$_tern_status")
            eval "$_tern_command"
        done
        [[ "$PS1" == *$'\e]133;B'* ]] || PS1+=$'\[\e]133;B\a\]'
        return "$_tern_status"
    }
    PROMPT_COMMAND=_tern_prompt_chain
    if [[ -z "$(trap -p DEBUG)" ]]; then
        trap '[[ "$BASH_COMMAND" == _tern_prompt_chain || "$BASH_COMMAND" == _tern_prompt ]] || _tern_before' DEBUG
    else
        # Never replace an unrelated DEBUG trap. Existing prompt hooks still work.
        # PS0 assigns the marker in the parent shell so precmd can finish it.
        PS0='${_tern_running:=$(_tern_before)}'"$PS0"
    fi
fi
"#;

const FISH: &str = r#"# Installed for this shell only, after the user's startup files.
function _tern_before --on-event fish_preexec
    printf '\e]133;C\a'
    printf '%s' "$argv[1]" > "$TERN_COMMAND_FILE"
end
function _tern_after --on-event fish_postexec
    set -l code $status
    printf '\e]133;D;%s\a' $code
    printf '' > "$TERN_COMMAND_FILE.done"
end
function _tern_prompt --on-event fish_prompt
    printf '\e]133;A\a'
end
# Wrap only the prompt function in this shell, keeping the user's implementation.
if functions -q fish_prompt
    functions -c fish_prompt _tern_user_fish_prompt
    function fish_prompt
        _tern_user_fish_prompt
        printf '\e]133;B\a'
    end
end
"#;

/// The shell sessions run: `$SHELL`, else the user's login shell from the password database
/// (ternd started over SSH by a non-interactive command may have no `$SHELL`).
pub fn login_shell() -> String {
    if let Some(shell) = std::env::var("SHELL").ok().filter(|s| s.starts_with('/')) {
        return shell;
    }
    nix::unistd::User::from_uid(nix::unistd::getuid())
        .ok()
        .flatten()
        .map(|u| u.shell.display().to_string())
        .filter(|s| s.starts_with('/') && Path::new(s).exists())
        .unwrap_or_else(|| if Path::new("/bin/zsh").exists() { "/bin/zsh" } else { "/bin/sh" }.into())
}

/// A session's environment, with `TERM` one this machine knows. The app's terminal is
/// `xterm-ghostty`; a device without that terminfo entry gets `xterm-256color`, which Ghostty
/// also speaks, rather than programs that can't draw. A `TERMINFO` that isn't here is dropped.
pub fn terminal_env(env: Vec<(String, String)>) -> Vec<(String, String)> {
    let terminfo = env.iter().find(|(k, _)| k == "TERMINFO").map(|(_, v)| PathBuf::from(v)).filter(|p| p.is_dir());
    let mut env: Vec<(String, String)> = env.into_iter().filter(|(k, _)| k != "TERMINFO").collect();
    if let Some(dir) = &terminfo {
        env.push(("TERMINFO".into(), dir.display().to_string()));
    }
    for (key, value) in env.iter_mut() {
        if key == "TERM" && value != "xterm-256color" && !knows_terminal(value, terminfo.as_deref()) {
            *value = "xterm-256color".into();
        }
    }
    env
}

/// Whether a terminfo entry for `term` is where ncurses looks: `$TERMINFO`, `~/.terminfo`,
/// `$TERMINFO_DIRS`, then the system folders. Entries sit under their first letter, or its hex
/// code on macOS (`78/xterm-ghostty`).
pub fn knows_terminal(term: &str, terminfo: Option<&Path>) -> bool {
    let Some(first) = term.chars().next() else { return false };
    if term.contains('/') {
        return false;
    }
    let mut dirs: Vec<PathBuf> = terminfo.map(Path::to_path_buf).into_iter().collect();
    if let Some(home) = std::env::var_os("HOME") {
        dirs.push(PathBuf::from(home).join(".terminfo"));
    }
    if let Some(list) = std::env::var_os("TERMINFO_DIRS") {
        dirs.extend(std::env::split_paths(&list).filter(|p| !p.as_os_str().is_empty()));
    }
    for dir in ["/etc/terminfo", "/lib/terminfo", "/usr/share/terminfo", "/usr/lib/terminfo", "/usr/local/share/terminfo",
                "/opt/homebrew/share/terminfo", "/usr/share/lib/terminfo"] {
        dirs.push(dir.into());
    }
    let hex = format!("{:02x}", first as u32);
    dirs.iter().any(|d| d.join(first.to_string()).join(term).is_file() || d.join(&hex).join(term).is_file())
}

/// Configure only the shell being spawned; user dotfiles are never edited.
pub fn configure(command: &mut std::process::Command, shell: &str, env: &[(String, String)]) {
    let dir = std::path::absolute(runtime_dir()).unwrap_or_else(|_| runtime_dir());
    let name = Path::new(shell).file_name().and_then(|s| s.to_str()).unwrap_or("");
    match name {
        "zsh" if dir.join("zsh/.zshenv").exists() => {
            if let Some((_, value)) = env.iter().find(|(k, _)| k == "ZDOTDIR") {
                command.env("TERN_ZDOTDIR", value);
            }
            command.env("ZDOTDIR", dir.join("zsh"));
            command.arg("-l");
        }
        "bash" => { command.args(["--rcfile"]).arg(dir.join("shell/bashrc")).arg("-i"); }
        "fish" => { command.args(["-l", "--init-command"]).arg(format!("source {}", crate::shell_quote(&dir.join("shell/tern.fish").to_string_lossy()))); }
        _ => { command.arg("-l"); }
    }
}

/// Writes the integration's .zshenv and returns its directory, for ZDOTDIR.
pub fn install_zsh() -> std::io::Result<PathBuf> {
    let dir = runtime_dir();
    let dir = std::path::absolute(&dir).unwrap_or(dir).join("zsh");
    std::fs::create_dir_all(&dir)?;
    std::fs::write(dir.join(".zshenv"), ZSHENV)?;
    let scripts = runtime_dir().join("shell");
    std::fs::create_dir_all(&scripts)?;
    std::fs::write(scripts.join("bashrc"), BASHRC)?;
    std::fs::write(scripts.join("tern.fish"), FISH)?;
    Ok(dir)
}

pub fn is_zsh(shell: &str) -> bool {
    Path::new(shell).file_name().is_some_and(|n| n == "zsh")
}

/// Where a session's shell records its commands.
pub fn command_file(id: &str) -> PathBuf {
    let dir = runtime_dir();
    // ternd refuses such ids, but this file is written and removed, so it never leaves its folder.
    let id = if crate::valid_session_id(id) { id } else { "invalid-session-id" };
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

/// The last command line the session's shell ran, as typed (its first line, at most 200 characters).
pub fn last_line(id: &str) -> Option<String> {
    let text = std::fs::read_to_string(command_file(id)).ok()?;
    let line = text.lines().map(str::trim).find(|l| !l.is_empty())?;
    Some(line.chars().take(200).collect())
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
    fn interactive_shells_keep_startup_and_command_boundaries() {
        use std::io::{Read, Write};
        use std::os::fd::{AsFd, OwnedFd};
        use std::time::{Duration, Instant};
        let _guard = crate::TEST_ENV.lock().unwrap_or_else(|e| e.into_inner());
        let root = std::env::temp_dir().join(format!("tern-shell-test-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        std::env::set_var("TERN_RUNTIME_DIR", &root);
        super::install_zsh().unwrap();
        std::fs::create_dir_all(root.join("commands")).unwrap();
        std::fs::write(root.join(".zshrc"), "printf 'USER-STARTUP\\n'\nPS1='test> '\n").unwrap();
        std::fs::write(root.join(".bash_profile"), "printf 'USER-STARTUP\\n'\nPS1='test> '\n").unwrap();
        let mut shells: Vec<(String, bool)> =
            ["/bin/zsh", "/bin/bash"].into_iter().filter(|s| std::path::Path::new(s).exists()).map(|s| (s.to_string(), false)).collect();
        // Exercise PS0 with an existing DEBUG trap when modern bash is available.
        if let Ok(shell) = std::env::var("TERN_TEST_BASH") { shells.push((shell, true)); }
        for (shell, debug_trap) in shells {
            if debug_trap {
                std::fs::write(root.join(".bash_profile"), "printf 'USER-STARTUP\\n'\nPS1='test> '\ntrap ':' DEBUG\n").unwrap();
            }
            let pty = nix::pty::openpty(None, None).unwrap();
            let mut command = std::process::Command::new(&shell);
            command.env("HOME", &root).env("TERN_COMMAND_FILE", root.join("commands/test")).env_remove("ZDOTDIR");
            super::configure(&mut command, &shell, &[]);
            let slave: OwnedFd = pty.slave;
            let mut child = crate::spawn_on_pty(command, slave).unwrap();
            let mut master = std::fs::File::from(pty.master);
            let mut output = Vec::new();
            let until = Instant::now() + Duration::from_secs(5);
            let mut sent = 0;
            let mut first_command = None;
            let line = "cd /tmp && printf 'COMMAND-OUTPUT\\n'; false";
            while Instant::now() < until {
                let mut fds = [nix::poll::PollFd::new(master.as_fd(), nix::poll::PollFlags::POLLIN)];
                if nix::poll::poll(&mut fds, 100u16).unwrap() == 0 { continue; }
                let mut bytes = [0u8; 4096];
                let Ok(n) = master.read(&mut bytes) else { break };
                if n == 0 { break; }
                output.extend_from_slice(&bytes[..n]);
                if sent == 0 && output.windows(6).any(|w| w == b"133;A\x07") {
                    master.write_all(format!("{line}\r").as_bytes()).unwrap();
                    sent = 1;
                }
                if sent == 1 && output.windows(8).any(|w| w == b"133;D;1\x07") {
                    first_command = std::fs::read_to_string(root.join("commands/test")).ok();
                    master.write_all(b"printf 'SECOND-OUTPUT\\n'\r").unwrap();
                    sent = 2;
                }
                if sent == 2 && output.windows(8).any(|w| w == b"133;D;0\x07") { break; }
            }
            let _ = child.kill(); let _ = child.wait();
            assert_eq!(first_command.as_deref().map(str::trim), Some(line), "{shell}");
            let output = String::from_utf8_lossy(&output);
            assert!(output.contains("USER-STARTUP"), "{shell}: {output:?}");
            assert!(output.contains("COMMAND-OUTPUT"), "{shell}: {output:?}");
            assert!(output.contains("133;C"), "{shell}: {output:?}");
            assert!(output.contains("133;D;1"), "{shell}: {output:?}");
            assert!(output.contains("SECOND-OUTPUT") && output.contains("133;D;0"), "{shell}: {output:?}");
            assert_eq!(std::fs::read_to_string(root.join("commands/test")).unwrap().trim(), "printf 'SECOND-OUTPUT\\n'", "{shell}");
        }
        std::env::remove_var("TERN_RUNTIME_DIR");
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn an_unknown_terminal_falls_back_to_one_ghostty_speaks() {
        let env = |pairs: &[(&str, &str)]| pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect::<Vec<_>>();
        let out = super::terminal_env(env(&[("TERM", "xterm-tern-test-none"), ("COLORTERM", "truecolor")]));
        assert_eq!(out, env(&[("TERM", "xterm-256color"), ("COLORTERM", "truecolor")]));
        // A TERMINFO folder this machine has is kept and searched; one it hasn't is dropped.
        let dir = std::env::temp_dir().join(format!("tern-terminfo-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("78")).unwrap();
        std::fs::write(dir.join("78/xterm-tern-test"), b"").unwrap();
        let dir_text = dir.display().to_string();
        let out = super::terminal_env(env(&[("TERM", "xterm-tern-test"), ("TERMINFO", &dir_text)]));
        assert_eq!(out, env(&[("TERM", "xterm-tern-test"), ("TERMINFO", &dir_text)]));
        let out = super::terminal_env(env(&[("TERM", "xterm-256color"), ("TERMINFO", "/nonexistent/terminfo")]));
        assert_eq!(out, env(&[("TERM", "xterm-256color")]));
        assert!(!super::knows_terminal("../../x", Some(&dir)));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_login_shell_is_always_found() {
        assert!(super::login_shell().starts_with('/'));
    }

    #[test]
    fn picks_the_telling_part() {
        assert_eq!(telling("cd api && npm run dev").as_deref(), Some("npm run dev"));
        assert_eq!(telling("ls -la"), None);
        assert_eq!(telling("git status; clear").as_deref(), Some("git status"));
        assert_eq!(telling("cargo test\n  --release").as_deref(), Some("cargo test"));
    }

    #[test]
    fn command_files_stay_in_their_folder() {
        let file = super::command_file("../../victim");
        assert_eq!(file.file_name().unwrap(), "invalid-session-id");
        assert_eq!(super::finished_file("/tmp/x").file_name().unwrap(), "invalid-session-id.done");
        assert_eq!(super::command_file("p-1").file_name().unwrap(), "p-1");
    }
}
