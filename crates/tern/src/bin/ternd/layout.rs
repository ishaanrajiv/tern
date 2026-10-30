//! Window layouts: the folders, tabs and split panes each window shows.
//!
//! ternd keeps them and is the only one to write them, in the files the app used to
//! write itself (`layout.json` for the main window, `windows/<id>.json` for others), so
//! `tern split` and `tern tab` work with the app quit and answer with the pane they made.
//! The app reads what ternd hands it with its own forgiving decoding, and keeps a copy
//! of anything it can't read aside, as it always has.

use std::collections::{BTreeMap, HashMap, VecDeque};
use std::io::{Read, Write};
use std::path::PathBuf;
use std::sync::{Condvar, Mutex};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use tern::{LayoutReply, LayoutUpdate, PaneReply, Target};

/// The layout version the app writes; a file of another version is kept aside by the app.
const LAYOUT_VERSION: u64 = 1;
/// Updates kept for watchers that fall behind; one further back gets every layout again.
const BACKLOG: usize = 64;

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Axis {
    /// Side by side (split right).
    Horizontal,
    /// Stacked (split down).
    Vertical,
}

/// A tab's panes, in the shape Swift's synthesized `Codable` gives the app's `SplitNode`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Node {
    Pane {
        #[serde(rename = "_0")]
        id: String,
    },
    Split {
        #[serde(rename = "_0")]
        axis: Axis,
        ratio: f64,
        #[serde(rename = "_2")]
        first: Box<Node>,
        #[serde(rename = "_3")]
        second: Box<Node>,
    },
}

impl Node {
    pub fn panes(&self) -> Vec<&str> {
        match self {
            Node::Pane { id } => vec![id],
            Node::Split { first, second, .. } => {
                let mut all = first.panes();
                all.extend(second.panes());
                all
            }
        }
    }

    fn split(&self, pane: &str, axis: Axis, new: &str) -> Node {
        match self {
            Node::Pane { id } if id == pane => Node::Split {
                axis,
                ratio: 0.5,
                first: Box::new(self.clone()),
                second: Box::new(Node::Pane { id: new.into() }),
            },
            Node::Pane { .. } => self.clone(),
            Node::Split { axis: a, ratio, first, second } => Node::Split {
                axis: *a,
                ratio: *ratio,
                first: Box::new(first.split(pane, axis, new)),
                second: Box::new(second.split(pane, axis, new)),
            },
        }
    }

    /// The tree without `pane`, or None if it was the only one, and the pane that took its place.
    fn removing(&self, pane: &str) -> Option<(Node, Option<String>)> {
        match self {
            Node::Pane { id } if id == pane => None,
            Node::Pane { .. } => Some((self.clone(), None)),
            Node::Split { axis, ratio, first, second } => match (first.removing(pane), second.removing(pane)) {
                (None, _) => Some((*second.clone(), second.panes().first().map(|p| p.to_string()))),
                (_, None) => Some((*first.clone(), first.panes().last().map(|p| p.to_string()))),
                (Some((a, fa)), Some((b, fb))) => Some((
                    Node::Split { axis: *axis, ratio: *ratio, first: Box::new(a), second: Box::new(b) },
                    fa.or(fb),
                )),
            },
        }
    }

    /// For `tern ls --json`: "right"/"down" rather than the app's axis names.
    fn describe(&self) -> Value {
        match self {
            Node::Pane { id } => serde_json::json!({ "pane": id }),
            Node::Split { axis, ratio, first, second } => serde_json::json!({
                "split": if *axis == Axis::Horizontal { "right" } else { "down" },
                "ratio": ratio,
                "first": first.describe(),
                "second": second.describe(),
            }),
        }
    }
}

/// A window's layout. Fields ternd doesn't touch (recents, closed tabs...) pass through as they are.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Doc {
    #[serde(default)]
    pub projects: Vec<Project>,
    #[serde(rename = "selectedTabID", default, skip_serializing_if = "Option::is_none")]
    pub selected_tab: Option<String>,
    #[serde(default)]
    pub pane_cwd: BTreeMap<String, String>,
    /// Names given with `--name`, which CLI commands can address a pane by.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub pane_name: BTreeMap<String, String>,
    /// The agent or program that opened a pane from the CLI, which its header names.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub pane_opener: BTreeMap<String, String>,
    #[serde(flatten)]
    pub rest: Map<String, Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Project {
    pub path: String,
    #[serde(default)]
    pub tabs: Vec<Tab>,
    #[serde(flatten)]
    pub rest: Map<String, Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Tab {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    pub root: Node,
    pub focused_pane: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub number: Option<u64>,
    #[serde(flatten)]
    pub rest: Map<String, Value>,
}

impl Doc {
    fn tabs(&self) -> impl Iterator<Item = (usize, usize, &Tab)> {
        self.projects.iter().enumerate().flat_map(|(p, project)| project.tabs.iter().enumerate().map(move |(t, tab)| (p, t, tab)))
    }

    fn find_pane(&self, pane: &str) -> Option<(usize, usize)> {
        self.tabs().find(|(_, _, tab)| tab.root.panes().contains(&pane)).map(|(p, t, _)| (p, t))
    }

    /// Splits `pane` and puts `new` beside it. Focus stays where it was unless asked.
    pub fn split(&mut self, pane: &str, axis: Axis, new: &str, cwd: &str, focus: bool) -> Option<String> {
        let (p, t) = self.find_pane(pane)?;
        let tab = &mut self.projects[p].tabs[t];
        tab.root = tab.root.split(pane, axis, new);
        if focus {
            tab.focused_pane = new.into();
            tab.rest.insert("zoomed".into(), Value::Bool(false));
        }
        let id = tab.id.clone();
        if focus { self.select(&id) }
        self.pane_cwd.insert(new.into(), cwd.into());
        Some(id)
    }

    /// Adds a tab with one pane to the folder at `path`, which gets a header if it has none.
    pub fn new_tab(&mut self, path: &str, pane: &str, tab_id: &str, cwd: &str, focus: bool) {
        let p = match self.projects.iter().position(|project| project.path == path) {
            Some(p) => p,
            None => {
                let mut rest = Map::new();
                rest.insert("collapsed".into(), Value::Bool(false));
                self.projects.push(Project { path: path.into(), tabs: vec![], rest });
                self.projects.len() - 1
            }
        };
        let project = &mut self.projects[p];
        let used: Vec<u64> = project.tabs.iter().filter_map(|tab| tab.number).collect();
        let number = (1..).find(|n| !used.contains(n)).unwrap();
        project.tabs.push(Tab {
            id: tab_id.into(),
            name: None,
            root: Node::Pane { id: pane.into() },
            focused_pane: pane.into(),
            number: Some(number),
            rest: Map::new(),
        });
        if project.tabs.len() == 1 { project.rest.insert("lastTab".into(), tab_id.into()); }
        if focus || self.selected_tab.is_none() { self.select(tab_id) }
        self.pane_cwd.insert(pane.into(), cwd.into());
    }

    fn select(&mut self, tab_id: &str) {
        self.selected_tab = Some(tab_id.into());
        if let Some(project) = self.projects.iter_mut().find(|p| p.tabs.iter().any(|t| t.id == tab_id)) {
            project.rest.insert("collapsed".into(), Value::Bool(false));
            project.rest.insert("lastTab".into(), tab_id.into());
        }
    }

    /// Takes `pane` out of its tab; the tab goes with its last pane and the folder with its last tab.
    pub fn remove(&mut self, pane: &str) -> bool {
        let Some((p, t)) = self.find_pane(pane) else { return false };
        let tab = &mut self.projects[p].tabs[t];
        match tab.root.removing(pane) {
            Some((root, heir)) => {
                if tab.focused_pane == pane {
                    tab.focused_pane = heir.unwrap_or_else(|| root.panes()[0].to_string());
                }
                tab.root = root;
            }
            None => {
                let order: Vec<String> = self.tabs().map(|(_, _, tab)| tab.id.clone()).collect();
                let id = self.projects[p].tabs.remove(t).id;
                let project = &mut self.projects[p];
                if project.rest.get("lastTab").and_then(Value::as_str) == Some(id.as_str()) {
                    project.rest.remove("lastTab");
                }
                let sibling = (!project.tabs.is_empty()).then(|| project.tabs[t.min(project.tabs.len() - 1)].id.clone());
                if project.tabs.is_empty() { self.projects.remove(p); }
                if self.selected_tab.as_deref() == Some(id.as_str()) {
                    let left: Vec<String> = self.tabs().map(|(_, _, tab)| tab.id.clone()).collect();
                    let i = order.iter().position(|x| *x == id).unwrap_or(0);
                    self.selected_tab = sibling.or_else(|| (!left.is_empty()).then(|| left[i.min(left.len() - 1)].clone()));
                }
            }
        }
        self.pane_cwd.remove(pane);
        self.pane_name.remove(pane);
        self.pane_opener.remove(pane);
        for key in ["paneAgent", "paneRemote"] {
            if let Some(Value::Object(map)) = self.rest.get_mut(key) { map.remove(pane); }
        }
        true
    }
}

struct Window {
    /// Absent until a layout is written for it.
    doc: Option<Value>,
    rev: u64,
}

#[derive(Default)]
struct Inner {
    windows: HashMap<String, Window>,
    seq: u64,
    backlog: VecDeque<(u64, LayoutUpdate)>,
}

#[derive(Default)]
pub struct Store {
    inner: Mutex<Inner>,
    changed: Condvar,
}

/// "main" or the app's `w-<uuid>`; anything else could name a path.
pub fn valid_window(id: &str) -> bool {
    id == "main" || (id.len() > 2 && id.len() <= 64 && id.starts_with("w-") && id[2..].chars().all(|c| c.is_ascii_hexdigit() || c == '-'))
}

fn window_path(id: &str) -> PathBuf {
    let dir = tern::runtime_dir();
    if id == "main" { dir.join("layout.json") } else { dir.join("windows").join(format!("{id}.json")) }
}

/// The app's windows, from the list it keeps beside the layouts, and which one was in front.
fn open_windows() -> Vec<(String, bool)> {
    #[derive(Deserialize)]
    struct Record {
        id: String,
        #[serde(default)]
        active: bool,
    }
    let records: Vec<(String, bool)> = std::fs::read(tern::runtime_dir().join("windows.json")).ok()
        .and_then(|data| serde_json::from_slice::<Vec<Value>>(&data).ok())
        .unwrap_or_default()
        .into_iter()
        .filter_map(|v| serde_json::from_value::<Record>(v).ok())
        .filter(|r| valid_window(&r.id))
        .map(|r| (r.id, r.active))
        .collect();
    if records.is_empty() { vec![("main".into(), true)] } else { records }
}

/// A random id like the app's: `p-1a2b3c4d`.
pub fn new_id(prefix: &str) -> String {
    let mut bytes = [0u8; 4];
    if std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut bytes)).is_err() {
        let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_nanos();
        bytes = (nanos as u32 ^ std::process::id()).to_be_bytes();
    }
    format!("{prefix}-{:02x}{:02x}{:02x}{:02x}", bytes[0], bytes[1], bytes[2], bytes[3])
}

/// Where a CLI command's pane is.
#[derive(Debug, Clone, PartialEq)]
pub struct Found {
    pub pane: String,
    /// None for a session no window shows (detached).
    pub window: Option<String>,
    pub tab: Option<String>,
}

impl Store {
    fn load(inner: &mut Inner, id: &str) {
        if inner.windows.contains_key(id) { return }
        let doc = std::fs::read(window_path(id)).ok().and_then(|data| serde_json::from_slice(&data).ok());
        inner.windows.insert(id.into(), Window { doc, rev: 0 });
    }

    pub fn get(&self, id: &str) -> LayoutReply {
        let mut inner = self.inner.lock().unwrap();
        Self::load(&mut inner, id);
        let window = &inner.windows[id];
        LayoutReply { ok: true, rev: window.rev, doc: window.doc.clone(), error: None }
    }

    pub fn put(&self, id: &str, base: u64, doc: Value, by: &str) -> LayoutReply {
        let mut inner = self.inner.lock().unwrap();
        Self::load(&mut inner, id);
        let window = &inner.windows[id];
        if window.rev != base {
            return LayoutReply { ok: false, rev: window.rev, doc: window.doc.clone(), error: Some("the layout changed".into()) };
        }
        let result = Self::commit(&mut inner, id, doc, by);
        let rev = inner.windows[id].rev;
        drop(inner);
        match result {
            Ok(rev) => {
                self.notify();
                LayoutReply { ok: true, rev, doc: None, error: None }
            }
            Err(e) => LayoutReply { ok: false, rev, doc: None, error: Some(format!("saving the layout: {e}")) },
        }
    }

    /// Saves a window's new layout and tells watchers.
    fn commit(inner: &mut Inner, id: &str, doc: Value, by: &str) -> std::io::Result<u64> {
        let data = serde_json::to_vec_pretty(&doc).map_err(std::io::Error::other)?;
        write_private(&window_path(id), &data)?;
        let window = inner.windows.get_mut(id).unwrap();
        window.rev += 1;
        window.doc = Some(doc.clone());
        let update = LayoutUpdate { window: id.into(), rev: window.rev, doc, by: by.into() };
        inner.seq += 1;
        let seq = inner.seq;
        inner.backlog.push_back((seq, update));
        while inner.backlog.len() > BACKLOG { inner.backlog.pop_front(); }
        Ok(window.rev)
    }

    /// Calls `send` with each change after `since` as it happens; returns when `send` fails.
    pub fn watch(&self, mut send: impl FnMut(&LayoutUpdate) -> bool) {
        let mut since = self.inner.lock().unwrap().seq;
        loop {
            let pending: Vec<LayoutUpdate> = {
                let mut inner = self.changed.wait_while(self.inner.lock().unwrap(), |inner| inner.seq == since).unwrap();
                let behind = inner.backlog.front().is_some_and(|(seq, _)| *seq > since + 1);
                let pending = if behind {
                    // Too far behind for the backlog: every layout as it is now.
                    let ids: Vec<String> = inner.windows.keys().cloned().collect();
                    ids.into_iter().filter_map(|id| {
                        Self::load(&mut inner, &id);
                        let w = &inner.windows[&id];
                        w.doc.clone().map(|doc| LayoutUpdate { window: id.clone(), rev: w.rev, doc, by: String::new() })
                    }).collect()
                } else {
                    inner.backlog.iter().filter(|(seq, _)| *seq > since).map(|(_, u)| u.clone()).collect()
                };
                since = inner.seq;
                pending
            };
            if !pending.iter().all(&mut send) { return }
        }
    }

    pub fn notify(&self) { self.changed.notify_all() }

    /// The open windows' layouts that parse, in window order, and which window is in front.
    fn docs(inner: &mut Inner) -> Vec<(String, bool, Doc)> {
        open_windows().into_iter().filter_map(|(id, active)| {
            Self::load(inner, &id);
            let doc = inner.windows[&id].doc.clone().map(serde_json::from_value::<Doc>).unwrap_or(Ok(Doc::default())).ok()?;
            Some((id, active, doc))
        }).collect()
    }

    /// The pane a CLI command means. `exists` says whether ternd has a session by that id,
    /// so a session no window shows can still be addressed by its id.
    pub fn resolve(&self, target: &Target, exists: impl Fn(&str) -> bool) -> Result<Found, Box<PaneReply>> {
        let docs = Self::docs(&mut self.inner.lock().unwrap());
        resolve(&docs, target, exists)
    }

    /// Opens a pane beside `pane` (or in a new tab) in whichever window shows it, and saves.
    /// `make` gets the window, tab and pane and starts the session; nothing is saved if it fails.
    pub fn open(&self, change: Change, make: impl FnOnce(&str) -> Result<(), String>) -> PaneReply {
        let mut inner = self.inner.lock().unwrap();
        let docs = Self::docs(&mut inner);
        if let Some(name) = &change.name {
            if docs.iter().any(|(_, _, doc)| doc.pane_name.values().any(|n| n == name)) {
                return PaneReply::failed(format!("a pane is already named {name}"), None);
            }
        }
        let pane = new_id("p");
        let tab_id = new_id("t");
        let (window, mut doc) = match &change.place {
            Place::Beside { pane: beside, .. } | Place::Tab { near: Some(beside), .. } => {
                match docs.iter().find(|(_, _, doc)| doc.find_pane(beside).is_some()) {
                    Some((id, _, doc)) => (id.clone(), doc.clone()),
                    None => return PaneReply::failed(format!("pane {beside} isn't in a window"), Some("not_found")),
                }
            }
            Place::Tab { folder, near: None } => {
                let showing = docs.iter().find(|(_, _, doc)| doc.projects.iter().any(|p| p.path == *folder));
                let front = docs.iter().find(|(_, active, _)| *active).or(docs.first());
                match showing.or(front) {
                    Some((id, _, doc)) => (id.clone(), doc.clone()),
                    None => ("main".into(), Doc::default()),
                }
            }
        };
        let tab = match &change.place {
            Place::Beside { pane: beside, axis } => match doc.split(beside, *axis, &pane, &change.cwd, change.focus) {
                Some(tab) => tab,
                None => return PaneReply::failed(format!("pane {beside} isn't in a window"), Some("not_found")),
            },
            Place::Tab { folder, near } => {
                // A tab opened from a pane goes in that pane's folder unless told otherwise.
                let path = near.as_ref().filter(|_| folder.is_empty())
                    .and_then(|near| doc.find_pane(near)).map(|(p, _)| doc.projects[p].path.clone())
                    .unwrap_or_else(|| folder.clone());
                doc.new_tab(&path, &pane, &tab_id, &change.cwd, change.focus);
                tab_id
            }
        };
        if let Some(name) = &change.name { doc.pane_name.insert(pane.clone(), name.clone()); }
        if let Some(opener) = &change.opener { doc.pane_opener.insert(pane.clone(), opener.clone()); }
        doc.rest.entry("version").or_insert(LAYOUT_VERSION.into());
        if let Err(e) = make(&pane) { return PaneReply::failed(e, None) }
        let value = match serde_json::to_value(&doc) {
            Ok(value) => value,
            Err(e) => return PaneReply::failed(e.to_string(), None),
        };
        if let Err(e) = Self::commit(&mut inner, &window, value, "cli") {
            return PaneReply::failed(format!("saving the layout: {e}"), None);
        }
        drop(inner);
        self.notify();
        PaneReply { ok: true, pane: Some(pane), tab: Some(tab), window: Some(window), ..Default::default() }
    }

    /// Takes a pane out of whichever window shows it.
    pub fn remove(&self, pane: &str) -> bool {
        let mut inner = self.inner.lock().unwrap();
        let docs = Self::docs(&mut inner);
        let Some((window, _, mut doc)) = docs.into_iter().find(|(_, _, doc)| doc.find_pane(pane).is_some()) else { return false };
        doc.remove(pane);
        let ok = serde_json::to_value(&doc).ok().is_some_and(|value| Self::commit(&mut inner, &window, value, "cli").is_ok());
        drop(inner);
        self.notify();
        ok
    }

    /// Every open window's tabs and panes, for `tern ls --json`.
    pub fn tree(&self) -> Value {
        let docs = Self::docs(&mut self.inner.lock().unwrap());
        let windows: Vec<Value> = docs.iter().map(|(id, active, doc)| {
            let folders: Vec<Value> = doc.projects.iter().map(|project| {
                let tabs: Vec<Value> = project.tabs.iter().map(|tab| {
                    let panes: Vec<Value> = tab.root.panes().into_iter().map(|pane| serde_json::json!({
                        "id": pane,
                        "name": doc.pane_name.get(pane),
                        "opened_by": doc.pane_opener.get(pane),
                        "focused": tab.focused_pane == pane,
                    })).collect();
                    serde_json::json!({
                        "id": tab.id,
                        "name": tab.name,
                        "selected": doc.selected_tab.as_deref() == Some(tab.id.as_str()),
                        "layout": tab.root.describe(),
                        "panes": panes,
                    })
                }).collect();
                serde_json::json!({ "path": project.path, "tabs": tabs })
            }).collect();
            serde_json::json!({ "id": id, "active": active, "folders": folders })
        }).collect();
        serde_json::json!({ "windows": windows })
    }
}

/// What `Store::open` adds.
pub struct Change {
    pub place: Place,
    pub cwd: String,
    pub name: Option<String>,
    pub opener: Option<String>,
    pub focus: bool,
}

pub enum Place {
    Beside { pane: String, axis: Axis },
    /// A new tab in `folder`, or with an empty folder, in the folder of the pane `near`.
    Tab { folder: String, near: Option<String> },
}

fn resolve(docs: &[(String, bool, Doc)], target: &Target, exists: impl Fn(&str) -> bool) -> Result<Found, Box<PaneReply>> {
    let locate = |pane: &str| -> Found {
        for (id, _, doc) in docs {
            if let Some((p, t)) = doc.find_pane(pane) {
                return Found { pane: pane.into(), window: Some(id.clone()), tab: Some(doc.projects[p].tabs[t].id.clone()) };
            }
        }
        Found { pane: pane.into(), window: None, tab: None }
    };
    let not_found = |what: String| Box::new(PaneReply::failed(format!("no {what}"), Some("not_found")));
    if let Some(tab) = &target.tab {
        let matches: Vec<&Tab> = docs.iter().flat_map(|(_, _, doc)| doc.tabs().map(|(_, _, t)| t))
            .filter(|t| t.id == *tab || t.name.as_deref() == Some(tab.as_str())).collect();
        return match matches.as_slice() {
            [] => Err(not_found(format!("tab {tab}"))),
            [one] => Ok(locate(&one.focused_pane)),
            _ => Err(Box::new(PaneReply::failed(format!("{} tabs are named {tab}; use the tab id", matches.len()), Some("ambiguous")))),
        };
    }
    match target.pane.as_deref() {
        Some("@focused") => {
            let front = docs.iter().find(|(_, active, _)| *active).or(docs.first());
            front.and_then(|(_, _, doc)| {
                let selected = doc.selected_tab.as_ref()?;
                doc.tabs().find(|(_, _, t)| t.id == *selected).map(|(_, _, t)| locate(&t.focused_pane))
            }).ok_or_else(|| not_found("focused pane".into()))
        }
        Some(pane) => {
            let in_layout = docs.iter().any(|(_, _, doc)| doc.find_pane(pane).is_some());
            if in_layout || exists(pane) { return Ok(locate(pane)) }
            let named: Vec<&String> = docs.iter().flat_map(|(_, _, doc)| doc.pane_name.iter())
                .filter(|(_, name)| *name == pane).map(|(id, _)| id).collect();
            match named.as_slice() {
                [] => Err(not_found(format!("pane {pane}"))),
                [one] => Ok(locate(one)),
                _ => Err(Box::new(PaneReply::failed(format!("{} panes are named {pane}; use the pane id", named.len()), Some("ambiguous")))),
            }
        }
        None => match target.caller.as_deref() {
            Some(caller) if exists(caller) => Ok(locate(caller)),
            _ => Err(Box::new(PaneReply::failed("not running in a tern pane; pass --pane or --tab", Some("not_found")))),
        },
    }
}

/// Writes through a temporary file, so a crash never leaves half a layout.
fn write_private(path: &std::path::Path, data: &[u8]) -> std::io::Result<()> {
    use std::os::unix::fs::OpenOptionsExt;
    if let Some(dir) = path.parent() { std::fs::create_dir_all(dir)?; }
    let tmp = path.with_extension("json.tmp");
    let mut file = std::fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(&tmp)?;
    file.write_all(data)?;
    file.sync_all()?;
    std::fs::rename(&tmp, path)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// As the app writes it (sorted keys, Swift's enum encoding).
    const SAVED: &str = r#"{
      "closedTabs" : [],
      "paneAgent" : { "p-2" : { "agent" : "claude", "session" : "abc" } },
      "paneCwd" : { "p-1" : "/repo", "p-2" : "/repo" },
      "projects" : [ {
        "collapsed" : true, "lastTab" : "t-1", "path" : "/repo",
        "tabs" : [ {
          "focusedPane" : "p-1", "id" : "t-1", "number" : 1, "zoomed" : false, "worktree" : "/wt",
          "root" : { "split" : { "_0" : "horizontal", "ratio" : 0.3,
            "_2" : { "pane" : { "_0" : "p-1" } }, "_3" : { "pane" : { "_0" : "p-2" } } } }
        } ]
      } ],
      "recents" : { "/repo" : 815073187.4 },
      "selectedTabID" : "t-1",
      "version" : 1
    }"#;

    fn doc() -> Doc { serde_json::from_str(SAVED).unwrap() }

    #[test]
    fn the_apps_layout_reads_and_writes_back_unchanged() {
        let original: Value = serde_json::from_str(SAVED).unwrap();
        assert_eq!(serde_json::to_value(doc()).unwrap(), original);
        assert_eq!(doc().projects[0].tabs[0].root.panes(), ["p-1", "p-2"]);
    }

    #[test]
    fn a_split_goes_beside_its_pane_and_leaves_focus_alone() {
        let mut d = doc();
        assert_eq!(d.split("p-2", Axis::Vertical, "p-3", "/repo/sub", false).as_deref(), Some("t-1"));
        let tab = &d.projects[0].tabs[0];
        assert_eq!(tab.root.panes(), ["p-1", "p-2", "p-3"]);
        assert_eq!(tab.focused_pane, "p-1");
        assert_eq!(d.pane_cwd["p-3"], "/repo/sub");
        let Node::Split { second, ratio, .. } = &tab.root else { panic!() };
        assert_eq!(*ratio, 0.3);
        assert!(matches!(&**second, Node::Split { axis: Axis::Vertical, ratio, .. } if *ratio == 0.5));
        assert!(d.split("p-9", Axis::Vertical, "p-4", "/", false).is_none());
    }

    #[test]
    fn a_focused_split_selects_its_tab() {
        let mut d = doc();
        d.new_tab("/other", "p-5", "t-5", "/other", false);
        assert_eq!(d.selected_tab.as_deref(), Some("t-1"));
        d.split("p-5", Axis::Horizontal, "p-6", "/other", true);
        assert_eq!(d.selected_tab.as_deref(), Some("t-5"));
        assert_eq!(d.projects[1].tabs[0].focused_pane, "p-6");
    }

    #[test]
    fn new_tabs_take_the_lowest_free_number_and_new_folders_get_a_header() {
        let mut d = doc();
        d.new_tab("/repo", "p-3", "t-3", "/repo", false);
        d.new_tab("/elsewhere", "p-4", "t-4", "/elsewhere", false);
        assert_eq!(d.projects[0].tabs[1].number, Some(2));
        assert_eq!(d.projects[1].path, "/elsewhere");
        assert_eq!(d.projects[1].tabs[0].number, Some(1));
        assert_eq!(d.selected_tab.as_deref(), Some("t-1"));
    }

    #[test]
    fn removing_panes_collapses_splits_then_tabs_then_folders() {
        let mut d = doc();
        assert!(d.remove("p-1"));
        let tab = &d.projects[0].tabs[0];
        assert_eq!(tab.root, Node::Pane { id: "p-2".into() });
        assert_eq!(tab.focused_pane, "p-2");
        assert!(!d.pane_cwd.contains_key("p-1"));
        assert!(d.remove("p-2"));
        assert!(d.projects.is_empty());
        assert_eq!(d.selected_tab, None);
        assert_eq!(d.rest["paneAgent"], serde_json::json!({}));
        assert!(!d.remove("p-2"));
    }

    #[test]
    fn closing_a_selected_tab_selects_its_neighbour() {
        let mut d = doc();
        d.new_tab("/repo", "p-3", "t-3", "/repo", false);
        d.new_tab("/repo", "p-4", "t-4", "/repo", true);
        d.remove("p-4");
        assert_eq!(d.selected_tab.as_deref(), Some("t-3"));
    }

    fn docs() -> Vec<(String, bool, Doc)> {
        let mut main = doc();
        main.pane_name.insert("p-2".into(), "tests".into());
        let mut other = Doc::default();
        other.new_tab("/b", "p-7", "t-7", "/b", true);
        other.pane_name.insert("p-7".into(), "server".into());
        other.projects[0].tabs[0].name = Some("api".into());
        vec![("main".into(), false, main), ("w-1".into(), true, other)]
    }

    fn target(pane: Option<&str>, tab: Option<&str>, caller: Option<&str>) -> Target {
        Target { pane: pane.map(Into::into), tab: tab.map(Into::into), caller: caller.map(Into::into) }
    }

    #[test]
    fn targets_resolve_by_id_name_tab_focus_and_caller() {
        let none = |_: &str| false;
        let found = |pane: &str, window: &str, tab: &str| Found { pane: pane.into(), window: Some(window.into()), tab: Some(tab.into()) };
        assert_eq!(resolve(&docs(), &target(Some("p-1"), None, None), none), Ok(found("p-1", "main", "t-1")));
        assert_eq!(resolve(&docs(), &target(Some("tests"), None, None), none), Ok(found("p-2", "main", "t-1")));
        assert_eq!(resolve(&docs(), &target(None, Some("api"), None), none), Ok(found("p-7", "w-1", "t-7")));
        assert_eq!(resolve(&docs(), &target(Some("@focused"), None, None), none), Ok(found("p-7", "w-1", "t-7")));
        assert_eq!(resolve(&docs(), &target(None, None, Some("p-2")), |id| id == "p-2"), Ok(found("p-2", "main", "t-1")));
        // A session no window shows is still reachable by id.
        assert_eq!(resolve(&docs(), &target(Some("p-x"), None, None), |id| id == "p-x"),
                   Ok(Found { pane: "p-x".into(), window: None, tab: None }));
    }

    #[test]
    fn unknown_and_ambiguous_targets_say_which() {
        let none = |_: &str| false;
        let reason = |r: Result<Found, Box<PaneReply>>| r.unwrap_err().reason.unwrap();
        assert_eq!(reason(resolve(&docs(), &target(Some("nope"), None, None), none)), "not_found");
        assert_eq!(reason(resolve(&docs(), &target(None, None, None), none)), "not_found");
        let mut twice = docs();
        twice[1].2.pane_name.insert("p-7".into(), "tests".into());
        assert_eq!(reason(resolve(&twice, &target(Some("tests"), None, None), none)), "ambiguous");
    }

    #[test]
    fn window_ids_cannot_name_paths() {
        assert!(valid_window("main"));
        assert!(valid_window("w-0a1b-2c"));
        assert!(!valid_window("w-../../x"));
        assert!(!valid_window("other"));
    }
}
