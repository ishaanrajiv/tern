//! Commands for agents and scripts to drive tern's panes: split, tab, send, capture,
//! wait, close and run. Each takes a target, the pane the command runs in by default:
//!
//!   --pane ID|NAME|@focused    a pane by id, by the name it was given with --name, or the one in front
//!   --tab ID|NAME              that tab's focused pane
//!
//! Exit codes: 0 done, 1 failed, 2 bad arguments, 3 no such pane or tab, 4 the name
//! matches more than one, 5 timed out. `run` exits with its command's code instead.

use std::io::BufRead;
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use serde::de::DeserializeOwned;
use tern::*;

use super::request;

pub const USAGE: &str = "\
tern split [right|down] [target] [--name N] [--cwd DIR] [--focus] [-- CMD...]
       tern tab [DIR] [target] [--name N] [--focus] [-- CMD...]
       tern send [target] [--no-enter] TEXT...
       tern capture [target] [--lines N] [--last-command]
       tern wait [target] --prompt|--exit|--text REGEX|--state STATE [--timeout SECS]
       tern close [target]
       tern run [--tab] [--keep] [--cwd DIR] [--timeout SECS] -- CMD...
       target: --pane ID|NAME|@focused or --tab ID|NAME (default: this pane)";

const NOT_FOUND: i32 = 3;
const AMBIGUOUS: i32 = 4;
const TIMED_OUT: i32 = 5;

/// A usage mistake, reported with exit code 2.
#[derive(Debug)]
struct Usage(String);

impl std::fmt::Display for Usage {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result { write!(f, "{}\nusage: {USAGE}", self.0) }
}

impl std::error::Error for Usage {}

fn usage<T>(message: impl Into<String>) -> Result<T> { Err(Usage(message.into()).into()) }

pub fn is_usage(e: &anyhow::Error) -> bool { e.downcast_ref::<Usage>().is_some() }

/// Options common to every command, and what's left once they're taken.
#[derive(Debug, Default, PartialEq)]
struct Args {
    target: Target,
    name: Option<String>,
    cwd: Option<String>,
    focus: bool,
    /// After `--`: one argument is a shell line as it is; several are quoted and joined.
    command: Option<String>,
    flags: Vec<String>,
    values: Vec<(String, String)>,
    words: Vec<String>,
}

impl Args {
    /// `valued` names the options that take a value, besides the common ones.
    fn parse(args: &[String], valued: &[&str]) -> Result<Args> {
        let mut out = Args { target: Target { caller: std::env::var("TERN_SESSION_ID").ok().filter(|id| !id.is_empty()), ..Default::default() }, ..Default::default() };
        let mut i = 0;
        while i < args.len() {
            let arg = args[i].as_str();
            let mut value = || -> Result<String> {
                i += 1;
                match args.get(i) { Some(v) => Ok(v.clone()), None => usage(format!("{arg} needs a value")) }
            };
            match arg {
                "--pane" => out.target.pane = Some(value()?),
                "--tab" if valued.contains(&"--tab") => out.target.tab = Some(value()?),
                "--name" => out.name = Some(value()?),
                "--cwd" => out.cwd = Some(absolute(&value()?)?),
                "--focus" => out.focus = true,
                "--" => {
                    let rest = &args[i + 1..];
                    if rest.is_empty() { return usage("expected a command after --") }
                    out.command = Some(if rest.len() == 1 { rest[0].clone() } else { rest.iter().map(|a| shell_quote(a)).collect::<Vec<_>>().join(" ") });
                    break;
                }
                a if valued.contains(&a) => { let v = value()?; out.values.push((a.to_string(), v)) }
                a if a.starts_with("--") => out.flags.push(a.to_string()),
                _ => out.words.push(arg.to_string()),
            }
            i += 1;
        }
        Ok(out)
    }

    fn flag(&self, name: &str) -> bool { self.flags.iter().any(|f| f == name) }

    fn value(&self, name: &str) -> Option<&str> { self.values.iter().rev().find(|(k, _)| k == name).map(|(_, v)| v.as_str()) }

    fn only(&self, flags: &[&str]) -> Result<()> {
        match self.flags.iter().find(|f| !flags.contains(&f.as_str())) {
            Some(f) => usage(format!("unknown option {f}")),
            None => Ok(()),
        }
    }

    fn open(&self) -> OpenPane {
        OpenPane {
            cwd: self.cwd.clone(),
            line: self.command.clone(),
            name: self.name.clone(),
            focus: self.focus,
            env: std::env::vars().filter(|(k, _)| k != "TERN_SESSION_ID").collect(),
        }
    }
}

fn absolute(path: &str) -> Result<String> {
    let path = std::path::Path::new(path);
    let path = if path.is_absolute() { path.to_path_buf() } else { std::env::current_dir()?.join(path) };
    Ok(path.canonicalize().with_context(|| format!("no folder {}", path.display()))?.display().to_string())
}

fn ask<T: DeserializeOwned>(req: &Request) -> Result<T> {
    let (_sock, mut reader) = request(req)?;
    let mut line = String::new();
    reader.read_line(&mut line)?;
    serde_json::from_str(&line).context("reading ternd's reply")
}

/// The pane, or the exit code saying why there's none.
fn pane(reply: PaneReply) -> Result<std::result::Result<PaneReply, i32>> {
    if reply.ok { return Ok(Ok(reply)) }
    eprintln!("tern: {}", reply.error.unwrap_or_else(|| "failed".into()));
    Ok(Err(match reply.reason.as_deref() {
        Some("not_found") => NOT_FOUND,
        Some("ambiguous") => AMBIGUOUS,
        _ => 1,
    }))
}

fn resolve(target: &Target) -> Result<std::result::Result<String, i32>> {
    Ok(pane(ask(&Request::Resolve { target: target.clone() })?)?.map(|r| r.pane.unwrap_or_default()))
}

fn sessions() -> Result<Vec<SessionInfo>> { ask(&Request::List) }

pub fn split(args: &[String]) -> Result<i32> {
    let a = Args::parse(args, &["--tab"])?;
    a.only(&["--focus"])?;
    let direction = match a.words.as_slice() {
        [] => "right".to_string(),
        [d] if d == "right" || d == "down" => d.clone(),
        _ => return usage("split right or down"),
    };
    let reply = ask(&Request::Split { target: a.target.clone(), direction, open: a.open() })?;
    Ok(match pane(reply)? { Ok(r) => { println!("{}", r.pane.unwrap_or_default()); 0 } Err(code) => code })
}

pub fn tab(args: &[String]) -> Result<i32> {
    let a = Args::parse(args, &["--tab"])?;
    a.only(&["--focus"])?;
    let folder = match a.words.as_slice() {
        [] => None,
        [dir] => Some(absolute(dir)?),
        _ => return usage("only one folder"),
    };
    // Outside tern with no folder, the tab opens where the command runs.
    let folder = folder.or_else(|| a.target.caller.is_none().then(|| std::env::current_dir().ok().map(|d| d.display().to_string())).flatten());
    let reply = ask(&Request::NewTab { target: a.target.clone(), folder, open: a.open() })?;
    Ok(match pane(reply)? { Ok(r) => { println!("{}", r.pane.unwrap_or_default()); 0 } Err(code) => code })
}

pub fn send(args: &[String]) -> Result<i32> {
    let a = Args::parse(args, &["--tab"])?;
    a.only(&["--no-enter"])?;
    let mut text = a.words.join(" ");
    if let Some(command) = &a.command { text = if text.is_empty() { command.clone() } else { format!("{text} {command}") } }
    if text.is_empty() && a.flag("--no-enter") { return usage("nothing to send") }
    if !a.flag("--no-enter") { text.push('\r') }
    let id = match resolve(&a.target)? { Ok(id) => id, Err(code) => return Ok(code) };
    let reply: serde_json::Value = ask(&Request::Input { id: id.clone(), data: text })?;
    if reply["ok"] != true { bail!("pane {id} has no running session") }
    Ok(0)
}

pub fn capture(args: &[String]) -> Result<i32> {
    let a = Args::parse(args, &["--tab", "--lines"])?;
    a.only(&["--last-command"])?;
    let lines = a.value("--lines").map(|n| n.parse::<usize>()).transpose().or_else(|_| usage("--lines needs a number"))?;
    let id = match resolve(&a.target)? { Ok(id) => id, Err(code) => return Ok(code) };
    print!("{}", text(&id, a.flag("--last-command"), lines)?);
    Ok(0)
}

/// A pane's screen and history as plain text, or its last command's output; the last `lines` lines only, if given.
fn text(id: &str, last_command: bool, lines: Option<usize>) -> Result<String> {
    let reply: serde_json::Value = ask(&Request::ReadOutput { id: id.into(), last_command })?;
    if reply["ok"] != true { bail!("pane {id} has no running session") }
    let text = reply["text"].as_str().unwrap_or_default().trim_end();
    let all: Vec<&str> = text.lines().collect();
    let keep = lines.map_or(all.len(), |n| n.min(all.len()));
    let mut out = all[all.len() - keep..].join("\n");
    if !out.is_empty() { out.push('\n') }
    Ok(out)
}

enum Until {
    /// Back at a prompt, with nothing typed since the last command finished.
    Prompt,
    Exit,
    Text(regex_lite::Regex),
    State(String),
}

pub fn wait(args: &[String]) -> Result<i32> {
    let a = Args::parse(args, &["--tab", "--text", "--state", "--timeout"])?;
    a.only(&["--prompt", "--exit"])?;
    let mut until = Vec::new();
    if a.flag("--prompt") { until.push(Until::Prompt) }
    if a.flag("--exit") { until.push(Until::Exit) }
    if let Some(pattern) = a.value("--text") {
        until.push(Until::Text(line_pattern(pattern)?));
    }
    if let Some(state) = a.value("--state") {
        let state = state.replace('-', "_");
        if !["idle", "working", "needs_you", "done", "failed"].contains(&state.as_str()) {
            return usage("--state is idle, working, needs-you, done or failed");
        }
        until.push(Until::State(state));
    }
    let [until] = until.as_slice() else { return usage("wait for one of --prompt, --exit, --text or --state") };
    let timeout = timeout(&a)?;
    let id = match resolve(&a.target)? { Ok(id) => id, Err(code) => return Ok(code) };
    let met = |s: Option<&SessionInfo>| -> Result<Option<bool>> {
        Ok(Some(match (until, s) {
            (Until::Exit, s) => s.is_none(),
            (_, None) => return Ok(None),
            (Until::Prompt, Some(s)) => at_prompt(s),
            (Until::State(state), Some(s)) => s.agent_state.and_then(|st| serde_json::to_value(st).ok()).is_some_and(|v| v == state.as_str()),
            (Until::Text(re), Some(_)) => re.is_match(&text(&id, false, None)?),
        }))
    };
    poll(timeout, || match met(sessions()?.iter().find(|s| s.id == id))? {
        Some(done) => Ok(done.then_some(0)),
        None => { eprintln!("tern: pane {id} ended"); Ok(Some(1)) }
    })
}

/// A `--text` pattern, where ^ and $ match at each line, as the screen shows them.
fn line_pattern(pattern: &str) -> Result<regex_lite::Regex> {
    regex_lite::Regex::new(&format!("(?m){pattern}")).or_else(|e| usage(format!("--text: {e}")))
}

fn timeout(a: &Args) -> Result<Option<Duration>> {
    a.value("--timeout").map(|t| t.parse::<f64>().ok().filter(|t| *t >= 0.0).map(Duration::from_secs_f64))
        .map(|t| t.map_or_else(|| usage("--timeout needs seconds"), Ok)).transpose()
}

/// Calls `check` every fifth of a second until it gives an exit code, or the time is up.
fn poll(timeout: Option<Duration>, mut check: impl FnMut() -> Result<Option<i32>>) -> Result<i32> {
    let start = Instant::now();
    loop {
        if let Some(code) = check()? { return Ok(code) }
        if timeout.is_some_and(|t| start.elapsed() >= t) {
            eprintln!("tern: timed out");
            return Ok(TIMED_OUT);
        }
        std::thread::sleep(Duration::from_millis(200));
    }
}

fn at_prompt(s: &SessionInfo) -> bool { !s.command_running && s.finished_ms >= s.input_ms }

pub fn close(args: &[String]) -> Result<i32> {
    let a = Args::parse(args, &["--tab"])?;
    a.only(&[])?;
    Ok(match pane(ask(&Request::Close { target: a.target })?)? { Ok(_) => 0, Err(code) => code })
}

/// Runs a command in a pane beside this one (or a new tab), prints what it printed and
/// exits with its code. The pane closes afterwards unless `--keep`.
pub fn run(args: &[String]) -> Result<i32> {
    let a = Args::parse(args, &["--timeout"])?;
    a.only(&["--tab", "--keep"])?;
    if a.command.is_none() { return usage("run needs a command after --") }
    let timeout = timeout(&a)?;
    let in_tab = a.flag("--tab") || a.target.caller.is_none();
    let mut open = a.open();
    if open.cwd.is_none() { open.cwd = std::env::current_dir().ok().map(|d| d.display().to_string()) }
    let reply = if in_tab {
        ask(&Request::NewTab { target: a.target.clone(), folder: open.cwd.clone(), open })?
    } else {
        ask(&Request::Split { target: a.target.clone(), direction: "right".into(), open })?
    };
    let id = match pane(reply)? { Ok(r) => r.pane.unwrap_or_default(), Err(code) => return Ok(code) };
    let mut code = None;
    let waited = poll(timeout, || {
        let Some(s) = sessions()?.into_iter().find(|s| s.id == id) else { return Ok(Some(1)) };
        // Typed, then finished.
        if s.input_ms > 0 && at_prompt(&s) && s.finished_ms > 0 {
            code = Some(s.exit_code.unwrap_or(0));
            return Ok(Some(0));
        }
        Ok(None)
    })?;
    if code.is_some() { print!("{}", text(&id, true, None)?) }
    if !a.flag("--keep") && waited != TIMED_OUT {
        let _: PaneReply = ask(&Request::Close { target: Target { pane: Some(id.clone()), ..Default::default() } })?;
    } else {
        eprintln!("tern: the command is in pane {id}");
    }
    Ok(code.unwrap_or(waited))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<String> { list.iter().map(|s| s.to_string()).collect() }

    #[test]
    fn options_targets_and_the_command_are_split_apart() {
        let a = Args::parse(&args(&["down", "--pane", "tests", "--name", "server", "--focus", "--", "npm", "run", "dev it"]), &["--tab"]).unwrap();
        assert_eq!(a.words, ["down"]);
        assert_eq!(a.target.pane.as_deref(), Some("tests"));
        assert_eq!(a.name.as_deref(), Some("server"));
        assert!(a.focus);
        assert_eq!(a.command.as_deref(), Some("npm run 'dev it'"));
    }

    #[test]
    fn one_argument_after_the_dashes_is_a_shell_line() {
        let a = Args::parse(&args(&["--", "cargo test && echo ok"]), &[]).unwrap();
        assert_eq!(a.command.as_deref(), Some("cargo test && echo ok"));
    }

    #[test]
    fn mistakes_are_usage_errors() {
        assert!(is_usage(&Args::parse(&args(&["--pane"]), &[]).unwrap_err()));
        assert!(is_usage(&Args::parse(&args(&["--"]), &[]).unwrap_err()));
        let a = Args::parse(&args(&["--bogus"]), &[]).unwrap();
        assert!(is_usage(&a.only(&[]).unwrap_err()));
    }

    #[test]
    fn text_patterns_anchor_at_lines() {
        assert!(line_pattern("^ready$").unwrap().is_match("$ echo ready\nready\n$ "));
        assert!(!line_pattern("^ready$").unwrap().is_match("$ echo ready\n"));
        assert!(is_usage(&line_pattern("(").unwrap_err()));
    }

    #[test]
    fn a_prompt_counts_only_once_whats_typed_has_finished() {
        let mut s: SessionInfo = serde_json::from_value(serde_json::json!({
            "id": "p", "pid": 1, "cols": 80, "rows": 24, "clients": 0, "cwd": null, "process": "zsh",
            "title": "", "git_root": null, "branch": null, "last_output_ms": 0, "bells": 0,
        })).unwrap();
        assert!(at_prompt(&s));
        s.input_ms = 10;
        assert!(!at_prompt(&s));
        s.finished_ms = 12;
        s.command_running = true;
        assert!(!at_prompt(&s));
        s.command_running = false;
        assert!(at_prompt(&s));
    }
}
