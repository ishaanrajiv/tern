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
pub mod open;
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
pub const PROTOCOL: u32 = 3;

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
    /// Read retained terminal text or the last completed command output.
    ReadOutput { id: String, #[serde(default)] last_command: bool },
    /// Same byte limit as the app surface; applied to existing and new sessions.
    SetScrollback { bytes: usize },
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
        /// The subagent that sent it (Claude Code's `agent_id`); none for the main agent.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        subagent: Option<String>,
    },
    /// A window's saved layout, answered with a `LayoutReply`. ternd keeps every window's
    /// layout and is the only one to write it, so the CLI can change it with the app quit.
    LayoutGet { window: String },
    /// The app replacing a window's layout. Refused, with the current layout, unless
    /// `base` is the revision the app last saw: the CLI changed it in the meantime.
    LayoutPut {
        window: String,
        base: u64,
        doc: serde_json::Value,
        /// Who wrote it, so a watcher can skip its own changes.
        #[serde(default)]
        by: String,
    },
    /// Streams a `LayoutUpdate` line each time a window's layout changes.
    LayoutWatch,
    /// Every open window's layout with each pane's name and who opened it, for `tern ls --json`.
    LayoutTree,
    /// Finds the pane a CLI command means. Answered with a `PaneReply`.
    Resolve { target: Target },
    /// Splits a pane and starts a session in the new one. Answered with a `PaneReply`.
    Split {
        target: Target,
        /// "right" or "down".
        direction: String,
        #[serde(flatten)]
        open: OpenPane,
    },
    /// Opens a tab with a new session, in `folder` or the target's folder. Answered with a `PaneReply`.
    NewTab {
        target: Target,
        folder: Option<String>,
        #[serde(flatten)]
        open: OpenPane,
    },
    /// Ends a pane's session and takes the pane out of its tab. Answered with a `PaneReply`.
    Close { target: Target },
    /// Types into a session as if from the keyboard.
    Input { id: String, data: String },
}

/// Which pane a CLI command is for. With neither field, the pane the command runs in.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Target {
    /// A pane id, a name given with `--name`, or `@focused` for the pane in front.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pane: Option<String>,
    /// A tab id or name, meaning that tab's focused pane.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tab: Option<String>,
    /// The session the CLI runs in (`TERN_SESSION_ID`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub caller: Option<String>,
}

/// What a new pane runs and how it shows.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct OpenPane {
    /// Where its shell starts; the target pane's directory by default.
    #[serde(default)]
    pub cwd: Option<String>,
    /// A line typed into the new shell, so the pane stays open after it ends.
    #[serde(default)]
    pub line: Option<String>,
    /// A name to address the pane by, unique among open panes.
    #[serde(default)]
    pub name: Option<String>,
    /// Bring the new pane to the front. Panes an agent opens stay in the background otherwise.
    #[serde(default)]
    pub focus: bool,
    /// The new session's environment (the CLI's own).
    #[serde(default)]
    pub env: Vec<(String, String)>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct LayoutReply {
    pub ok: bool,
    /// 0 for a layout as read from disk; each change after that counts up.
    pub rev: u64,
    pub doc: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct LayoutUpdate {
    pub window: String,
    pub rev: u64,
    pub doc: serde_json::Value,
    pub by: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct PaneReply {
    pub ok: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pane: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tab: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// Why the target couldn't be used: "not_found" or "ambiguous".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

impl PaneReply {
    pub fn failed(error: impl Into<String>, reason: Option<&str>) -> Self {
        PaneReply { ok: false, error: Some(error.into()), reason: reason.map(str::to_string), ..Default::default() }
    }
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
    /// Failed and stopped. Only a program's own OSC 7501 report says this.
    Failed,
}

/// What a blocked program needs, from its OSC 7501 report.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BlockKind {
    /// Approval to do something.
    Permission,
    /// An answer typed in.
    Question,
    /// A login, token or other credential.
    Auth,
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
    /// What a program blocked on the user needs, when it said (OSC 7501 only).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_kind: Option<BlockKind>,
    /// Percent done, when the program said (OSC 7501 only).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_progress: Option<u8>,
    /// The state came from the program's own OSC 7501 report rather than agent hooks.
    /// Such a report is never repeated, so silence doesn't mean the program stopped.
    #[serde(default)]
    pub agent_osc: bool,
    /// The OSC 7501 `app` of the program that reported, like "cargo" or "claude-code".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub program: Option<String>,
    /// How many OSC 7501 records the session holds; more than one means the state
    /// shown is the most urgent of several tasks.
    #[serde(default)]
    pub status_records: usize,
    /// The command in the foreground ("npm run dev"), or the last one to run
    /// there once the shell is back at its prompt.
    #[serde(default)]
    pub command: Option<String>,
    /// Unix time in milliseconds when the shell last finished a command; 0 if it
    /// hasn't, or has no integration.
    #[serde(default)]
    pub finished_ms: u64,
    #[serde(default)]
    pub exit_code: Option<i32>,
    #[serde(default)]
    pub duration_ms: Option<u64>,
    /// The shell integration says a command is running now, so `exit_code` and
    /// `duration_ms` belong to the one before it.
    #[serde(default)]
    pub command_running: bool,
    /// Unix time in milliseconds of the last input typed into the session, by a client or `tern send`.
    #[serde(default)]
    pub input_ms: u64,
}

/// Quotes a string for a POSIX shell. Plain words are left alone; anything
/// else is single-quoted, with embedded quotes closed, escaped and reopened.
pub fn shell_quote(arg: &str) -> String {
    let plain = !arg.is_empty() && arg.chars().all(|c| c.is_ascii_alphanumeric() || "-_./=:,+@%".contains(c));
    if plain {
        arg.to_string()
    } else {
        format!("'{}'", arg.replace('\'', "'\\''"))
    }
}

/// Longest session id. Ids become file names with suffixes such as `.screen.tmp`,
/// and macOS caps a file name at 255 bytes.
pub const MAX_SESSION_ID: usize = 128;

/// Session ids are also file names, so they must not reach outside the runtime directory.
pub fn valid_session_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= MAX_SESSION_ID
        && !id.starts_with('.')
        && id.bytes().all(|c| c.is_ascii_alphanumeric() || b"-_.".contains(&c))
}

/// Directory holding the daemon socket, log and pid file.
pub fn runtime_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("TERN_RUNTIME_DIR") {
        return PathBuf::from(dir);
    }
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| "/tmp".into());
    home.join("Library/Application Support/tern")
}

/// Creates the runtime directory private to this user, or makes it so, and tightens
/// what earlier versions left in it. It holds terminal output, typed commands and
/// launch presets. Symlinks inside, such as the stable CLI link in `bin/`, are left
/// alone, and a root that is a symlink or belongs to someone else is refused.
pub fn prepare_runtime_dir() -> io::Result<PathBuf> {
    use std::os::unix::fs::{DirBuilderExt, MetadataExt};
    let dir = runtime_dir();
    match std::fs::symlink_metadata(&dir) {
        Ok(meta) => {
            if !meta.is_dir() {
                return Err(io::Error::new(io::ErrorKind::InvalidInput, format!("{} is not a directory", dir.display())));
            }
            if meta.uid() != nix::unistd::geteuid().as_raw() {
                return Err(io::Error::new(io::ErrorKind::PermissionDenied, format!("{} belongs to another user", dir.display())));
            }
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&dir)?;
        }
        Err(e) => return Err(e),
    }
    secure_tree(&dir)?;
    Ok(dir)
}

fn secure_tree(path: &std::path::Path) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let meta = std::fs::symlink_metadata(path)?;
    if meta.file_type().is_symlink() {
        return Ok(());
    }
    let mode = if meta.is_dir() { 0o700 } else { 0o600 | (meta.permissions().mode() & 0o100) };
    if meta.permissions().mode() & 0o777 != mode {
        // A file we can't chmod (another owner, an immutable flag) is no reason not to start.
        if let Err(e) = std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)) {
            if e.kind() != io::ErrorKind::PermissionDenied {
                return Err(e);
            }
            eprintln!("tern: can't make {} private", path.display());
        }
    }
    if meta.is_dir() {
        for entry in std::fs::read_dir(path)? {
            match secure_tree(&entry?.path()) {
                // A running ternd can rename or remove a saved screen meanwhile.
                Err(e) if e.kind() == io::ErrorKind::NotFound => {}
                result => result?,
            }
        }
    }
    Ok(())
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

/// Largest request line a client may send. An attach carries the client's environment.
pub const MAX_REQUEST_LINE: usize = 1 << 20;
/// Largest frame ternd accepts from a client. `tern attach` sends 4 KiB of input at most.
pub const MAX_CLIENT_FRAME: usize = 1 << 20;
/// Largest frame a client accepts from ternd. A daemon sends output in chunks of at
/// most `OUTPUT_CHUNK`; older ones sent the whole reattach snapshot in one frame.
pub const MAX_DAEMON_FRAME: usize = 64 << 20;
/// ternd splits output, including reattach snapshots, into frames of at most this.
pub const OUTPUT_CHUNK: usize = 1 << 20;

/// Reads one frame into `buf`, returning its kind. `Ok(None)` means clean EOF.
/// A frame longer than `max` is an error, before anything is allocated for it.
pub fn read_frame(r: &mut impl Read, buf: &mut Vec<u8>, max: usize) -> io::Result<Option<u8>> {
    let mut header = [0u8; 5];
    match r.read_exact(&mut header) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e),
    }
    let len = u32::from_be_bytes(header[1..].try_into().unwrap()) as usize;
    if len > max {
        return Err(io::Error::new(io::ErrorKind::InvalidData, format!("a {len}-byte frame is over the {max}-byte limit")));
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

/// Tests that change HOME or TERN_RUNTIME_DIR take turns.
#[cfg(test)]
pub(crate) static TEST_ENV: std::sync::Mutex<()> = std::sync::Mutex::new(());

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
        assert_eq!(read_frame(&mut r, &mut buf, 64).unwrap(), Some(FRAME_INPUT));
        assert_eq!(buf, b"ls\r");
        assert_eq!(read_frame(&mut r, &mut buf, 64).unwrap(), Some(FRAME_RESIZE));
        assert_eq!(parse_resize(&buf), Some((120, 40)));
        assert_eq!(read_frame(&mut r, &mut buf, 64).unwrap(), Some(FRAME_OUTPUT));
        assert!(buf.is_empty());
        // Clean EOF between frames.
        assert_eq!(read_frame(&mut r, &mut buf, 64).unwrap(), None);
    }

    #[test]
    fn a_cut_off_frame_is_an_error() {
        let mut wire = Vec::new();
        write_frame(&mut wire, FRAME_OUTPUT, b"hello").unwrap();
        wire.truncate(7);
        assert!(read_frame(&mut wire.as_slice(), &mut Vec::new(), 64).is_err());
    }

    #[test]
    fn oversized_frames_are_refused_before_allocating() {
        let mut wire = std::io::Cursor::new([FRAME_INPUT, 255, 255, 255, 255]);
        let mut buf = Vec::new();
        assert_eq!(read_frame(&mut wire, &mut buf, MAX_CLIENT_FRAME).unwrap_err().kind(), io::ErrorKind::InvalidData);
        assert!(buf.capacity() < 1024);
        // At the limit is fine.
        let mut wire = Vec::new();
        write_frame(&mut wire, FRAME_INPUT, b"abcd").unwrap();
        assert_eq!(read_frame(&mut wire.as_slice(), &mut buf, 4).unwrap(), Some(FRAME_INPUT));
        assert!(read_frame(&mut wire.as_slice(), &mut buf, 3).is_err());
    }

    #[test]
    fn session_ids_stay_file_names() {
        for id in ["", ".", "..", "../x", "/tmp/x", "a/b", "a\\b", ".hidden", "a\n", "a b", "é"] {
            assert!(!valid_session_id(id), "accepted {id:?}");
        }
        assert!(!valid_session_id(&"x".repeat(MAX_SESSION_ID + 1)));
        for id in ["p-f7dc6598", "bench-0", "s_1.2", &"x".repeat(MAX_SESSION_ID)] {
            assert!(valid_session_id(id), "refused {id:?}");
        }
    }

    #[test]
    fn quoting() {
        assert_eq!(shell_quote("npm"), "npm");
        assert_eq!(shell_quote("it's here"), "'it'\\''s here'");
        assert_eq!(shell_quote(""), "''");
        assert_eq!(shell_quote("$(rm -rf ~)"), "'$(rm -rf ~)'");
    }

    #[test]
    fn runtime_storage_is_made_private_without_following_links() {
        use std::os::unix::fs::PermissionsExt;
        let mode = |p: &std::path::Path| std::fs::symlink_metadata(p).unwrap().permissions().mode() & 0o777;
        let _guard = TEST_ENV.lock().unwrap_or_else(|e| e.into_inner());
        let root = std::env::temp_dir().join(format!("tern-private-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let dir = root.join("rt");
        std::fs::create_dir_all(dir.join("saved")).unwrap();
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::fs::write(dir.join("saved/p.screen"), "output").unwrap();
        std::fs::set_permissions(dir.join("saved/p.screen"), std::fs::Permissions::from_mode(0o644)).unwrap();
        std::fs::write(dir.join("tool"), "#!/bin/sh").unwrap();
        std::fs::set_permissions(dir.join("tool"), std::fs::Permissions::from_mode(0o755)).unwrap();
        let outside = root.join("outside");
        std::fs::write(&outside, "x").unwrap();
        std::fs::set_permissions(&outside, std::fs::Permissions::from_mode(0o644)).unwrap();
        std::os::unix::fs::symlink(&outside, dir.join("link")).unwrap();

        std::env::set_var("TERN_RUNTIME_DIR", &dir);
        prepare_runtime_dir().unwrap();
        assert_eq!(mode(&dir), 0o700);
        assert_eq!(mode(&dir.join("saved")), 0o700);
        assert_eq!(mode(&dir.join("saved/p.screen")), 0o600);
        assert_eq!(mode(&dir.join("tool")), 0o700);
        // The link's target is not ours to change.
        assert_eq!(mode(&outside), 0o644);

        // A root that is itself a link is refused, and its target left alone.
        let linked = root.join("linked");
        std::os::unix::fs::symlink(&outside, &linked).unwrap();
        std::env::set_var("TERN_RUNTIME_DIR", &linked);
        assert!(prepare_runtime_dir().is_err());
        assert_eq!(mode(&outside), 0o644);

        // A missing root is created private.
        let fresh = root.join("fresh/rt");
        std::env::set_var("TERN_RUNTIME_DIR", &fresh);
        prepare_runtime_dir().unwrap();
        assert_eq!(mode(&fresh), 0o700);
        std::env::remove_var("TERN_RUNTIME_DIR");
        let _ = std::fs::remove_dir_all(&root);
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
