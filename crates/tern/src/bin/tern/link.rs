//! `tern link HOST` and `tern proxy`: reaching a ternd on another device over SSH.
//!
//! The link runs on the Mac, one per device. It installs this tern's build on the device when
//! it isn't there, starts `tern proxy` over one SSH session, and offers the device's ternd on a
//! local socket (`device::socket_path`), many connections riding that session (`tern::mux`).
//! It reconnects when the connection drops, and writes how it's doing to the device's status
//! file for the app. `tern proxy` runs on the device: it starts ternd there if it isn't running
//! and connects each stream to it.
//!
//! SSH is the system's own, so the user's config, keys, agent and jump hosts apply. The link
//! never prompts: a device that wants a password, a passphrase or a host key answered is
//! "sign_in", and a pane on it offers to sign in in the terminal (`sign_in`), leaving an SSH
//! control connection the link then uses.

use std::fs::File;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use tern::device::{self, Status};
use tern::mux::{self, Mux};
use tern::*;

/// Where this tern's builds go on a device, one folder per build, under its home.
const INSTALL_DIR: &str = ".local/share/tern/versions";
/// How long the link stays with nothing using it.
const IDLE: Duration = Duration::from_secs(10 * 60);
const PING_EVERY: Duration = Duration::from_secs(15);
/// Silence after which the connection counts as dead, though SSH hasn't noticed yet.
const DEAD_AFTER: Duration = Duration::from_secs(45);

pub fn run(args: &[String]) -> Result<i32> {
    let host = args.first().filter(|h| !h.starts_with('-')).context("usage: tern link HOST [--ensure | --status | --wake | --sign-in | --restart-daemon]")?;
    if !device::valid_host(host) {
        bail!("{host:?} isn't an SSH destination tern can use: an alias from ~/.ssh/config or user@host");
    }
    match args.get(1).map(String::as_str) {
        None | Some("--serve") => serve(host),
        Some("--ensure") => ensure(host).map(|_| 0),
        Some("--status") => {
            let status = current_status(host);
            println!("{}", serde_json::to_string(&status)?);
            Ok(0)
        }
        Some("--wake") => {
            wake(host);
            Ok(0)
        }
        Some("--restart-daemon") => restart_daemon(host),
        // In a terminal: answers SSH's questions for the link (what the app runs in a tab).
        Some("--sign-in") => Ok(if sign_in(host)? { 0 } else { 1 }),
        Some(other) => bail!("unknown link option {other}"),
    }
}

/// The status file, unless the link that wrote it is gone.
pub fn current_status(host: &str) -> Status {
    match Status::read(host) {
        Some(status) if status.pid != 0 && alive(status.pid) => status,
        Some(status) => Status { state: "stopped".into(), ..status },
        None => Status { state: "stopped".into(), ..Default::default() },
    }
}

fn alive(pid: u32) -> bool {
    nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid as i32), None).is_ok()
}

/// Tells a waiting link to try again now (after signing in, or restarting the device's ternd).
pub fn wake(host: &str) {
    if let Some(status) = Status::read(host).filter(|s| s.pid != 0) {
        let _ = nix::sys::signal::kill(nix::unistd::Pid::from_raw(status.pid as i32), nix::sys::signal::Signal::SIGUSR1);
    }
}

/// Starts the device's link unless it's running.
pub fn ensure(host: &str) -> Result<()> {
    if UnixStream::connect(device::socket_path(host)).is_ok() {
        return Ok(());
    }
    prepare_runtime_dir()?;
    std::fs::create_dir_all(device::dir())?;
    // Whoever holds the lock is a running link.
    let lock = File::options().create(true).truncate(false).write(true).open(device::lock_path(host))?;
    match nix::fcntl::Flock::lock(lock, nix::fcntl::FlockArg::LockExclusiveNonblock) {
        Ok(held) => drop(held),
        Err(_) => return Ok(()),
    }
    let exe = std::env::current_exe()?;
    let log = File::options().create(true).append(true).open(device::dir().join(format!("{}.log", device::file_name(host))))?;
    let mut cmd = Command::new(exe);
    cmd.args(["link", host, "--serve"]).stdin(Stdio::null()).stdout(log.try_clone()?).stderr(log);
    unsafe {
        use std::os::unix::process::CommandExt;
        cmd.pre_exec(|| nix::unistd::setsid().map(|_| ()).map_err(Into::into));
    }
    cmd.spawn().context("starting tern link")?;
    Ok(())
}

/// A connection to the device's ternd through its link, starting the link if needed. The link
/// turns clients away until it has connected, so this waits up to `wait` for its status to say
/// so; a failure the link reported since this began ends the wait early.
pub fn connect_within(host: &str, wait: Duration) -> Result<UnixStream> {
    let began = mux::now_ms();
    let deadline = Instant::now() + wait;
    let mut ensured = false;
    loop {
        let status = current_status(host);
        match status.state.as_str() {
            "connected" => {
                if let Ok(s) = UnixStream::connect(device::socket_path(host)) {
                    return Ok(s);
                }
            }
            "stopped" if !ensured => {
                ensure(host)?;
                ensured = true;
            }
            "connecting" | "installing" | "stopped" => {}
            // Something the link found out by trying, not a leftover from before it started.
            state if !ensured || status.updated_ms >= began => {
                bail!("{host} isn't connected ({state}{})", if status.message.is_empty() { String::new() } else { format!(": {}", status.message) })
            }
            _ => {}
        }
        if Instant::now() >= deadline {
            bail!("{host} isn't connected yet ({})", status.state);
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

// MARK: SSH

fn ssh_binary() -> &'static str {
    if Path::new("/usr/bin/ssh").exists() { "/usr/bin/ssh" } else { "ssh" }
}

/// SSH as the link runs it: never prompting, sharing one control connection, dropping a dead
/// connection within a minute, and ignoring forwardings and a RemoteCommand from the user's
/// config, which would fail or replace tern's command on every connection.
fn ssh(host: &str) -> Command {
    let mut cmd = Command::new(ssh_binary());
    cmd.args(["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"]);
    cmd.args(["-o", "RequestTTY=no", "-o", "RemoteCommand=none", "-o", "ClearAllForwardings=yes", "-o", "LogLevel=ERROR"]);
    control_options(&mut cmd, host, "auto");
    cmd.args(["--", host]);
    cmd
}

fn control_options(cmd: &mut Command, host: &str, master: &str) {
    match device::control_path(host) {
        Some(path) => {
            if let Some(dir) = path.parent() {
                use std::os::unix::fs::DirBuilderExt;
                let _ = std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir);
            }
            cmd.arg("-o").arg(format!("ControlPath={}", path.display()));
            cmd.args(["-o", &format!("ControlMaster={master}"), "-o", "ControlPersist=600"]);
        }
        None => {
            cmd.args(["-o", "ControlPath=none"]);
        }
    }
}

/// Ends the shared control connection, so the next attempt starts a fresh one rather than
/// riding one that's half-open.
fn drop_control(host: &str) {
    let Some(path) = device::control_path(host) else { return };
    if !path.exists() {
        return;
    }
    let _ = Command::new(ssh_binary())
        .arg("-o").arg(format!("ControlPath={}", path.display()))
        .args(["-O", "exit", "--", host])
        .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null())
        .status();
    // A socket left by a master that died would turn SSH's sharing off for the next one.
    let _ = std::fs::remove_file(path);
}

/// Runs `remote` on the device with `input` on its stdin, returning its output. SSH's own
/// complaints go to the device's SSH log, for the status message.
fn ssh_run(host: &str, remote: &str, input: &[u8]) -> Result<Vec<u8>> {
    let log = File::create(device::ssh_log_path(host))?;
    let mut child = ssh(host).arg(remote).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(log).spawn().context("running ssh")?;
    let mut stdin = child.stdin.take().unwrap();
    let input = input.to_vec();
    // Written from a thread: a device that doesn't read its input mustn't stall reading output.
    let writer = std::thread::spawn(move || {
        let _ = stdin.write_all(&input);
    });
    let mut out = Vec::new();
    child.stdout.take().unwrap().read_to_end(&mut out)?;
    let _ = writer.join();
    let status = child.wait()?;
    if !status.success() {
        bail!(Failure::from_ssh(host, status.code()));
    }
    Ok(out)
}

/// Why a connection attempt failed, as the status says it.
#[derive(Debug)]
struct Failure {
    state: &'static str,
    message: String,
}

impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for Failure {}

impl Failure {
    fn new(state: &'static str, message: impl Into<String>) -> Failure {
        Failure { state, message: message.into() }
    }

    /// Reads what SSH said: a question it wasn't allowed to ask means signing in.
    fn from_ssh(host: &str, code: Option<i32>) -> Failure {
        let said = std::fs::read_to_string(device::ssh_log_path(host)).unwrap_or_default();
        let line = said.lines().map(str::trim).rfind(|l| !l.is_empty()).unwrap_or("").to_string();
        Failure::classify(&said, &line, code)
    }

    fn classify(said: &str, line: &str, code: Option<i32>) -> Failure {
        let asks = ["Permission denied", "Host key verification failed", "REMOTE HOST IDENTIFICATION HAS CHANGED",
                    "passphrase", "No more authentication methods", "keyboard-interactive", "Too many authentication failures"];
        if asks.iter().any(|a| said.contains(a)) {
            return Failure::new("sign_in", if line.is_empty() { "SSH needs you to sign in".to_string() } else { line.to_string() });
        }
        match code {
            Some(255) => Failure::new("unreachable", if line.is_empty() { "SSH couldn't connect".to_string() } else { line.to_string() }),
            Some(code) => Failure::new("unreachable", if line.is_empty() { format!("the device's command ended with {code}") } else { line.to_string() }),
            None => Failure::new("unreachable", "SSH was stopped"),
        }
    }
}

// MARK: Installing

/// What the device said about itself.
#[derive(Debug, PartialEq)]
struct Probe {
    os: String,
    arch: String,
    home: String,
    terminfo: bool,
    /// Builds of tern copied there completely, by folder name.
    installed: Vec<String>,
}

/// Run by `sh -s` on the device, whatever the user's login shell is.
const PROBE: &str = r#"printf '\001tern-probe\n'
uname -s
uname -m
printf '%s\n' "$HOME"
if infocmp xterm-ghostty >/dev/null 2>&1; then echo terminfo; else echo no-terminfo; fi
for d in "$HOME"/.local/share/tern/versions/*/; do
  [ -f "$d.complete" ] && [ -x "${d}tern" ] && [ -x "${d}ternd" ] && basename "$d"
done
true
"#;

impl Probe {
    /// Lines after the marker; what the shell printed before it is ignored.
    fn parse(out: &[u8]) -> Option<Probe> {
        let text = String::from_utf8_lossy(out);
        let after = text.split("\u{1}tern-probe\n").nth(1)?;
        let lines: Vec<&str> = after.lines().map(str::trim).collect();
        let [os, arch, home, terminfo, installed @ ..] = lines.as_slice() else { return None };
        if !home.starts_with('/') {
            return None;
        }
        Some(Probe {
            os: os.to_string(),
            arch: arch.to_string(),
            home: home.to_string(),
            terminfo: *terminfo == "terminfo",
            installed: installed.iter().filter(|l| !l.is_empty()).map(|l| l.to_string()).collect(),
        })
    }
}

/// This tern's own `tern` and `ternd` built for the device's system, if it has them: its own
/// for a machine like this one, otherwise a cross-built pair shipped in the app's `remote/`.
fn binaries_for(os: &str, arch: &str) -> Option<(PathBuf, PathBuf)> {
    let arch = match arch {
        "arm64" | "aarch64" => "aarch64",
        "x86_64" | "amd64" => "x86_64",
        _ => return None,
    };
    let os = match os {
        "Linux" => "linux",
        "Darwin" => "macos",
        _ => return None,
    };
    let exe = std::env::current_exe().ok()?.canonicalize().ok()?;
    let here = exe.parent()?;
    let pair = |dir: &Path| {
        let (tern, ternd) = (dir.join("tern"), dir.join("ternd"));
        (tern.is_file() && ternd.is_file()).then_some((tern, ternd))
    };
    if os == std::env::consts::OS && arch == std::env::consts::ARCH {
        if let Some(found) = pair(here) {
            return Some(found);
        }
    }
    let name = format!("{os}-{arch}");
    let mut dirs: Vec<PathBuf> = std::env::var_os("TERN_REMOTE_BINARIES").map(|d| PathBuf::from(d).join(&name)).into_iter().collect();
    dirs.push(here.join("../Resources/remote").join(&name));
    dirs.push(here.join("remote").join(&name));
    dirs.iter().find_map(|d| pair(d))
}

/// The build's folder name on a device: version and ternd's build id, so two builds of the
/// same version don't share one.
fn install_id(ternd: &Path) -> Result<String> {
    let build = build_id(ternd)?;
    Ok(format!("{}-{}", env!("CARGO_PKG_VERSION"), &build[..12]))
}

/// Copies one file to `dir` on the device through SSH's stdin, renaming it into place once
/// whole: a binary a running ternd uses is never written over.
fn upload(host: &str, file: &Path, dir: &str, name: &str) -> Result<()> {
    let bytes = std::fs::read(file).with_context(|| format!("reading {}", file.display()))?;
    let script = r#"sh -c 'umask 077 && mkdir -p "$1" && cat > "$1/.$2.part" && chmod 755 "$1/.$2.part" && mv -f "$1/.$2.part" "$1/$2"' tern-upload "#;
    ssh_run(host, &format!("{script}{} {}", shell_quote(dir), shell_quote(name)), &bytes)?;
    Ok(())
}

fn install(host: &str, probe: &Probe, tern: &Path, ternd: &Path, dir: &str) -> Result<()> {
    upload(host, tern, dir, "tern")?;
    upload(host, ternd, dir, "ternd")?;
    // The device's own tern checks what arrived, which also shows it runs there.
    let check = format!("{} build-id {} {}", shell_quote(&format!("{dir}/tern")), shell_quote(&format!("{dir}/tern")), shell_quote(&format!("{dir}/ternd")));
    let out = ssh_run(host, &check, b"")?;
    let ids: Vec<String> = String::from_utf8_lossy(&out).lines().map(str::trim).filter(|l| !l.is_empty()).map(str::to_string).collect();
    let want = [build_id(tern)?, build_id(ternd)?];
    if ids.len() < 2 || ids[ids.len() - 2..] != want[..] {
        bail!(Failure::new("unreachable", format!("the copy of tern on {host} doesn't match this one ({} {})", probe.os, probe.arch)));
    }
    // Points the device's stable `tern` (used by agent hooks) at this build, unless it's a Mac
    // with tern's app, whose own copy keeps it; marks the build done; and keeps only the three
    // newest builds (a running ternd keeps a removed binary open).
    let finish = format!(
        r#"[ "$(uname -s)" = Darwin ] && [ -e "$HOME/Library/Application Support/tern/bin/tern" ] || {} hooks link >/dev/null 2>&1; : > {}; cd {} && ls -1t | tail -n +4 | while IFS= read -r d; do [ "$d" = {} ] || rm -rf -- "./$d"; done; true"#,
        shell_quote(&format!("{dir}/tern")),
        shell_quote(&format!("{dir}/.complete")),
        shell_quote(dir.rsplit_once('/').map_or(dir, |(base, _)| base)),
        shell_quote(dir.rsplit('/').next().unwrap_or_default()),
    );
    ssh_run(host, &finish, b"")?;
    Ok(())
}

/// Gives the device Ghostty's terminfo entry, so its programs know the terminal they draw in.
/// Without it, ternd there falls back to `xterm-256color`.
fn install_terminfo(host: &str) {
    let mut infocmp = Command::new("infocmp");
    infocmp.args(["-x", "xterm-ghostty"]).stderr(Stdio::null());
    if let Some(dir) = std::env::current_exe().ok().and_then(|e| Some(e.parent()?.join("../Resources/terminfo"))).filter(|d| d.is_dir()) {
        infocmp.env("TERMINFO", dir);
    }
    let Ok(out) = infocmp.output() else { return };
    if !out.status.success() || out.stdout.is_empty() {
        return;
    }
    if let Err(e) = ssh_run(host, "tic -x - >/dev/null 2>&1", &out.stdout) {
        eprintln!("installing Ghostty's terminfo on {host}: {e:#}");
    }
}

// MARK: The link

struct Link {
    host: String,
    mux: Mutex<Option<Arc<Mux>>>,
    last_used: Mutex<Instant>,
    woken: Mutex<bool>,
    wake: Condvar,
    status: Mutex<Status>,
}

impl Link {
    fn set(&self, update: impl FnOnce(&mut Status)) {
        let mut status = self.status.lock().unwrap();
        update(&mut status);
        status.pid = std::process::id();
        status.updated_ms = mux::now_ms();
        if let Err(e) = status.write(&self.host) {
            eprintln!("writing the status of {}: {e}", self.host);
        }
    }

    fn state(&self, state: &str, message: &str) {
        self.set(|s| {
            s.state = state.into();
            s.message = message.into();
        });
    }

    /// Waits up to `limit` or until woken.
    fn sleep(&self, limit: Duration) {
        let woken = self.woken.lock().unwrap();
        let (mut woken, _) = self.wake.wait_timeout_while(woken, limit, |w| !*w).unwrap();
        *woken = false;
    }

    fn in_use(&self) -> bool {
        let streams = self.mux.lock().unwrap().as_ref().map_or(0, |m| m.streams());
        if streams > 0 {
            *self.last_used.lock().unwrap() = Instant::now();
        }
        streams > 0 || self.last_used.lock().unwrap().elapsed() < IDLE
    }
}

fn serve(host: &str) -> Result<i32> {
    prepare_runtime_dir()?;
    std::fs::create_dir_all(device::dir())?;
    let lock = File::options().create(true).truncate(false).write(true).open(device::lock_path(host))?;
    let Ok(_held) = nix::fcntl::Flock::lock(lock, nix::fcntl::FlockArg::LockExclusiveNonblock) else {
        eprintln!("a link to {host} is already running");
        return Ok(0);
    };
    let path = device::socket_path(host);
    let _ = std::fs::remove_file(&path);
    let listener = UnixListener::bind(&path).with_context(|| format!("binding {}", path.display()))?;
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
    }
    let link = Arc::new(Link {
        host: host.to_string(),
        mux: Mutex::new(None),
        last_used: Mutex::new(Instant::now()),
        woken: Mutex::new(false),
        wake: Condvar::new(),
        status: Mutex::new(Status::read(host).unwrap_or_default()),
    });
    link.state("connecting", "");
    drop_control(host);
    eprintln!("tern link {host}: listening on {}", path.display());

    // Local clients: carried to the device while connected, turned away otherwise (they retry).
    {
        let link = link.clone();
        std::thread::spawn(move || {
            let me = nix::unistd::geteuid().as_raw();
            for conn in listener.incoming() {
                let Ok(conn) = conn else { continue };
                if peer_uid(&conn).ok() != Some(me) {
                    continue;
                }
                *link.last_used.lock().unwrap() = Instant::now();
                let mux = link.mux.lock().unwrap().clone();
                if let Some(mux) = mux.filter(|m| !m.is_dead()) {
                    let _ = mux.open(conn);
                }
            }
        });
    }
    // `tern link --wake`: try again now.
    {
        let link = link.clone();
        let mut signals = signal_hook::iterator::Signals::new([signal_hook::consts::SIGUSR1])?;
        std::thread::spawn(move || {
            for _ in signals.forever() {
                *link.woken.lock().unwrap() = true;
                link.wake.notify_all();
            }
        });
    }

    let mut backoff = Duration::from_secs(1);
    loop {
        let started = Instant::now();
        let result = connect_once(&link);
        *link.mux.lock().unwrap() = None;
        let wait = match result {
            Ok(()) => {
                link.state("connecting", "the connection dropped; reconnecting");
                // A connection that lasted resets the backoff; one that dropped at once doesn't.
                if started.elapsed() > Duration::from_secs(30) { backoff = Duration::from_secs(1) }
                backoff
            }
            Err(e) => {
                let (state, message) = match e.downcast_ref::<Failure>() {
                    Some(f) => (f.state, f.message.clone()),
                    None => ("unreachable", format!("{e:#}")),
                };
                eprintln!("tern link {host}: {state}: {message}");
                link.state(state, &message);
                match state {
                    // Waiting on the user: sign in, or restart the device's ternd.
                    "sign_in" | "incompatible" | "unsupported" => Duration::from_secs(300),
                    _ => backoff,
                }
            }
        };
        backoff = (backoff * 2).min(Duration::from_secs(30));
        if !link.in_use() {
            eprintln!("tern link {host}: unused for a while; stopping");
            break;
        }
        link.sleep(wait);
        if !link.in_use() {
            break;
        }
    }
    let _ = std::fs::remove_file(&path);
    link.state("stopped", "");
    Ok(0)
}

/// One connection, from probing the device to its end. Ok when an established connection
/// dropped; Err when it couldn't be made.
fn connect_once(link: &Arc<Link>) -> Result<()> {
    let host = link.host.as_str();
    let probe = ssh_run(host, "sh -s", PROBE.as_bytes())?;
    let probe = Probe::parse(&probe).ok_or_else(|| Failure::new("unreachable", "the device didn't answer like a Unix shell"))?;
    link.set(|s| {
        s.os = Some(probe.os.clone());
        s.arch = Some(probe.arch.clone());
        s.home = Some(probe.home.clone());
    });
    let Some((tern, ternd)) = binaries_for(&probe.os, &probe.arch) else {
        bail!(Failure::new("unsupported", format!("this tern has no build for {} {}", probe.os, probe.arch)));
    };
    let id = install_id(&ternd)?;
    let dir = format!("{}/{INSTALL_DIR}/{id}", probe.home);
    if !probe.installed.contains(&id) {
        link.state("installing", &format!("copying tern {} to {host}", env!("CARGO_PKG_VERSION")));
        install(host, &probe, &tern, &ternd, &dir)?;
    }
    if !probe.terminfo {
        install_terminfo(host);
    }

    let log = File::create(device::ssh_log_path(host))?;
    let mut child = ssh(host)
        .arg(format!("{} proxy", shell_quote(&format!("{dir}/tern"))))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(log)
        .spawn()
        .context("running ssh")?;
    let result = run_session(link, &mut child, &ternd);
    let _ = child.kill();
    let exit = child.wait().ok().and_then(|s| s.code());
    // A dropped connection can leave its control connection half-open; the next starts afresh.
    drop_control(host);
    match result {
        Err(e) if e.downcast_ref::<Failure>().is_none() && e.downcast_ref::<std::io::Error>().is_some() => {
            // The pipe ended before tern spoke: SSH's own reason says more.
            Err(Failure::from_ssh(host, exit).into())
        }
        other => other,
    }
}

fn run_session(link: &Arc<Link>, child: &mut Child, ternd: &Path) -> Result<()> {
    let host = link.host.clone();
    let stdin = child.stdin.take().unwrap();
    let mut stdout = child.stdout.take().unwrap();
    // The greeting, with a deadline: a device that never runs tern mustn't hold the link.
    let greeting = {
        let (tx, rx) = std::sync::mpsc::channel();
        let reader = std::thread::spawn(move || {
            let got = mux::read_preamble(&mut stdout);
            let _ = tx.send(());
            (got, stdout)
        });
        if rx.recv_timeout(Duration::from_secs(30)).is_err() {
            let _ = child.kill();
        }
        reader.join().map_err(|_| anyhow::anyhow!("reading the device's greeting"))?
    };
    let (greeting, stdout) = greeting;
    let greeting = greeting?;
    eprintln!("tern link {host}: proxy {greeting}");

    let mux = Mux::new(Box::new(stdin));
    {
        let mux = mux.clone();
        std::thread::spawn(move || {
            let _ = mux.run(stdout, None);
        });
    }
    let hello = hello(&mux)?;
    if hello.protocol != PROTOCOL {
        let sessions = list(&mux).map(|l| l.len()).unwrap_or(0);
        link.set(|s| {
            s.version = Some(hello.version.clone());
            s.protocol = Some(hello.protocol);
            s.current = false;
        });
        bail!(Failure::new("incompatible", format!(
            "{host} runs ternd {} (protocol {}), which this tern ({}) can't use; restarting it ends its {sessions} session{}",
            hello.version, hello.protocol, env!("CARGO_PKG_VERSION"), if sessions == 1 { "" } else { "s" })));
    }
    let current = build_id(ternd).is_ok_and(|b| b == hello.build);
    link.set(|s| {
        s.state = "connected".into();
        s.message = String::new();
        s.version = Some(hello.version.clone());
        s.protocol = Some(hello.protocol);
        s.current = current;
    });
    *link.mux.lock().unwrap() = Some(mux.clone());
    eprintln!("tern link {host}: connected to ternd {}", hello.version);

    loop {
        std::thread::sleep(PING_EVERY.min(Duration::from_secs(5)));
        if mux.is_dead() || child.try_wait().ok().flatten().is_some() {
            break;
        }
        // `tern link --wake` while connected (after restarting the device's ternd): start afresh,
        // so the status describes the ternd running now.
        if std::mem::take(&mut *link.woken.lock().unwrap()) {
            eprintln!("tern link {host}: reconnecting as asked");
            break;
        }
        if mux::now_ms().saturating_sub(mux.last_rx_ms()) > DEAD_AFTER.as_millis() as u64 {
            eprintln!("tern link {host}: no answer for {}s; reconnecting", DEAD_AFTER.as_secs());
            break;
        }
        if mux::now_ms().saturating_sub(mux.last_rx_ms()) >= PING_EVERY.as_millis() as u64 && mux.ping().is_err() {
            break;
        }
        link.in_use();
    }
    *link.mux.lock().unwrap() = None;
    mux.close_all();
    Ok(())
}

/// A request through the link's own stream, answered with one line.
fn ask(mux: &Arc<Mux>, req: &Request) -> Result<String> {
    let (ours, theirs) = UnixStream::pair()?;
    mux.open(theirs)?;
    ours.set_read_timeout(Some(Duration::from_secs(15)))?;
    writeln!(&ours, "{}", serde_json::to_string(req)?)?;
    let mut line = String::new();
    BufReader::new(&ours).read_line(&mut line)?;
    anyhow::ensure!(!line.is_empty(), "the device's ternd hung up");
    Ok(line)
}

fn hello(mux: &Arc<Mux>) -> Result<HelloReply> {
    let line = ask(mux, &Request::Hello).map_err(|e| Failure::new("unreachable", format!("the device's ternd didn't answer: {e:#}")))?;
    // A ternd from before `hello` hangs up without a word; ask() reports that as an error.
    serde_json::from_str(&line).context("reading the device's hello")
}

fn list(mux: &Arc<Mux>) -> Result<Vec<SessionInfo>> {
    Ok(serde_json::from_str(&ask(mux, &Request::List)?)?)
}

/// Restarts the device's ternd with this tern's build: what the app's Restart does for a
/// device whose ternd is older or incompatible. Its sessions end; their screens come back.
fn restart_daemon(host: &str) -> Result<i32> {
    let status = current_status(host);
    let (Some(home), Some(os), Some(arch)) = (status.home, status.os, status.arch) else {
        bail!("{host} hasn't been reached yet");
    };
    let (_, ternd) = binaries_for(&os, &arch).context("no tern build for that device")?;
    let tern = format!("{home}/{INSTALL_DIR}/{}/tern", install_id(&ternd)?);
    let out = ssh_run(host, &format!("{} daemon restart", shell_quote(&tern)), b"")?;
    print!("{}", String::from_utf8_lossy(&out));
    wake(host);
    Ok(0)
}

// MARK: The device's side

/// `tern proxy`: run over SSH by a link. Starts ternd here if needed, then carries the link's
/// streams to it until the connection ends.
pub fn proxy() -> Result<i32> {
    // ternd first, so its reply to the link's hello is at hand.
    drop(super::connect()?);
    {
        let mut stdout = std::io::stdout().lock();
        stdout.write_all(b"\n")?;
        stdout.write_all(mux::MAGIC)?;
        writeln!(stdout, "{PROTOCOL} {}", env!("CARGO_PKG_VERSION"))?;
        stdout.flush()?;
    }
    let mux = Mux::new(Box::new(std::io::stdout()));
    let open = || UnixStream::connect(socket_path()).or_else(|_| super::connect().map_err(std::io::Error::other));
    mux.run(std::io::stdin().lock(), Some(&open))?;
    Ok(0)
}

/// `tern build-id FILE...`: what the link compares after copying tern to a device.
pub fn print_build_ids(files: &[String]) -> Result<i32> {
    for file in files {
        println!("{}", build_id(Path::new(file))?);
    }
    Ok(0)
}

// MARK: Signing in from a pane

/// Lets a pane on a device that wants a password (or a passphrase, or a new host key answered)
/// sign in in the terminal: SSH asks, and the control connection it leaves is the link's.
pub fn sign_in(host: &str) -> Result<bool> {
    drop_control(host);
    let mut cmd = Command::new(ssh_binary());
    control_options(&mut cmd, host, "yes");
    cmd.args(["-o", "RemoteCommand=none", "-o", "ClearAllForwardings=yes", "--", host, "true"]);
    let ok = cmd.status().context("running ssh")?.success();
    if ok {
        wake(host);
    }
    Ok(ok)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_probe_ignores_what_the_shell_printed_first() {
        let out = b"Welcome!\n\x01tern-probe\nLinux\nx86_64\n/home/me\nterminfo\n0.0.6-abc\n0.0.5-def\n";
        assert_eq!(Probe::parse(out), Some(Probe {
            os: "Linux".into(), arch: "x86_64".into(), home: "/home/me".into(), terminfo: true,
            installed: vec!["0.0.6-abc".into(), "0.0.5-def".into()],
        }));
        let fresh = Probe::parse(b"\x01tern-probe\nDarwin\narm64\n/Users/me\nno-terminfo\n").unwrap();
        assert!(fresh.installed.is_empty() && !fresh.terminfo);
        assert_eq!(Probe::parse(b"no marker here\n"), None);
        assert_eq!(Probe::parse(b"\x01tern-probe\nLinux\nx86_64\n"), None);
    }

    #[test]
    fn ssh_failures_say_whether_to_sign_in() {
        let f = Failure::classify("me@box: Permission denied (publickey,password).\n", "me@box: Permission denied (publickey,password).", Some(255));
        assert_eq!(f.state, "sign_in");
        let f = Failure::classify("Host key verification failed.\n", "Host key verification failed.", Some(255));
        assert_eq!(f.state, "sign_in");
        let f = Failure::classify("ssh: Could not resolve hostname box\n", "ssh: Could not resolve hostname box", Some(255));
        assert_eq!((f.state, f.message.as_str()), ("unreachable", "ssh: Could not resolve hostname box"));
        assert_eq!(Failure::classify("", "", Some(255)).state, "unreachable");
    }

    #[test]
    fn this_machine_has_a_build_for_itself() {
        // Under `cargo test` the binaries sit beside the test runner's parent folder only after a
        // build; the lookup must at least not claim a system it doesn't know.
        assert_eq!(binaries_for("Plan9", "x86_64"), None);
        assert_eq!(binaries_for("Linux", "mips"), None);
    }
}
