//! Opening the graphical app uses a private file queue, so a CLI can address an
//! already-running instance without AppleScript or executing URL-supplied commands.
use std::path::{Path, PathBuf};
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize, PartialEq)]
pub struct OpenRequest {
    pub directory: String,
    pub command: Option<String>,
    pub split: Option<String>,
    pub window: bool,
}

impl OpenRequest {
    pub fn parse(args: &[String], cwd: &Path) -> Result<Self> {
        let mut directory = None;
        let mut split = None;
        let mut window = false;
        let mut command = None;
        let mut i = 0;
        while i < args.len() {
            match args[i].as_str() {
                "--window" => window = true,
                "--split" => {
                    i += 1;
                    let axis = args.get(i).context("--split needs right or down")?;
                    if !matches!(axis.as_str(), "right" | "down") { bail!("--split needs right or down"); }
                    split = Some(axis.clone());
                }
                "--command" => {
                    i += 1;
                    command = Some(args.get(i).context("--command needs a shell command")?.clone());
                }
                "--" => {
                    if i + 1 == args.len() { bail!("expected a command after --"); }
                    command = Some(args[i + 1..].iter().map(|s| crate::shell_quote(s)).collect::<Vec<_>>().join(" "));
                    break;
                }
                arg if arg.starts_with('-') => bail!("unknown open option: {arg}"),
                arg => {
                    if directory.replace(arg.to_string()).is_some() { bail!("only one directory can be opened at a time"); }
                }
            }
            i += 1;
        }
        if window && split.is_some() { bail!("--window and --split cannot be combined"); }
        let path = PathBuf::from(directory.unwrap_or_else(|| ".".into()));
        let path = if path.is_absolute() { path } else { cwd.join(path) };
        let path = path.canonicalize().context("opening directory")?;
        if !path.is_dir() { bail!("{} is not a directory", path.display()); }
        Ok(Self { directory: path.to_str().context("directory is not UTF-8")?.into(), command, split, window })
    }
}

pub fn run(args: &[String]) -> Result<i32> {
    use std::os::unix::fs::OpenOptionsExt;
    use std::io::Write;
    let request = OpenRequest::parse(args, &std::env::current_dir()?)?;
    let directory = crate::prepare_runtime_dir()?.join("open-requests");
    std::fs::create_dir_all(&directory)?;
    let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_nanos();
    let path = directory.join(format!("{}-{stamp}", std::process::id()));
    let mut file = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&path)?;
    file.write_all(&serde_json::to_vec(&request)?)?;
    file.sync_all()?;
    let ready = path.with_extension("json");
    std::fs::rename(path, &ready)?;
    let executable = std::env::current_exe()?;
    let bundle = executable.ancestors().find(|p| p.extension().is_some_and(|e| e == "app"));
    let mut open = std::process::Command::new("/usr/bin/open");
    if let Some(bundle) = bundle { open.arg("-a").arg(bundle); } else { open.args(["-b", "dev.tern.Tern"]); }
    if let Some(dir) = std::env::var_os("TERN_RUNTIME_DIR") { open.arg("--env").arg(format!("TERN_RUNTIME_DIR={}", PathBuf::from(dir).display())); }
    let status = open.status().context("launching Tern.app")?;
    if !status.success() { let _ = std::fs::remove_file(ready); bail!("could not open Tern.app"); }
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn launch_arguments_preserve_paths_and_command_arguments() {
        let cwd = std::env::temp_dir().canonicalize().unwrap();
        let args = [".", "--split", "down", "--", "printf", "%s", "a 'quote' $(bad)"].map(String::from);
        let req = OpenRequest::parse(&args, &cwd).unwrap();
        assert_eq!(req.directory, cwd.to_str().unwrap());
        assert_eq!(req.split.as_deref(), Some("down"));
        assert_eq!(req.command.as_deref(), Some("printf %s 'a '\\''quote'\\'' $(bad)'"));
        for args in [vec!["--window", "--split", "right"], vec!["--split", "bad"], vec!["--command"], vec!["--"], vec![".", "."]] {
            assert!(OpenRequest::parse(&args.into_iter().map(String::from).collect::<Vec<_>>(), &cwd).is_err());
        }
    }
}
