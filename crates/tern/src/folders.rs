//! Folders worth offering in the app's folder picker, found where ternd runs: zoxide's
//! history and git repositories under the given roots. On the Mac the app looks for itself;
//! for a device, it asks the device's ternd (`folders` and `list_dirs`).

use std::path::{Path, PathBuf};

use serde::Serialize;

#[derive(Debug, Default, Serialize, PartialEq)]
pub struct Folders {
    pub home: String,
    /// zoxide's directories, best first.
    pub recent: Vec<String>,
    pub repos: Vec<String>,
}

fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| "/".into())
}

/// `~` and `~/x` from the home folder; anything else as given.
pub fn expand(path: &str, home: &Path) -> PathBuf {
    if path == "~" {
        return home.to_path_buf();
    }
    match path.strip_prefix("~/") {
        Some(rest) => home.join(rest),
        None => PathBuf::from(path),
    }
}

pub fn list(roots: &[String]) -> Folders {
    let home = home();
    let roots: Vec<PathBuf> = roots.iter().map(|r| expand(r, &home)).collect();
    Folders { home: home.display().to_string(), recent: zoxide(&home), repos: repos(&roots, 400) }
}

/// zoxide's database, best first, or nothing without zoxide. It's looked for where installers
/// put it too: ternd started over SSH has a non-interactive shell's PATH.
fn zoxide(home: &Path) -> Vec<String> {
    let mut candidates: Vec<PathBuf> = std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).map(|d| d.join("zoxide")).collect())
        .unwrap_or_default();
    for dir in [".local/bin", ".cargo/bin", ".nix-profile/bin"] {
        candidates.push(home.join(dir).join("zoxide"));
    }
    for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/run/current-system/sw/bin", "/home/linuxbrew/.linuxbrew/bin"] {
        candidates.push(Path::new(dir).join("zoxide"));
    }
    let Some(zoxide) = candidates.into_iter().find(|p| p.is_file()) else { return Vec::new() };
    let Ok(out) = std::process::Command::new(zoxide).args(["query", "--list"]).stderr(std::process::Stdio::null()).output() else {
        return Vec::new();
    };
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && Path::new(l) != home && Path::new(l).is_dir())
        .take(200)
        .map(str::to_string)
        .collect()
}

/// Git repositories up to three levels under each root, not descending into them. A `.git`
/// file is a worktree or submodule, which opens from its repository.
pub fn repos(roots: &[PathBuf], limit: usize) -> Vec<String> {
    const SKIP: &[&str] = &["node_modules", "target", "build", "dist", "vendor", "Library", "Pods"];
    fn walk(dir: &Path, depth: usize, limit: usize, found: &mut Vec<String>) {
        let Ok(entries) = std::fs::read_dir(dir) else { return };
        let mut names: Vec<String> = entries.flatten().filter_map(|e| e.file_name().into_string().ok()).collect();
        names.sort();
        for name in names {
            if found.len() >= limit {
                return;
            }
            if name.starts_with('.') || SKIP.contains(&name.as_str()) {
                continue;
            }
            let path = dir.join(&name);
            if !path.is_dir() {
                continue;
            }
            let git = path.join(".git");
            if git.exists() {
                if git.is_dir() {
                    found.push(path.display().to_string());
                }
                continue;
            }
            if depth < 3 {
                walk(&path, depth + 1, limit, found);
            }
        }
    }
    let mut found = Vec::new();
    for root in roots {
        walk(root, 1, limit, &mut found);
    }
    found
}

/// The folders in `path` (with `~` expanded), sorted, for completing a typed path.
pub fn subdirs(path: &str) -> std::io::Result<(String, Vec<String>)> {
    let dir = expand(path, &home());
    let mut names: Vec<String> = std::fs::read_dir(&dir)?
        .flatten()
        .filter(|e| e.path().is_dir())
        .filter_map(|e| e.file_name().into_string().ok())
        .collect();
    names.sort_by_key(|n| n.to_lowercase());
    names.truncate(1000);
    Ok((dir.display().to_string(), names))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tilde_expands_only_at_the_start() {
        let home = Path::new("/home/x");
        assert_eq!(expand("~", home), PathBuf::from("/home/x"));
        assert_eq!(expand("~/dev", home), PathBuf::from("/home/x/dev"));
        assert_eq!(expand("/srv/~/a", home), PathBuf::from("/srv/~/a"));
        assert_eq!(expand("~other", home), PathBuf::from("~other"));
    }

    #[test]
    fn repositories_are_found_without_descending_into_them() {
        let root = std::env::temp_dir().join(format!("tern-repos-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        for dir in ["a/.git", "a/inner/.git", "group/b/.git", "node_modules/c/.git", ".hidden/d/.git", "deep/1/2/3/.git"] {
            std::fs::create_dir_all(root.join(dir)).unwrap();
        }
        std::fs::create_dir_all(root.join("wt")).unwrap();
        std::fs::write(root.join("wt/.git"), "gitdir: elsewhere").unwrap();
        let found = repos(std::slice::from_ref(&root), 10);
        let rel: Vec<_> = found.iter().map(|p| p.strip_prefix(&format!("{}/", root.display())).unwrap()).collect();
        assert_eq!(rel, ["a", "group/b"]);
        assert_eq!(repos(std::slice::from_ref(&root), 1).len(), 1);
        let (dir, names) = subdirs(&root.display().to_string()).unwrap();
        assert_eq!(dir, root.display().to_string());
        assert!(names.contains(&"group".to_string()) && names.contains(&".hidden".to_string()));
        let _ = std::fs::remove_dir_all(&root);
    }
}
