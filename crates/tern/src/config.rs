//! tern's config file, `~/.config/tern/config`, in Ghostty's style: one `key = value` per
//! line, `#` comments, and keys that may repeat (`on-done` twice runs two commands).
//!
//! A private instance (`TERN_RUNTIME_DIR`) reads `config` in its runtime directory instead,
//! so experiments never touch the real one.

use std::path::PathBuf;

pub fn config_path() -> PathBuf {
    if std::env::var_os("TERN_RUNTIME_DIR").is_some() {
        return crate::runtime_dir().join("config");
    }
    let base = std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from).filter(|p| p.is_absolute())
        .unwrap_or_else(|| std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| "/tmp".into()).join(".config"));
    base.join("tern").join("config")
}

#[derive(Debug, Default, Clone, PartialEq)]
pub struct Config {
    pub entries: Vec<(String, String)>,
    /// Lines that aren't `key = value`, by line number, to report rather than guess at.
    pub invalid: Vec<usize>,
}

impl Config {
    pub fn parse(text: &str) -> Config {
        let mut config = Config::default();
        for (i, line) in text.lines().enumerate() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') { continue }
            match line.split_once('=') {
                Some((key, value)) if !key.trim().is_empty() && !key.trim().contains(char::is_whitespace) => {
                    let value = value.trim();
                    // Quotes are optional, as in Ghostty, and keep surrounding spaces.
                    let value = value.strip_prefix('"').and_then(|v| v.strip_suffix('"')).unwrap_or(value);
                    config.entries.push((key.trim().to_string(), value.to_string()));
                }
                _ => config.invalid.push(i + 1),
            }
        }
        config
    }

    /// The config file as it is now; empty if there's none.
    pub fn load() -> Config {
        std::fs::read_to_string(config_path()).map(|text| Config::parse(&text)).unwrap_or_default()
    }

    /// Every value given for `key`, in order. An empty value clears the ones before it.
    pub fn all(&self, key: &str) -> Vec<&str> {
        let mut values = Vec::new();
        for (k, v) in &self.entries {
            if k == key {
                if v.is_empty() { values.clear() } else { values.push(v.as_str()) }
            }
        }
        values
    }

    /// The last value given for `key`.
    pub fn get(&self, key: &str) -> Option<&str> { self.all(key).last().copied() }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lines_comments_quotes_and_repeats() {
        let c = Config::parse("# tern\n\non-done = say done\non-done=\"  echo spaced  \"\ntheme = Paper\nnot a setting\nbad key = x\n");
        assert_eq!(c.all("on-done"), ["say done", "  echo spaced  "]);
        assert_eq!(c.get("theme"), Some("Paper"));
        assert_eq!(c.get("missing"), None);
        assert_eq!(c.invalid, [6, 7]);
    }

    #[test]
    fn an_empty_value_clears_earlier_ones() {
        let c = Config::parse("on-bell = a\non-bell =\non-bell = b\n");
        assert_eq!(c.all("on-bell"), ["b"]);
    }
}
