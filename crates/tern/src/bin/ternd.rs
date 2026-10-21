//! ternd: owns the PTYs so terminal sessions outlive the tern app.
//!
//! Each session keeps a headless vt100 screen alongside its PTY. When a client
//! attaches, it first receives a snapshot of that screen (plain-text history,
//! then the formatted visible screen), then the live output stream.

use std::collections::HashMap;
use std::fs::File;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::net::{UnixListener, UnixStream};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Sender};
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
    clients: Vec<(u64, Sender<Msg>)>,
    last_output_ms: u64,
    agent: Option<AgentReport>,
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
    let (cols, rows, clients, title, bells, last_output_ms, report) = {
        let mut st = s.state.lock().unwrap();
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
        (cols, rows, st.clients.len(), cb.title.clone(), cb.bells, st.last_output_ms, report)
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
    let dir = runtime_dir();
    std::fs::create_dir_all(&dir).with_context(|| format!("creating {}", dir.display()))?;
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
    reader.read_line(&mut line)?;
    let req: Request = serde_json::from_str(&line).context("bad request line")?;
    let mut out = conn.try_clone()?;

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
                    Ok(s) => {
                        if let Some(line) = init {
                            let s = s.clone();
                            thread::spawn(move || type_when_ready(&s, &line));
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
) -> Result<Arc<Session>> {
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
    command.envs(env).env("TERN_SESSION_ID", id);
    let child = spawn_on_pty(command, slave).context("spawning session process")?;
    let pid = child.id() as i32;
    // We reap the child ourselves with waitpid once its PTY closes.
    std::mem::forget(child);

    let session = Arc::new(Session {
        id: id.to_string(),
        pid,
        start_cwd: cwd,
        master,
        state: Mutex::new(SessionState {
            parser: vt100::Parser::new_with_callbacks(rows, cols, SCROLLBACK_LINES, TermEvents::default()),
            clients: Vec::new(),
            last_output_ms: now_ms(),
            agent: None,
        }),
    });
    sessions.lock().unwrap().insert(id.to_string(), session.clone());
    eprintln!("session {id}: spawned pid {pid}");

    let reader_session = session.clone();
    let sessions = sessions.clone();
    thread::spawn(move || pump_output(reader_session, sessions));
    Ok(session)
}

/// Reads PTY output, feeds the headless screen and fans it out to clients.
fn pump_output(session: Arc<Session>, sessions: Sessions) {
    let mut master = session.master.try_clone().expect("clone master");
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        match master.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                let bytes = &buf[..n];
                let mut st = session.state.lock().unwrap();
                st.parser.process(bytes);
                st.last_output_ms = now_ms();
                st.clients.retain(|(_, tx)| tx.send(Msg::Output(bytes.to_vec())).is_ok());
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
    {
        let mut map = sessions.lock().unwrap();
        if map.get(&session.id).is_some_and(|s| Arc::ptr_eq(s, &session)) {
            map.remove(&session.id);
        }
    }
    let st = session.state.lock().unwrap();
    for (_, tx) in &st.clients {
        let _ = tx.send(Msg::Exit(code));
    }
}

fn attach(session: Arc<Session>, mut reader: BufReader<UnixStream>, out: UnixStream, cols: u16, rows: u16) -> Result<()> {
    let client_id = NEXT_CLIENT.fetch_add(1, Ordering::Relaxed);
    let (tx, rx) = mpsc::channel::<Msg>();

    // Snapshot and registration happen under one lock so no output is lost or doubled.
    let snapshot = {
        let mut st = session.state.lock().unwrap();
        resize_locked(&session, &mut st, cols, rows);
        let snap = snapshot(&mut st.parser);
        st.clients.push((client_id, tx));
        snap
    };

    let writer = thread::spawn(move || {
        let mut out = out;
        if write_frame(&mut out, FRAME_OUTPUT, &snapshot).is_err() {
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
        match read_frame(&mut reader, &mut buf) {
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

    session.state.lock().unwrap().clients.retain(|(id, _)| *id != client_id);
    let _ = writer.join();
    Ok(())
}

/// Types `line` into a new session once the shell has drawn its prompt and gone
/// quiet. Writing earlier risks the shell flushing pending input as it starts.
fn type_when_ready(session: &Session, line: &str) {
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
    let _ = master.write_all(format!("{line}\r").as_bytes());
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
    let (rows, cols) = parser.screen().size();
    if parser.screen().alternate_screen() {
        out.extend_from_slice(b"\x1b[?1049h");
    } else {
        // Main-screen history goes in as plain text so it lands in the new
        // terminal's scrollback. Colors in history are dropped for now.
        let screen = parser.screen_mut();
        screen.set_scrollback(usize::MAX);
        let total = screen.scrollback();
        let mut off = total;
        while off > 0 {
            screen.set_scrollback(off);
            let take = off.min(rows as usize);
            for row in screen.rows(0, cols).take(take) {
                out.extend_from_slice(row.trim_end().as_bytes());
                out.extend_from_slice(b"\r\n");
            }
            off -= take;
        }
        screen.set_scrollback(0);
        if total > 0 {
            // Push the tail of the history off the visible screen before repainting it.
            out.extend(std::iter::repeat_n(b'\n', rows as usize));
        }
    }
    out.extend(parser.screen().state_formatted());
    out
}
