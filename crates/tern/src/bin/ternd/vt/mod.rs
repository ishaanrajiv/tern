//! A headless terminal from libghostty-vt: the same engine that draws the app's
//! panes, so what ternd replays on reattach is what Ghostty showed.

#[allow(clippy::all)]
mod ffi;

use std::ffi::c_void;
use std::ptr;

use ffi::*;
pub use tern::BlockKind;

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
    /// What the callbacks record; a separate allocation so they can write it
    /// while the terminal is borrowed.
    effects: *mut Effects,
}

// The handle is only used behind the session's mutex, one thread at a time.
unsafe impl Send for Terminal {}

/// Something the program said, in the order it said it, for the session to act on.
#[derive(Debug, PartialEq)]
pub enum Event {
    /// An OSC 7501 report, already checked against the protocol's limits and decoded.
    Status(Report),
    /// The shell started a new primary prompt (OSC 133;A).
    Prompt,
}

/// An OSC 7501 report. Text is empty and `progress` is None when the report left them out.
#[derive(Debug, Clone, PartialEq)]
pub struct Report {
    pub state: ReportState,
    pub kind: Option<BlockKind>,
    pub progress: Option<u8>,
    pub id: String,
    pub app: String,
    pub title: String,
    pub message: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReportState {
    Idle,
    Working,
    Done,
    Blocked,
    Error,
    /// Removes the record with this id and those beneath it; every record when the id is empty.
    Clear,
}

/// Events waiting to be read. A session reads them after every write, so this only
/// bounds a terminal nobody reads, like one replaying a saved screen.
const MAX_EVENTS: usize = 1024;

#[derive(Default)]
struct Effects {
    bells: u64,
    events: Vec<Event>,
    reply: Vec<u8>,
}

impl Effects {
    fn push(&mut self, event: Event) {
        if self.events.len() < MAX_EVENTS {
            self.events.push(event);
        }
    }
}

unsafe fn effects<'a>(userdata: *mut c_void) -> &'a mut Effects {
    unsafe { &mut *(userdata as *mut Effects) }
}

unsafe extern "C" fn on_bell(_: GhosttyTerminal, userdata: *mut c_void) {
    unsafe { effects(userdata).bells += 1 };
}

unsafe extern "C" fn on_program_status(_: GhosttyTerminal, userdata: *mut c_void, report: *const GhosttyTerminalProgramStatus) {
    let r = unsafe { &*report };
    let state = match r.state {
        GHOSTTY_PROGRAM_STATUS_STATE_IDLE => ReportState::Idle,
        GHOSTTY_PROGRAM_STATUS_STATE_WORKING => ReportState::Working,
        GHOSTTY_PROGRAM_STATUS_STATE_DONE => ReportState::Done,
        GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED => ReportState::Blocked,
        GHOSTTY_PROGRAM_STATUS_STATE_ERROR => ReportState::Error,
        GHOSTTY_PROGRAM_STATUS_STATE_CLEAR => ReportState::Clear,
        _ => return,
    };
    let kind = match r.kind {
        GHOSTTY_PROGRAM_STATUS_KIND_PERMISSION => Some(BlockKind::Permission),
        GHOSTTY_PROGRAM_STATUS_KIND_QUESTION => Some(BlockKind::Question),
        GHOSTTY_PROGRAM_STATUS_KIND_AUTH => Some(BlockKind::Auth),
        _ => None,
    };
    let report = Report {
        state,
        kind,
        progress: u8::try_from(r.progress).ok(),
        id: copied(r.id),
        app: copied(r.app),
        title: copied(r.title),
        message: copied(r.message),
    };
    unsafe { effects(userdata).push(Event::Status(report)) };
}

unsafe extern "C" fn on_semantic_prompt(_: GhosttyTerminal, userdata: *mut c_void, event: *const GhosttyTerminalSemanticPrompt) {
    let e = unsafe { &*event };
    if e.kind == GHOSTTY_SEMANTIC_PROMPT_PROMPT_START && e.prompt_kind == GHOSTTY_SEMANTIC_PROMPT_PROMPT_PRIMARY {
        unsafe { effects(userdata).push(Event::Prompt) };
    }
}

/// Only the OSC 7501 support reply goes back to the program. The app's Ghostty answers
/// every other query, and a second answer would be typed into the shell; it doesn't
/// answer this one.
unsafe extern "C" fn on_write_pty(_: GhosttyTerminal, userdata: *mut c_void, data: *const u8, len: usize) {
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    if bytes.starts_with(b"\x1b]7501;?") {
        unsafe { effects(userdata).reply.extend_from_slice(bytes) };
    }
}

/// Borrowed text, copied before the callback returns.
fn copied(s: GhosttyString) -> String {
    if s.ptr.is_null() || s.len == 0 {
        return String::new();
    }
    String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(s.ptr, s.len) }).into_owned()
}

impl Terminal {
    pub fn new(cols: u16, rows: u16, scrollback_lines: usize) -> Terminal {
        let mut raw = ptr::null_mut();
        let ok = unsafe { ghostty_terminal_new(ptr::null(), &mut raw, cols.max(1), rows.max(1)) };
        assert!(ok == GHOSTTY_SUCCESS && !raw.is_null(), "ghostty_terminal_new failed: {ok}");
        let effects = Box::into_raw(Box::new(Effects::default()));
        let bell: GhosttyTerminalBellFn = Some(on_bell);
        let status: GhosttyTerminalProgramStatusFn = Some(on_program_status);
        let prompt: GhosttyTerminalSemanticPromptFn = Some(on_semantic_prompt);
        let write_pty: GhosttyTerminalWritePtyFn = Some(on_write_pty);
        unsafe {
            ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_USERDATA, effects as *const c_void);
            ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_BELL, bell.map_or(ptr::null(), |f| f as *const c_void));
            // Also makes the terminal answer the OSC 7501 support query.
            ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS, status.map_or(ptr::null(), |f| f as *const c_void));
            ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT, prompt.map_or(ptr::null(), |f| f as *const c_void));
            ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_WRITE_PTY, write_pty.map_or(ptr::null(), |f| f as *const c_void));
            ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &scrollback_lines as *const usize as *const c_void);
            // The default byte limit (10 KB) would cut history to a couple of hundred lines.
            ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, ptr::null());
        }
        Terminal { raw, effects }
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
        unsafe { (*self.effects).bells }
    }

    /// What the program said since the last call, in order.
    pub fn take_events(&mut self) -> Vec<Event> {
        unsafe { std::mem::take(&mut (*self.effects).events) }
    }

    /// Bytes to write back to the program: the OSC 7501 support reply.
    pub fn take_reply(&mut self) -> Vec<u8> {
        unsafe { std::mem::take(&mut (*self.effects).reply) }
    }

    pub fn alternate_screen(&self) -> bool {
        self.get::<GhosttyTerminalScreen>(GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN) == GHOSTTY_TERMINAL_SCREEN_ALTERNATE
    }

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
            drop(Box::from_raw(self.effects));
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
    fn program_status_reports_arrive_decoded_and_in_order() {
        let mut t = Terminal::new(40, 5, 100);
        // "Plan" and "Apply?", then a report split across writes, then a prompt.
        t.write(b"\x1b]7501;state=blocked:kind=permission:progress=40:id=a/b:app=terraform:title=UGxhbg==:msg=QXBwbHk/\x07");
        t.write(b"\x1b]7501;state=do");
        t.write(b"ne\x1b\\\x1b]133;A\x07$ ");
        let events = t.take_events();
        assert_eq!(events.len(), 3);
        let Event::Status(first) = &events[0] else { panic!("{events:?}") };
        assert_eq!(first.state, ReportState::Blocked);
        assert_eq!(first.kind, Some(BlockKind::Permission));
        assert_eq!(first.progress, Some(40));
        assert_eq!((first.id.as_str(), first.app.as_str()), ("a/b", "terraform"));
        assert_eq!((first.title.as_str(), first.message.as_str()), ("Plan", "Apply?"));
        assert!(matches!(&events[1], Event::Status(r) if r.state == ReportState::Done && r.progress.is_none()));
        assert_eq!(events[2], Event::Prompt);
        assert!(t.take_events().is_empty());
    }

    #[test]
    fn reports_with_control_characters_are_refused() {
        let mut t = Terminal::new(40, 5, 100);
        // msg decodes to "a\nb".
        t.write(b"\x1b]7501;state=working:msg=YQpi\x1b\\");
        assert!(t.take_events().is_empty());
    }

    #[test]
    fn only_the_program_status_query_is_answered() {
        let mut t = Terminal::new(40, 5, 100);
        // Device attributes and a cursor position report: the app's Ghostty answers those.
        t.write(b"\x1b[c\x1b[6n");
        assert!(t.take_reply().is_empty());
        t.write(b"\x1b]7501;?\x1b\\");
        assert_eq!(t.take_reply(), b"\x1b]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\x1b\\");
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
