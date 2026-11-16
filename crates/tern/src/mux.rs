//! Many unix-socket connections over one byte pipe: how the Mac reaches a ternd on another
//! device. `tern link` on the Mac accepts connections on a local socket and `tern proxy` on the
//! device connects each one to its ternd, both ends speaking this over one SSH session. Each
//! connection carries the ordinary ternd protocol untouched, so a client can't tell the
//! difference between a local ternd and a device's.
//!
//! A frame is `[stream: u32 BE][kind: u8][len: u32 BE][payload]`. The link opens streams
//! (odd ids); either side closes one. Stream 0 carries pings, so a link notices a dead
//! connection before SSH's own keepalive does.
//!
//! The proxy writes `MAGIC`, then a version line, before its first frame. Anything the device's
//! shell startup prints before that (a motd, an rc file's echo) is skipped, not misread.

use std::collections::{HashMap, VecDeque};
use std::io::{self, Read, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

pub const OPEN: u8 = 1;
pub const DATA: u8 = 2;
pub const CLOSE: u8 = 3;
pub const PING: u8 = 4;
pub const PONG: u8 = 5;

/// What `tern proxy` writes before its version line: a NUL, which no motd or rc file prints.
pub const MAGIC: &[u8] = b"\0tern-proxy ";
/// Shell startup output the link skips before giving up on finding `MAGIC`.
pub const MAX_PREAMBLE: usize = 1 << 20;
/// Largest payload in one frame.
pub const MAX_PAYLOAD: usize = 1 << 20;
/// Output a stream's receiver may fall behind by before the stream is closed. A pane's
/// `tern attach` reattaches and gets its screen again, so nothing is lost but a moment.
const QUEUE_BYTES: usize = 8 << 20;

pub fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

pub fn write_frame(w: &mut impl Write, stream: u32, kind: u8, payload: &[u8]) -> io::Result<()> {
    let mut buf = Vec::with_capacity(9 + payload.len());
    buf.extend_from_slice(&stream.to_be_bytes());
    buf.push(kind);
    buf.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    buf.extend_from_slice(payload);
    w.write_all(&buf)?;
    w.flush()
}

/// The next frame, or None at a clean end of the pipe.
pub fn read_frame(r: &mut impl Read, payload: &mut Vec<u8>) -> io::Result<Option<(u32, u8)>> {
    let mut header = [0u8; 9];
    match r.read_exact(&mut header) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e),
    }
    let stream = u32::from_be_bytes(header[..4].try_into().unwrap());
    let len = u32::from_be_bytes(header[5..].try_into().unwrap()) as usize;
    if len > MAX_PAYLOAD {
        return Err(io::Error::new(io::ErrorKind::InvalidData, format!("a {len}-byte frame is over the limit")));
    }
    payload.resize(len, 0);
    r.read_exact(payload)?;
    Ok(Some((stream, header[4])))
}

/// Reads past whatever the device's shell printed up to `MAGIC`, then the rest of that line:
/// the proxy's protocol number and version.
pub fn read_preamble(r: &mut impl Read) -> io::Result<String> {
    let mut seen = Vec::new();
    let mut byte = [0u8; 1];
    loop {
        if r.read(&mut byte)? == 0 {
            let printed = String::from_utf8_lossy(&seen).trim().chars().take(300).collect::<String>();
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, if printed.is_empty() {
                "the device closed the connection before tern started".to_string()
            } else {
                format!("the device closed the connection before tern started; it printed: {printed}")
            }));
        }
        seen.push(byte[0]);
        if seen.ends_with(MAGIC) {
            break;
        }
        if seen.len() > MAX_PREAMBLE {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "the device printed too much before tern started"));
        }
    }
    let mut line = Vec::new();
    while r.read(&mut byte)? == 1 && byte[0] != b'\n' {
        line.push(byte[0]);
        if line.len() > 256 {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "a malformed tern proxy greeting"));
        }
    }
    Ok(String::from_utf8_lossy(&line).into_owned())
}

/// Bytes waiting for one stream's local socket.
#[derive(Default)]
struct Outbox {
    state: Mutex<OutboxState>,
    ready: Condvar,
}

#[derive(Default)]
struct OutboxState {
    chunks: VecDeque<Vec<u8>>,
    bytes: usize,
    closed: bool,
}

impl Outbox {
    /// False once the receiver is too far behind, or the stream closed.
    fn push(&self, bytes: &[u8]) -> bool {
        let mut st = self.state.lock().unwrap();
        if st.closed || st.bytes + bytes.len() > QUEUE_BYTES {
            st.closed = true;
            self.ready.notify_all();
            return false;
        }
        st.bytes += bytes.len();
        st.chunks.push_back(bytes.to_vec());
        self.ready.notify_all();
        true
    }

    fn close(&self) {
        self.state.lock().unwrap().closed = true;
        self.ready.notify_all();
    }

    /// The next chunk; None once closed and drained of nothing more to send.
    fn pop(&self) -> Option<Vec<u8>> {
        let mut st = self.state.lock().unwrap();
        loop {
            if let Some(chunk) = st.chunks.pop_front() {
                st.bytes -= chunk.len();
                return Some(chunk);
            }
            if st.closed {
                return None;
            }
            st = self.ready.wait(st).unwrap();
        }
    }
}

struct Stream {
    socket: UnixStream,
    outbox: Arc<Outbox>,
}

/// One end of the pipe and the streams riding it.
pub struct Mux {
    writer: Mutex<Box<dyn Write + Send>>,
    streams: Mutex<HashMap<u32, Stream>>,
    next: AtomicU32,
    /// When a frame last arrived, for the link's liveness check.
    last_rx_ms: AtomicU64,
    dead: Mutex<bool>,
}

impl Mux {
    pub fn new(writer: Box<dyn Write + Send>) -> Arc<Mux> {
        Arc::new(Mux {
            writer: Mutex::new(writer),
            streams: Mutex::new(HashMap::new()),
            next: AtomicU32::new(1),
            last_rx_ms: AtomicU64::new(now_ms()),
            dead: Mutex::new(false),
        })
    }

    fn send(&self, stream: u32, kind: u8, payload: &[u8]) -> io::Result<()> {
        let result = write_frame(&mut *self.writer.lock().unwrap(), stream, kind, payload);
        if result.is_err() {
            *self.dead.lock().unwrap() = true;
        }
        result
    }

    pub fn is_dead(&self) -> bool {
        *self.dead.lock().unwrap()
    }

    pub fn last_rx_ms(&self) -> u64 {
        self.last_rx_ms.load(Ordering::Relaxed)
    }

    pub fn ping(&self) -> io::Result<()> {
        self.send(0, PING, &[])
    }

    pub fn streams(&self) -> usize {
        self.streams.lock().unwrap().len()
    }

    /// The link's side: carries a local client's connection to the device.
    pub fn open(self: &Arc<Self>, socket: UnixStream) -> io::Result<u32> {
        let id = self.next.fetch_add(2, Ordering::Relaxed);
        self.send(id, OPEN, &[])?;
        self.attach(id, socket)?;
        Ok(id)
    }

    /// Starts relaying between `socket` and stream `id`.
    fn attach(self: &Arc<Self>, id: u32, socket: UnixStream) -> io::Result<()> {
        let outbox = Arc::new(Outbox::default());
        let reader = socket.try_clone()?;
        let writer = socket.try_clone()?;
        self.streams.lock().unwrap().insert(id, Stream { socket, outbox: outbox.clone() });

        // Socket -> pipe.
        let mux = self.clone();
        std::thread::spawn(move || {
            let mut reader = reader;
            let mut buf = vec![0u8; 64 * 1024];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        if mux.send(id, DATA, &buf[..n]).is_err() {
                            break;
                        }
                    }
                }
            }
            mux.close(id, true);
        });

        // Pipe -> socket, through a bounded queue so one slow client can't hold up the rest.
        // Once the other side has closed the stream and the queue is empty, it hangs up here.
        let mux = self.clone();
        std::thread::spawn(move || {
            let mut writer = writer;
            while let Some(chunk) = outbox.pop() {
                if writer.write_all(&chunk).is_err() {
                    break;
                }
            }
            let _ = writer.shutdown(Shutdown::Both);
            mux.close(id, true);
        });
        Ok(())
    }

    /// The other side ended the stream: what it sent before still reaches the socket (a reply
    /// ternd writes just before hanging up), then the socket is hung up.
    fn finish(&self, id: u32) {
        let Some(stream) = self.streams.lock().unwrap().remove(&id) else { return };
        stream.outbox.close();
    }

    /// Ends a stream on this side at once, telling the other side when `tell`.
    fn close(&self, id: u32, tell: bool) {
        let Some(stream) = self.streams.lock().unwrap().remove(&id) else { return };
        stream.outbox.close();
        let _ = stream.socket.shutdown(Shutdown::Both);
        if tell {
            let _ = self.send(id, CLOSE, &[]);
        }
    }

    /// Ends every stream: the pipe is gone.
    pub fn close_all(&self) {
        *self.dead.lock().unwrap() = true;
        let all: Vec<_> = self.streams.lock().unwrap().drain().collect();
        for (_, stream) in all {
            stream.outbox.close();
            let _ = stream.socket.shutdown(Shutdown::Both);
        }
    }

    /// Reads frames until the pipe ends. `open` makes the socket for a stream the other side
    /// opened (the proxy's ternd connection); the link passes None and refuses them.
    pub fn run(self: &Arc<Self>, mut reader: impl Read, open: Option<&dyn Fn() -> io::Result<UnixStream>>) -> io::Result<()> {
        let mut payload = Vec::new();
        let result = loop {
            let frame = match read_frame(&mut reader, &mut payload) {
                Ok(Some(frame)) => frame,
                Ok(None) => break Ok(()),
                Err(e) => break Err(e),
            };
            self.last_rx_ms.store(now_ms(), Ordering::Relaxed);
            match frame {
                (0, PING) => {
                    if let Err(e) = self.send(0, PONG, &[]) {
                        break Err(e);
                    }
                }
                (0, _) => {}
                (id, OPEN) => {
                    let socket = match open {
                        Some(open) => open(),
                        None => Err(io::Error::other("this side doesn't take streams")),
                    };
                    match socket.and_then(|s| self.attach(id, s)) {
                        Ok(()) => {}
                        Err(_) => {
                            let _ = self.send(id, CLOSE, &[]);
                        }
                    }
                }
                (id, DATA) => {
                    let outbox = self.streams.lock().unwrap().get(&id).map(|s| s.outbox.clone());
                    // Behind by too much: hang up on it, and its client starts over.
                    if outbox.is_some_and(|o| !o.push(&payload)) {
                        self.close(id, true);
                    }
                }
                (id, CLOSE) => self.finish(id),
                _ => {}
            }
        };
        self.close_all();
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader};
    use std::time::Duration;

    #[test]
    fn frames_round_trip() {
        let mut wire = Vec::new();
        write_frame(&mut wire, 7, DATA, b"hello").unwrap();
        write_frame(&mut wire, 0, PING, b"").unwrap();
        let mut r = wire.as_slice();
        let mut buf = Vec::new();
        assert_eq!(read_frame(&mut r, &mut buf).unwrap(), Some((7, DATA)));
        assert_eq!(buf, b"hello");
        assert_eq!(read_frame(&mut r, &mut buf).unwrap(), Some((0, PING)));
        assert_eq!(read_frame(&mut r, &mut buf).unwrap(), None);
    }

    #[test]
    fn oversized_frames_are_refused() {
        let mut wire = vec![0, 0, 0, 1, DATA];
        wire.extend_from_slice(&u32::MAX.to_be_bytes());
        assert!(read_frame(&mut wire.as_slice(), &mut Vec::new()).is_err());
    }

    #[test]
    fn shell_noise_before_the_greeting_is_skipped() {
        let mut wire = b"Welcome to Ubuntu\nLast login: today\n".to_vec();
        wire.extend_from_slice(MAGIC);
        wire.extend_from_slice(b"3 0.0.5\nFRAMES");
        let mut r = wire.as_slice();
        assert_eq!(read_preamble(&mut r).unwrap(), "3 0.0.5");
        assert_eq!(r, b"FRAMES");
        // A device that hangs up says what it printed instead.
        let err = read_preamble(&mut &b"tern: command not found\n"[..]).unwrap_err();
        assert!(err.to_string().contains("command not found"), "{err}");
    }

    /// A link and a proxy joined by socket pairs, the proxy's streams reaching an echo server.
    fn joined() -> (Arc<Mux>, Arc<Mux>) {
        let (link_end, proxy_end) = UnixStream::pair().unwrap();
        let link = Mux::new(Box::new(link_end.try_clone().unwrap()));
        let proxy = Mux::new(Box::new(proxy_end.try_clone().unwrap()));
        {
            let link = link.clone();
            std::thread::spawn(move || link.run(link_end, None));
        }
        {
            let proxy = proxy.clone();
            std::thread::spawn(move || {
                let open = || {
                    let (ours, theirs) = UnixStream::pair()?;
                    // Answers each line with the line upper-cased, like a request and reply;
                    // after "bye", hangs up at once, as ternd does after a one-off request.
                    std::thread::spawn(move || {
                        let mut out = theirs.try_clone().unwrap();
                        for line in BufReader::new(theirs).lines() {
                            let Ok(line) = line else { break };
                            if writeln!(out, "{}", line.to_uppercase()).is_err() || line == "bye" {
                                break;
                            }
                        }
                    });
                    Ok(ours)
                };
                proxy.run(proxy_end, Some(&open))
            });
        }
        (link, proxy)
    }

    #[test]
    fn streams_carry_requests_and_replies_independently() {
        let (link, _proxy) = joined();
        let mut clients = Vec::new();
        for i in 0..3 {
            let (client, local) = UnixStream::pair().unwrap();
            link.open(local).unwrap();
            clients.push((i, client));
        }
        for (i, client) in &mut clients {
            writeln!(client, "pane {i}").unwrap();
        }
        for (i, client) in clients {
            client.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
            let mut line = String::new();
            BufReader::new(client).read_line(&mut line).unwrap();
            assert_eq!(line, format!("PANE {i}\n"));
        }
    }

    #[test]
    fn a_reply_sent_just_before_hanging_up_still_arrives() {
        let (link, _proxy) = joined();
        for _ in 0..50 {
            let (client, local) = UnixStream::pair().unwrap();
            client.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
            link.open(local).unwrap();
            writeln!(&client, "bye").unwrap();
            let mut got = String::new();
            BufReader::new(&client).read_to_string(&mut got).unwrap();
            assert_eq!(got, "BYE\n");
        }
    }

    #[test]
    fn a_client_hanging_up_closes_its_stream_on_both_sides() {
        let (link, proxy) = joined();
        let (client, local) = UnixStream::pair().unwrap();
        link.open(local).unwrap();
        let mut client = client;
        writeln!(client, "x").unwrap();
        let mut line = String::new();
        BufReader::new(client.try_clone().unwrap()).read_line(&mut line).unwrap();
        drop(client);
        let until = std::time::Instant::now() + Duration::from_secs(5);
        while (link.streams() > 0 || proxy.streams() > 0) && std::time::Instant::now() < until {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!((link.streams(), proxy.streams()), (0, 0));
    }

    #[test]
    fn the_pipe_ending_ends_every_stream() {
        let (link_end, proxy_end) = UnixStream::pair().unwrap();
        let link = Mux::new(Box::new(link_end.try_clone().unwrap()));
        let runner = {
            let link = link.clone();
            std::thread::spawn(move || link.run(link_end, None))
        };
        let (client, local) = UnixStream::pair().unwrap();
        // macOS refuses socket options once the other end has shut down.
        client.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        link.open(local).unwrap();
        drop(proxy_end);
        // Linux reports the unread OPEN frame as a reset rather than an end; either ends the pipe.
        let _ = runner.join().unwrap();
        // The client reads end of file, as from a ternd that went away.
        assert_eq!((&client).read(&mut [0u8; 8]).unwrap(), 0);
        assert!(link.is_dead());
    }

    #[test]
    fn a_receiver_too_far_behind_loses_only_its_stream() {
        let outbox = Outbox::default();
        let chunk = vec![0u8; 1 << 20];
        let fits = (0..64).take_while(|_| outbox.push(&chunk)).count();
        assert_eq!(fits, QUEUE_BYTES / chunk.len());
        assert!(!outbox.push(b"x"));
        // What was queued still drains before the end.
        assert_eq!(outbox.pop().map(|c| c.len()), Some(chunk.len()));
    }

    #[test]
    fn pings_are_answered() {
        let (link, _proxy) = joined();
        let before = link.last_rx_ms();
        std::thread::sleep(Duration::from_millis(5));
        link.ping().unwrap();
        let until = std::time::Instant::now() + Duration::from_secs(5);
        while link.last_rx_ms() == before && std::time::Instant::now() < until {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(link.last_rx_ms() > before);
    }
}
