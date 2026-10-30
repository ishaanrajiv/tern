//! Events: what changes in the sessions, for `tern watch` and the config's `on-<event>` commands.
//!
//! A thread compares the session list with the last one four times a second, like `watch`,
//! and turns the differences into events: an agent or program needing you, working, done or
//! failed; a shell command finishing; a bell; a session starting or ending.

use std::collections::{HashMap, VecDeque};
use std::process::{Command, Stdio};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::Duration;

use tern::config::Config;
use tern::{AgentState, Event, SessionInfo};

use crate::layout::Store;
use crate::session::{list_sessions, now_ms, Sessions};

/// Events kept for watchers that fall behind.
const BACKLOG: usize = 256;

/// The events between two looks at a session; `None` before it started or after it ended.
pub fn changes(prev: Option<&SessionInfo>, now: Option<&SessionInfo>) -> Vec<&'static str> {
    let (prev, now) = match (prev, now) {
        (None, Some(_)) => return vec!["start"],
        (Some(_), None) => return vec!["exit"],
        (Some(prev), Some(now)) => (prev, now),
        (None, None) => return vec![],
    };
    let mut out = Vec::new();
    if now.agent_state != prev.agent_state || (now.agent_state.is_some() && now.agent_state_ms != prev.agent_state_ms && now.agent_state == Some(AgentState::NeedsYou) && now.agent_message != prev.agent_message) {
        match now.agent_state {
            Some(AgentState::NeedsYou) => out.push("needs-you"),
            Some(AgentState::Working) if prev.agent_state != Some(AgentState::Working) => out.push("working"),
            Some(AgentState::Done) => out.push("done"),
            Some(AgentState::Failed) => out.push("failed"),
            _ => {}
        }
    }
    // A shell command, not an agent's turn; ⌃C (130) is you stopping it, not news.
    if now.finished_ms > prev.finished_ms && !now.command_running && now.agent.is_none() {
        match now.exit_code {
            Some(130) => {}
            Some(0) | None => out.push("command-done"),
            Some(_) => out.push("command-failed"),
        }
    }
    if now.bells > prev.bells { out.push("bell") }
    out
}

fn event(kind: &str, s: &SessionInfo, folder: Option<String>) -> Event {
    let command = kind.starts_with("command-");
    Event {
        event: kind.into(),
        pane: s.id.clone(),
        at_ms: now_ms(),
        folder,
        agent: s.agent.clone(),
        program: s.program.clone(),
        message: if command { None } else { s.agent_message.clone() },
        command: if command { s.last_command.clone().or(s.command.clone()) } else { None },
        exit_code: if command { s.exit_code } else { None },
        duration_ms: if command { s.duration_ms } else { None },
    }
}

#[derive(Default)]
pub struct Bus {
    inner: Mutex<(u64, VecDeque<(u64, Event)>)>,
    changed: Condvar,
}

impl Bus {
    pub fn push(&self, event: Event) {
        let mut inner = self.inner.lock().unwrap();
        inner.0 += 1;
        let seq = inner.0;
        inner.1.push_back((seq, event));
        while inner.1.len() > BACKLOG { inner.1.pop_front(); }
        drop(inner);
        self.changed.notify_all();
    }

    /// Calls `send` with each event from now on; returns when `send` fails.
    pub fn watch(&self, mut send: impl FnMut(&Event) -> bool) {
        let mut since = self.inner.lock().unwrap().0;
        loop {
            let pending: Vec<Event> = {
                let inner = self.changed.wait_while(self.inner.lock().unwrap(), |inner| inner.0 == since).unwrap();
                let pending = inner.1.iter().filter(|(seq, _)| *seq > since).map(|(_, e)| e.clone()).collect();
                since = inner.0;
                pending
            };
            if !pending.iter().all(&mut send) { return }
        }
    }
}

/// Watches the sessions for good, publishing events and running the config's commands.
pub fn monitor(sessions: Sessions, layouts: Arc<Store>, bus: Arc<Bus>) {
    let mut last: Option<HashMap<String, SessionInfo>> = None;
    loop {
        let now: HashMap<String, SessionInfo> = list_sessions(&sessions).into_iter().map(|s| (s.id.clone(), s)).collect();
        if let Some(prev) = &last {
            let mut found = Vec::new();
            for (id, s) in &now {
                for kind in changes(prev.get(id), Some(s)) { found.push(event(kind, s, None)) }
            }
            for (id, s) in prev {
                if !now.contains_key(id) { found.push(event("exit", s, None)) }
            }
            if !found.is_empty() {
                let config = Config::load();
                for mut e in found {
                    e.folder = layouts.folder(&e.pane);
                    run_commands(&config, &e);
                    bus.push(e);
                }
            }
        }
        last = Some(now);
        thread::sleep(Duration::from_millis(250));
    }
}

/// Runs each `on-<event>` command with the event in its environment, without waiting for it.
fn run_commands(config: &Config, e: &Event) {
    for line in config.all(&format!("on-{}", e.event)) {
        let mut command = Command::new("/bin/sh");
        command.arg("-c").arg(line).stdin(Stdio::null()).stdout(Stdio::null())
            .envs(event_env(e))
            .env_remove("TERN_SESSION_ID");
        if let Some(home) = std::env::var_os("HOME") { command.current_dir(home); }
        match command.spawn() {
            // Reaped here so it doesn't linger as a zombie; its errors go to ternd's log.
            Ok(mut child) => { thread::spawn(move || child.wait()); }
            Err(e) => eprintln!("on-event command {line:?}: {e}"),
        }
    }
}

/// `TERN_EVENT`, `TERN_PANE`... and the whole event as `TERN_EVENT_JSON`.
fn event_env(e: &Event) -> Vec<(String, String)> {
    let mut env = vec![("TERN_EVENT".into(), e.event.clone()), ("TERN_PANE".into(), e.pane.clone())];
    let fields = [
        ("TERN_FOLDER", e.folder.clone()),
        ("TERN_AGENT", e.agent.clone()),
        ("TERN_PROGRAM", e.program.clone()),
        ("TERN_MESSAGE", e.message.clone()),
        ("TERN_COMMAND", e.command.clone()),
        ("TERN_EXIT_CODE", e.exit_code.map(|c| c.to_string())),
        ("TERN_DURATION_MS", e.duration_ms.map(|d| d.to_string())),
    ];
    env.extend(fields.into_iter().filter_map(|(k, v)| v.map(|v| (k.to_string(), v))));
    env.push(("TERN_EVENT_JSON".into(), serde_json::to_string(e).unwrap_or_default()));
    env
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session() -> SessionInfo {
        serde_json::from_value(serde_json::json!({
            "id": "p-1", "pid": 1, "cols": 80, "rows": 24, "clients": 0, "cwd": null, "process": "zsh",
            "title": "", "git_root": null, "branch": null, "last_output_ms": 0, "bells": 0,
        })).unwrap()
    }

    #[test]
    fn agent_states_become_events_once() {
        let prev = session();
        let mut now = session();
        now.agent = Some("claude".into());
        now.agent_state = Some(AgentState::NeedsYou);
        now.agent_state_ms = 5;
        assert_eq!(changes(Some(&prev), Some(&now)), ["needs-you"]);
        assert!(changes(Some(&now), Some(&now)).is_empty());
        let mut asked_again = now.clone();
        asked_again.agent_state_ms = 9;
        asked_again.agent_message = Some("Run rm?".into());
        assert_eq!(changes(Some(&now), Some(&asked_again)), ["needs-you"]);
        let mut done = now.clone();
        done.agent_state = Some(AgentState::Done);
        assert_eq!(changes(Some(&now), Some(&done)), ["done"]);
        let mut failed = now.clone();
        failed.agent_state = Some(AgentState::Failed);
        assert_eq!(changes(Some(&done), Some(&failed)), ["failed"]);
    }

    #[test]
    fn shell_commands_bells_and_lifetimes() {
        let prev = session();
        let mut now = session();
        now.finished_ms = 10;
        now.exit_code = Some(2);
        now.bells = 1;
        assert_eq!(changes(Some(&prev), Some(&now)), ["command-failed", "bell"]);
        now.exit_code = Some(130);
        now.bells = 0;
        assert!(changes(Some(&prev), Some(&now)).is_empty(), "⌃C says nothing");
        now.exit_code = Some(0);
        assert_eq!(changes(Some(&prev), Some(&now)), ["command-done"]);
        assert_eq!(changes(None, Some(&now)), ["start"]);
        assert_eq!(changes(Some(&now), None), ["exit"]);
    }

    #[test]
    fn commands_get_the_event_in_their_environment() {
        let mut s = session();
        s.command = None;
        s.last_command = Some("cargo test".into());
        s.exit_code = Some(101);
        let env = event_env(&event("command-failed", &s, Some("/repo".into())));
        let get = |k: &str| env.iter().find(|(key, _)| key == k).map(|(_, v)| v.as_str());
        assert_eq!(get("TERN_EVENT"), Some("command-failed"));
        assert_eq!(get("TERN_FOLDER"), Some("/repo"));
        assert_eq!(get("TERN_COMMAND"), Some("cargo test"));
        assert_eq!(get("TERN_EXIT_CODE"), Some("101"));
        assert_eq!(get("TERN_MESSAGE"), None);
        assert!(get("TERN_EVENT_JSON").unwrap().contains("\"exit_code\":101"));
    }

    #[test]
    fn every_event_can_be_produced() {
        for kind in ["needs-you", "working", "done", "failed", "command-done", "command-failed", "bell", "start", "exit"] {
            assert!(tern::EVENTS.contains(&kind));
        }
        assert_eq!(tern::EVENTS.len(), 9);
    }
}
