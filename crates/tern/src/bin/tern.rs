//! tern: command-line client for ternd.
//!
//!   tern attach [--cwd DIR] [--cmd CMD] [--init LINE] <id>
//!                                              relay this terminal to a session (creating it if needed;
//!                                              --init types LINE into a new session's shell)
//!   tern ls [--json]                           list sessions (with --json, every window's tabs and panes too)
//!   tern split|tab|send|capture|wait|close|run drive panes from a script or agent (see agent.rs)
//!   tern kill <id>                             hang up a session
//!   tern daemon [status|restart]              whether the running ternd matches this tern (JSON);
//!                                              restart it, saving screens first
//!   tern bench [iterations]                    keystroke round-trip: direct PTY vs through ternd
//!   tern hooks [status|install|uninstall|link] [claude|codex]
//!                                              manage agent hooks (link also updates installed ones)
//!   tern hook <agent>                          (run by the agents) report agent state
//!   tern statusline                            (run by Claude Code) record its usage limits

use std::fs::File;
use std::io::{BufRead, BufReader, Read, Write};
use std::mem::ManuallyDrop;
use std::os::fd::{AsFd, FromRawFd};
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use nix::poll::{poll, PollFd, PollFlags, PollTimeout};
use nix::pty::{openpty, Winsize};
use nix::sys::termios::{self, SetArg, Termios};
use tern::*;

#[path = "tern/agent.rs"]
mod agent;

nix::ioctl_read_bad!(get_winsize, nix::libc::TIOCGWINSZ, Winsize);

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("open") => tern::open::run(&args[1..]),
        Some(".") => tern::open::run(&args),
        Some("attach") => attach(&args[1..]),
        Some("ls") => list(args.get(1).is_some_and(|a| a == "--json")),
        Some("kill") => kill(&args[1..]),
        Some("split") => agent::split(&args[1..]),
        Some("tab") => agent::tab(&args[1..]),
        Some("send") => agent::send(&args[1..]),
        Some("capture") => agent::capture(&args[1..]),
        Some("wait") => agent::wait(&args[1..]),
        Some("close") => agent::close(&args[1..]),
        Some("run") => agent::run(&args[1..]),
        Some("daemon") => daemon(args.get(1).map_or("status", String::as_str)),
        Some("bench") => bench(&args[1..]),
        Some("hook") => {
            hooks::run_hook(args.get(1).map_or("claude", String::as_str));
            Ok(0)
        }
        Some("hooks") => manage_hooks(&args[1..]),
        Some("statusline") => {
            usage::run_statusline();
            Ok(0)
        }
        _ => {
            eprintln!(
                "usage: tern open [DIR] [--window | --split right|down] [--command CMD | -- ARGS...]\n       tern attach [--cwd DIR] [--cmd CMD] <id> | tern ls [--json] | tern kill <id> | tern bench [n]\n       \
                 tern daemon [status|restart]\n       \
                 tern hooks [status|install|uninstall|link] [claude|codex]\n       {}",
                agent::USAGE
            );
            std::process::exit(2);
        }
    };
    match result {
        Ok(code) => std::process::exit(code),
        Err(e) => {
            eprintln!("tern: {e:#}");
            std::process::exit(if agent::is_usage(&e) { 2 } else { 1 });
        }
    }
}

fn manage_hooks(args: &[String]) -> Result<i32> {
    let action = args.first().map_or("status", String::as_str);
    let agents: Vec<&str> = match args.get(1) {
        Some(a) => vec![a.as_str()],
        None => hooks::AGENTS.to_vec(),
    };
    match action {
        "status" => {
            let all: Vec<_> = agents.iter().map(|a| hooks::status(a)).collect::<Result<_>>()?;
            println!("{}", serde_json::to_string(&all)?);
        }
        "install" => {
            for a in agents {
                println!("{a}: hooks installed in {}", hooks::install(a)?.display());
                if a == "codex" {
                    println!("codex: run /hooks inside Codex once to trust them");
                }
            }
        }
        "uninstall" => {
            for a in agents {
                println!("{a}: hooks removed from {}", hooks::uninstall(a)?.display());
            }
        }
        "link" => {
            println!("{}", hooks::link_binary()?.display());
            for a in hooks::update_installed() {
                println!("{a}: hooks updated to this tern's events");
            }
        }
        _ => bail!("unknown hooks action {action}"),
    }
    Ok(0)
}

const LAUNCHD_LABEL: &str = "dev.tern.ternd";

/// Connects to ternd, starting it next to this binary if it isn't running.
fn connect() -> Result<UnixStream> {
    let path = socket_path();
    if let Ok(s) = UnixStream::connect(&path) {
        return Ok(s);
    }
    let ternd = std::env::current_exe()?.with_file_name("ternd");
    prepare_runtime_dir()?;
    // One client starts ternd at a time: panes reconnecting together after a
    // restart would otherwise boot out each other's fresh daemon.
    let lock = File::options().create(true).truncate(false).write(true).open(runtime_dir().join("ternd.lock"))?;
    let _locked = nix::fcntl::Flock::lock(lock, nix::fcntl::FlockArg::LockExclusive).map_err(|(_, e)| e)?;
    if let Ok(s) = UnixStream::connect(&path) {
        return Ok(s);
    }
    if std::env::var_os("TERN_RUNTIME_DIR").is_some() {
        // Tests and benches get a private daemon, spawned directly.
        spawn_detached(&ternd)?;
    } else {
        start_launch_agent(&ternd)?;
    }
    let deadline = Instant::now() + Duration::from_secs(3);
    while Instant::now() < deadline {
        if let Ok(s) = UnixStream::connect(&path) {
            return Ok(s);
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    bail!("ternd did not come up at {}", path.display())
}

/// Runs ternd as a per-user launchd agent. macOS kills processes attributed to
/// an app when it quits, even setsid'd ones, so the daemon must belong to launchd.
fn start_launch_agent(ternd: &std::path::Path) -> Result<()> {
    let home = std::env::var("HOME").context("HOME not set")?;
    let plist_path = std::path::PathBuf::from(&home).join(format!("Library/LaunchAgents/{LAUNCHD_LABEL}.plist"));
    let log = runtime_dir().join("ternd.log");
    let xml_escape = |s: &str| s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;");
    let plist = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>{LAUNCHD_LABEL}</string>
    <key>ProgramArguments</key><array><string>{}</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ProcessType</key><string>Interactive</string>
    <key>StandardOutPath</key><string>{log}</string>
    <key>StandardErrorPath</key><string>{log}</string>
</dict>
</plist>
"#,
        xml_escape(&ternd.display().to_string()),
        log = xml_escape(&log.display().to_string()),
    );
    std::fs::create_dir_all(plist_path.parent().unwrap())?;
    std::fs::write(&plist_path, plist)?;

    let domain = format!("gui/{}", nix::unistd::getuid());
    // Drop a stale registration (dead daemon, or one pointing at an old app path).
    let _ = Command::new("/bin/launchctl")
        .args(["bootout", &format!("{domain}/{LAUNCHD_LABEL}")])
        .stderr(Stdio::null())
        .status();
    let status = Command::new("/bin/launchctl")
        .args(["bootstrap", &domain])
        .arg(&plist_path)
        .status()
        .context("running launchctl")?;
    if !status.success() {
        bail!("launchctl bootstrap {} failed", plist_path.display());
    }
    Ok(())
}

fn spawn_detached(ternd: &std::path::Path) -> Result<()> {
    let log = File::options().create(true).append(true).open(runtime_dir().join("ternd.log"))?;
    let mut cmd = Command::new(ternd);
    cmd.stdin(Stdio::null()).stdout(log.try_clone()?).stderr(log);
    unsafe {
        cmd.pre_exec(|| nix::unistd::setsid().map(|_| ()).map_err(Into::into));
    }
    cmd.spawn().with_context(|| format!("starting {}", ternd.display()))?;
    Ok(())
}

/// How the running ternd compares with the one next to this binary.
#[derive(serde::Serialize)]
struct DaemonStatus {
    running: bool,
    /// None for a daemon from before `hello`.
    protocol: Option<u32>,
    expected_protocol: u32,
    /// Speaks this tern's protocol.
    compatible: bool,
    /// Is the build installed next to this tern; false means a restart would upgrade it.
    current: bool,
    pid: Option<u32>,
    version: Option<String>,
}

/// Asks a running ternd who it is, without starting one. `Ok(None)`: an older
/// daemon that doesn't know `hello`. `Err`: nothing listening.
fn hello() -> Result<Option<HelloReply>> {
    let mut sock = UnixStream::connect(socket_path()).context("ternd is not running")?;
    sock.set_read_timeout(Some(Duration::from_secs(2)))?;
    writeln!(sock, "{}", serde_json::to_string(&Request::Hello)?)?;
    let mut line = String::new();
    BufReader::new(sock).read_line(&mut line).ok();
    Ok(serde_json::from_str(&line).ok())
}

fn daemon_status() -> DaemonStatus {
    let installed = std::env::current_exe().ok().and_then(|exe| build_id(&exe.with_file_name("ternd")).ok());
    match hello() {
        Err(_) => DaemonStatus {
            running: false,
            protocol: None,
            expected_protocol: PROTOCOL,
            compatible: true,
            current: true,
            pid: None,
            version: None,
        },
        Ok(reply) => {
            let protocol = reply.as_ref().map(|h| h.protocol);
            let compatible = protocol == Some(PROTOCOL);
            DaemonStatus {
                running: true,
                protocol,
                expected_protocol: PROTOCOL,
                compatible,
                current: compatible && reply.as_ref().is_some_and(|h| Some(&h.build) == installed.as_ref()),
                pid: reply.as_ref().map(|h| h.pid),
                version: reply.map(|h| h.version),
            }
        }
    }
}

fn daemon(action: &str) -> Result<i32> {
    match action {
        "status" => println!("{}", serde_json::to_string(&daemon_status())?),
        "restart" => {
            restart_daemon()?;
            println!("{}", serde_json::to_string(&daemon_status())?);
        }
        _ => bail!("unknown daemon action {action}"),
    }
    Ok(0)
}

/// Stops the running ternd (it saves every screen on SIGTERM) and starts the one
/// next to this binary. Attached panes reconnect on their own.
fn restart_daemon() -> Result<()> {
    let status = daemon_status();
    if status.running {
        // An older daemon can't say its pid; it wrote it down when it started.
        let pid = match status.pid {
            Some(pid) => pid as i32,
            None => std::fs::read_to_string(runtime_dir().join("ternd.pid"))?.trim().parse().context("reading ternd.pid")?,
        };
        let name = procinfo::process_name(pid).unwrap_or_default();
        if name != "ternd" {
            bail!("pid {pid} is {name:?}, not ternd");
        }
        nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid), nix::sys::signal::Signal::SIGTERM)?;
        let deadline = Instant::now() + Duration::from_secs(10);
        while UnixStream::connect(socket_path()).is_ok() || procinfo::process_name(pid).as_deref() == Some("ternd") {
            if Instant::now() > deadline {
                bail!("ternd (pid {pid}) did not quit");
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }
    connect()?;
    Ok(())
}

fn request(req: &Request) -> Result<(UnixStream, BufReader<UnixStream>)> {
    let mut sock = connect()?;
    writeln!(sock, "{}", serde_json::to_string(req)?)?;
    let reader = BufReader::new(sock.try_clone()?);
    Ok((sock, reader))
}

fn tty_size() -> (u16, u16) {
    let mut ws = Winsize { ws_row: 0, ws_col: 0, ws_xpixel: 0, ws_ypixel: 0 };
    let ok = unsafe { get_winsize(0, &mut ws) }.is_ok() && ws.ws_col > 0 && ws.ws_row > 0;
    if ok { (ws.ws_col, ws.ws_row) } else { (80, 24) }
}

struct RawMode(Option<Termios>);

impl RawMode {
    fn enable() -> Self {
        let stdin = std::io::stdin();
        let Ok(orig) = termios::tcgetattr(stdin.as_fd()) else { return RawMode(None) };
        let mut raw = orig.clone();
        termios::cfmakeraw(&mut raw);
        let _ = termios::tcsetattr(stdin.as_fd(), SetArg::TCSANOW, &raw);
        RawMode(Some(orig))
    }
}

impl Drop for RawMode {
    fn drop(&mut self) {
        if let Some(orig) = &self.0 {
            let _ = termios::tcsetattr(std::io::stdin().as_fd(), SetArg::TCSANOW, orig);
        }
    }
}

/// Resets attributes and clears the screen and scrollback before a snapshot.
const CLEAR: &[u8] = b"\x1b[m\x1b[H\x1b[2J\x1b[3J";

fn attach(args: &[String]) -> Result<i32> {
    let (mut cwd, mut cmd, mut init, mut id) = (None, None, None, None);
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--cwd" => cwd = it.next().cloned(),
            "--cmd" => cmd = it.next().cloned(),
            "--init" => init = it.next().cloned(),
            _ => id = Some(a.clone()),
        }
    }
    let id = id.context("attach needs a session id")?;
    let cwd = cwd.or_else(|| std::env::current_dir().ok().map(|p| p.display().to_string()));
    // New sessions inherit this client's environment (PATH, SSH_AUTH_SOCK, TERM...),
    // not the launchd daemon's minimal one.
    let env: Vec<(String, String)> = std::env::vars().filter(|(k, _)| k != "TERN_SESSION_ID").collect();
    let open = |init: Option<String>| -> Result<(UnixStream, BufReader<UnixStream>)> {
        let (cols, rows) = tty_size();
        let req = Request::Attach { id: id.clone(), cols, rows, cwd: cwd.clone(), cmd: cmd.clone(), init, env: env.clone() };
        let (sock, mut reader) = request(&req)?;
        let mut line = String::new();
        reader.read_line(&mut line)?;
        let reply: AttachReply = serde_json::from_str(&line).context("bad attach reply")?;
        if !reply.ok {
            bail!("attach failed: {}", reply.error.unwrap_or_default());
        }
        Ok((sock, reader))
    };
    let (sock, mut reader) = open(init)?;

    let _raw = RawMode::enable();
    let sock_w = Arc::new(Mutex::new(sock));

    // Keystrokes -> daemon.
    let w = sock_w.clone();
    std::thread::spawn(move || {
        let mut stdin = ManuallyDrop::new(unsafe { File::from_raw_fd(0) });
        let mut buf = [0u8; 4096];
        loop {
            match stdin.read(&mut buf) {
                Ok(0) | Err(_) => break,
                // While reconnecting, keystrokes have nowhere to go and are dropped.
                Ok(n) => {
                    let _ = write_frame(&mut *w.lock().unwrap(), FRAME_INPUT, &buf[..n]);
                }
            }
        }
    });

    // Window size changes -> daemon.
    let w = sock_w.clone();
    let mut signals = signal_hook::iterator::Signals::new([signal_hook::consts::SIGWINCH])?;
    std::thread::spawn(move || {
        for _ in signals.forever() {
            let (c, r) = tty_size();
            let _ = write_frame(&mut *w.lock().unwrap(), FRAME_RESIZE, &resize_payload(c, r));
        }
    });

    // Daemon output -> this terminal. Unbuffered: every frame is written immediately.
    let mut stdout = ManuallyDrop::new(unsafe { File::from_raw_fd(1) });
    // The snapshot expects a blank terminal, but whatever started this client may
    // have written first: Ghostty runs it through login(1), which prints "Last login".
    stdout.write_all(CLEAR)?;
    let mut buf = Vec::new();
    loop {
        // A reset connection counts as ternd going away, same as a clean close.
        match read_frame(&mut reader, &mut buf, MAX_DAEMON_FRAME).unwrap_or(None) {
            Some(FRAME_OUTPUT) => stdout.write_all(&buf)?,
            Some(FRAME_EXIT) => {
                let code = buf.get(..4).map(|b| i32::from_be_bytes(b.try_into().unwrap())).unwrap_or(0);
                return Ok(code);
            }
            Some(_) => {}
            None => {
                // ternd went away (restarted, upgraded, crashed). launchd brings it back;
                // reattach, and the session returns with its saved screen.
                let deadline = Instant::now() + Duration::from_secs(10);
                let reattached = loop {
                    std::thread::sleep(Duration::from_millis(300));
                    if let Ok(pair) = open(None) {
                        break Some(pair);
                    }
                    if Instant::now() > deadline {
                        break None;
                    }
                };
                let Some((sock, r)) = reattached else {
                    drop(_raw);
                    eprintln!("\r\n[tern: lost connection to ternd]");
                    return Ok(1);
                };
                *sock_w.lock().unwrap() = sock;
                reader = r;
                // The snapshot that follows replays the whole screen and history.
                stdout.write_all(CLEAR)?;
            }
        }
    }
}

fn list(json: bool) -> Result<i32> {
    let (_sock, mut reader) = request(&Request::List)?;
    let mut line = String::new();
    reader.read_line(&mut line)?;
    let sessions: Vec<SessionInfo> = serde_json::from_str(&line)?;
    if json {
        // Windows, folders, tabs and their split panes, each pane with its session.
        let (_sock, mut reader) = request(&Request::LayoutTree)?;
        let mut tree = String::new();
        reader.read_line(&mut tree)?;
        let mut tree: serde_json::Value = serde_json::from_str(&tree)?;
        for window in tree["windows"].as_array_mut().into_iter().flatten() {
            for folder in window["folders"].as_array_mut().into_iter().flatten() {
                for tab in folder["tabs"].as_array_mut().into_iter().flatten() {
                    for pane in tab["panes"].as_array_mut().into_iter().flatten() {
                        let session = sessions.iter().find(|s| pane["id"] == s.id.as_str());
                        pane["session"] = serde_json::to_value(session)?;
                    }
                }
            }
        }
        tree["sessions"] = serde_json::to_value(&sessions)?;
        println!("{tree}");
        return Ok(0);
    }
    if sessions.is_empty() {
        println!("no sessions");
    }
    for s in sessions {
        let branch = s.branch.map(|b| format!(" ({b})")).unwrap_or_default();
        println!("{:<20} {:<10} {}x{}  {} attached  {}{branch}", s.id, s.process, s.cols, s.rows, s.clients, s.cwd.unwrap_or_default());
    }
    Ok(0)
}

fn kill(args: &[String]) -> Result<i32> {
    let id = args.first().context("kill needs a session id")?.clone();
    let (_sock, mut reader) = request(&Request::Kill { id })?;
    let mut line = String::new();
    reader.read_line(&mut line)?;
    print!("{line}");
    Ok(0)
}

/// Measures keystroke echo round trips through a PTY running `cat`, once
/// directly and once through `tern attach` + ternd, to isolate relay overhead.
fn bench(args: &[String]) -> Result<i32> {
    let iters: usize = args.first().and_then(|a| a.parse().ok()).unwrap_or(2000);
    let echo = "stty raw -echo; exec cat";
    let id = format!("bench-{}", std::process::id());

    let mut direct = Command::new("/bin/sh");
    direct.arg("-c").arg(echo);
    let d = measure(direct, iters)?;

    let mut relayed = Command::new(std::env::current_exe()?);
    relayed.args(["attach", "--cmd", echo, &id]);
    let r = measure(relayed, iters);
    let _ = request(&Request::Kill { id });
    let r = r?;

    let report = |name: &str, mut v: Vec<Duration>| {
        v.sort();
        let p = |q: f64| v[((v.len() as f64 * q) as usize).min(v.len() - 1)].as_secs_f64() * 1e6;
        let mean = v.iter().sum::<Duration>().as_secs_f64() * 1e6 / v.len() as f64;
        println!("{name:<8} p50 {:>7.1}µs  p90 {:>7.1}µs  p99 {:>7.1}µs  mean {:>7.1}µs", p(0.5), p(0.9), p(0.99), mean);
        p(0.5)
    };
    println!("keystroke echo round trip, {iters} iterations");
    let dp = report("direct", d);
    let rp = report("ternd", r);
    println!("relay overhead at p50: {:.1}µs", rp - dp);
    Ok(0)
}

fn measure(cmd: Command, iters: usize) -> Result<Vec<Duration>> {
    let ws = Winsize { ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0 };
    let pty = openpty(Some(&ws), None)?;
    // Raw from the start, so the outer line discipline never echoes our probes itself.
    let mut raw = termios::tcgetattr(pty.slave.as_fd())?;
    termios::cfmakeraw(&mut raw);
    termios::tcsetattr(pty.slave.as_fd(), SetArg::TCSANOW, &raw)?;
    let mut child = spawn_on_pty(cmd, pty.slave)?;
    let mut master = File::from(pty.master);

    let wait = |master: &File, ms: u16| -> Result<bool> {
        let mut fds = [PollFd::new(master.as_fd(), PollFlags::POLLIN)];
        Ok(poll(&mut fds, PollTimeout::from(ms))? > 0)
    };
    let mut buf = [0u8; 8192];

    // Wait until `cat` is echoing: probe with a byte that the attach snapshot never contains.
    let ready_by = Instant::now() + Duration::from_secs(5);
    'ready: loop {
        if Instant::now() > ready_by {
            bail!("echo process never became ready");
        }
        master.write_all(b"Z")?;
        while wait(&master, 100)? {
            let n = master.read(&mut buf)?;
            if buf[..n].contains(&b'Z') {
                break 'ready;
            }
        }
    }
    while wait(&master, 50)? {
        let _ = master.read(&mut buf)?;
    }

    let mut samples = Vec::with_capacity(iters);
    for i in 0..iters {
        let byte = [b'a' + (i % 26) as u8];
        let t = Instant::now();
        master.write_all(&byte)?;
        loop {
            if !wait(&master, 1000)? {
                bail!("echo timed out at iteration {i}");
            }
            if master.read(&mut buf)? > 0 {
                break;
            }
        }
        samples.push(t.elapsed());
    }
    let _ = child.kill();
    let _ = child.wait();
    Ok(samples)
}
