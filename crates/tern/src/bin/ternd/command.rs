//! Streaming OSC 133 command boundaries. Escape sequences may span PTY reads.
//! Output is bounded independently of scrollback, and is never sent as input.
use std::time::Instant;

const MAX_OUTPUT: usize = 4 << 20;

#[derive(Default)]
pub struct CommandCapture {
    escape: Vec<u8>,
    current: Vec<u8>,
    pub output: Vec<u8>,
    started: Option<Instant>,
    pub exit_code: Option<i32>,
    pub duration_ms: Option<u64>,
    pub finished_ms: u64,
    current_truncated: bool,
    pub truncated: bool,
}

impl CommandCapture {
    /// Between a command's start and end markers.
    pub fn running(&self) -> bool {
        self.started.is_some()
    }

    pub fn write(&mut self, bytes: &[u8]) {
        let mut offset = 0;
        while offset < bytes.len() {
            if self.escape.is_empty() {
                if let Some(next) = bytes[offset..].iter().position(|b| *b == 0x1b) {
                    self.append(&bytes[offset..offset + next]);
                    self.escape.push(0x1b);
                    offset += next + 1;
                } else {
                    self.append(&bytes[offset..]);
                    break;
                }
                continue;
            }
            let byte = bytes[offset];
            offset += 1;
            self.escape.push(byte);
            if self.escape.len() == 2 && byte != b']' {
                let escape = std::mem::take(&mut self.escape);
                self.append(&escape);
            } else if self.escape.len() > 2 && (byte == 7 || self.escape.ends_with(b"\x1b\\")) {
                let escape = std::mem::take(&mut self.escape);
                let end = escape.len() - if byte == 7 { 1 } else { 2 };
                let code = &escape[2..end];
                if code == b"133;C" {
                    self.current.clear();
                    self.current_truncated = false;
                    self.started = Some(Instant::now());
                } else if let Some(status) = code.strip_prefix(b"133;D") {
                    if let Some(started) = self.started.take() {
                        self.output = std::mem::take(&mut self.current);
                        self.truncated = self.current_truncated;
                        self.duration_ms = Some(started.elapsed().as_millis() as u64);
                        self.exit_code = std::str::from_utf8(status).ok().and_then(|s| s.strip_prefix(';')).and_then(|s| s.split(';').next()).and_then(|s| s.parse().ok());
                        self.finished_ms = super::session::now_ms();
                    }
                } else if !code.starts_with(b"133;") { self.append(&escape); }
            } else if self.escape.len() > 4096 {
                let escape = std::mem::take(&mut self.escape);
                self.append(&escape);
            }
        }
    }

    fn append(&mut self, bytes: &[u8]) {
        if self.started.is_none() { return; }
        let remaining = MAX_OUTPUT.saturating_sub(self.current.len());
        self.current.extend_from_slice(&bytes[..remaining.min(bytes.len())]);
        self.current_truncated |= remaining < bytes.len();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn command_markers_split_at_every_byte_exclude_prompts() {
        let mut capture = CommandCapture::default();
        for &byte in b"$ command\x1b]133;C\x1b\\hello\x1b[31m world\x1b[m\r\n\x1b]133;D;7\x07$ " {
            capture.write(&[byte]);
        }
        assert_eq!(capture.output, b"hello\x1b[31m world\x1b[m\r\n");
        assert_eq!(capture.exit_code, Some(7));
        assert!(capture.finished_ms > 0);
        capture.write(b"\x1b]133;C\x07next");
        assert!(capture.output.starts_with(b"hello"));
        capture.write(b"\x1b]133;D;0\x07");
        assert_eq!(capture.output, b"next");
    }
    #[test]
    fn output_and_unterminated_sequences_are_bounded() {
        let mut capture = CommandCapture::default();
        capture.write(b"\x1b]133;C\x07");
        capture.write(&vec![b'x'; MAX_OUTPUT + 10]);
        capture.write(b"\x1b]133;D;0\x07");
        assert_eq!(capture.output.len(), MAX_OUTPUT);
        assert!(capture.truncated);
        capture.write(b"\x1b]");
        capture.write(&vec![b'y'; 10000]);
        assert!(capture.escape.len() <= 4096);
    }
}
