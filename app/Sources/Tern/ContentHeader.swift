import AppKit
import SwiftUI

/// The strip above the terminal: what this session is and where, then its state.
struct ContentHeader: View {
    let workspace: Workspace
    let layout: HeaderLayout
    @AppStorage(Prefs.workingIndicator) private var indicator = WorkingIndicator.trailing

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                if let tab = workspace.selectedTab {
                    let s = workspace.sessions[tab.focusedPane]
                    Text(workspace.title(for: tab))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    // A tab titled "~" needn't say "~" twice.
                    if let cwd = s?.cwd, abbreviateHome(cwd) != workspace.title(for: tab) {
                        Text(abbreviateHome(cwd))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    if let branch = s?.branch {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    // Only what needs saying: an agent at work or waiting, with how long. An idle
                    // shell says nothing; the sidebar already shows every tab's age.
                    let status = workspace.status(for: tab, now: context.date)
                    let agent = workspace.agent(for: tab)
                    if status == .needsYou, let message = workspace.agentMessage(tab) {
                        Text(message)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.amber)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if status == .needsYou || (status == .working && agent != nil) {
                        // The sidebar's glyph, with the agent spelled out: "Codex working · 4m".
                        StatusIcon(status: status, agent: agent, turning: indicator == .turning)
                        let label = agent.map { "\(agentName($0)) \(status.label.lowercased())" } ?? status.label
                        Text([label, relativeAge(workspace.stateSince(tab), now: context.date)]
                                .filter { !$0.isEmpty && $0 != "now" }.joined(separator: " · "))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(status == .needsYou ? Palette.amber : .secondary)
                        if status == .working, indicator == .trailing {
                            Spinner(color: Palette.working).frame(width: 12, height: 12)
                        }
                    }
                } else {
                    Spacer()
                }
            }
            .padding(.leading, 14 + layout.leadingInset)
            .padding(.trailing, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .overlay(alignment: .bottom) {
                Rectangle().fill(Palette.border).frame(height: 1)
            }
            .themedText()
        }
    }
}

/// Window geometry the SwiftUI parts follow.
@Observable
final class HeaderLayout {
    /// Room the header leaves on its left for the traffic lights when the sidebar is hidden.
    var leadingInset: CGFloat = 0
    /// The titlebar's height, which the sidebar starts below (zero in full screen).
    var titlebarHeight: CGFloat = 38
}

/// Lets the header act as titlebar: drag moves the window, double-click zooms.
final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.performZoom(nil)
        } else {
            window?.performDrag(with: event)
        }
    }
}
