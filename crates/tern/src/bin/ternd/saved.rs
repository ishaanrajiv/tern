//! Saved screens: each session's screen on disk, so a session recreated under
//! the same id after a reboot or a ternd restart shows what it showed.

use std::os::fd::AsRawFd;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use anyhow::Result;
use tern::*;

use crate::screen::saved_screen;
use crate::status::Record;
use crate::session::{now_ms, Session, Sessions};

/// Set once ternd is told to quit, so sessions dying with it keep their saved screens.
pub static QUITTING: AtomicBool = AtomicBool::new(false);

const SAVE_EVERY: Duration = Duration::from_secs(15);

/// Version of the saved screen's bytes. 0: no header, rows from the vt100 crate.
/// 1: libghostty-vt's formatter output. Both are VT bytes that replay as they are.
const SCREEN_FORMAT: u32 = 1;
/// The header is an APC string, which terminals ignore, so even a ternd that
/// predates it replays the file without stray text.
const HEADER_START: &[u8] = b"\x1b_tern-screen ";
const HEADER_END: &[u8] = b"\x1b\\";
const KEEP_SAVED_FOR: Duration = Duration::from_secs(30 * 24 * 3600);

#[derive(serde::Serialize, serde::Deserialize)]
pub struct SavedMeta {
    pub saved_ms: u64,
    /// What was running in the foreground (an agent's resume command for an
    /// agent), typed at the prompt after a restore for the user to run again.
    #[serde(default)]
    pub command: Option<String>,
    /// Finished and failed OSC 7501 records the user hasn't seen yet.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub status: Vec<(String, Record)>,
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

pub fn load_saved(id: &str) -> Option<(SavedMeta, Vec<u8>)> {
    let (screen, meta) = saved_paths(id)?;
    let meta: SavedMeta = serde_json::from_slice(&std::fs::read(meta).ok()?).ok()?;
    let (_, body) = screen_body(std::fs::read(screen).ok()?)?;
    Some((meta, body))
}

/// The format version and the bytes to replay; None for a format newer than this ternd.
fn screen_body(file: Vec<u8>) -> Option<(u32, Vec<u8>)> {
    let Some(rest) = file.strip_prefix(HEADER_START) else { return Some((0, file)) };
    let end = rest.windows(HEADER_END.len()).position(|w| w == HEADER_END)?;
    let version: u32 = std::str::from_utf8(&rest[..end]).ok()?.trim().parse().ok()?;
    (version <= SCREEN_FORMAT).then(|| (version, rest[end + HEADER_END.len()..].to_vec()))
}

pub fn forget_saved(id: &str) {
    if let Some((screen, meta)) = saved_paths(id) {
        let _ = std::fs::remove_file(screen);
        let _ = std::fs::remove_file(meta);
    }
}

fn write_saved(id: &str, screen: &[u8], meta: &SavedMeta) -> Result<()> {
    let Some((screen_path, meta_path)) = saved_paths(id) else { return Ok(()) };
    std::fs::create_dir_all(saved_dir())?;
    let tmp = screen_path.with_extension("screen.tmp");
    let mut file = format!("{}{SCREEN_FORMAT}", String::from_utf8_lossy(HEADER_START)).into_bytes();
    file.extend_from_slice(HEADER_END);
    file.extend_from_slice(screen);
    std::fs::write(&tmp, file)?;
    std::fs::rename(&tmp, &screen_path)?;
    std::fs::write(&meta_path, serde_json::to_vec(meta)?)?;
    Ok(())
}

/// A dim rule under the restored screen: "── restored · saved Oct 21 14:02 ──".
pub fn restored_banner(saved_ms: u64, cols: u16) -> String {
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
    if saved_paths(&s.id).is_none() {
        return;
    }
    let fg = procinfo::foreground(s.master.as_raw_fd(), s.pid);
    let (screen, agent, status) = {
        let mut st = s.state.lock().unwrap();
        // Full-screen programs own the screen; the main screen behind them isn't
        // reachable, so the last save from before they started stands.
        if st.screen.alternate_screen() || (!force && st.saved_output_ms == st.last_output_ms) {
            return;
        }
        st.saved_output_ms = st.last_output_ms;
        let out = saved_screen(&st.screen);
        let agent = st.agent.as_ref().and_then(|a| Some((a.agent.clone(), a.session.clone()?)));
        (out, agent, st.status.lasting())
    };
    let command = if fg.agent.is_some() {
        // An agent's conversation picks up where it was, given its session id.
        agent.and_then(|(agent, session)| resume_command(&agent, &session))
    } else if fg.pid != s.pid && !is_shell(&fg.name) {
        procinfo::process_args(fg.pid)
            .filter(|args| !args.is_empty())
            .map(|args| args.iter().map(|a| shell_quote(a)).collect::<Vec<_>>().join(" "))
    } else {
        None
    };
    let meta = SavedMeta { saved_ms: now_ms(), command, status };
    if let Err(e) = write_saved(&s.id, &screen, &meta) {
        eprintln!("session {}: saving screen: {e:#}", s.id);
    }
}

fn resume_command(agent: &str, session: &str) -> Option<String> {
    match agent {
        "claude" => Some(format!("claude --resume {}", shell_quote(session))),
        "codex" => Some(format!("codex resume {}", shell_quote(session))),
        _ => None,
    }
}

pub fn save_all(sessions: &Sessions, force: bool) {
    let all: Vec<Arc<Session>> = sessions.lock().unwrap().values().cloned().collect();
    for s in all {
        save_session(&s, force);
    }
}

pub fn save_periodically(sessions: Sessions) {
    loop {
        thread::sleep(SAVE_EVERY);
        save_all(&sessions, false);
    }
}

/// launchd sends SIGTERM at logout and shutdown: save every screen, then go.
pub fn save_on_quit(sessions: Sessions) {
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
pub fn prune_saved() {
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    /// Tests that point TERN_RUNTIME_DIR somewhere take turns.
    static ENV: Mutex<()> = Mutex::new(());

    fn with_runtime_dir(f: impl FnOnce(&std::path::Path)) {
        let _guard = ENV.lock().unwrap_or_else(|e| e.into_inner());
        let dir = std::env::temp_dir().join(format!("ternd-test-{}-{}", std::process::id(), now_ms()));
        std::fs::create_dir_all(&dir).unwrap();
        std::env::set_var("TERN_RUNTIME_DIR", &dir);
        f(&dir);
        std::env::remove_var("TERN_RUNTIME_DIR");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn saved_screen_round_trips() {
        with_runtime_dir(|_| {
            let meta = SavedMeta { saved_ms: 1234, command: Some("npm run dev".into()), status: Vec::new() };
            write_saved("p-1", b"\x1b[31mhello\x1b[m\r\n", &meta).unwrap();
            let (back, screen) = load_saved("p-1").unwrap();
            assert_eq!(back.saved_ms, 1234);
            assert_eq!(back.command.as_deref(), Some("npm run dev"));
            assert_eq!(screen, b"\x1b[31mhello\x1b[m\r\n");
            forget_saved("p-1");
            assert!(load_saved("p-1").is_none());
        });
    }

    #[test]
    fn screens_carry_their_format_version() {
        with_runtime_dir(|dir| {
            write_saved("p-3", b"hi\r\n", &SavedMeta { saved_ms: 1, command: None, status: Vec::new() }).unwrap();
            let file = std::fs::read(dir.join("saved/p-3.screen")).unwrap();
            assert!(file.starts_with(b"\x1b_tern-screen 1\x1b\\"), "{file:?}");
            assert_eq!(screen_body(file), Some((1, b"hi\r\n".to_vec())));
        });
    }

    #[test]
    fn headerless_screens_replay_unchanged() {
        let old = b"\x1b[m\x1b[31mred\x1b[m\r\n".to_vec();
        assert_eq!(screen_body(old.clone()), Some((0, old)));
    }

    #[test]
    fn screens_from_a_newer_ternd_are_skipped() {
        assert_eq!(screen_body(b"\x1b_tern-screen 9\x1b\\x".to_vec()), None);
        assert_eq!(screen_body(b"\x1b_tern-screen junk\x1b\\x".to_vec()), None);
    }

    #[test]
    fn the_header_is_invisible_to_a_terminal() {
        let mut file = HEADER_START.to_vec();
        file.extend_from_slice(b"1");
        file.extend_from_slice(HEADER_END);
        file.extend_from_slice(b"hello");
        let mut t = crate::vt::Terminal::new(20, 3, 10);
        t.write(&file);
        assert_eq!(String::from_utf8(t.format(crate::vt::Format::Plain)).unwrap(), "hello");
    }

    #[test]
    fn meta_from_an_older_ternd_loads() {
        with_runtime_dir(|dir| {
            std::fs::create_dir_all(dir.join("saved")).unwrap();
            std::fs::write(dir.join("saved/p-2.json"), br#"{"saved_ms":5}"#).unwrap();
            std::fs::write(dir.join("saved/p-2.screen"), b"x").unwrap();
            let (meta, _) = load_saved("p-2").unwrap();
            assert_eq!(meta.command, None);
        });
    }

    #[test]
    fn unsafe_ids_are_never_paths() {
        for id in ["", "../x", ".hidden", "a/b", "a b"] {
            assert!(saved_paths(id).is_none(), "{id:?}");
        }
        assert!(saved_paths("p-f7dc6598").is_some());
    }

    #[test]
    fn quoting() {
        assert_eq!(resume_command("claude", "abc-1").as_deref(), Some("claude --resume abc-1"));
        assert_eq!(resume_command("codex", "x y").as_deref(), Some("codex resume 'x y'"));
        assert_eq!(resume_command("vim", "x"), None);
    }

    #[test]
    fn banner_fits_narrow_panes() {
        let b = restored_banner(0, 10);
        assert!(b.contains("restored · saved"));
        assert!(b.ends_with("\x1b[m\r\n"));
    }
}
