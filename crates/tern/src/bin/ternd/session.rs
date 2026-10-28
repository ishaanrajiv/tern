//! A session: a PTY, the process on it, and a headless screen that mirrors it.

use std::collections::{HashMap, VecDeque};
use std::fs::File;
use std::io::{BufReader, Read, Write};
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::net::UnixStream;
use std::process::Command;
use std::sync::atomic::{AtomicU32, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use nix::pty::{openpty, Winsize};
use nix::sys::wait::{waitpid, WaitStatus};
use nix::unistd::Pid;
use tern::*;

use crate::saved::{forget_saved, load_saved, restored_banner, SavedMeta, QUITTING};
use crate::screen::snapshot;
use crate::vt::Terminal;

const SCROLLBACK_LINES: usize = 10_000;
pub static SCROLLBACK_BYTES: AtomicUsize = AtomicUsize::new(10_000_000);

nix::ioctl_write_ptr_bad!(set_winsize, nix::libc::TIOCSWINSZ, Winsize);

pub type Sessions = Arc<Mutex<HashMap<String, Arc<Session>>>>;

static NEXT_CLIENT: AtomicU64 = AtomicU64::new(1);

/// The umask ternd started with, for the processes it runs: its own is stricter.
pub static USER_UMASK: AtomicU32 = AtomicU32::new(0o022);

/// Output a client may fall behind by before it's disconnected. It reattaches from
/// the screen, so nothing it would show is lost.
const CLIENT_QUEUE_BYTES: usize = 8 << 20;

#[derive(Debug, PartialEq)]
enum Msg {
    Output(Vec<u8>),
    Exit(i32),
}

/// Output waiting to go to one client. Bounded, so a client that stops reading
/// can't grow ternd's memory or hold up the session.
#[derive(Default)]
struct ClientQueue {
    state: Mutex<QueueState>,
    ready: Condvar,
}

#[derive(Default)]
struct QueueState {
    output: VecDeque<Vec<u8>>,
    bytes: usize,
    exit: Option<i32>,
    closed: bool,
}

impl ClientQueue {
    /// Queues output; false (and closed) once the client is too far behind.
    fn push(&self, bytes: &[u8]) -> bool {
        let mut st = self.state.lock().unwrap();
        if st.closed || st.bytes + bytes.len() > CLIENT_QUEUE_BYTES {
            st.closed = true;
            self.ready.notify_all();
            return false;
        }
        st.bytes += bytes.len();
        st.output.push_back(bytes.to_vec());
        self.ready.notify_all();
        true
    }

    /// The exit code goes after whatever output is still queued: the last thing a
    /// command printed matters most.
    fn exit(&self, code: i32) {
        self.state.lock().unwrap().exit = Some(code);
        self.ready.notify_all();
    }

    fn close(&self) {
        self.state.lock().unwrap().closed = true;
        self.ready.notify_all();
    }

    /// The next message, waiting for one; None once closed.
    fn recv(&self) -> Option<Msg> {
        let mut st = self.state.lock().unwrap();
        loop {
            if st.closed {
                return None;
            }
            if let Some(bytes) = st.output.pop_front() {
                st.bytes -= bytes.len();
                return Some(Msg::Output(bytes));
            }
            if let Some(code) = st.exit.take() {
                return Some(Msg::Exit(code));
            }
            st = self.ready.wait(st).unwrap();
        }
    }
}

struct Client {
    id: u64,
    queue: Arc<ClientQueue>,
    socket: UnixStream,
}

impl Client {
    /// False if the client fell too far behind; it's hung up on, which wakes
    /// both its threads, and its `tern attach` reattaches.
    fn send(&self, bytes: &[u8]) -> bool {
        if self.queue.push(bytes) {
            return true;
        }
        let _ = self.socket.shutdown(std::net::Shutdown::Both);
        false
    }
}

pub struct Session {
    pub id: String,
    pub pid: i32,
    start_cwd: Option<String>,
    pub master: File,
    pub state: Mutex<SessionState>,
}

pub struct SessionState {
    pub screen: Terminal,
    pub capture: super::command::CommandCapture,
    clients: Vec<Client>,
    pub last_output_ms: u64,
    /// `last_output_ms` when the screen was last saved to disk.
    pub saved_output_ms: u64,
    pub agent: Option<AgentReport>,
    /// The foreground command, by its process, for shells without tern's integration.
    command: Option<String>,
    /// The last telling command line typed, from the zsh integration.
    typed: Option<String>,
}

/// The last thing an agent's hooks told us.
pub struct AgentReport {
    pub agent: String,
    pub state: AgentState,
    pub at_ms: u64,
    pub session: Option<String>,
    pub message: Option<String>,
}

pub fn now_ms() -> u64 {
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
        let (cols, rows) = st.screen.size();
        (cols, rows, st.clients.len(), st.screen.title(), st.screen.bells(), st.last_output_ms, report, command)
    };
    let cwd = fg.cwd.or_else(|| procinfo::process_cwd(s.pid)).or_else(|| s.start_cwd.clone());
    let git = cwd.as_deref().and_then(|d| procinfo::git_info(std::path::Path::new(d)));
    let st = s.state.lock().unwrap();
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
        finished_ms: if st.capture.finished_ms > 0 { st.capture.finished_ms } else { shell::finished_ms(&s.id) },
        exit_code: st.capture.exit_code,
        duration_ms: st.capture.duration_ms,
    }
}

pub fn list_sessions(sessions: &Sessions) -> Vec<SessionInfo> {
    let all: Vec<Arc<Session>> = sessions.lock().unwrap().values().cloned().collect();
    let mut list: Vec<SessionInfo> = all.iter().map(|s| session_info(s)).collect();
    list.sort_by(|a, b| a.id.cmp(&b.id));
    list
}

/// Records what an agent's hooks reported. Returns false if there's no such session.
pub fn report(sessions: &Sessions, id: &str, agent: String, state: AgentState, agent_session: Option<String>, message: Option<String>) -> bool {
    let Some(s) = sessions.lock().unwrap().get(id).cloned() else { return false };
    let mut st = s.state.lock().unwrap();
    st.agent = Some(merge_report(st.agent.take(), agent, state, agent_session, message, now_ms()));
    true
}

/// The new report, keeping the agent's session id and message from the previous
/// one when this one doesn't carry them.
fn merge_report(prev: Option<AgentReport>, agent: String, state: AgentState, session: Option<String>, message: Option<String>, at_ms: u64) -> AgentReport {
    let (old_session, old_message) = match prev {
        Some(p) if p.agent == agent => (p.session, p.message),
        _ => (None, None),
    };
    let message = match state {
        AgentState::Working => None,
        _ => message.or(if state == AgentState::Done { old_message } else { None }),
    };
    AgentReport { agent, state, at_ms, session: session.or(old_session), message }
}

pub fn spawn_session(
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
            Command::new(&shell)
        }
    };
    if let Some(dir) = &cwd {
        command.current_dir(dir);
    }
    command.envs(env.clone()).env("TERN_SESSION_ID", id);
    if cmd.is_none() { shell::configure(&mut command, &std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into()), &env); }
    let commands = shell::command_file(id);
    let _ = std::fs::remove_file(&commands);
    let _ = std::fs::remove_file(shell::finished_file(id));
    command.env("TERN_COMMAND_FILE", &commands);
    let umask = nix::sys::stat::Mode::from_bits_truncate(USER_UMASK.load(Ordering::Relaxed) as _);
    unsafe {
        use std::os::unix::process::CommandExt;
        command.pre_exec(move || {
            nix::sys::stat::umask(umask);
            Ok(())
        });
    }
    let child = spawn_on_pty(command, slave).context("spawning session process")?;
    let pid = child.id() as i32;
    // We reap the child ourselves with waitpid once its PTY closes.
    std::mem::forget(child);

    let mut screen = Terminal::new(cols, rows, SCROLLBACK_LINES);
    screen.set_scrollback_bytes(SCROLLBACK_BYTES.load(Ordering::Relaxed));
    // Lay the saved screen down before the new shell prints anything.
    let restored = load_saved(id).map(|(meta, saved)| {
        screen.write(&saved);
        screen.write(restored_banner(meta.saved_ms, cols).as_bytes());
        meta
    });
    let session = Arc::new(Session {
        id: id.to_string(),
        pid,
        start_cwd: cwd,
        master,
        state: Mutex::new(SessionState {
            screen,
            capture: super::command::CommandCapture::default(),
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
                st.capture.write(bytes);
                st.screen.write(bytes);
                st.last_output_ms = now_ms();
                st.clients.retain(|c| c.send(bytes));
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
    let _ = std::fs::remove_file(shell::finished_file(&session.id));
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
    for c in &st.clients {
        c.queue.exit(code);
    }
}

pub fn attach(session: Arc<Session>, mut reader: BufReader<UnixStream>, out: UnixStream, cols: u16, rows: u16) -> Result<()> {
    let client_id = NEXT_CLIENT.fetch_add(1, Ordering::Relaxed);
    let queue = Arc::new(ClientQueue::default());
    let client = Client { id: client_id, queue: queue.clone(), socket: out.try_clone()? };

    // Snapshot and registration happen under one lock so no output is lost or doubled.
    let snapshot = {
        let mut st = session.state.lock().unwrap();
        resize_locked(&session, &mut st, cols, rows);
        let snap = snapshot(&st.screen);
        st.clients.push(client);
        snap
    };

    let writer_queue = queue.clone();
    let writer = thread::spawn(move || {
        let mut out = out;
        // In pieces, so no frame is larger than a client will read.
        if snapshot.chunks(OUTPUT_CHUNK).any(|chunk| write_frame(&mut out, FRAME_OUTPUT, chunk).is_err()) {
            let _ = out.shutdown(std::net::Shutdown::Both);
            return;
        }
        while let Some(msg) = writer_queue.recv() {
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
        match read_frame(&mut reader, &mut buf, MAX_CLIENT_FRAME) {
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

    session.state.lock().unwrap().clients.retain(|c| c.id != client_id);
    // The writer may be waiting for output that will never come.
    queue.close();
    let _ = writer.join();
    Ok(())
}

/// Types `line` into a new session once the shell has drawn its prompt and gone
/// quiet. Writing earlier risks the shell flushing pending input as it starts.
/// Without `enter` the line is left at the prompt for the user to run.
pub fn type_when_ready(session: &Session, line: &str, enter: bool) {
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
    if cols == 0 || rows == 0 || st.screen.size() == (cols, rows) {
        return;
    }
    st.screen.resize(cols, rows);
    let ws = Winsize { ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0 };
    unsafe {
        let _ = set_winsize(session.master.as_raw_fd(), &ws);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn report(agent: &str, state: AgentState, session: Option<&str>, message: Option<&str>) -> AgentReport {
        AgentReport { agent: agent.into(), state, at_ms: 0, session: session.map(Into::into), message: message.map(Into::into) }
    }

    #[test]
    fn a_client_that_stops_reading_is_hung_up_on() {
        let (socket, mut peer) = UnixStream::pair().unwrap();
        let client = Client { id: 1, queue: Arc::default(), socket };
        let chunk = vec![0u8; 64 * 1024];
        let sent = (0..1000).take_while(|_| client.send(&chunk)).count();
        assert_eq!(sent, CLIENT_QUEUE_BYTES / chunk.len());
        // Hung up: the peer reads end of file, and nothing more is queued.
        assert_eq!(peer.read(&mut [0u8; 1]).unwrap(), 0);
        assert!(!client.send(b"x"));
        assert_eq!(client.queue.recv(), None);
    }

    #[test]
    fn the_exit_follows_the_last_output() {
        let queue = ClientQueue::default();
        assert!(queue.push(b"last words"));
        queue.exit(3);
        assert_eq!(queue.recv(), Some(Msg::Output(b"last words".to_vec())));
        assert_eq!(queue.recv(), Some(Msg::Exit(3)));
    }

    #[test]
    fn closing_wakes_a_waiting_writer() {
        let queue = Arc::new(ClientQueue::default());
        let waiting = {
            let queue = queue.clone();
            thread::spawn(move || queue.recv())
        };
        thread::sleep(Duration::from_millis(50));
        queue.close();
        assert_eq!(waiting.join().unwrap(), None);
    }

    #[test]
    fn reports_keep_the_session_id_and_last_reply() {
        let prev = report("claude", AgentState::Done, Some("abc"), Some("All done."));
        // A later report without the ids keeps them; "done" keeps the last reply.
        let next = merge_report(Some(prev), "claude".into(), AgentState::Done, None, None, 1);
        assert_eq!(next.session.as_deref(), Some("abc"));
        assert_eq!(next.message.as_deref(), Some("All done."));
    }

    #[test]
    fn working_clears_the_message() {
        let prev = report("claude", AgentState::NeedsYou, Some("abc"), Some("Allow Bash?"));
        let next = merge_report(Some(prev), "claude".into(), AgentState::Working, None, Some("ignored".into()), 1);
        assert_eq!(next.message, None);
        assert_eq!(next.session.as_deref(), Some("abc"));
    }

    #[test]
    fn a_different_agent_starts_fresh() {
        let prev = report("claude", AgentState::Done, Some("abc"), Some("bye"));
        let next = merge_report(Some(prev), "codex".into(), AgentState::Idle, None, None, 1);
        assert_eq!(next.session, None);
        assert_eq!(next.message, None);
    }

    #[test]
    fn needs_you_does_not_inherit_an_old_reply() {
        let prev = report("codex", AgentState::Done, None, Some("finished"));
        let next = merge_report(Some(prev), "codex".into(), AgentState::NeedsYou, None, None, 1);
        assert_eq!(next.message, None);
    }
}
