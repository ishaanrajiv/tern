//! Shared pieces of the tern daemon protocol.
//!
//! A client opens the daemon socket and sends one JSON line (`Request`).
//! For `attach`, the daemon answers with one JSON line (`AttachReply`) and
//! the connection then switches to binary frames in both directions:
//! `[kind: u8][len: u32 big-endian][payload]`.
//!
//! `hello` tells a client which protocol and build the running daemon speaks;
//! a daemon from before `hello` closes the connection without answering.

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

/// Bumped whenever a request, reply or frame changes in a way an older peer
/// would misread. A client finding a different number asks for a restart.
pub const PROTOCOL: u32 = 1;

#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Request {
    /// Answered with a `HelloReply`.
    Hello,
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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HelloReply {
    pub protocol: u32,
    /// The crate version, for people reading logs.
    pub version: String,
    pub pid: u32,
    /// `build_id` of the ternd binary as it was when this daemon started, so a
    /// client can tell a different one has been installed since.
    pub build: String,
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
    /// Unix time in milliseconds when the shell last finished a command; 0 if it
    /// hasn't, or has no integration.
    #[serde(default)]
    pub finished_ms: u64,
}

/// Directory holding the daemon socket, log and pid file.
pub fn runtime_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("TERN_RUNTIME_DIR") {
        return PathBuf::from(dir);
    }
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| "/tmp".into());
    home.join("Library/Application Support/tern")
}

pub fn socket_path() -> PathBuf {
    runtime_dir().join("ternd.sock")
}

/// Identifies a binary by its contents (FNV-1a, hex), the same however it got
/// where it is. A Mach-O's code signature is left out: signing with an identity
/// stamps the signing time into it, so every build would otherwise look new.
pub fn build_id(path: &std::path::Path) -> io::Result<String> {
    let bytes = std::fs::read(path)?;
    let bytes = &bytes[..signature_offset(&bytes).unwrap_or(bytes.len())];
    let hash = bytes.iter().fold(0xcbf2_9ce4_8422_2325u64, |h, b| (h ^ u64::from(*b)).wrapping_mul(0x0100_0000_01b3));
    Ok(format!("{hash:016x}"))
}

/// Where a 64-bit Mach-O's code signature starts, if it has one.
fn signature_offset(bytes: &[u8]) -> Option<usize> {
    const MH_MAGIC_64: u32 = 0xfeed_facf;
    const LC_CODE_SIGNATURE: u32 = 0x1d;
    let u32_at = |at: usize| bytes.get(at..at + 4).and_then(|b| b.try_into().ok()).map(u32::from_le_bytes);
    if u32_at(0)? != MH_MAGIC_64 {
        return None;
    }
    // Load commands follow the 32-byte header; ncmds is at offset 16.
    let mut at = 32;
    for _ in 0..u32_at(16)? {
        if u32_at(at)? == LC_CODE_SIGNATURE {
            let offset = u32_at(at + 8)? as usize;
            return (offset <= bytes.len()).then_some(offset);
        }
        at += u32_at(at + 4)? as usize;
    }
    None
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
    let mut header = [0u8; 5];
    match r.read_exact(&mut header) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e),
    }
    let len = u32::from_be_bytes(header[1..].try_into().unwrap()) as usize;
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

    #[test]
    fn frames_round_trip() {
        let mut wire = Vec::new();
        write_frame(&mut wire, FRAME_INPUT, b"ls\r").unwrap();
        write_frame(&mut wire, FRAME_RESIZE, &resize_payload(120, 40)).unwrap();
        write_frame(&mut wire, FRAME_OUTPUT, b"").unwrap();
        let mut r = wire.as_slice();
        let mut buf = Vec::new();
        assert_eq!(read_frame(&mut r, &mut buf).unwrap(), Some(FRAME_INPUT));
        assert_eq!(buf, b"ls\r");
        assert_eq!(read_frame(&mut r, &mut buf).unwrap(), Some(FRAME_RESIZE));
        assert_eq!(parse_resize(&buf), Some((120, 40)));
        assert_eq!(read_frame(&mut r, &mut buf).unwrap(), Some(FRAME_OUTPUT));
        assert!(buf.is_empty());
        // Clean EOF between frames.
        assert_eq!(read_frame(&mut r, &mut buf).unwrap(), None);
    }

    #[test]
    fn a_cut_off_frame_is_an_error() {
        let mut wire = Vec::new();
        write_frame(&mut wire, FRAME_OUTPUT, b"hello").unwrap();
        wire.truncate(7);
        assert!(read_frame(&mut wire.as_slice(), &mut Vec::new()).is_err());
    }

    #[test]
    fn bad_resize_payloads() {
        assert_eq!(parse_resize(&[0, 1, 2]), None);
        assert_eq!(parse_resize(&[]), None);
    }

    #[test]
    fn requests_on_the_wire() {
        assert_eq!(serde_json::to_string(&Request::Hello).unwrap(), r#"{"op":"hello"}"#);
        // An attach from an older client (no init, no env) still parses.
        let req: Request = serde_json::from_str(r#"{"op":"attach","id":"p-1","cols":80,"rows":24,"cwd":null,"cmd":null}"#).unwrap();
        assert!(matches!(req, Request::Attach { init: None, ref env, .. } if env.is_empty()));
        let req: Request =
            serde_json::from_str(r#"{"op":"report","id":"p","agent":"claude","state":"needs_you","agent_session":null,"message":"Allow?"}"#)
                .unwrap();
        assert!(matches!(req, Request::Report { state: AgentState::NeedsYou, .. }));
    }

    #[test]
    fn session_info_from_an_older_daemon() {
        // Fields added later default when missing.
        let json = r#"{"id":"p","pid":1,"cols":80,"rows":24,"clients":1,"cwd":null,"process":"zsh","title":"",
            "git_root":null,"branch":null,"last_output_ms":0,"bells":0}"#;
        let info: SessionInfo = serde_json::from_str(json).unwrap();
        assert_eq!(info.agent, None);
        assert_eq!(info.command, None);
        assert_eq!(info.finished_ms, 0);
    }

    #[test]
    fn build_id_follows_contents() {
        let dir = std::env::temp_dir().join(format!("tern-build-id-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let (a, b) = (dir.join("a"), dir.join("b"));
        std::fs::write(&a, b"one").unwrap();
        std::fs::write(&b, b"one").unwrap();
        assert_eq!(build_id(&a).unwrap(), build_id(&b).unwrap());
        std::fs::write(&b, b"two").unwrap();
        assert_ne!(build_id(&a).unwrap(), build_id(&b).unwrap());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn build_id_ignores_code_signature() {
        // A header with one load command, LC_CODE_SIGNATURE, pointing at byte 52.
        let macho = |code: &[u8], signature: &[u8]| {
            let mut bytes = Vec::new();
            for word in [0xfeed_facf, 0x0100_000c, 0, 2, 1, 16, 0, 0, 0x1d, 16, 52, signature.len() as u32] {
                bytes.extend_from_slice(&u32::to_le_bytes(word));
            }
            bytes.extend_from_slice(code);
            bytes.extend_from_slice(signature);
            bytes
        };
        let dir = std::env::temp_dir().join(format!("tern-build-id-sig-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let (a, b) = (dir.join("a"), dir.join("b"));
        std::fs::write(&a, macho(b"code", b"signed at 1")).unwrap();
        std::fs::write(&b, macho(b"code", b"signed at 2")).unwrap();
        assert_eq!(build_id(&a).unwrap(), build_id(&b).unwrap());
        std::fs::write(&b, macho(b"edit", b"signed at 1")).unwrap();
        assert_ne!(build_id(&a).unwrap(), build_id(&b).unwrap());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
