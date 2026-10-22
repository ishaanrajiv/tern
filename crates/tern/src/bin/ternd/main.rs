//! ternd: owns the PTYs so terminal sessions outlive the tern app.
//!
//! Each session keeps a headless vt100 screen alongside its PTY. When a client
//! attaches, it first receives a snapshot of that screen (history, then the
//! visible screen), then the live output stream.
//!
//! Screens are also saved to disk now and then, and when ternd is told to quit,
//! so after a reboot a session recreated under the same id shows what it showed.

mod saved;
mod screen;
mod session;

use std::io::{BufRead, BufReader, Write};
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
    // Before anything replaces the binary: what we are, for `hello`.
    let hello = HelloReply {
        protocol: PROTOCOL,
        version: env!("CARGO_PKG_VERSION").to_string(),
        pid: std::process::id(),
        build: std::env::current_exe().and_then(|exe| build_id(&exe)).unwrap_or_default(),
    };
    let _ = std::fs::remove_file(&path);
    let listener = UnixListener::bind(&path).with_context(|| format!("binding {}", path.display()))?;
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

fn handle_conn(conn: UnixStream, sessions: Sessions, hello: &HelloReply) -> Result<()> {
    let mut reader = BufReader::new(conn.try_clone()?);
    let mut line = String::new();
    // Clients probing whether ternd is up connect and hang up without a word.
    if reader.read_line(&mut line)? == 0 {
        return Ok(());
    }
    let req: Request = serde_json::from_str(&line).context("bad request line")?;
    let mut out = conn.try_clone()?;

    match req {
        Request::Hello => {
            writeln!(out, "{}", serde_json::to_string(hello)?)?;
        }
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
            let ok = session::report(&sessions, &id, agent, state, agent_session, message);
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
