//! ternd: owns the PTYs so terminal sessions outlive the tern app.
//!
//! Each session keeps a headless libghostty-vt terminal alongside its PTY. When a client
//! attaches, it first receives a snapshot of that screen (history, then the
//! visible screen), then the live output stream.
//!
//! Screens are also saved to disk now and then, and when ternd is told to quit,
//! so after a reboot a session recreated under the same id shows what it showed.

mod saved;
mod screen;
mod vt;
mod session;
mod command;

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use anyhow::{Context, Result};
use nix::sys::signal::{killpg, Signal};
use nix::unistd::Pid;
use tern::*;

use saved::{forget_saved, prune_saved, save_on_quit, save_periodically};
use session::{attach, list_sessions, spawn_session, type_when_ready, Sessions};

fn main() -> Result<()> {
    // Everything ternd creates (screens, typed commands, the socket) is for this user
    // only. Sessions get the umask ternd started with back.
    let umask = nix::sys::stat::umask(nix::sys::stat::Mode::from_bits_truncate(0o077));
    session::USER_UMASK.store(umask.bits() as u32, std::sync::atomic::Ordering::Relaxed);
    let dir = prepare_runtime_dir().with_context(|| format!("preparing {}", runtime_dir().display()))?;
    if let Some(bytes) = std::fs::read(dir.join("terminal-settings.json")).ok()
        .and_then(|data| serde_json::from_slice::<serde_json::Value>(&data).ok())
        .and_then(|value| value.get("scrollback").and_then(|n| n.as_u64()))
        .filter(|n| (100_000..=1_000_000_000).contains(n)) {
        session::SCROLLBACK_BYTES.store(bytes as usize, std::sync::atomic::Ordering::Relaxed);
    }
    let path = socket_path();
    // sockaddr_un.sun_path is 104 bytes on macOS.
    if path.as_os_str().len() >= 104 {
        anyhow::bail!("socket path is too long for a unix socket: {}", path.display());
    }

    if UnixStream::connect(&path).is_ok() {
        eprintln!("ternd already running at {}", path.display());
        return Ok(());
    }
    // Before anything replaces the binary: what we are, for `hello`.
    let hello = HelloReply {
        protocol: PROTOCOL,
        version: env!("CARGO_PKG_VERSION").to_string(),
        pid: std::process::id(),
        build: std::env::current_exe().and_then(|exe| build_id(&exe)).unwrap_or_default(),
    };
    let _ = std::fs::remove_file(&path);
    let listener = UnixListener::bind(&path).with_context(|| format!("binding {}", path.display()))?;
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).with_context(|| format!("securing {}", path.display()))?;
    }
    std::fs::write(dir.join("ternd.pid"), std::process::id().to_string())?;
    eprintln!("ternd {} (protocol {}, build {}) listening on {}", hello.version, hello.protocol, hello.build, path.display());

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
    let hello = Arc::new(hello);
    for conn in listener.incoming() {
        let Ok(conn) = conn else { continue };
        let sessions = sessions.clone();
        let hello = hello.clone();
        thread::spawn(move || {
            if let Err(e) = handle_conn(conn, sessions, &hello) {
                eprintln!("connection error: {e:#}");
            }
        });
    }
    Ok(())
}

/// ternd hands out terminal output and takes keystrokes, so only its own user may
/// talk to it. The socket's mode keeps others out; this refuses one that got in anyway.
fn verify_peer(conn: &UnixStream, me: nix::unistd::Uid) -> Result<()> {
    use std::os::fd::AsRawFd;
    let (mut uid, mut gid) = (0, 0);
    if unsafe { nix::libc::getpeereid(conn.as_raw_fd(), &mut uid, &mut gid) } != 0 {
        return Err(std::io::Error::last_os_error()).context("reading the peer's credentials");
    }
    anyhow::ensure!(uid == me.as_raw(), "refused a connection from uid {uid}");
    Ok(())
}

fn handle_conn(conn: UnixStream, sessions: Sessions, hello: &HelloReply) -> Result<()> {
    verify_peer(&conn, nix::unistd::geteuid())?;
    let mut reader = BufReader::new(conn.try_clone()?);
    let mut line = String::new();
    // Clients probing whether ternd is up connect and hang up without a word.
    if reader.by_ref().take(MAX_REQUEST_LINE as u64 + 1).read_line(&mut line)? == 0 {
        return Ok(());
    }
    anyhow::ensure!(line.len() <= MAX_REQUEST_LINE, "request line over {MAX_REQUEST_LINE} bytes");
    let req: Request = serde_json::from_str(&line).context("bad request line")?;
    let mut out = conn.try_clone()?;

    let id = match &req {
        Request::Attach { id, .. } | Request::Kill { id } | Request::Report { id, .. } | Request::ReadOutput { id, .. } => Some(id),
        Request::Hello | Request::List | Request::Watch | Request::SetScrollback { .. } => None,
    };
    if id.is_some_and(|id| !valid_session_id(id)) {
        // In the shape the caller expects for that request.
        let reply = match req {
            Request::Attach { .. } => {
                serde_json::to_string(&AttachReply { ok: false, created: false, error: Some("invalid session id".into()) })?
            }
            _ => serde_json::json!({ "ok": false, "error": "invalid session id" }).to_string(),
        };
        writeln!(out, "{reply}")?;
        return Ok(());
    }

    match req {
        Request::Hello => {
            writeln!(out, "{}", serde_json::to_string(hello)?)?;
        }
        Request::List => {
            writeln!(out, "{}", serde_json::to_string(&list_sessions(&sessions))?)?;
        }
        Request::ReadOutput { id, last_command } => {
            let session = sessions.lock().unwrap().get(&id).cloned();
            if let Some(session) = session {
                let (text, truncated) = {
                    let st = session.state.lock().unwrap();
                    if last_command {
                        let (cols, rows) = st.screen.size();
                        let mut terminal = vt::Terminal::new(cols, rows, 10_000);
                        terminal.set_scrollback_bytes(64 << 20);
                        terminal.write(&st.capture.output);
                        let lines = st.capture.output.iter().filter(|b| **b == b'\n').count();
                        let pruned = lines > terminal.scrollback_rows() + usize::from(rows);
                        (terminal.format(vt::Format::Plain), st.capture.truncated || pruned)
                    } else {
                        (st.screen.format(vt::Format::Plain), false)
                    }
                };
                // Keep JSON replies bounded even when the history setting is very large.
                let max = 8 << 20;
                let truncated = truncated || text.len() > max;
                let text = String::from_utf8_lossy(&text[..text.len().min(max)]);
                writeln!(out, "{}", serde_json::json!({"ok": true, "text": text, "truncated": truncated}))?;
            } else {
                writeln!(out, "{}", serde_json::json!({"ok": false, "error": "session no longer exists"}))?;
            }
        }
        Request::SetScrollback { bytes } => {
            let ok = (100_000..=1_000_000_000).contains(&bytes);
            if ok {
                session::SCROLLBACK_BYTES.store(bytes, std::sync::atomic::Ordering::Relaxed);
                let all: Vec<_> = sessions.lock().unwrap().values().cloned().collect();
                for session in all { session.state.lock().unwrap().screen.set_scrollback_bytes(bytes); }
            }
            writeln!(out, "{}", serde_json::json!({"ok": ok}))?;
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
        Request::Report { id, agent, state, agent_session, message, subagent } => {
            let ok = session::report(&sessions, &id, agent, state, agent_session, message, subagent);
            writeln!(out, "{}", serde_json::json!({ "ok": ok }))?;
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

#[cfg(test)]
mod tests {
    use super::*;

    fn hello() -> HelloReply {
        HelloReply { protocol: PROTOCOL, version: "test".into(), pid: 0, build: String::new() }
    }

    #[test]
    fn output_and_retention_requests_have_bounded_replies() {
        for (request, expected) in [
            (serde_json::json!({"op":"read_output", "id":"missing"}), false),
            (serde_json::json!({"op":"set_scrollback", "bytes":0}), false),
            (serde_json::json!({"op":"set_scrollback", "bytes":1_000_000_001u64}), false),
        ] {
            let (server, mut client) = UnixStream::pair().unwrap();
            writeln!(client, "{request}").unwrap();
            handle_conn(server, Sessions::default(), &hello()).unwrap();
            let mut reply = String::new();
            BufReader::new(client).read_line(&mut reply).unwrap();
            let reply: serde_json::Value = serde_json::from_str(&reply).unwrap();
            assert_eq!(reply["ok"], expected);
        }
    }

    #[test]
    fn only_this_user_may_connect() {
        let (conn, _peer) = UnixStream::pair().unwrap();
        let me = nix::unistd::geteuid();
        assert!(verify_peer(&conn, me).is_ok());
        let other = nix::unistd::Uid::from_raw(me.as_raw() + 1);
        assert!(verify_peer(&conn, other).is_err());
    }

    #[test]
    fn ids_that_are_paths_are_refused_before_touching_files() {
        let root = std::env::temp_dir().join(format!("ternd-ids-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let victim = root.join("victim");
        std::fs::write(&victim, "keep").unwrap();
        let requests = [
            serde_json::json!({ "op": "attach", "id": victim, "cols": 80, "rows": 24, "cwd": null, "cmd": "true" }),
            serde_json::json!({ "op": "attach", "id": "../../victim", "cols": 80, "rows": 24, "cwd": null, "cmd": "true" }),
            serde_json::json!({ "op": "kill", "id": victim }),
            serde_json::json!({ "op": "read_output", "id": "../victim", "last_command": true }),
            serde_json::json!({ "op": "report", "id": "../x", "agent": "claude", "state": "idle", "agent_session": null, "message": null }),
        ];
        for req in requests {
            let (server, mut client) = UnixStream::pair().unwrap();
            writeln!(client, "{req}").unwrap();
            handle_conn(server, Sessions::default(), &hello()).unwrap();
            let mut reply = String::new();
            BufReader::new(client).read_line(&mut reply).unwrap();
            let reply: serde_json::Value = serde_json::from_str(&reply).unwrap();
            assert_eq!(reply["ok"], false, "{req}");
            assert_eq!(reply["error"], "invalid session id");
        }
        assert_eq!(std::fs::read_to_string(&victim).unwrap(), "keep");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn an_endless_request_line_is_cut_off() {
        let (server, client) = UnixStream::pair().unwrap();
        let writer = thread::spawn(move || {
            let mut client = client;
            let chunk = vec![b'x'; 64 * 1024];
            // Stops once ternd hangs up.
            while client.write_all(&chunk).is_ok() {}
        });
        assert!(handle_conn(server, Sessions::default(), &hello()).is_err());
        writer.join().unwrap();
    }
}
