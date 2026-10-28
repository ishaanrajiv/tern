import Foundation
import SwiftUI

struct ClosedTab: Codable, Identifiable {
    var id: String { tab.id }
    var project: String
    var tab: Tab
    var directories: [String: String]
    var remotes: [String: RemoteConnection]
    var detached: Bool
    var closedAt: Date? = Date()
}

/// Session identity stays unchanged when moving between windows or detaching.
struct TabTransfer {
    var project: String
    var tab: Tab
    var directories: [String: String]
    var agents: [String: AgentRef]
    var remotes: [String: RemoteConnection]
    var pending: [String: String]
}

struct DetachedSessionsView: View {
    let sessions: [SessionInfo]
    let attach: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Detached sessions").font(.headline)
            Text("These processes are still running. Reattach to continue where you left off.")
                .font(.callout).foregroundStyle(.secondary)
            if sessions.isEmpty { Text("No detached sessions.").foregroundStyle(.secondary) }
            List(sessions, id: \.id) { session in
                HStack {
                    VStack(alignment: .leading) {
                        Text(session.command ?? session.title.nonempty ?? session.process)
                        Text(session.cwd ?? session.id).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reattach") { attach(session.id) }
                }
            }
        }.padding(16).frame(minWidth: 620, minHeight: 360)
    }
}

private extension String {
    var nonempty: String? { isEmpty ? nil : self }
}
