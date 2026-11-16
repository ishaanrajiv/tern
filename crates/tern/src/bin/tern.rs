//! tern: command-line client for ternd.
//!
//!   tern attach [--host HOST] [--cwd DIR] [--cmd CMD] [--init LINE] <id>
//!                                              relay this terminal to a session (creating it if needed;
//!                                              --init types LINE into a new session's shell; --host
//!                                              reaches a device's ternd through `tern link`)
//!   tern ls [--json] [--host HOST]             list sessions (with --json, every window's tabs and panes too)
//!   tern link HOST [--ensure|--status|--wake|--sign-in|--restart-daemon]
//!                                              hold the SSH connection to a device (see link.rs)
//!   tern proxy                                 (run over SSH by a link) carry its streams to ternd here
//!   tern split|tab|send|capture|wait|close|run drive panes from a script or agent (see agent.rs)
//!   tern watch [--json]                        print events as they happen
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
#[path = "tern/link.rs"]
mod link;

nix::ioctl_read_bad!(get_winsize, nix::libc::TIOCGWINSZ, Winsize);

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("open") => tern::open::run(&args[1..]),
        Some(".") => tern::open::run(&args),
        Some("attach") => attach(&args[1..]),
        Some("ls") => list(&args[1..]),
        Some("kill") => kill(&args[1..]),
        Some("link") => link::run(&args[1..]),
        Some("proxy") => link::proxy(),
        Some("build-id") => link::print_build_ids(&args[1..]),
        Some("split") => agent::split(&args[1..]),
        Some("tab") => agent::tab(&args[1..]),
        Some("send") => agent::send(&args[1..]),
        Some("capture") => agent::capture(&args[1..]),
        Some("wait") => agent::wait(&args[1..]),
        Some("close") => agent::close(&args[1..]),
        Some("run") => agent::run(&args[1..]),
        Some("watch") => agent::watch(&args[1..]),
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
                "usage: tern open [DIR] [--window | --split right|down] [--command CMD | -- ARGS...]\n       tern attach [--host HOST] [--cwd DIR] [--cmd CMD] <id> | tern ls [--json] [--host HOST] | tern kill [--host HOST] <id> | tern bench [n]\n       \
                 tern link HOST [--ensure | --status | --wake | --sign-in | --restart-daemon]\n       \
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

#[cfg(target_os = "macos")]
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
    start_daemon(&ternd)?;
    let deadline = Instant::now() + Duration::from_secs(3);
    while Instant::now() < deadline {
        if let Ok(s) = UnixStream::connect(&path) {
            return Ok(s);
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    bail!("ternd did not come up at {}", path.display())
}

#[cfg(target_os = "macos")]
fn start_daemon(ternd: &std::path::Path) -> Result<()> {
    if std::env::var_os("TERN_RUNTIME_DIR").is_some() {
        // Tests and benches get a private daemon, spawned directly.
        return spawn_detached(ternd);
    }
    match start_launch_agent(ternd) {
        Ok(()) => Ok(()),
        // Over SSH to a Mac nobody is logged in to, launchd has no session to run an agent in.
        // A detached ternd outlives the connection, though not a restart of that Mac.
        Err(e) if std::env::var_os("SSH_CONNECTION").is_some() => {
            eprintln!("tern: {e:#}; starting ternd without launchd");
            spawn_detached(ternd)
        }
        Err(e) => Err(e),
    }
}

/// Off a Mac there is no app to be killed along with: ternd is started by whoever first
/// needs it, usually `tern proxy` over SSH, and its own session keeps it past that connection.
#[cfg(not(target_os = "macos"))]
fn start_daemon(ternd: &std::path::Path) -> Result<()> {
    spawn_detached(ternd)
}

/// Runs ternd as a per-user launchd agent. macOS kills processes attributed to
/// an app when it quits, even setsid'd ones, so the daemon must belong to launchd.
#[cfg(target_os = "macos")]
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
    // Whatever started it over SSH is gone long before its sessions are: an agent socket or
    // client address from that connection would be stale in every shell ternd starts later.
    for stale in ["SSH_AUTH_SOCK", "SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY"] {
        cmd.env_remove(stale);
    }
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
    request_on(None, req, Duration::ZERO)
}

/// A request to this machine's ternd, or to a device's through its link, waiting up to `wait`
/// for the link to connect.
fn request_on(host: Option<&str>, req: &Request, wait: Duration) -> Result<(UnixStream, BufReader<UnixStream>)> {
    let mut sock = match host {
        Some(host) => link::connect_within(host, wait)?,
        None => connect()?,
    };
    writeln!(sock, "{}", serde_json::to_string(req)?)?;
    let reader = BufReader::new(sock.try_clone()?);
    Ok((sock, reader))
}

/// Takes `--host HOST` out of `args`.
fn take_host(args: &[String]) -> Result<(Option<String>, Vec<String>)> {
    let mut rest = Vec::new();
    let mut host = None;
    let mut it = args.iter();
    while let Some(a) = it.next() {
        if a == "--host" {
            let h = it.next().context("--host needs an SSH destination")?;
            if !tern::device::valid_host(h) {
                bail!("{h:?} isn't an SSH destination tern can use");
            }
            host = Some(h.clone());
        } else {
            rest.push(a.clone());
        }
    }
    Ok((host, rest))
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
    let (host, args) = take_host(args)?;
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
    let host = host.as_deref();
    // A folder on a device is that device's; this machine's own folder means nothing there.
    let cwd = if host.is_some() { cwd } else { cwd.or_else(|| std::env::current_dir().ok().map(|p| p.display().to_string())) };
    // New sessions inherit this client's environment (PATH, SSH_AUTH_SOCK, TERM...),
    // not the launchd daemon's minimal one. On a device, only what describes the terminal.
    let env: Vec<(String, String)> = std::env::vars()
        .filter(|(k, _)| k != "TERN_SESSION_ID")
        .filter(|(k, _)| host.is_none() || tern::device::FORWARDED_ENV.contains(&k.as_str()))
        .collect();
    let owner = Some(tern::device::client_id());
    let open = |init: Option<String>| -> Result<(UnixStream, BufReader<UnixStream>)> {
        let (cols, rows) = tty_size();
        let req = Request::Attach { id: id.clone(), cols, rows, cwd: cwd.clone(), cmd: cmd.clone(), init, env: env.clone(), owner: owner.clone() };
        // Briefly: wait_for_device says what is happening meanwhile.
        let (sock, mut reader) = request_on(host, &req, Duration::from_secs(1))?;
        let mut line = String::new();
        reader.read_line(&mut line)?;
        let reply: AttachReply = serde_json::from_str(&line).context("bad attach reply")?;
        if !reply.ok {
            return Err(Refused(reply.error.unwrap_or_default()).into());
        }
        Ok((sock, reader))
    };
    let (sock, mut reader) = match host {
        Some(host) => wait_for_device(host, || open(init.clone()))?,
        None => open(init)?,
    };

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
                // reattach, and the session returns with its saved screen. A device's
                // connection may take longer to come back, so its panes keep trying.
                let deadline = Instant::now() + Duration::from_secs(10);
                let mut said = false;
                let mut delay = Duration::from_millis(300);
                let reattached = loop {
                    std::thread::sleep(delay);
                    if let Ok(pair) = open(None) {
                        break Some(pair);
                    }
                    if let Some(host) = host {
                        if !said {
                            stdout.write_all(format!("\r\n\x1b[2m[tern: lost the connection to {host}; reconnecting…]\x1b[m\r\n").as_bytes())?;
                            said = true;
                        }
                        delay = (delay * 2).min(Duration::from_secs(5));
                        continue;
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

/// ternd answered and said no: trying again won't help.
#[derive(Debug)]
struct Refused(String);

impl std::fmt::Display for Refused {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "attach failed: {}", self.0)
    }
}

impl std::error::Error for Refused {}

/// Opens a pane's session on a device, saying what's happening while the device connects.
/// When SSH needs a password, a passphrase or a host key answered, the pane is where it asks.
fn wait_for_device<T>(host: &str, mut open: impl FnMut() -> Result<T>) -> Result<T> {
    let mut shown = String::new();
    let mut delay = Duration::from_millis(200);
    loop {
        let error = match open() {
            Ok(done) => return Ok(done),
            Err(e) if e.downcast_ref::<Refused>().is_some() => return Err(e),
            Err(e) => e,
        };
        let status = link::current_status(host);
        let message = match status.state.as_str() {
            "sign_in" => {
                println!("\r\n{host} needs you to sign in: {}\r", status.message);
                println!("Press Return to sign in here, or close this pane.\r");
                let mut line = String::new();
                if std::io::stdin().read_line(&mut line)? == 0 {
                    return Err(error);
                }
                match link::sign_in(host) {
                    Ok(true) => println!("Signed in. Connecting…\r"),
                    _ => println!("Signing in didn't work; press Return to try again.\r"),
                }
                shown.clear();
                delay = Duration::from_millis(200);
                continue;
            }
            "installing" => format!("Copying tern to {host}…"),
            "connecting" | "stopped" | "" => format!("Connecting to {host}…"),
            "incompatible" => format!("{}. Restart it from tern's Settings → Devices.", status.message),
            _ => format!("Can't reach {host}: {}. Trying again…", if status.message.is_empty() { error.to_string() } else { status.message.clone() }),
        };
        if message != shown {
            println!("\x1b[2m{message}\x1b[m\r");
            shown = message;
        }
        std::thread::sleep(delay);
        delay = (delay * 2).min(Duration::from_secs(3));
    }
}

fn list(args: &[String]) -> Result<i32> {
    let (host, args) = take_host(args)?;
    let json = args.iter().any(|a| a == "--json");
    let (_sock, mut reader) = request_on(host.as_deref(), &Request::List, Duration::from_secs(90))?;
    let mut line = String::new();
    reader.read_line(&mut line)?;
    let sessions: Vec<SessionInfo> = serde_json::from_str(&line)?;
    if json && host.is_some() {
        // Windows and tabs are the Mac's; a device only has sessions.
        println!("{}", serde_json::json!({ "sessions": sessions }));
        return Ok(0);
    }
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
    let (host, args) = take_host(args)?;
    let id = args.first().context("kill needs a session id")?.clone();
    let (_sock, mut reader) = request_on(host.as_deref(), &Request::Kill { id }, Duration::from_secs(90))?;
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
