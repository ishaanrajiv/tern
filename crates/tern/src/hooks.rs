//! Agent hooks: Claude Code and Codex run `tern hook <agent>` on lifecycle
//! events, and it reports the agent's state to ternd for the session it runs in.
//!
//! The hooks are installed into the agents' user config, so they run for every
//! session of that agent; outside tern (no TERN_SESSION_ID) they exit at once.

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{bail, Context, Result};
use serde_json::{json, Map, Value};

use crate::{socket_path, AgentState, Request};

pub const AGENTS: [&str; 2] = ["claude", "codex"];

/// Events each agent is hooked on.
fn events(agent: &str) -> &'static [&'static str] {
    match agent {
        "claude" => &[
            "SessionStart",
            "UserPromptSubmit",
            "PreToolUse",
            "PostToolUse",
            "PostToolUseFailure",
            "PermissionRequest",
            "Notification",
            "Stop",
            "StopFailure",
            "SessionEnd",
        ],
        _ => &["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "Stop", "SessionEnd", "Interrupt"],
    }
}

/// What an event means for the agent's state, if anything.
pub fn state_for(agent: &str, input: &Value) -> Option<(AgentState, Option<String>)> {
    let event = input["hook_event_name"].as_str()?;
    let text = |key: &str| input[key].as_str().map(summarize);
    let state = match event {
        "SessionStart" => match input["source"].as_str() {
            // "compact" happens mid-turn; the agent is still working.
            Some("compact") => return None,
            _ => AgentState::Idle,
        },
        "UserPromptSubmit" | "PreToolUse" | "PostToolUse" => AgentState::Working,
        // Esc during a tool ends the turn without a Stop; other failures go back to the model.
        "PostToolUseFailure" => match input["is_interrupt"].as_bool() {
            Some(true) => AgentState::Idle,
            _ => return None,
        },
        "PermissionRequest" | "Elicitation" => {
            let tool = input["tool_name"].as_str().map(|t| format!("Allow {t}?"));
            return Some((AgentState::NeedsYou, tool.or_else(|| text("message"))));
        }
        "Notification" => {
            let kind = input["notification_type"].as_str().or(input["type"].as_str()).unwrap_or("");
            let message = input["message"].as_str().unwrap_or("");
            let asks = matches!(
                kind,
                "permission_prompt" | "elicitation_dialog" | "elicitation_url_dialog" | "agent_needs_input"
            ) || (kind.is_empty() && message.to_lowercase().contains("permission"));
            if !asks {
                return None;
            }
            return Some((AgentState::NeedsYou, text("message")));
        }
        "Stop" => return Some((AgentState::Done, text("last_assistant_message"))),
        "StopFailure" => return Some((AgentState::Done, Some("Stopped with an error".into()))),
        "Interrupt" => AgentState::Idle,
        "SessionEnd" => AgentState::Ended,
        _ => return None,
    };
    let _ = agent;
    Some((state, None))
}

/// First line-ish of a message, whitespace collapsed, at most 200 characters.
fn summarize(s: &str) -> String {
    let flat: String = s.split_whitespace().collect::<Vec<_>>().join(" ");
    if flat.chars().count() > 200 {
        flat.chars().take(199).chain(std::iter::once('…')).collect()
    } else {
        flat
    }
}

/// `tern hook <agent>`: never fails loudly, never prints, never blocks the agent.
pub fn run_hook(agent: &str) {
    let Ok(id) = std::env::var("TERN_SESSION_ID") else { return };
    let mut raw = String::new();
    let _ = std::io::stdin().take(4 << 20).read_to_string(&mut raw);
    // Codex's legacy `notify` passes the payload as an argument instead.
    let input: Value = serde_json::from_str(&raw).unwrap_or(Value::Null);
    let Some((state, message)) = state_for(agent, &input) else { return };
    let req = Request::Report {
        id,
        agent: agent.to_string(),
        state,
        agent_session: input["session_id"].as_str().map(str::to_string),
        message,
    };
    let _ = send(&req);
}

fn send(req: &Request) -> Result<()> {
    let mut conn = UnixStream::connect(socket_path())?;
    conn.set_read_timeout(Some(Duration::from_secs(1)))?;
    conn.set_write_timeout(Some(Duration::from_secs(1)))?;
    writeln!(conn, "{}", serde_json::to_string(req)?)?;
    let mut line = String::new();
    BufReader::new(conn).read_line(&mut line)?;
    Ok(())
}

// MARK: Installing

fn home() -> Result<PathBuf> {
    Ok(PathBuf::from(std::env::var("HOME").context("HOME not set")?))
}

fn config_path(agent: &str) -> Result<PathBuf> {
    Ok(match agent {
        "claude" => home()?.join(".claude/settings.json"),
        "codex" => home()?.join(".codex/hooks.json"),
        _ => bail!("unknown agent {agent} (expected claude or codex)"),
    })
}

/// A stable path for the hook command, so moving or rebuilding Tern.app
/// doesn't break installed hooks (or Codex's trust in them).
pub fn stable_binary() -> Result<PathBuf> {
    Ok(home()?.join("Library/Application Support/tern/bin/tern"))
}

/// Points the stable path at this binary.
pub fn link_binary() -> Result<PathBuf> {
    crate::prepare_runtime_dir()?;
    let link = stable_binary()?;
    let exe = std::env::current_exe()?.canonicalize()?;
    if std::fs::read_link(&link).ok().as_deref() == Some(exe.as_path()) {
        return Ok(link);
    }
    std::fs::create_dir_all(link.parent().unwrap())?;
    let _ = std::fs::remove_file(&link);
    std::os::unix::fs::symlink(&exe, &link)?;
    Ok(link)
}

fn command(agent: &str) -> Result<String> {
    Ok(format!("\"{}\" hook {agent}", stable_binary()?.display()))
}

fn is_ours(group: &Value, agent: &str) -> bool {
    group["hooks"].as_array().is_some_and(|hs| {
        hs.iter().any(|h| {
            h["command"].as_str().is_some_and(|c| c.contains("/tern/bin/tern\"") && c.ends_with(&format!("hook {agent}")))
        })
    })
}

fn statusline_command() -> Result<String> {
    Ok(format!("\"{}\" statusline", stable_binary()?.display()))
}

fn is_our_statusline(config: &Map<String, Value>) -> bool {
    config.get("statusLine").and_then(|s| s["command"].as_str()).is_some_and(|c| c.contains("/tern/bin/tern\" statusline"))
}

/// Makes `tern statusline` Claude Code's status line, keeping any the user had to run after it.
fn install_statusline(config: &mut Map<String, Value>) -> Result<()> {
    if !is_our_statusline(config) {
        if let Some(previous) = config.get("statusLine") {
            let saved = crate::usage::saved_statusline_file();
            std::fs::create_dir_all(saved.parent().unwrap())?;
            std::fs::write(&saved, json!({ "statusLine": previous }).to_string())?;
        }
    }
    config.insert("statusLine".into(), json!({ "type": "command", "command": statusline_command()?, "padding": 0 }));
    Ok(())
}

/// Puts back the user's own status line, if they had one.
fn uninstall_statusline(config: &mut Map<String, Value>) -> bool {
    if !is_our_statusline(config) {
        return false;
    }
    let saved = crate::usage::saved_statusline_file();
    let previous = std::fs::read(&saved).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok());
    match previous.map(|p| p["statusLine"].clone()).filter(|p| !p.is_null()) {
        Some(p) => config.insert("statusLine".into(), p),
        None => config.remove("statusLine"),
    };
    let _ = std::fs::remove_file(saved);
    true
}

fn read_config(path: &Path) -> Result<Map<String, Value>> {
    match std::fs::read_to_string(path) {
        Ok(text) if !text.trim().is_empty() => match serde_json::from_str(&text)? {
            Value::Object(m) => Ok(m),
            _ => bail!("{} is not a JSON object", path.display()),
        },
        Ok(_) => Ok(Map::new()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Map::new()),
        Err(e) => Err(e.into()),
    }
}

fn write_config(path: &Path, config: &Map<String, Value>) -> Result<()> {
    if path.exists() {
        std::fs::copy(path, path.with_extension("json.tern-backup"))?;
    }
    std::fs::create_dir_all(path.parent().unwrap())?;
    let tmp = path.with_extension("json.tern-tmp");
    std::fs::write(&tmp, serde_json::to_string_pretty(config)? + "\n")?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

/// Removes our hook groups from a config, returning whether any were there.
fn strip(config: &mut Map<String, Value>, agent: &str) -> bool {
    let Some(Value::Object(hooks)) = config.get_mut("hooks") else { return false };
    let mut found = false;
    for groups in hooks.values_mut() {
        if let Value::Array(gs) = groups {
            let before = gs.len();
            gs.retain(|g| !is_ours(g, agent));
            found |= gs.len() != before;
        }
    }
    hooks.retain(|_, v| !v.as_array().is_some_and(Vec::is_empty));
    if hooks.is_empty() {
        config.remove("hooks");
    }
    found
}

pub fn install(agent: &str) -> Result<PathBuf> {
    link_binary()?;
    let path = config_path(agent)?;
    let mut config = read_config(&path)?;
    strip(&mut config, agent);
    let cmd = command(agent)?;
    let hooks = config.entry("hooks").or_insert_with(|| json!({}));
    let Value::Object(hooks) = hooks else { bail!("\"hooks\" in {} is not an object", path.display()) };
    for event in events(agent) {
        let groups = hooks.entry(*event).or_insert_with(|| json!([]));
        let Value::Array(groups) = groups else { bail!("hooks.{event} in {} is not a list", path.display()) };
        // Codex caps some events at 3s and warns above that; the hook takes a few ms anyway.
        groups.push(json!({ "hooks": [{ "type": "command", "command": cmd, "timeout": 3 }] }));
    }
    if agent == "claude" {
        install_statusline(&mut config)?;
    }
    write_config(&path, &config)?;
    Ok(path)
}

pub fn uninstall(agent: &str) -> Result<PathBuf> {
    let path = config_path(agent)?;
    let mut config = read_config(&path)?;
    let statusline = agent == "claude" && uninstall_statusline(&mut config);
    if strip(&mut config, agent) || statusline {
        if config.is_empty() && agent == "codex" {
            // hooks.json held only our hooks, so we created it; leave no trace.
            std::fs::remove_file(&path)?;
            let _ = std::fs::remove_file(path.with_extension("json.tern-backup"));
        } else {
            write_config(&path, &config)?;
        }
    }
    Ok(path)
}

/// Which of the agent's events carry our hook.
fn hooked_events(agent: &str, config: &Map<String, Value>) -> Vec<&'static str> {
    events(agent)
        .iter()
        .copied()
        .filter(|e| {
            config.get("hooks").and_then(|h| h.get(*e)).and_then(Value::as_array).is_some_and(|gs| gs.iter().any(|g| is_ours(g, agent)))
        })
        .collect()
}

/// Whether our hooks are installed (from this or an older tern), whether they
/// cover every event this tern uses, and whether the agent is installed at all.
pub fn status(agent: &str) -> Result<Value> {
    let path = config_path(agent)?;
    let config = read_config(&path).unwrap_or_default();
    let hooked = hooked_events(agent, &config).len();
    let agent_dir = path.parent().is_some_and(Path::exists);
    Ok(json!({
        "agent": agent,
        "installed": hooked > 0,
        "current": is_current(agent, &config),
        "available": agent_dir,
        "config": path,
    }))
}

/// Every event hooked, and for Claude Code the status line that reports usage limits.
fn is_current(agent: &str, config: &Map<String, Value>) -> bool {
    hooked_events(agent, config).len() == events(agent).len() && (agent != "claude" || is_our_statusline(config))
}

/// Brings hooks an older tern installed up to this tern's events. Hooks that
/// were never installed stay that way. Returns the agents updated.
pub fn update_installed() -> Vec<&'static str> {
    AGENTS
        .into_iter()
        .filter(|a| {
            let Ok(path) = config_path(a) else { return false };
            let Ok(config) = read_config(&path) else { return false };
            !hooked_events(a, &config).is_empty() && !is_current(a, &config) && install(a).is_ok()
        })
        .collect()
}
