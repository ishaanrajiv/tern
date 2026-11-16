//! Devices: other machines, reached over SSH, whose folders the app shows beside this Mac's.
//!
//! A device runs its own ternd, which owns its sessions. On the Mac, `tern link <host>` holds
//! one SSH connection to it and offers that ternd on a local socket, `devices/<name>.sock` in
//! the runtime folder. Anything that speaks to ternd speaks to a device by using that socket:
//! `tern attach --host`, the app's session lists, the folder picker. The link writes how the
//! connection is doing to `devices/<name>.json`, which the app shows.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

/// The SSH destination as the user named it: an alias from ~/.ssh/config, or `user@host`.
/// Ports, keys and jump hosts belong in ~/.ssh/config.
/// No colon: `devbox:/path` is how the app writes a folder on a device.
pub fn valid_host(host: &str) -> bool {
    !host.is_empty()
        && host.len() <= 255
        && !host.starts_with('-')
        && host.bytes().all(|c| c.is_ascii_alphanumeric() || b"-_.@".contains(&c))
}

/// A file name for the device: the host itself when short and plain, otherwise a hash of it,
/// since socket paths are capped near 104 bytes.
pub fn file_name(host: &str) -> String {
    let plain = host.len() <= 32 && host.bytes().all(|c| c.is_ascii_alphanumeric() || b"-_.@".contains(&c));
    if plain {
        return host.to_string();
    }
    let hash = host.bytes().fold(0xcbf2_9ce4_8422_2325u64, |h, b| (h ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3));
    format!("h-{hash:016x}")
}

pub fn dir() -> PathBuf {
    crate::runtime_dir().join("devices")
}

/// The local socket the link offers the device's ternd on.
pub fn socket_path(host: &str) -> PathBuf {
    dir().join(format!("{}.sock", file_name(host)))
}

pub fn status_path(host: &str) -> PathBuf {
    dir().join(format!("{}.json", file_name(host)))
}

pub fn lock_path(host: &str) -> PathBuf {
    dir().join(format!("{}.lock", file_name(host)))
}

/// What SSH last said, kept for the status' message.
pub fn ssh_log_path(host: &str) -> PathBuf {
    dir().join(format!("{}.ssh.log", file_name(host)))
}

/// The SSH control socket the link and its one-off commands share, so a device that asks for a
/// password asks once. SSH can't take a path with spaces in an option (Application Support has
/// one), so it lives in the per-user temporary folder; None when even that won't do.
pub fn control_path(host: &str) -> Option<PathBuf> {
    let uid = nix::unistd::getuid();
    let base = std::env::var_os("TERN_RUNTIME_DIR").map(PathBuf::from).unwrap_or_else(std::env::temp_dir);
    let path = base.join(format!("tern-ssh-{uid}")).join(format!("{}.ctl", file_name(host)));
    let text = path.to_string_lossy();
    // SSH binds a temporary name 17 bytes longer first.
    (!text.contains(char::is_whitespace) && text.len() + 18 < 104).then_some(path)
}

/// How the link's connection to a device is doing.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Status {
    /// `connecting`, `installing`, `connected`, `sign_in` (SSH needs a password, passphrase or
    /// host key answered), `unreachable`, `incompatible` (its ternd speaks another protocol
    /// and is running sessions) or `unsupported` (no tern build for its system).
    pub state: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub message: String,
    /// `Linux` or `Darwin`, and `x86_64`, `aarch64` or `arm64`, from its `uname`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub os: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub arch: Option<String>,
    /// Its home folder, which the app shows as `~`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub home: Option<String>,
    /// What its running ternd says it is.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub protocol: Option<u32>,
    /// Its ternd is the build this tern installed; false means a restart would update it.
    #[serde(default)]
    pub current: bool,
    /// The link's process, which `tern link --wake` signals to try again at once.
    #[serde(default)]
    pub pid: u32,
    #[serde(default)]
    pub updated_ms: u64,
}

impl Status {
    pub fn read(host: &str) -> Option<Status> {
        serde_json::from_slice(&std::fs::read(status_path(host)).ok()?).ok()
    }

    /// Written whole and renamed into place, so a reader never sees half of it.
    pub fn write(&self, host: &str) -> std::io::Result<()> {
        let path = status_path(host);
        std::fs::create_dir_all(dir())?;
        let tmp = path.with_extension("json.tmp");
        std::fs::write(&tmp, serde_json::to_vec(self)?)?;
        std::fs::rename(tmp, path)
    }
}

/// This Mac's id, recorded on the sessions it starts, local or on a device. Another Mac's app
/// sharing a ternd (Mac to Mac) leaves sessions that aren't its own alone.
pub fn client_id() -> String {
    let path = crate::runtime_dir().join("client-id");
    if let Ok(id) = std::fs::read_to_string(&path) {
        let id = id.trim();
        if crate::valid_session_id(id) {
            return id.to_string();
        }
    }
    let mut bytes = [0u8; 8];
    if std::fs::File::open("/dev/urandom").and_then(|mut f| std::io::Read::read_exact(&mut f, &mut bytes)).is_err() {
        bytes = (crate::mux::now_ms() ^ u64::from(std::process::id()) << 32).to_be_bytes();
    }
    let id = format!("c-{}", bytes.iter().map(|b| format!("{b:02x}")).collect::<String>());
    if crate::prepare_runtime_dir().is_ok() {
        // Another tern may have written one meanwhile; the first one written wins.
        use std::os::unix::fs::OpenOptionsExt;
        let created = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&path)
            .and_then(|mut f| std::io::Write::write_all(&mut f, id.as_bytes()));
        if created.is_err() {
            if let Ok(existing) = std::fs::read_to_string(&path) {
                if crate::valid_session_id(existing.trim()) {
                    return existing.trim().to_string();
                }
            }
        }
    }
    id
}

/// Environment a pane on a device starts with: what describes the terminal, never the Mac's own
/// paths and settings. The device's login shell sets the rest, as SSH would.
pub const FORWARDED_ENV: &[&str] = &["TERM", "COLORTERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION"];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hosts_are_ssh_destinations_not_options() {
        for ok in ["devbox", "me@devbox", "box.example.com", "dev-2", "10.0.0.5"] {
            assert!(valid_host(ok), "{ok}");
        }
        for bad in ["", "-oProxyCommand=x", "jar vis", "a;b", "host:/path", "$(x)", "a\nb", "[::1]"] {
            assert!(!valid_host(bad), "{bad:?}");
        }
    }

    #[test]
    fn file_names_stay_short_and_plain() {
        assert_eq!(file_name("devbox"), "devbox");
        assert_eq!(file_name("me@devbox"), "me@devbox");
        let long = file_name(&"x".repeat(40));
        assert!(long.starts_with("h-") && long.len() == 18);
        assert_eq!(long, file_name(&"x".repeat(40)));
    }

    #[test]
    fn status_round_trips() {
        let status = Status { state: "connected".into(), os: Some("Linux".into()), current: true, ..Default::default() };
        let text = serde_json::to_string(&status).unwrap();
        assert!(!text.contains("message"));
        assert_eq!(serde_json::from_str::<Status>(&text).unwrap(), status);
    }
}
