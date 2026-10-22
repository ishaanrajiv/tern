//! Turning a session's headless screen back into bytes a terminal can replay.

use crate::session::TermEvents;

/// Bytes that repaint a fresh terminal to match the session's screen.
pub fn snapshot(parser: &mut vt100::Parser<TermEvents>) -> Vec<u8> {
    let mut out = Vec::new();
    let (rows, _) = parser.screen().size();
    if parser.screen().alternate_screen() {
        out.extend_from_slice(b"\x1b[?1049h");
    } else {
        // Main-screen history is replayed line by line so it lands in the new
        // terminal's scrollback, colours included.
        let total = write_lines(parser, &mut out, false);
        if total > 0 {
            // Push the tail of the history off the visible screen before repainting it.
            out.extend(std::iter::repeat_n(b'\n', rows as usize));
        }
    }
    out.extend(parser.screen().state_formatted());
    out
}

/// Writes the main screen's history, and the visible rows too if `visible`, as
/// formatted lines. Each starts and ends with a reset, since vt100 formats every
/// row as if from default attributes. Returns the number of history lines.
pub fn write_lines(parser: &mut vt100::Parser<TermEvents>, out: &mut Vec<u8>, visible: bool) -> usize {
    let (rows, cols) = parser.screen().size();
    let mut line = |row: Vec<u8>| {
        out.extend_from_slice(b"\x1b[m");
        out.extend_from_slice(&row);
        out.extend_from_slice(b"\x1b[m\r\n");
    };
    let screen = parser.screen_mut();
    screen.set_scrollback(usize::MAX);
    let total = screen.scrollback();
    let mut off = total;
    while off > 0 {
        screen.set_scrollback(off);
        let take = off.min(rows as usize);
        screen.rows_formatted(0, cols).take(take).for_each(&mut line);
        off -= take;
    }
    screen.set_scrollback(0);
    if visible {
        // Up to the last row with anything on it.
        let used = screen.rows(0, cols).enumerate().filter(|(_, r)| !r.trim().is_empty()).map(|(i, _)| i + 1).last();
        screen.rows_formatted(0, cols).take(used.unwrap_or(0)).for_each(&mut line);
    }
    total
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parser(rows: u16, cols: u16) -> vt100::Parser<TermEvents> {
        vt100::Parser::new_with_callbacks(rows, cols, 100, TermEvents::default())
    }

    fn contents(bytes: &[u8], rows: u16, cols: u16) -> (String, usize) {
        let mut p = parser(rows, cols);
        p.process(bytes);
        let screen = p.screen_mut();
        screen.set_scrollback(usize::MAX);
        let history = screen.scrollback();
        screen.set_scrollback(0);
        (p.screen().contents(), history)
    }

    #[test]
    fn snapshot_replays_history_and_screen() {
        let mut p = parser(3, 20);
        for i in 1..=6 {
            p.process(format!("line {i}\r\n").as_bytes());
        }
        let snap = snapshot(&mut p);
        // A fresh terminal fed the snapshot shows the same screen and keeps the history.
        let (screen, history) = contents(&snap, 3, 20);
        assert_eq!(screen, p.screen().contents());
        assert!(history >= 4, "history lines kept: {history}");
    }

    #[test]
    fn snapshot_keeps_colours() {
        let mut p = parser(3, 20);
        p.process(b"\x1b[31mred\x1b[m plain");
        let mut fresh = parser(3, 20);
        fresh.process(&snapshot(&mut p));
        let cell = fresh.screen().cell(0, 0).unwrap();
        assert_eq!(cell.contents(), "r");
        assert_eq!(cell.fgcolor(), vt100::Color::Idx(1));
        assert_eq!(fresh.screen().cell(0, 4).unwrap().fgcolor(), vt100::Color::Default);
    }

    #[test]
    fn snapshot_of_a_full_screen_program_enters_the_alternate_screen() {
        let mut p = parser(3, 20);
        p.process(b"shell\r\n\x1b[?1049hvim");
        let snap = snapshot(&mut p);
        assert!(snap.starts_with(b"\x1b[?1049h"));
        let mut fresh = parser(3, 20);
        fresh.process(&snap);
        assert!(fresh.screen().alternate_screen());
        assert!(fresh.screen().contents().contains("vim"));
    }

    #[test]
    fn saved_lines_stop_at_the_last_used_row() {
        let mut p = parser(5, 20);
        p.process(b"one\r\ntwo\r\n");
        let mut out = Vec::new();
        let history = write_lines(&mut p, &mut out, true);
        assert_eq!(history, 0);
        let text = String::from_utf8_lossy(&out);
        assert_eq!(text.matches("\r\n").count(), 2, "{text:?}");
    }
}
