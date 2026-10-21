import AppKit
import SwiftUI

/// The strip above the terminal: what this session is and where, then its state.
struct ContentHeader: View {
    let workspace: Workspace

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                if let tab = workspace.selectedTab {
                    let s = workspace.sessions[tab.focusedPane]
                    Text(workspace.title(for: tab))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if let cwd = s?.cwd {
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
                    let status = workspace.status(for: tab, now: context.date)
                    if status == .needsYou, let message = workspace.agentMessage(tab) {
                        Text(message)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.amber)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    StatusIcon(status: status)
                    Text([status.label, relativeAge(workspace.lastActivity(tab), now: context.date)].joined(separator: " · "))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(status == .needsYou ? Palette.amber : .secondary)
                } else {
                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                Rectangle().fill(.separator.opacity(0.6)).frame(height: 1)
            }
        }
    }
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
