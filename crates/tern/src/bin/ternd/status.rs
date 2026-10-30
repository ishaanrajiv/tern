//! OSC 7501 program status records, kept per session as the protocol describes:
//! one record per id, each report replacing its record, and records dropped at
//! the shell's next prompt or once the user has seen them.
//! https://www.superlogical.com/rex/docs/build/program-status

use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use tern::{AgentState, BlockKind};

use crate::vt::{Report, ReportState};

/// The protocol's cap. The record updated longest ago makes room for a new one.
const MAX_RECORDS: usize = 256;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Record {
    pub state: AgentState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<BlockKind>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub progress: Option<u8>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub app: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    pub at_ms: u64,
}

/// What the session shows: its most urgent record.
#[derive(Debug, Clone, PartialEq)]
pub struct Summary {
    pub state: AgentState,
    pub kind: Option<BlockKind>,
    pub progress: Option<u8>,
    /// The record's app, or its nearest ancestor's.
    pub app: Option<String>,
    /// The message, or failing that the title.
    pub message: Option<String>,
    pub at_ms: u64,
    pub records: usize,
}

/// Records by id; the empty id is the root record, the program itself.
#[derive(Default)]
pub struct Records(HashMap<String, Record>);

impl Records {
    pub fn apply(&mut self, report: Report, at_ms: u64) {
        let state = match report.state {
            ReportState::Clear => {
                self.clear(&report.id);
                return;
            }
            ReportState::Idle => AgentState::Idle,
            ReportState::Working => AgentState::Working,
            ReportState::Blocked => AgentState::NeedsYou,
            ReportState::Done => AgentState::Done,
            ReportState::Error => AgentState::Failed,
        };
        let text = |s: String| Some(clean(&s)).filter(|s| !s.is_empty());
        let record = Record {
            state,
            kind: report.kind.filter(|_| state == AgentState::NeedsYou),
            progress: report.progress.filter(|_| matches!(state, AgentState::Working | AgentState::NeedsYou)),
            app: Some(report.app).filter(|a| !a.is_empty()),
            title: text(report.title),
            message: text(report.message),
            at_ms,
        };
        if !self.0.contains_key(&report.id) && self.0.len() >= MAX_RECORDS {
            if let Some(oldest) = self.0.iter().min_by_key(|(_, r)| r.at_ms).map(|(id, _)| id.clone()) {
                self.0.remove(&oldest);
            }
        }
        self.0.insert(report.id, record);
    }

    /// The record with this id and every one beneath it; all of them for the empty id.
    fn clear(&mut self, id: &str) {
        if id.is_empty() {
            self.0.clear();
        } else {
            let below = format!("{id}/");
            self.0.retain(|k, _| k != id && !k.starts_with(&below));
        }
    }

    /// A new shell prompt: whatever was working or blocked has stopped.
    pub fn prompt(&mut self) {
        self.0.retain(|_, r| !matches!(r.state, AgentState::Working | AgentState::NeedsYou));
    }

    /// The user is back at the terminal: finished and failed records have been seen.
    pub fn seen(&mut self) {
        self.0.retain(|_, r| !matches!(r.state, AgentState::Done | AgentState::Failed));
    }

    /// Records worth keeping across a daemon restart, which ends whatever was running.
    pub fn lasting(&self) -> Vec<(String, Record)> {
        let mut kept: Vec<_> = self.0.iter()
            .filter(|(_, r)| matches!(r.state, AgentState::Done | AgentState::Failed))
            .map(|(id, r)| (id.clone(), r.clone()))
            .collect();
        kept.sort_by(|a, b| a.0.cmp(&b.0));
        kept
    }

    pub fn restore(&mut self, records: Vec<(String, Record)>) {
        for (id, record) in records.into_iter().take(MAX_RECORDS) {
            if matches!(record.state, AgentState::Done | AgentState::Failed) {
                self.0.insert(id, record);
            }
        }
    }

    /// The most urgent record (blocked, failed, done, working, idle), the latest of equals.
    pub fn summary(&self) -> Option<Summary> {
        let (id, r) = self.0.iter().max_by_key(|(_, r)| (urgency(r.state), r.at_ms))?;
        Some(Summary {
            state: r.state,
            kind: r.kind,
            progress: r.progress,
            app: self.app(id),
            message: r.message.clone().or_else(|| r.title.clone()),
            at_ms: r.at_ms,
            records: self.0.len(),
        })
    }

    /// A record without an app takes its nearest ancestor's.
    fn app(&self, id: &str) -> Option<String> {
        let mut at = Some(id);
        while let Some(id) = at {
            if let Some(app) = self.0.get(id).and_then(|r| r.app.clone()) {
                return Some(app);
            }
            at = if id.is_empty() { None } else { Some(id.rsplit_once('/').map_or("", |(parent, _)| parent)) };
        }
        None
    }
}

fn urgency(state: AgentState) -> u8 {
    match state {
        AgentState::NeedsYou => 4,
        AgentState::Failed => 3,
        AgentState::Done => 2,
        AgentState::Working => 1,
        AgentState::Idle | AgentState::Ended => 0,
    }
}

/// Program text shown outside the terminal: libghostty-vt has already refused control
/// characters, so this removes the invisible ones that could reorder or hide what's shown.
fn clean(s: &str) -> String {
    s.chars()
        .filter(|c| !matches!(*c as u32, 0x200B..=0x200F | 0x202A..=0x202E | 0x2060..=0x2064 | 0x2066..=0x2069 | 0xFEFF))
        .collect::<String>()
        .trim()
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn report(state: ReportState, id: &str) -> Report {
        Report { state, kind: None, progress: None, id: id.into(), app: String::new(), title: String::new(), message: String::new() }
    }

    #[test]
    fn a_report_replaces_its_record_whole() {
        let mut r = Records::default();
        r.apply(Report { app: "brew".into(), message: "Installing".into(), progress: Some(40), ..report(ReportState::Working, "") }, 1);
        r.apply(report(ReportState::Working, ""), 2);
        let s = r.summary().unwrap();
        assert_eq!((s.app, s.message, s.progress), (None, None, None));
    }

    #[test]
    fn the_most_urgent_record_shows_and_children_inherit_the_app() {
        let mut r = Records::default();
        r.apply(Report { app: "deploy".into(), ..report(ReportState::Working, "") }, 1);
        r.apply(Report { kind: Some(BlockKind::Permission), message: "Approve eu-west?".into(), ..report(ReportState::Blocked, "eu-west") }, 2);
        r.apply(report(ReportState::Done, "us-east"), 3);
        let s = r.summary().unwrap();
        assert_eq!(s.state, AgentState::NeedsYou);
        assert_eq!(s.kind, Some(BlockKind::Permission));
        assert_eq!(s.app.as_deref(), Some("deploy"));
        assert_eq!(s.message.as_deref(), Some("Approve eu-west?"));
        assert_eq!(s.records, 3);
    }

    #[test]
    fn clearing_removes_the_record_and_those_beneath_it() {
        let mut r = Records::default();
        for id in ["build", "build/test", "builder", ""] {
            r.apply(report(ReportState::Working, id), 1);
        }
        r.apply(report(ReportState::Clear, "build"), 2);
        let mut left: Vec<_> = r.0.keys().cloned().collect();
        left.sort();
        assert_eq!(left, ["", "builder"]);
        r.apply(report(ReportState::Clear, ""), 3);
        assert!(r.summary().is_none());
    }

    #[test]
    fn a_prompt_ends_work_and_a_keypress_ends_results() {
        let mut r = Records::default();
        r.apply(report(ReportState::Working, "a"), 1);
        r.apply(report(ReportState::Blocked, "b"), 1);
        r.apply(report(ReportState::Done, "c"), 1);
        r.apply(report(ReportState::Error, "d"), 1);
        r.apply(report(ReportState::Idle, "e"), 1);
        r.prompt();
        let mut left: Vec<_> = r.0.keys().cloned().collect();
        left.sort();
        assert_eq!(left, ["c", "d", "e"]);
        assert_eq!(r.summary().unwrap().state, AgentState::Failed);
        r.seen();
        assert_eq!(r.summary().unwrap().state, AgentState::Idle);
    }

    #[test]
    fn kind_and_progress_only_go_with_their_states() {
        let mut r = Records::default();
        r.apply(Report { kind: Some(BlockKind::Auth), progress: Some(10), ..report(ReportState::Done, "") }, 1);
        let s = r.summary().unwrap();
        assert_eq!((s.kind, s.progress), (None, None));
    }

    #[test]
    fn the_oldest_record_makes_room() {
        let mut r = Records::default();
        for i in 0..MAX_RECORDS {
            r.apply(report(ReportState::Working, &format!("t{i}")), i as u64 + 1);
        }
        r.apply(report(ReportState::Working, "new"), 10_000);
        assert_eq!(r.0.len(), MAX_RECORDS);
        assert!(!r.0.contains_key("t0") && r.0.contains_key("new"));
    }

    #[test]
    fn results_outlast_a_restart_and_work_does_not() {
        let mut r = Records::default();
        r.apply(report(ReportState::Working, "a"), 1);
        r.apply(Report { message: "Deployed".into(), ..report(ReportState::Done, "b") }, 2);
        let json = serde_json::to_string(&r.lasting()).unwrap();
        let mut back = Records::default();
        back.restore(serde_json::from_str(&json).unwrap());
        assert_eq!(back.summary().unwrap().message.as_deref(), Some("Deployed"));
        assert_eq!(back.0.len(), 1);
    }

    #[test]
    fn invisible_formatting_is_removed_from_text() {
        assert_eq!(clean("\u{202E}evil\u{200B} name "), "evil name");
    }
}
