//! Turning a session's headless screen back into bytes a terminal can replay.

use crate::vt::{Format, Terminal};

/// Bytes that repaint a fresh terminal to match the session's screen: main-screen
/// history first, so it lands in the new terminal's scrollback, then the screen,
/// the cursor and the modes the program set. With a full-screen program up, only
/// its screen; the main screen behind it isn't replayed.
pub fn snapshot(term: &Terminal) -> Vec<u8> {
    term.format(Format::Replay)
}

/// The main screen's history and rows, up to the last one in use, for saving to
/// disk. Colours only: no modes, which would outlive the program that set them.
pub fn saved_screen(term: &Terminal) -> Vec<u8> {
    let mut out = term.format(Format::Saved);
    if !out.is_empty() && !out.ends_with(b"\n") {
        // The "restored" rule goes on a line of its own.
        out.extend_from_slice(b"\x1b[m\r\n");
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn replay(bytes: &[u8], cols: u16, rows: u16) -> Terminal {
        let mut t = Terminal::new(cols, rows, 100);
        t.write(bytes);
        t
    }

    fn text(t: &Terminal) -> String {
        String::from_utf8(t.format(Format::Plain)).unwrap()
    }

    #[test]
    fn snapshot_replays_history_and_screen() {
        let mut t = Terminal::new(20, 3, 100);
        for i in 1..=6 {
            t.write(format!("line {i}\r\n").as_bytes());
        }
        let fresh = replay(&snapshot(&t), 20, 3);
        assert_eq!(text(&fresh), text(&t));
        assert_eq!(fresh.scrollback_rows(), t.scrollback_rows());
        assert!(fresh.scrollback_rows() >= 4);
    }

    #[test]
    fn snapshot_keeps_colours_links_and_wide_characters() {
        let mut t = Terminal::new(40, 4, 100);
        t.write(b"\x1b[31mred\x1b[m plain \x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\\r\n");
        t.write("wide 日本 combining e\u{301} emoji 👍".as_bytes());
        let snap = snapshot(&t);
        let fresh = replay(&snap, 40, 4);
        assert_eq!(text(&fresh), text(&t));
        assert!(snap.windows(8).any(|w| w == b"]8;;http"), "OSC 8 link: {:?}", String::from_utf8_lossy(&snap));
        // Replaying it again gives the same bytes: nothing was lost on the way.
        assert_eq!(snapshot(&fresh), snap);
    }

    #[test]
    fn snapshot_restores_modes_and_kitty_keyboard_flags() {
        let mut t = Terminal::new(20, 3, 100);
        t.write(b"\x1b[?2004h\x1b[?1004h\x1b[?1000h\x1b[?1006h\x1b[>5u$ ");
        let snap = snapshot(&t);
        let s = String::from_utf8_lossy(&snap);
        for mode in ["?2004h", "?1004h", "?1000h", "?1006h", "=5;1u"] {
            assert!(s.contains(mode), "{mode} missing from {s:?}");
        }
        assert_eq!(snapshot(&replay(&snap, 20, 3)), snap);
    }

    #[test]
    fn snapshot_of_a_full_screen_program_enters_the_alternate_screen() {
        let mut t = Terminal::new(20, 3, 100);
        t.write(b"shell\r\n\x1b[?1049hvim");
        let snap = snapshot(&t);
        let fresh = replay(&snap, 20, 3);
        assert!(fresh.alternate_screen());
        assert!(text(&fresh).contains("vim"));
    }

    #[test]
    fn long_lines_rewrap_at_a_new_width() {
        let mut t = Terminal::new(20, 5, 100);
        t.write(format!("{}\r\n$ ", "x".repeat(50)).as_bytes());
        // Saved at 20 columns, restored at 60: one line, not three.
        let wide = replay(&saved_screen(&t), 60, 5);
        assert_eq!(text(&wide).lines().next().unwrap().len(), 50);
        t.resize(60, 5);
        assert_eq!(text(&t).lines().next().unwrap().len(), 50);
    }

    #[test]
    fn saved_lines_stop_at_the_last_used_row() {
        let mut t = Terminal::new(20, 5, 100);
        t.write(b"one\r\ntwo\r\n");
        let saved = String::from_utf8(saved_screen(&t)).unwrap();
        assert_eq!(saved.matches("\r\n").count(), 2, "{saved:?}");
        assert!(saved.ends_with("\r\n"));
    }

    #[test]
    fn saved_screens_leave_modes_behind() {
        let mut t = Terminal::new(20, 3, 100);
        t.write(b"\x1b[?2004h\x1b[?1000h\x1b[>5u\x1b[?25l\x1b[31mred\x1b[m");
        let saved = String::from_utf8(saved_screen(&t)).unwrap();
        for mode in ["?2004h", "?1000h", "=5;1u", "?25l"] {
            assert!(!saved.contains(mode), "{mode} in {saved:?}");
        }
        assert!(saved.contains("red"));
    }
}
