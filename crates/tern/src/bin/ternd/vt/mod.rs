//! A headless terminal from libghostty-vt: the same engine that draws the app's
//! panes, so what ternd replays on reattach is what Ghostty showed.

#[allow(clippy::all)]
mod ffi;

use std::ffi::c_void;
use std::ptr;

use ffi::*;

// Statically linked from vendor/ghostty/zig-out/lib (see build.rs). Only ternd links it.
#[link(name = "ghostty-vt", kind = "static")]
unsafe extern "C" {}

/// How to write a terminal back out as bytes.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Format {
    /// For a terminal attaching now: content plus the modes the program set
    /// (bracketed paste, mouse, kitty keyboard flags), cursor and pen.
    Replay,
    /// For a screen restored after a reboot, under a new shell: content and
    /// colours only, since modes left on would confuse that shell.
    Saved,
    /// Text without escapes.
    Plain,
}

pub struct Terminal {
    raw: GhosttyTerminal,
    /// Bells counted by the bell callback; a separate allocation so the callback
    /// can write it while the terminal is borrowed.
    bells: *mut u64,
}

// The handle is only used behind the session's mutex, one thread at a time.
unsafe impl Send for Terminal {}

unsafe extern "C" fn on_bell(_: GhosttyTerminal, userdata: *mut c_void) {
    unsafe { *(userdata as *mut u64) += 1 };
}

impl Terminal {
    pub fn new(cols: u16, rows: u16, scrollback_lines: usize) -> Terminal {
        let mut raw = ptr::null_mut();
        let ok = unsafe { ghostty_terminal_new(ptr::null(), &mut raw, cols.max(1), rows.max(1)) };
        assert!(ok == GHOSTTY_SUCCESS && !raw.is_null(), "ghostty_terminal_new failed: {ok}");
        let bells = Box::into_raw(Box::new(0u64));
        let bell: GhosttyTerminalBellFn = Some(on_bell);
        unsafe {
            ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_USERDATA, bells as *const c_void);
            ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_BELL, bell.map_or(ptr::null(), |f| f as *const c_void));
            ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &scrollback_lines as *const usize as *const c_void);
            // The default byte limit (10 KB) would cut history to a couple of hundred lines.
            ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, ptr::null());
        }
        // No WRITE_PTY callback on purpose: the app's Ghostty answers the program's
        // queries, and a second answer would be typed into the shell.
        Terminal { raw, bells }
    }

    pub fn set_scrollback_bytes(&mut self, bytes: usize) {
        unsafe {
            ghostty_terminal_set(self.raw, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, ptr::null());
            ghostty_terminal_set(self.raw, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &bytes as *const usize as *const c_void);
        }
    }

    pub fn write(&mut self, bytes: &[u8]) {
        unsafe { ghostty_terminal_vt_write(self.raw, bytes.as_ptr(), bytes.len()) };
    }

    pub fn resize(&mut self, cols: u16, rows: u16) {
        unsafe { ghostty_terminal_resize(self.raw, cols.max(1), rows.max(1), 0, 0) };
    }

    /// (cols, rows)
    pub fn size(&self) -> (u16, u16) {
        (self.get(GHOSTTY_TERMINAL_DATA_COLS), self.get(GHOSTTY_TERMINAL_DATA_ROWS))
    }

    pub fn title(&self) -> String {
        let s: GhosttyString = self.get(GHOSTTY_TERMINAL_DATA_TITLE);
        if s.ptr.is_null() || s.len == 0 {
            return String::new();
        }
        // Borrowed until the next write: copied now.
        String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(s.ptr, s.len) }).into_owned()
    }

    pub fn bells(&self) -> u64 {
        unsafe { *self.bells }
    }

    pub fn alternate_screen(&self) -> bool {
        self.get::<GhosttyTerminalScreen>(GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN) == GHOSTTY_TERMINAL_SCREEN_ALTERNATE
    }

    #[cfg(test)]
    pub fn scrollback_rows(&self) -> usize {
        self.get(GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS)
    }

    /// The whole active screen, history first, as bytes another terminal can replay.
    pub fn format(&self, format: Format) -> Vec<u8> {
        let mut extra = GhosttyFormatterTerminalExtra {
            size: size_of::<GhosttyFormatterTerminalExtra>(),
            palette: false,
            modes: false,
            scrolling_region: false,
            tabstops: false,
            // Off: at the pinned Ghostty it writes a NUL inside OSC 7, and the
            // shell reports its folder again at the next prompt anyway.
            pwd: false,
            keyboard: false,
            screen: GhosttyFormatterScreenExtra {
                size: size_of::<GhosttyFormatterScreenExtra>(),
                cursor: false,
                style: false,
                hyperlink: false,
                protection: false,
                kitty_keyboard: false,
                charsets: false,
            },
        };
        if format == Format::Replay {
            extra.modes = true;
            extra.scrolling_region = true;
            extra.keyboard = true;
            extra.screen.cursor = true;
            extra.screen.style = true;
            extra.screen.hyperlink = true;
            extra.screen.kitty_keyboard = true;
            extra.screen.charsets = true;
        }
        let options = GhosttyFormatterTerminalOptions {
            size: size_of::<GhosttyFormatterTerminalOptions>(),
            emit: match format {
                Format::Plain => GHOSTTY_FORMATTER_FORMAT_PLAIN,
                _ => GHOSTTY_FORMATTER_FORMAT_VT,
            },
            // Soft-wrapped rows go out as one line, so the receiving terminal can rewrap them.
            unwrap: true,
            // A live replay keeps blank rows so the layout and cursor line up.
            trim: format != Format::Replay,
            extra,
            selection: ptr::null(),
        };
        let mut out = Vec::new();
        unsafe {
            let mut formatter = ptr::null_mut();
            if ghostty_formatter_terminal_new(ptr::null(), &mut formatter, self.raw, options) != GHOSTTY_SUCCESS {
                return out;
            }
            let writer = GhosttyWriter { write: Some(append), userdata: &mut out as *mut Vec<u8> as *mut c_void };
            if ghostty_formatter_format(formatter, writer) != GHOSTTY_SUCCESS {
                out.clear();
            }
            ghostty_formatter_free(formatter);
        }
        out
    }

    fn get<T: Default>(&self, data: GhosttyTerminalData) -> T {
        let mut value = T::default();
        unsafe { ghostty_terminal_get(self.raw, data, &mut value as *mut T as *mut c_void) };
        value
    }
}

unsafe extern "C" fn append(userdata: *mut c_void, data: *const u8, len: usize) -> bool {
    let out = unsafe { &mut *(userdata as *mut Vec<u8>) };
    out.extend_from_slice(unsafe { std::slice::from_raw_parts(data, len) });
    true
}

impl Default for GhosttyString {
    fn default() -> Self {
        GhosttyString { ptr: ptr::null(), len: 0 }
    }
}

impl Drop for Terminal {
    fn drop(&mut self) {
        unsafe {
            ghostty_terminal_free(self.raw);
            drop(Box::from_raw(self.bells));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn byte_limit_replaces_the_fixed_row_limit_and_prunes_existing_history() {
        let mut terminal = Terminal::new(80, 24, 2);
        terminal.set_scrollback_bytes(20_000_000);
        for _ in 0..12000 { terminal.write(b"retained row\r\n"); }
        assert!(terminal.scrollback_rows() > 10_000);
        terminal.set_scrollback_bytes(100_000);
        assert!(terminal.scrollback_rows() < 2_000);
    }

    #[test]
    fn reads_text_back() {
        let mut t = Terminal::new(40, 5, 100);
        t.write(b"hello \x1b[31mworld\x1b[m\r\n$ ");
        let plain = String::from_utf8(t.format(Format::Plain)).unwrap();
        assert_eq!(plain, "hello world\n$");
    }

    #[test]
    fn title_bells_and_size() {
        let mut t = Terminal::new(40, 5, 100);
        t.write(b"\x1b]2;npm run dev\x07\x07\x07");
        assert_eq!(t.title(), "npm run dev");
        assert_eq!(t.bells(), 2);
        t.resize(100, 30);
        assert_eq!(t.size(), (100, 30));
        assert!(!t.alternate_screen());
        t.write(b"\x1b[?1049h");
        assert!(t.alternate_screen());
    }

    #[test]
    fn scrollback_is_not_cut_by_the_default_byte_limit() {
        let mut t = Terminal::new(200, 50, 10_000);
        for i in 0..5_000 {
            t.write(format!("\x1b[3{}mline {i} with some text to fill the row\x1b[m\r\n", i % 8).as_bytes());
        }
        assert!(t.scrollback_rows() >= 4_900, "{}", t.scrollback_rows());
    }
}
