//! Shared pieces of the tern daemon protocol.
//!
//! A client opens the daemon socket and sends one JSON line (`Request`).
//! For `attach`, the daemon answers with one JSON line (`AttachReply`) and
//! the connection then switches to binary frames in both directions:
//! `[kind: u8][len: u32 big-endian][payload]`.

use std::io::{self, Read, Write};
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

pub mod hooks;
pub mod procinfo;
pub mod shell;
pub mod usage;

/// Client -> daemon: raw bytes typed into the terminal.
pub const FRAME_INPUT: u8 = 0x01;
/// Client -> daemon: new terminal size, payload is `cols: u16, rows: u16` big-endian.
pub const FRAME_RESIZE: u8 = 0x02;
/// Daemon -> client: raw bytes produced by the session.
pub const FRAME_OUTPUT: u8 = 0x81;
/// Daemon -> client: the session's process exited, payload is `code: i32` big-endian.
pub const FRAME_EXIT: u8 = 0x82;

#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Request {
    Attach {
        id: String,
        cols: u16,
        rows: u16,
        /// Working directory for a new session. Ignored if the session exists.
        cwd: Option<String>,
        /// Command for a new session, run through `/bin/sh -c`. Defaults to the login shell.
        cmd: Option<String>,
        /// A line typed into a new session once its shell is ready (resuming an agent).
        #[serde(default)]
        init: Option<String>,
        /// Extra environment for a new session (TERM, COLORTERM, ...).
        #[serde(default)]
        env: Vec<(String, String)>,
    },
    List,
    /// Streams the session list as one JSON line whenever it changes.
    Watch,
    Kill {
        id: String,
    },
    /// An agent hook running inside a session reports what the agent is doing.
    Report {
        id: String,
        agent: String,
        state: AgentState,
        /// The agent's own session id, so the conversation can be resumed later.
        agent_session: Option<String>,
        /// What the agent said: a permission question or its last reply.
        message: Option<String>,
    },
}

/// What a coding agent is doing, as reported by its hooks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentState {
    /// Started and waiting for a first prompt.
    Idle,
    Working,
    /// Blocked on the user: a permission prompt or a question.
    NeedsYou,
    /// Finished its turn.
    Done,
    /// The agent exited.
    Ended,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct AttachReply {
    pub ok: bool,
    pub created: bool,
    pub error: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionInfo {
    pub id: String,
    pub pid: i32,
    pub cols: u16,
    pub rows: u16,
    pub clients: usize,
    /// Working directory of the foreground process.
    pub cwd: Option<String>,
    /// Foreground process name: the shell when idle, otherwise what's running.
    pub process: String,
    /// Title set by the program via OSC 0/2, if any.
    pub title: String,
    pub git_root: Option<String>,
    pub branch: Option<String>,
    /// Unix time in milliseconds of the last output byte.
    pub last_output_ms: u64,
    /// Number of bells rung so far.
    pub bells: u64,
    /// The coding agent running in this session ("claude", "codex"), if any.
    #[serde(default)]
    pub agent: Option<String>,
    /// The agent's last reported state; absent if its hooks aren't installed.
    #[serde(default)]
    pub agent_state: Option<AgentState>,
    /// Unix time in milliseconds of that report.
    #[serde(default)]
    pub agent_state_ms: u64,
    #[serde(default)]
    pub agent_session: Option<String>,
    #[serde(default)]
    pub agent_message: Option<String>,
    /// The command in the foreground ("npm run dev"), or the last one to run
    /// there once the shell is back at its prompt.
    #[serde(default)]
    pub command: Option<String>,
}

/// Directory holding the daemon socket, log and pid file.
pub fn runtime_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("TERN_RUNTIME_DIR") {
        return PathBuf::from(dir);
    }
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| "/tmp".into());
    home.join("Library/Application Support/tern")
}

/// IDs are also filenames. Keep every protocol operation inside the runtime directory.
pub fn valid_session_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 128 && !id.starts_with('.')
        && id.bytes().all(|c| c.is_ascii_alphanumeric() || b"-_.".contains(&c))
}

/// Create private runtime storage and repair permissions left by earlier versions.
/// Never follow symlinks, including the stable CLI link in bin/.
pub fn prepare_runtime_dir() -> io::Result<()> {
    use std::os::unix::fs::DirBuilderExt;
    let dir = runtime_dir();
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&dir)?;
    secure_runtime_tree(&dir)
}

fn secure_runtime_tree(path: &std::path::Path) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let meta = std::fs::symlink_metadata(path)?;
    if meta.file_type().is_symlink() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "runtime directory must not be a symlink"));
    }
    let mode = if meta.is_dir() { 0o700 } else { 0o600 | (meta.permissions().mode() & 0o100) };
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode))?;
    if meta.is_dir() {
        for entry in std::fs::read_dir(path)? {
            let entry = entry?;
            if !entry.file_type()?.is_symlink() {
                match secure_runtime_tree(&entry.path()) {
                    // The running daemon can rename or remove a saved screen during repair.
                    Err(e) if e.kind() == io::ErrorKind::NotFound => {}
                    result => result?,
                }
            }
        }
    }
    Ok(())
}

pub fn socket_path() -> PathBuf {
    runtime_dir().join("ternd.sock")
}

pub fn write_frame(w: &mut impl Write, kind: u8, payload: &[u8]) -> io::Result<()> {
    let mut header = [0u8; 5];
    header[0] = kind;
    header[1..].copy_from_slice(&(payload.len() as u32).to_be_bytes());
    // One write per frame keeps small keystrokes to a single syscall.
    let mut buf = Vec::with_capacity(5 + payload.len());
    buf.extend_from_slice(&header);
    buf.extend_from_slice(payload);
    w.write_all(&buf)
}

/// Reads one frame into `buf`, returning its kind. `Ok(None)` means clean EOF.
pub fn read_frame(r: &mut impl Read, buf: &mut Vec<u8>) -> io::Result<Option<u8>> {
    // Reattach snapshots include scrollback and can exceed a normal output chunk.
    read_frame_limited(r, buf, 64 * 1024 * 1024)
}

pub fn read_frame_limited(r: &mut impl Read, buf: &mut Vec<u8>, max_bytes: usize) -> io::Result<Option<u8>> {
    let mut header = [0u8; 5];
    match r.read_exact(&mut header) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e),
    }
    let len = u32::from_be_bytes(header[1..].try_into().unwrap()) as usize;
    if len > max_bytes {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "frame exceeds size limit"));
    }
    buf.resize(len, 0);
    r.read_exact(buf)?;
    Ok(Some(header[0]))
}

pub fn resize_payload(cols: u16, rows: u16) -> [u8; 4] {
    let mut p = [0u8; 4];
    p[..2].copy_from_slice(&cols.to_be_bytes());
    p[2..].copy_from_slice(&rows.to_be_bytes());
    p
}

pub fn parse_resize(p: &[u8]) -> Option<(u16, u16)> {
    if p.len() != 4 {
        return None;
    }
    Some((u16::from_be_bytes([p[0], p[1]]), u16::from_be_bytes([p[2], p[3]])))
}

/// Spawns `command` as a session leader with `slave` as its controlling terminal.
pub fn spawn_on_pty(
    mut command: std::process::Command,
    slave: std::os::fd::OwnedFd,
) -> io::Result<std::process::Child> {
    use std::os::unix::process::CommandExt;
    use std::process::Stdio;
    command
        .stdin(Stdio::from(slave.try_clone()?))
        .stdout(Stdio::from(slave.try_clone()?))
        .stderr(Stdio::from(slave));
    unsafe {
        command.pre_exec(|| {
            nix::unistd::setsid()?;
            if nix::libc::ioctl(0, nix::libc::TIOCSCTTY as _, 0) != 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    command.spawn()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn session_ids_cannot_escape_storage() {
        for id in ["", ".", "..", "../victim", "/tmp/victim", "a/b", "a\\b", ".hidden", "a\n"] {
            assert!(!valid_session_id(id), "accepted {id:?}");
        }
        assert!(!valid_session_id(&"x".repeat(129)));
        for id in ["pane-123", "bench-0", "session_1.2"] {
            assert!(valid_session_id(id));
        }
    }

    #[test]
    fn repairs_private_storage_without_following_links() {
        let root = std::env::temp_dir().join(format!("tern-permissions-{}-{}", std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        std::fs::create_dir_all(root.join("runtime/saved")).unwrap();
        let outside = root.join("outside");
        std::fs::write(&outside, "untouched").unwrap();
        std::fs::set_permissions(&outside, std::fs::Permissions::from_mode(0o644)).unwrap();
        let screen = root.join("runtime/saved/pane.screen");
        std::fs::write(&screen, "private output").unwrap();
        std::os::unix::fs::symlink(&outside, root.join("runtime/link")).unwrap();
        secure_runtime_tree(&root.join("runtime")).unwrap();
        for dir in [root.join("runtime"), root.join("runtime/saved")] {
            assert_eq!(std::fs::metadata(dir).unwrap().permissions().mode() & 0o777, 0o700);
        }
        assert_eq!(std::fs::metadata(screen).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(std::fs::metadata(&outside).unwrap().permissions().mode() & 0o777, 0o644);
        assert!(secure_runtime_tree(&root.join("runtime/link")).is_err());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn refuses_oversized_frames_before_allocating() {
        let mut input = std::io::Cursor::new([FRAME_INPUT, 255, 255, 255, 255]);
        let mut buf = Vec::new();
        assert_eq!(read_frame(&mut input, &mut buf).unwrap_err().kind(), io::ErrorKind::InvalidData);
        assert!(buf.is_empty());
    }
}
