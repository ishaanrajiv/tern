//! What a session is doing right now: its foreground process and that
//! process's working directory (libproc on macOS, /proc on Linux), plus the git branch there.

#[cfg(target_os = "macos")]
use std::ffi::CStr;
use std::os::fd::RawFd;
use std::path::{Path, PathBuf};

use nix::libc;

pub struct Foreground {
    pub pid: i32,
    /// The process name, or the agent's name when the process is a coding agent
    /// (Claude Code's binary is named after its version, Codex runs under node).
    pub name: String,
    pub cwd: Option<String>,
    pub agent: Option<&'static str>,
}

/// The process group in the PTY's foreground (the shell when idle, `claude`
/// or `vim` while they run), falling back to `fallback_pid`.
pub fn foreground(master: RawFd, fallback_pid: i32) -> Foreground {
    let pgid = unsafe { libc::tcgetpgrp(master) };
    let pid = if pgid > 0 { pgid } else { fallback_pid };
    let agent = agent_of(pid);
    let name = agent.map(str::to_string).or_else(|| process_name(pid)).unwrap_or_default();
    Foreground { pid, name, cwd: process_cwd(pid), agent }
}

/// Recognizes Claude Code and Codex by executable path or, under node, by script.
pub fn agent_of(pid: i32) -> Option<&'static str> {
    let classify = |s: &str| -> Option<&'static str> {
        let base = s.rsplit('/').next().unwrap_or(s);
        if base == "claude" || s.contains("/claude/versions/") || s.contains("@anthropic-ai/claude-code") {
            Some("claude")
        } else if base == "codex" || base == "codex.js" || s.contains("@openai/codex") {
            Some("codex")
        } else {
            None
        }
    };
    if let Some(a) = process_path(pid).as_deref().and_then(classify) {
        return Some(a);
    }
    // Interpreters: look at the script, argv[1].
    process_args(pid)?.iter().take(3).find_map(|a| classify(a))
}

#[cfg(target_os = "macos")]
pub fn process_path(pid: i32) -> Option<String> {
    let mut buf = vec![0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    let n = unsafe { libc::proc_pidpath(pid, buf.as_mut_ptr().cast(), buf.len() as u32) };
    if n <= 0 {
        return None;
    }
    Some(String::from_utf8_lossy(&buf[..n as usize]).into_owned())
}

#[cfg(not(target_os = "macos"))]
pub fn process_path(pid: i32) -> Option<String> {
    let path = std::fs::read_link(format!("/proc/{pid}/exe")).ok()?;
    let path = path.to_string_lossy();
    // The kernel marks a binary replaced since it started (an update) this way.
    Some(path.strip_suffix(" (deleted)").unwrap_or(&path).to_string())
}

/// argv of a process, via sysctl KERN_PROCARGS2: argc, exec path, padding, argv.
#[cfg(target_os = "macos")]
pub fn process_args(pid: i32) -> Option<Vec<String>> {
    let mut mib = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid];
    let mut size: libc::size_t = 0;
    let mut buf: Vec<u8>;
    unsafe {
        if libc::sysctl(mib.as_mut_ptr(), 3, std::ptr::null_mut(), &mut size, std::ptr::null_mut(), 0) != 0 {
            return None;
        }
        buf = vec![0u8; size];
        if libc::sysctl(mib.as_mut_ptr(), 3, buf.as_mut_ptr().cast(), &mut size, std::ptr::null_mut(), 0) != 0 {
            return None;
        }
    }
    buf.truncate(size);
    let argc = i32::from_ne_bytes(buf.get(..4)?.try_into().ok()?) as usize;
    let rest = &buf[4..];
    // Skip the exec path and the NUL padding after it.
    let start = rest.iter().position(|&b| b == 0)?;
    let start = start + rest[start..].iter().position(|&b| b != 0)?;
    Some(
        rest[start..]
            .split(|&b| b == 0)
            .take(argc)
            .map(|a| String::from_utf8_lossy(a).into_owned())
            .collect(),
    )
}

/// argv of a process, from /proc/<pid>/cmdline.
#[cfg(not(target_os = "macos"))]
pub fn process_args(pid: i32) -> Option<Vec<String>> {
    parse_cmdline(&std::fs::read(format!("/proc/{pid}/cmdline")).ok()?)
}

/// /proc/<pid>/cmdline is argv with a NUL after each argument; a kernel thread's is empty.
#[cfg_attr(target_os = "macos", allow(dead_code))]
fn parse_cmdline(raw: &[u8]) -> Option<Vec<String>> {
    let raw = raw.strip_suffix(&[0]).unwrap_or(raw);
    if raw.is_empty() {
        return None;
    }
    Some(raw.split(|&b| b == 0).map(|a| String::from_utf8_lossy(a).into_owned()).collect())
}

/// A process's command line for display: "npm run dev", not
/// "node /opt/homebrew/bin/npm run dev". None for a shell.
pub fn command_line(pid: i32) -> Option<String> {
    let args = process_args(pid)?;
    let base = |a: &str| a.rsplit('/').next().unwrap_or(a).to_string();
    let mut words: Vec<String> = args.iter().map(|a| a.to_string()).collect();
    let first = base(words.first()?).trim_start_matches('-').to_string();
    if SHELLS.contains(&first.as_str()) && words.len() == 1 {
        return None;
    }
    // A script run by its interpreter goes by the script's name.
    let interpreter = ["node", "python", "Python", "ruby", "perl", "bun", "deno", "bash", "sh", "zsh"]
        .iter()
        .any(|i| first == *i || first.starts_with(&format!("{i}3")) || first.starts_with(&format!("{i}2")));
    if interpreter && words.len() > 1 && words[1].contains('/') && !words[1].starts_with('-') {
        words.remove(0);
    }
    words[0] = base(&words[0]);
    let line = words.join(" ");
    Some(if line.chars().count() > 80 { line.chars().take(80).collect() } else { line })
}

pub const SHELLS: &[&str] = &["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "login"];

#[cfg(target_os = "macos")]
pub fn process_name(pid: i32) -> Option<String> {
    let mut buf = [0u8; 256];
    let n = unsafe { libc::proc_name(pid, buf.as_mut_ptr().cast(), buf.len() as u32) };
    if n <= 0 {
        return None;
    }
    Some(String::from_utf8_lossy(&buf[..n as usize]).into_owned())
}

#[cfg(not(target_os = "macos"))]
pub fn process_name(pid: i32) -> Option<String> {
    let comm = std::fs::read_to_string(format!("/proc/{pid}/comm")).ok()?;
    let comm = comm.trim_end_matches('\n');
    if comm.is_empty() {
        return None;
    }
    Some(full_name(comm, process_args(pid).as_deref()))
}

/// Linux cuts a process name off at 15 bytes ("docker-compose-" for docker-compose-v2). When
/// the program's own name in argv starts with what's left, that is the whole name.
#[cfg_attr(target_os = "macos", allow(dead_code))]
fn full_name(comm: &str, args: Option<&[String]>) -> String {
    const TASK_COMM_LEN: usize = 15;
    if comm.len() < TASK_COMM_LEN {
        return comm.to_string();
    }
    let argv0 = args.and_then(|a| a.first()).map(|a| a.rsplit('/').next().unwrap_or(a).trim_start_matches('-'));
    match argv0 {
        Some(name) if name.starts_with(comm) => name.to_string(),
        _ => comm.to_string(),
    }
}

#[cfg(target_os = "macos")]
pub fn process_cwd(pid: i32) -> Option<String> {
    let mut info: libc::proc_vnodepathinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_vnodepathinfo>() as i32;
    let n = unsafe {
        libc::proc_pidinfo(pid, libc::PROC_PIDVNODEPATHINFO, 0, (&mut info as *mut libc::proc_vnodepathinfo).cast(), size)
    };
    if n != size {
        return None;
    }
    // vip_path is a MAXPATHLEN C string stored as [[c_char; 32]; 32].
    let raw = unsafe {
        std::slice::from_raw_parts(info.pvi_cdir.vip_path.as_ptr().cast::<u8>(), libc::MAXPATHLEN as usize)
    };
    let s = CStr::from_bytes_until_nul(raw).ok()?.to_str().ok()?;
    (!s.is_empty()).then(|| s.to_string())
}

#[cfg(not(target_os = "macos"))]
pub fn process_cwd(pid: i32) -> Option<String> {
    let path = std::fs::read_link(format!("/proc/{pid}/cwd")).ok()?;
    let path = path.to_string_lossy();
    // A directory removed under the process keeps its old path, marked.
    Some(path.strip_suffix(" (deleted)").unwrap_or(&path).to_string())
}

pub struct GitInfo {
    pub root: PathBuf,
    pub branch: Option<String>,
}

/// Finds the enclosing git work tree by reading files only (no `git` process).
pub fn git_info(dir: &Path) -> Option<GitInfo> {
    let mut cur = Some(dir);
    while let Some(d) = cur {
        let dot_git = d.join(".git");
        if dot_git.is_dir() {
            return Some(GitInfo { root: d.to_path_buf(), branch: read_branch(&dot_git) });
        }
        if dot_git.is_file() {
            // Worktrees and submodules: ".git" holds "gitdir: <path>".
            let text = std::fs::read_to_string(&dot_git).ok()?;
            let gitdir = text.strip_prefix("gitdir:")?.trim();
            let gitdir = if Path::new(gitdir).is_absolute() { PathBuf::from(gitdir) } else { d.join(gitdir) };
            return Some(GitInfo { root: d.to_path_buf(), branch: read_branch(&gitdir) });
        }
        cur = d.parent();
    }
    None
}

fn read_branch(gitdir: &Path) -> Option<String> {
    let head = std::fs::read_to_string(gitdir.join("HEAD")).ok()?;
    let head = head.trim();
    match head.strip_prefix("ref: refs/heads/") {
        Some(branch) => Some(branch.to_string()),
        // Detached HEAD: show the short hash.
        None => head.get(..7).map(str::to_string),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn proc_cmdline_splits_on_nul() {
        assert_eq!(parse_cmdline(b"node\0/usr/bin/npm\0run\0dev\0").unwrap(), ["node", "/usr/bin/npm", "run", "dev"]);
        // An empty argument in the middle is kept; a kernel thread has no command line.
        assert_eq!(parse_cmdline(b"sh\0-c\0\0x\0").unwrap(), ["sh", "-c", "", "x"]);
        assert_eq!(parse_cmdline(b""), None);
    }

    #[test]
    fn a_name_cut_off_by_the_kernel_is_completed_from_argv() {
        let args = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(full_name("zsh", Some(&args(&["-zsh"]))), "zsh");
        assert_eq!(full_name("docker-compose-", Some(&args(&["/usr/bin/docker-compose-v2", "up"]))), "docker-compose-v2");
        // A script's interpreter is named in full already; argv says something else.
        assert_eq!(full_name("python3.11-conf", Some(&args(&["/opt/tool", "x"]))), "python3.11-conf");
        assert_eq!(full_name("exactly15chars_", None), "exactly15chars_");
    }

    #[test]
    fn this_process_can_be_read() {
        let pid = std::process::id() as i32;
        assert!(process_name(pid).is_some_and(|n| !n.is_empty()));
        assert!(process_path(pid).is_some_and(|p| p.starts_with('/')));
        assert!(process_args(pid).is_some_and(|a| !a.is_empty()));
        let cwd = std::env::current_dir().unwrap().canonicalize().unwrap();
        assert_eq!(process_cwd(pid).map(std::path::PathBuf::from).and_then(|p| p.canonicalize().ok()), Some(cwd));
    }
}
