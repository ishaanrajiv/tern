import AppKit
import SwiftUI

struct PaletteItem: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let shortcut: String
    let symbol: String
    let action: () -> Void
}

/// Ranks `items` by how well `query` matches their title: prefix, then word
/// start, then substring, then in-order subsequence.
func fuzzyFilter(_ items: [PaletteItem], _ query: String) -> [PaletteItem] {
    let q = query.lowercased().trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return items }
    func score(_ text: String) -> Int? {
        let t = text.lowercased()
        if t.hasPrefix(q) { return 0 }
        if t.contains(" " + q) { return 1 }
        if t.contains(q) { return 2 }
        var it = t.makeIterator()
        for c in q {
            var found = false
            while let n = it.next() { if n == c { found = true; break } }
            if !found { return nil }
        }
        return 3
    }
    return items
        .compactMap { item in
            let s = [score(item.title), score(item.subtitle).map { $0 + 4 }].compactMap { $0 }.min()
            return s.map { (item, $0) }
        }
        .sorted { $0.1 < $1.1 }
        .map(\.0)
}

struct CommandPaletteView: View {
    let items: [PaletteItem]
    let dismiss: () -> Void

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var results: [PaletteItem] { fuzzyFilter(items, query) }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Type a command or session name", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($focused)
                        .onSubmit(run)
                        // On the field itself: its editor would otherwise take arrows and Esc first.
                        .onKeyPress(.downArrow) { move(1); return .handled }
                        .onKeyPress(.upArrow) { move(-1); return .handled }
                        .onKeyPress(.escape) { dismiss(); return .handled }
                        .onExitCommand(perform: dismiss)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { i, item in
                                PaletteRow(item: item, selected: i == selection)
                                    .id(i)
                                    .onTapGesture {
                                        selection = i
                                        run()
                                    }
                            }
                            if results.isEmpty {
                                Text("No matches").foregroundStyle(.secondary).padding(16)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 340)
                    .onChange(of: selection) { _, i in proxy.scrollTo(i) }
                }
            }
            .frame(width: 600)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
            .padding(.top, 80)
        }
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onChange(of: query) { _, _ in selection = 0 }
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
    }

    private func run() {
        let r = results
        guard r.indices.contains(selection) else { return }
        dismiss()
        r[selection].action()
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: item.symbol)
                .font(.system(size: 12))
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(item.title)
                .font(.system(size: 13))
                .lineLimit(1)
                .layoutPriority(1)
            if !item.subtitle.isEmpty {
                Text(item.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            Text(item.shortcut)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(selected ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
    }
}
