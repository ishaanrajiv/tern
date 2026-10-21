//! Claude Code's usage limits. Claude Code hands them only to its status line
//! command, so tern installs `tern statusline` as that command (with its hooks).
//! It records the limits for the app and prints nothing, or runs the status
//! line the user had before and prints what that prints.

use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};

use serde_json::{json, Value};

use crate::runtime_dir;

/// Where the last reported limits go; the app reads it.
pub fn claude_usage_file() -> PathBuf {
    runtime_dir().join("usage/claude.json")
}

/// The status line the user had before tern's, kept to run after ours and to put back.
pub fn saved_statusline_file() -> PathBuf {
    runtime_dir().join("claude-statusline.json")
}

/// `tern statusline`: never fails loudly; a broken status line would show in Claude Code.
pub fn run_statusline() {
    let mut raw = Vec::new();
    let _ = std::io::stdin().take(4 << 20).read_to_end(&mut raw);
    if let Ok(input) = serde_json::from_slice::<Value>(&raw) {
        record(&input);
    }
    if let Some(command) = saved_command() {
        let child = Command::new("/bin/sh")
            .arg("-c")
            .arg(&command)
            .stdin(Stdio::piped())
            .stdout(Stdio::inherit())
            .stderr(Stdio::null())
            .spawn();
        if let Ok(mut child) = child {
            if let Some(mut stdin) = child.stdin.take() {
                let _ = stdin.write_all(&raw);
            }
            let _ = child.wait();
        }
    }
}

fn record(input: &Value) {
    let limits = &input["rate_limits"];
    let window = |key: &str| {
        let w = &limits[key];
        Some(json!({ "used_percent": w["used_percentage"].as_f64()?, "resets_at": w["resets_at"].as_f64()? }))
    };
    let (five_hour, seven_day) = (window("five_hour"), window("seven_day"));
    if five_hour.is_none() && seven_day.is_none() {
        return;
    }
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs());
    let record = json!({ "five_hour": five_hour, "seven_day": seven_day, "updated_at": now });
    let path = claude_usage_file();
    // The status line runs after every message; skip the write when nothing moved.
    let same = std::fs::read(&path)
        .ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        .is_some_and(|old| old["five_hour"] == record["five_hour"] && old["seven_day"] == record["seven_day"]);
    if same {
        return;
    }
    let _ = std::fs::create_dir_all(path.parent().unwrap());
    let tmp = path.with_extension("json.tmp");
    if std::fs::write(&tmp, record.to_string()).is_ok() {
        let _ = std::fs::rename(&tmp, &path);
    }
}

fn saved_command() -> Option<String> {
    let saved: Value = serde_json::from_slice(&std::fs::read(saved_statusline_file()).ok()?).ok()?;
    let line = &saved["statusLine"];
    (line["type"].as_str() == Some("command")).then(|| line["command"].as_str().map(str::to_string)).flatten()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ignores_input_without_limits() {
        // No rate_limits: nothing to record, and no panic.
        record(&json!({ "model": { "id": "x" } }));
    }
}
