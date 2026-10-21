//! ternd: owns the PTYs so terminal sessions outlive the tern app.
//!
//! Each session keeps a headless vt100 screen alongside its PTY. When a client
//! attaches, it first receives a snapshot of that screen (history, then the
//! visible screen), then the live output stream.
//!
//! Screens are also saved to disk now and then, and when ternd is told to quit,
//! so after a reboot a session recreated under the same id shows what it showed.

use std::collections::HashMap;
use std::fs::File;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::net::{UnixListener, UnixStream};
use std::process::Command;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{self, SyncSender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use nix::pty::{openpty, Winsize};
use nix::sys::signal::{killpg, Signal};
use nix::sys::wait::{waitpid, WaitStatus};
use nix::unistd::Pid;
use tern::*;

const SCROLLBACK_LINES: usize = 10_000;
// Output chunks are at most 64 KiB, so each client queues at most 4 MiB.
const CLIENT_QUEUE_CAPACITY: usize = 64;

struct Client {
    id: u64,
    tx: SyncSender<Msg>,
    socket: UnixStream,
}

impl Client {
    fn send(&self, msg: Msg) -> bool {
        if self.tx.try_send(msg).is_ok() {
            true
        } else {
            // Wake both reader and writer immediately. The client can reattach
            // from the current screen instead of buffering unlimited output.
            let _ = self.socket.shutdown(std::net::Shutdown::Both);
            false
        }
    }
}

nix::ioctl_write_ptr_bad!(set_winsize, nix::libc::TIOCSWINSZ, Winsize);

enum Msg {
    Output(Vec<u8>),
    Exit(i32),
}

struct Session {
    id: String,
    pid: i32,
    start_cwd: Option<String>,
    master: File,
    state: Mutex<SessionState>,
}

struct SessionState {
    parser: vt100::Parser<TermEvents>,
    clients: Vec<Client>,
    last_output_ms: u64,
    /// `last_output_ms` when the screen was last saved to disk.
    saved_output_ms: u64,
    agent: Option<AgentReport>,
    /// The foreground command, by its process, for shells without tern's integration.
    command: Option<String>,
    /// The last telling command line typed, from the zsh integration.
    typed: Option<String>,
}

/// The last thing an agent's hooks told us.
struct AgentReport {
    agent: String,
    state: AgentState,
    at_ms: u64,
    session: Option<String>,
    message: Option<String>,
}

/// Terminal events the headless screen reports back to us.
#[derive(Default)]
struct TermEvents {
    title: String,
    bells: u64,
}

impl vt100::Callbacks for TermEvents {
    fn set_window_title(&mut self, _: &mut vt100::Screen, title: &[u8]) {
        self.title = String::from_utf8_lossy(title).into_owned();
    }
    fn audible_bell(&mut self, _: &mut vt100::Screen) {
        self.bells += 1;
    }
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

fn session_info(s: &Session) -> SessionInfo {
    // Read terminal state under the lock, but query the OS for process details outside it.
    let fg = procinfo::foreground(s.master.as_raw_fd(), s.pid);
    let typed = shell::last_command(&s.id);
    let running = if typed.is_some() || fg.pid == s.pid || fg.agent.is_some() {
        None
    } else {
        procinfo::command_line(fg.pid).and_then(|c| shell::telling(&c))
    };
    let (cols, rows, clients, title, bells, last_output_ms, report, command) = {
        let mut st = s.state.lock().unwrap();
        if running.is_some() {
            st.command = running;
        }
        if let Some(Some(line)) = &typed {
            st.typed = Some(line.clone());
        }
        let command = if typed.is_some() { st.typed.clone() } else { st.command.clone() };
        // Back at the shell: the agent is gone, whether or not it said goodbye.
        let gone = st.agent.as_ref().is_some_and(|a| {
            a.state == AgentState::Ended || (fg.pid == s.pid && fg.agent.is_none() && now_ms() - a.at_ms > 3000)
        });
        if gone {
            st.agent = None;
        }
        let report = st.agent.as_ref().map(|a| (a.agent.clone(), a.state, a.at_ms, a.session.clone(), a.message.clone()));
        let (rows, cols) = st.parser.screen().size();
        let cb = st.parser.callbacks();
        (cols, rows, st.clients.len(), cb.title.clone(), cb.bells, st.last_output_ms, report, command)
    };
    let cwd = fg.cwd.or_else(|| procinfo::process_cwd(s.pid)).or_else(|| s.start_cwd.clone());
    let git = cwd.as_deref().and_then(|d| procinfo::git_info(std::path::Path::new(d)));
    SessionInfo {
        id: s.id.clone(),
        pid: s.pid,
        cols,
        rows,
        clients,
        cwd,
        process: fg.name,
        title,
        git_root: git.as_ref().map(|g| g.root.display().to_string()),
        branch: git.and_then(|g| g.branch),
        last_output_ms,
        bells,
        agent: fg.agent.map(str::to_string).or_else(|| report.as_ref().map(|r| r.0.clone())),
        agent_state: report.as_ref().map(|r| r.1),
        agent_state_ms: report.as_ref().map_or(0, |r| r.2),
        agent_session: report.as_ref().and_then(|r| r.3.clone()),
        agent_message: report.and_then(|r| r.4),
        command,
    }
}

fn list_sessions(sessions: &Sessions) -> Vec<SessionInfo> {
    let all: Vec<Arc<Session>> = sessions.lock().unwrap().values().cloned().collect();
    let mut list: Vec<SessionInfo> = all.iter().map(|s| session_info(s)).collect();
    list.sort_by(|a, b| a.id.cmp(&b.id));
    list
}

type Sessions = Arc<Mutex<HashMap<String, Arc<Session>>>>;

static NEXT_CLIENT: AtomicU64 = AtomicU64::new(1);

fn main() -> Result<()> {
    // Set before starting any threads or creating any runtime files.
    nix::sys::stat::umask(nix::sys::stat::Mode::from_bits_truncate(0o077));
    let dir = runtime_dir();
    prepare_runtime_dir().with_context(|| format!("securing {}", dir.display()))?;
    let path = socket_path();
    // sockaddr_un.sun_path is 104 bytes on macOS.
    if path.as_os_str().len() >= 104 {
        anyhow::bail!("socket path is too long for a unix socket: {}", path.display());
    }

    if UnixStream::connect(&path).is_ok() {
        eprintln!("ternd already running at {}", path.display());
        return Ok(());
    }
    let _ = std::fs::remove_file(&path);
    let listener = UnixListener::bind(&path).with_context(|| format!("binding {}", path.display()))?;
    std::fs::write(dir.join("ternd.pid"), std::process::id().to_string())?;
    eprintln!("ternd listening on {}", path.display());

    let sessions: Sessions = Arc::default();
    prune_saved();
    if let Err(e) = shell::install_zsh().and_then(|_| std::fs::create_dir_all(shell::command_file("x").parent().unwrap())) {
        eprintln!("installing the zsh integration: {e}");
    }
    {
        let sessions = sessions.clone();
        thread::spawn(move || save_periodically(sessions));
    }
    {
        let sessions = sessions.clone();
        thread::spawn(move || save_on_quit(sessions));
    }
    for conn in listener.incoming() {
        let Ok(conn) = conn else { continue };
        let sessions = sessions.clone();
        thread::spawn(move || {
            if let Err(e) = handle_conn(conn, sessions) {
                eprintln!("connection error: {e:#}");
            }
        });
    }
    Ok(())
}

fn handle_conn(conn: UnixStream, sessions: Sessions) -> Result<()> {
    let mut reader = BufReader::new(conn.try_clone()?);
    let mut line = String::new();
    // Bound the initial JSON request independently of binary frame limits.
    reader.by_ref().take(64 * 1024 + 1).read_line(&mut line)?;
    anyhow::ensure!(line.len() <= 64 * 1024 && line.ends_with('\n'), "request line exceeds 64 KiB or is incomplete");
    let req: Request = serde_json::from_str(&line).context("bad request line")?;
    let mut out = conn.try_clone()?;
    let id = match &req {
        Request::Attach { id, .. } | Request::Kill { id } | Request::Report { id, .. } => Some(id),
        _ => None,
    };
    if id.is_some_and(|id| !valid_session_id(id)) {
        writeln!(out, "{}", serde_json::to_string(&AttachReply {
            ok: false, created: false, error: Some("invalid session id".into()),
        })?)?;
        return Ok(());
    }

    match req {
        Request::List => {
            writeln!(out, "{}", serde_json::to_string(&list_sessions(&sessions))?)?;
        }
        Request::Watch => {
            // Polling keeps this simple: a handful of sessions, a few syscalls each.
            let mut last = None;
            loop {
                let list = list_sessions(&sessions);
                if last.as_ref() != Some(&list) {
                    writeln!(out, "{}", serde_json::to_string(&list)?)?;
                    last = Some(list);
                }
                thread::sleep(Duration::from_millis(250));
            }
        }
        Request::Kill { id } => {
            let session = sessions.lock().unwrap().get(&id).cloned();
            let ok = match session {
                Some(s) => killpg(Pid::from_raw(s.pid), Signal::SIGHUP).is_ok(),
                None => false,
            };
            // Closed on purpose: nothing to bring back after a reboot.
            forget_saved(&id);
            writeln!(out, "{}", serde_json::json!({ "ok": ok }))?;
        }
        Request::Report { id, agent, state, agent_session, message } => {
            let session = sessions.lock().unwrap().get(&id).cloned();
            if let Some(s) = &session {
                let mut st = s.state.lock().unwrap();
                // Keep the agent's session id and message across reports that don't carry them.
                let prev = st.agent.take();
                let same = prev.as_ref().is_some_and(|p| p.agent == agent);
                let (old_session, old_message) = match prev {
                    Some(p) if same => (p.session, p.message),
                    _ => (None, None),
                };
                let message = match state {
                    AgentState::Working => None,
                    _ => message.or(if state == AgentState::Done { old_message } else { None }),
                };
                st.agent = Some(AgentReport { agent, state, at_ms: now_ms(), session: agent_session.or(old_session), message });
            }
            writeln!(out, "{}", serde_json::json!({ "ok": session.is_some() }))?;
        }
        Request::Attach { id, cols, rows, cwd, cmd, init, env } => {
            let existing = sessions.lock().unwrap().get(&id).cloned();
            let (session, created) = match existing {
                Some(s) => (s, false),
                None => match spawn_session(&id, cols, rows, cwd, cmd, env, &sessions) {
                    Ok((s, restored)) => {
                        // An agent's resume command wins over retyping what was running.
                        let typed = match (init, restored.and_then(|m| m.command)) {
                            (Some(line), _) => Some((line, true)),
                            (None, Some(command)) => Some((command, false)),
                            (None, None) => None,
                        };
                        if let Some((line, enter)) = typed {
                            let s = s.clone();
                            thread::spawn(move || type_when_ready(&s, &line, enter));
                        }
                        (s, true)
                    }
                    Err(e) => {
                        let reply = AttachReply { ok: false, created: false, error: Some(format!("{e:#}")) };
                        writeln!(out, "{}", serde_json::to_string(&reply)?)?;
                        return Ok(());
                    }
                },
            };
            let reply = AttachReply { ok: true, created, error: None };
            writeln!(out, "{}", serde_json::to_string(&reply)?)?;
            attach(session, reader, out, cols, rows)?;
        }
    }
    Ok(())
}

fn spawn_session(
    id: &str,
    cols: u16,
    rows: u16,
    cwd: Option<String>,
    cmd: Option<String>,
    env: Vec<(String, String)>,
    sessions: &Sessions,
) -> Result<(Arc<Session>, Option<SavedMeta>)> {
    let ws = Winsize { ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0 };
    let pty = openpty(Some(&ws), None).context("openpty")?;
    let master = File::from(pty.master);
    let slave: OwnedFd = pty.slave;

    let mut command = match &cmd {
        Some(c) => {
            let mut c2 = Command::new("/bin/sh");
            c2.arg("-c").arg(c);
            c2
        }
        None => {
            let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into());
            let mut c2 = Command::new(&shell);
            c2.arg("-l");
            c2
        }
    };
    if let Some(dir) = &cwd {
        command.current_dir(dir);
    }
    let zsh = cmd.is_none() && shell::is_zsh(&std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into()));
    let user_zdotdir = env.iter().find(|(k, _)| k == "ZDOTDIR").map(|(_, v)| v.clone());
    command.envs(env).env("TERN_SESSION_ID", id);
    let commands = shell::command_file(id);
    let _ = std::fs::remove_file(&commands);
    if zsh && runtime_dir().join("zsh/.zshenv").exists() {
        if let Some(dir) = user_zdotdir {
            command.env("TERN_ZDOTDIR", dir);
        }
        command.env("ZDOTDIR", commands.parent().unwrap().with_file_name("zsh")).env("TERN_COMMAND_FILE", &commands);
    }
    let child = spawn_on_pty(command, slave).context("spawning session process")?;
    let pid = child.id() as i32;
    // We reap the child ourselves with waitpid once its PTY closes.
    std::mem::forget(child);

    let mut parser = vt100::Parser::new_with_callbacks(rows, cols, SCROLLBACK_LINES, TermEvents::default());
    // Lay the saved screen down before the new shell prints anything.
    let restored = load_saved(id).map(|(meta, screen)| {
        parser.process(&screen);
        parser.process(restored_banner(meta.saved_ms, cols).as_bytes());
        meta
    });
    let session = Arc::new(Session {
        id: id.to_string(),
        pid,
        start_cwd: cwd,
        master,
        state: Mutex::new(SessionState {
            parser,
            clients: Vec::new(),
            last_output_ms: now_ms(),
            saved_output_ms: 0,
            agent: None,
            command: None,
            typed: None,
        }),
    });
    sessions.lock().unwrap().insert(id.to_string(), session.clone());
    eprintln!("session {id}: spawned pid {pid}");

    let reader_session = session.clone();
    let sessions = sessions.clone();
    thread::spawn(move || pump_output(reader_session, sessions));
    Ok((session, restored))
}

/// Reads PTY output, feeds the headless screen and fans it out to clients.
fn pump_output(session: Arc<Session>, sessions: Sessions) {
    let mut master = session.master.try_clone().expect("clone master");
    let mut buf = vec![0u8; 64 * 1024];
    // Checked on output too, not only when listed, so quick commands (`git status`) are seen.
    let mut seen_pgid = session.pid;
    loop {
        match master.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                let bytes = &buf[..n];
                let pgid = unsafe { nix::libc::tcgetpgrp(master.as_raw_fd()) };
                let command = if pgid > 0 && pgid != seen_pgid {
                    seen_pgid = pgid;
                    (pgid != session.pid && procinfo::agent_of(pgid).is_none())
                        .then(|| procinfo::command_line(pgid))
                        .flatten()
                        .and_then(|c| shell::telling(&c))
                } else {
                    None
                };
                let mut st = session.state.lock().unwrap();
                if command.is_some() {
                    st.command = command;
                }
                st.parser.process(bytes);
                st.last_output_ms = now_ms();
                st.clients.retain(|client| client.send(Msg::Output(bytes.to_vec())));
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            // EIO once the last slave fd closes, i.e. the process exited.
            Err(_) => break,
        }
    }
    let code = match waitpid(Pid::from_raw(session.pid), None) {
        Ok(WaitStatus::Exited(_, c)) => c,
        Ok(WaitStatus::Signaled(_, sig, _)) => 128 + sig as i32,
        _ => -1,
    };
    eprintln!("session {}: exited with {code}", session.id);
    let _ = std::fs::remove_file(shell::command_file(&session.id));
    // The session is over, so its saved screen goes, unless the machine is going
    // down: shells die of SIGHUP then too (exiting 1, like "exit 1" would), and
    // can beat ternd's own SIGTERM by a moment.
    let id = session.id.clone();
    let all = sessions.clone();
    thread::spawn(move || {
        thread::sleep(Duration::from_secs(5));
        // Not if a new session took the id meanwhile; that one saves its own.
        if !QUITTING.load(Ordering::SeqCst) && !all.lock().unwrap().contains_key(&id) {
            forget_saved(&id);
        }
    });
    {
        let mut map = sessions.lock().unwrap();
        if map.get(&session.id).is_some_and(|s| Arc::ptr_eq(s, &session)) {
            map.remove(&session.id);
        }
    }
    let st = session.state.lock().unwrap();
    for client in &st.clients {
        client.send(Msg::Exit(code));
    }
}

fn attach(session: Arc<Session>, mut reader: BufReader<UnixStream>, out: UnixStream, cols: u16, rows: u16) -> Result<()> {
    let client_id = NEXT_CLIENT.fetch_add(1, Ordering::Relaxed);
    let (tx, rx) = mpsc::sync_channel::<Msg>(CLIENT_QUEUE_CAPACITY);
    let cancel = out.try_clone()?;

    // Snapshot and registration happen under one lock so no output is lost or doubled.
    let snapshot = {
        let mut st = session.state.lock().unwrap();
        resize_locked(&session, &mut st, cols, rows);
        let snap = snapshot(&mut st.parser);
        st.clients.push(Client { id: client_id, tx, socket: out.try_clone()? });
        snap
    };

    let writer = thread::spawn(move || {
        let mut out = out;
        if write_frame(&mut out, FRAME_OUTPUT, &snapshot).is_err() {
            let _ = out.shutdown(std::net::Shutdown::Both);
            return;
        }
        for msg in rx {
            let res = match msg {
                Msg::Output(b) => write_frame(&mut out, FRAME_OUTPUT, &b),
                Msg::Exit(code) => {
                    let _ = write_frame(&mut out, FRAME_EXIT, &code.to_be_bytes());
                    break;
                }
            };
            if res.is_err() {
                break;
            }
        }
        let _ = out.shutdown(std::net::Shutdown::Both);
    });

    let mut buf = Vec::new();
    let mut master = &session.master;
    loop {
        match read_frame_limited(&mut reader, &mut buf, 64 * 1024) {
            Ok(Some(FRAME_INPUT)) => {
                if master.write_all(&buf).is_err() {
                    break;
                }
                answer_prompt(&session, &buf);
            }
            Ok(Some(FRAME_RESIZE)) => {
                if let Some((c, r)) = parse_resize(&buf) {
                    let mut st = session.state.lock().unwrap();
                    resize_locked(&session, &mut st, c, r);
                }
            }
            Ok(Some(_)) => {}
            Ok(None) | Err(_) => break,
        }
    }

    session.state.lock().unwrap().clients.retain(|client| client.id != client_id);
    let _ = cancel.shutdown(std::net::Shutdown::Both);
    let _ = writer.join();
    Ok(())
}

/// Types `line` into a new session once the shell has drawn its prompt and gone
/// quiet. Writing earlier risks the shell flushing pending input as it starts.
/// Without `enter` the line is left at the prompt for the user to run.
fn type_when_ready(session: &Session, line: &str, enter: bool) {
    let started = now_ms();
    loop {
        thread::sleep(Duration::from_millis(100));
        let last = session.state.lock().unwrap().last_output_ms;
        let now = now_ms();
        let printed = last > started;
        if (printed && now - last > 400) || now - started > 5000 {
            break;
        }
    }
    let mut master = &session.master;
    let _ = master.write_all(format!("{line}{}", if enter { "\r" } else { "" }).as_bytes());
}

/// A keypress (not a focus report or mouse event) while the agent waits on the
/// user answers it. If the answer was "no", the agent goes quiet and the app
/// stops showing it as working.
fn answer_prompt(session: &Session, input: &[u8]) {
    if !(input.contains(&b'\r') || input.len() == 1) {
        return;
    }
    let mut st = session.state.lock().unwrap();
    if let Some(a) = st.agent.as_mut().filter(|a| a.state == AgentState::NeedsYou) {
        a.state = AgentState::Working;
        a.at_ms = now_ms();
        a.message = None;
    }
}

fn resize_locked(session: &Session, st: &mut SessionState, cols: u16, rows: u16) {
    if cols == 0 || rows == 0 || st.parser.screen().size() == (rows, cols) {
        return;
    }
    st.parser.screen_mut().set_size(rows, cols);
    let ws = Winsize { ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0 };
    unsafe {
        let _ = set_winsize(session.master.as_raw_fd(), &ws);
    }
}

/// Bytes that repaint a fresh terminal to match the session's screen.
fn snapshot(parser: &mut vt100::Parser<TermEvents>) -> Vec<u8> {
    let mut out = Vec::new();
    let (rows, _) = parser.screen().size();
    if parser.screen().alternate_screen() {
        out.extend_from_slice(b"\x1b[?1049h");
    } else {
        // Main-screen history is replayed line by line so it lands in the new
        // terminal's scrollback, colours included.
        let total = write_lines(parser, &mut out, false);
        if total > 0 {
            // Push the tail of the history off the visible screen before repainting it.
            out.extend(std::iter::repeat_n(b'\n', rows as usize));
        }
    }
    out.extend(parser.screen().state_formatted());
    out
}

/// Writes the main screen's history, and the visible rows too if `visible`, as
/// formatted lines. Each starts and ends with a reset, since vt100 formats every
/// row as if from default attributes. Returns the number of history lines.
fn write_lines(parser: &mut vt100::Parser<TermEvents>, out: &mut Vec<u8>, visible: bool) -> usize {
    let (rows, cols) = parser.screen().size();
    let mut line = |row: Vec<u8>| {
        out.extend_from_slice(b"\x1b[m");
        out.extend_from_slice(&row);
        out.extend_from_slice(b"\x1b[m\r\n");
    };
    let screen = parser.screen_mut();
    screen.set_scrollback(usize::MAX);
    let total = screen.scrollback();
    let mut off = total;
    while off > 0 {
        screen.set_scrollback(off);
        let take = off.min(rows as usize);
        screen.rows_formatted(0, cols).take(take).for_each(&mut line);
        off -= take;
    }
    screen.set_scrollback(0);
    if visible {
        // Up to the last row with anything on it.
        let used = screen.rows(0, cols).enumerate().filter(|(_, r)| !r.trim().is_empty()).map(|(i, _)| i + 1).last();
        screen.rows_formatted(0, cols).take(used.unwrap_or(0)).for_each(&mut line);
    }
    total
}

// MARK: Saved screens

/// Set once ternd is told to quit, so sessions dying with it keep their saved screens.
static QUITTING: AtomicBool = AtomicBool::new(false);

const SAVE_EVERY: Duration = Duration::from_secs(15);
const KEEP_SAVED_FOR: Duration = Duration::from_secs(30 * 24 * 3600);

#[derive(serde::Serialize, serde::Deserialize)]
struct SavedMeta {
    saved_ms: u64,
    /// What was running in the foreground (an agent's resume command for an
    /// agent), typed at the prompt after a restore for the user to run again.
    #[serde(default)]
    command: Option<String>,
}

fn saved_dir() -> PathBuf {
    runtime_dir().join("saved")
}

/// The saved screen and its details for a session id, if the id is file-safe.
fn saved_paths(id: &str) -> Option<(PathBuf, PathBuf)> {
    valid_session_id(id).then(|| {
        let dir = saved_dir();
        (dir.join(format!("{id}.screen")), dir.join(format!("{id}.json")))
    })
}

fn load_saved(id: &str) -> Option<(SavedMeta, Vec<u8>)> {
    let (screen, meta) = saved_paths(id)?;
    let meta: SavedMeta = serde_json::from_slice(&std::fs::read(meta).ok()?).ok()?;
    Some((meta, std::fs::read(screen).ok()?))
}

fn forget_saved(id: &str) {
    if let Some((screen, meta)) = saved_paths(id) {
        let _ = std::fs::remove_file(screen);
        let _ = std::fs::remove_file(meta);
    }
}

/// A dim rule under the restored screen: "── restored · saved Oct 21 14:02 ──".
fn restored_banner(saved_ms: u64, cols: u16) -> String {
    let label = format!(" restored · saved {} ", local_time(saved_ms));
    let width = (cols as usize).max(label.chars().count() + 4);
    let rest = width - 2 - label.chars().count();
    format!("\x1b[m\x1b[2m──{label}{}\x1b[m\r\n", "─".repeat(rest.min(40)))
}

fn local_time(ms: u64) -> String {
    use nix::libc;
    let t = (ms / 1000) as libc::time_t;
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    let mut buf = [0u8; 64];
    let n = unsafe {
        libc::localtime_r(&t, &mut tm);
        libc::strftime(buf.as_mut_ptr().cast(), buf.len(), c"%b %-d %H:%M".as_ptr(), &tm)
    };
    String::from_utf8_lossy(&buf[..n]).into_owned()
}

/// Saves one session's screen if it changed since the last save.
fn save_session(s: &Session, force: bool) {
    let Some((screen_path, meta_path)) = saved_paths(&s.id) else { return };
    let fg = procinfo::foreground(s.master.as_raw_fd(), s.pid);
    let (screen, agent) = {
        let mut st = s.state.lock().unwrap();
        // Full-screen programs own the screen; the main screen behind them isn't
        // reachable, so the last save from before they started stands.
        if st.parser.screen().alternate_screen() || (!force && st.saved_output_ms == st.last_output_ms) {
            return;
        }
        st.saved_output_ms = st.last_output_ms;
        let mut out = Vec::new();
        write_lines(&mut st.parser, &mut out, true);
        let agent = st.agent.as_ref().and_then(|a| Some((a.agent.clone(), a.session.clone()?)));
        (out, agent)
    };
    let command = if fg.agent.is_some() {
        // An agent's conversation picks up where it was, given its session id.
        agent.and_then(|(agent, session)| match agent.as_str() {
            "claude" => Some(format!("claude --resume {}", shell_quote(&session))),
            "codex" => Some(format!("codex resume {}", shell_quote(&session))),
            _ => None,
        })
    } else if fg.pid != s.pid && !is_shell(&fg.name) {
        procinfo::process_args(fg.pid)
            .filter(|args| !args.is_empty())
            .map(|args| args.iter().map(|a| shell_quote(a)).collect::<Vec<_>>().join(" "))
    } else {
        None
    };
    let meta = SavedMeta { saved_ms: now_ms(), command };
    let write = || -> Result<()> {
        std::fs::create_dir_all(saved_dir())?;
        let tmp = screen_path.with_extension("screen.tmp");
        std::fs::write(&tmp, &screen)?;
        std::fs::rename(&tmp, &screen_path)?;
        std::fs::write(&meta_path, serde_json::to_vec(&meta)?)?;
        Ok(())
    };
    if let Err(e) = write() {
        eprintln!("session {}: saving screen: {e:#}", s.id);
    }
}

fn save_all(sessions: &Sessions, force: bool) {
    let all: Vec<Arc<Session>> = sessions.lock().unwrap().values().cloned().collect();
    for s in all {
        save_session(&s, force);
    }
}

fn save_periodically(sessions: Sessions) {
    loop {
        thread::sleep(SAVE_EVERY);
        save_all(&sessions, false);
    }
}

/// launchd sends SIGTERM at logout and shutdown: save every screen, then go.
fn save_on_quit(sessions: Sessions) {
    use signal_hook::consts::{SIGHUP, SIGINT, SIGTERM};
    let Ok(mut signals) = signal_hook::iterator::Signals::new([SIGTERM, SIGINT, SIGHUP]) else { return };
    if let Some(sig) = signals.forever().next() {
        QUITTING.store(true, Ordering::SeqCst);
        save_all(&sessions, true);
        eprintln!("ternd: saved screens, quitting on signal {sig}");
        let _ = std::fs::remove_file(socket_path());
        std::process::exit(0);
    }
}

/// Drops saved screens nobody came back for.
fn prune_saved() {
    let Ok(entries) = std::fs::read_dir(saved_dir()) else { return };
    for e in entries.flatten() {
        let old = e.metadata().and_then(|m| m.modified()).ok().and_then(|t| t.elapsed().ok()).is_some_and(|age| age > KEEP_SAVED_FOR);
        if old {
            let _ = std::fs::remove_file(e.path());
        }
    }
}

fn is_shell(name: &str) -> bool {
    matches!(name, "zsh" | "bash" | "fish" | "sh" | "dash" | "ksh" | "tcsh" | "csh" | "nu" | "login" | "-zsh" | "-bash")
}

fn shell_quote(arg: &str) -> String {
    let plain = !arg.is_empty() && arg.chars().all(|c| c.is_ascii_alphanumeric() || "-_./=:,+@%".contains(c));
    if plain {
        arg.to_string()
    } else {
        format!("'{}'", arg.replace('\'', "'\\''"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn full_client_queue_disconnects_without_blocking() {
        let (socket, mut peer) = UnixStream::pair().unwrap();
        peer.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
        let (tx, _rx) = mpsc::sync_channel(1);
        let client = Client { id: 1, tx, socket };
        assert!(client.send(Msg::Output(vec![1])));
        assert!(!client.send(Msg::Output(vec![2])));
        assert_eq!(peer.read(&mut [0]).unwrap(), 0);
    }

    #[test]
    fn invalid_attach_does_not_remove_files() {
        let root = std::env::temp_dir().join(format!("tern-traversal-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let sentinel = root.join("sentinel");
        std::fs::write(&sentinel, "keep").unwrap();
        let (server, mut client) = UnixStream::pair().unwrap();
        writeln!(client, "{}", serde_json::json!({
            "op": "attach", "id": sentinel.to_str().unwrap(), "cols": 80,
            "rows": 24, "cwd": null, "cmd": "true", "env": []
        })).unwrap();
        handle_conn(server, Arc::default()).unwrap();
        let mut reply = String::new();
        BufReader::new(client).read_line(&mut reply).unwrap();
        assert!(!serde_json::from_str::<AttachReply>(&reply).unwrap().ok);
        assert_eq!(std::fs::read_to_string(&sentinel).unwrap(), "keep");
        std::fs::remove_dir_all(root).unwrap();
    }
}
