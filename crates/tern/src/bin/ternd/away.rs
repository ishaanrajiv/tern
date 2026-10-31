//! Telling you about events while you're away from the Mac, through ntfy.
//!
//! You're away when tern isn't the app in front and either the screen is locked or there
//! has been no keyboard or mouse input for a while (`away-after`, two minutes by default).
//! Only a title is sent, like "Claude Code needs you · api": never what the agent said,
//! since the push service sees it.

use std::process::{Command, Stdio};

use tern::config::Config;
use tern::Event;

const BUNDLE_ID: &str = "dev.tern.Tern";
/// Events pushed when `notify-events` doesn't say.
const DEFAULT_EVENTS: &[&str] = &["needs-you", "done", "failed"];

#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    fn CGEventSourceSecondsSinceLastEventType(state: i32, event_type: u32) -> f64;
}

/// Seconds since the last keyboard, mouse or trackpad input anywhere in the session.
fn idle_seconds() -> f64 {
    // kCGEventSourceStateHIDSystemState and kCGAnyInputEventType.
    unsafe { CGEventSourceSecondsSinceLastEventType(1, u32::MAX) }
}

fn output(program: &str, args: &[&str]) -> Option<String> {
    let out = Command::new(program).args(args).stderr(Stdio::null()).output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

/// The console session says its screen is locked.
fn screen_locked() -> bool {
    output("/usr/sbin/ioreg", &["-n", "Root", "-d1", "-a"]).is_some_and(|plist| locked_in(&plist))
}

fn locked_in(plist: &str) -> bool {
    let compact: String = plist.split_whitespace().collect();
    compact.contains("<key>CGSSessionScreenIsLocked</key><true/>")
}

fn tern_in_front() -> bool {
    let Some(front) = output("/usr/bin/lsappinfo", &["front"]) else { return false };
    output("/usr/bin/lsappinfo", &["info", "-only", "bundleid", front.trim()]).is_some_and(|info| info.contains(BUNDLE_ID))
}

/// Whether you're away now, by the config's `away-after` (seconds).
pub fn away(config: &Config) -> bool {
    let after = config.get("away-after").and_then(|s| s.parse::<f64>().ok()).filter(|s| *s >= 0.0).unwrap_or(120.0);
    !tern_in_front() && (screen_locked() || idle_seconds() >= after)
}

/// Whether the config wants `event` pushed while away.
fn wanted(config: &Config, event: &str) -> bool {
    match config.get("notify-events") {
        Some(list) => list.split(',').map(str::trim).any(|e| e == event),
        None => DEFAULT_EVENTS.contains(&event),
    }
}

/// "Claude Code needs you · api", naming nothing the agent or command said.
pub fn title(e: &Event) -> String {
    let who = match e.agent.as_deref() {
        Some("claude") => "Claude Code".to_string(),
        Some("codex") => "Codex".to_string(),
        Some(other) => other.to_string(),
        None => e.program.clone().unwrap_or_else(|| "A command".into()),
    };
    let what = match e.event.as_str() {
        "needs-you" => "needs you",
        "done" | "command-done" => "is done",
        "failed" | "command-failed" => "failed",
        "working" => "is working",
        "bell" => "rang the bell",
        "start" => "started",
        "exit" => "ended",
        other => other,
    };
    let folder = e.folder.as_deref().and_then(|f| std::path::Path::new(f).file_name()).map(|n| n.to_string_lossy().into_owned());
    match folder {
        Some(folder) => format!("{who} {what} · {folder}"),
        None => format!("{who} {what}"),
    }
}

/// Pushes the event's title to the `notify-ntfy` topic if it's wanted.
pub fn push(config: &Config, e: &Event) {
    let Some(url) = config.get("notify-ntfy") else { return };
    if !wanted(config, &e.event) { return }
    if !(url.starts_with("https://") || url.starts_with("http://")) {
        eprintln!("notify-ntfy must be an http(s) URL, like https://ntfy.sh/your-topic");
        return;
    }
    let mut curl = Command::new("/usr/bin/curl");
    curl.args(["-fsS", "-m", "10", "-H", "Tags: tern", "--data-binary", &title(e), "--", url]).stdin(Stdio::null()).stdout(Stdio::null());
    match curl.spawn() {
        Ok(mut child) => { std::thread::spawn(move || {
            if child.wait().is_ok_and(|s| !s.success()) { eprintln!("pushing to ntfy failed") }
        }); }
        Err(e) => eprintln!("pushing to ntfy: {e}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn titles_say_who_and_where_but_not_what_was_said() {
        let e = Event { event: "needs-you".into(), agent: Some("claude".into()), folder: Some("/dev/api".into()),
                        message: Some("Run rm -rf /secret?".into()), ..Default::default() };
        assert_eq!(title(&e), "Claude Code needs you · api");
        let e = Event { event: "failed".into(), program: Some("cargo".into()), ..Default::default() };
        assert_eq!(title(&e), "cargo failed");
        let e = Event { event: "command-failed".into(), command: Some("deploy --token abc".into()), ..Default::default() };
        assert_eq!(title(&e), "A command failed");
    }

    #[test]
    fn events_pushed_by_default_and_by_choice() {
        let none = Config::default();
        assert!(wanted(&none, "needs-you") && wanted(&none, "done") && wanted(&none, "failed"));
        assert!(!wanted(&none, "bell"));
        let some = Config::parse("notify-events = needs-you, command-failed\n");
        assert!(wanted(&some, "command-failed"));
        assert!(!wanted(&some, "done"));
    }

    #[test]
    fn a_locked_screen_reads_from_the_console_plist() {
        assert!(locked_in("<dict>\n\t<key>CGSSessionScreenIsLocked</key>\n\t<true/>\n</dict>"));
        assert!(!locked_in("<dict><key>CGSSessionScreenIsLocked</key><false/></dict>"));
        assert!(!locked_in("<dict></dict>"));
    }

    #[test]
    fn idle_time_comes_back() {
        assert!(idle_seconds() >= 0.0);
    }
}
