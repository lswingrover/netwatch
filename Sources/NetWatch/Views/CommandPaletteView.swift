/// CommandPaletteView.swift — Quick-navigate command palette (⌘K)
///
/// Shows a fuzzy-searchable list of:
///   • Nav items (all sections of the app)
///   • Recent incidents
///
/// Pressing Return or clicking any result navigates to it and dismisses.
/// Escape also dismisses.

import SwiftUI

struct CommandPaletteView: View {
    @EnvironmentObject var monitor: NetworkMonitorService
    @Binding var selection:    NavItem
    @Binding var isPresented:  Bool

    @State private var query:    String = ""
    @State private var hoveredI: Int?   = nil
    @FocusState private var focused: Bool

    // MARK: - Results

    private var navResults: [PaletteItem] {
        NavItem.allCases.compactMap { item in
            let match = query.isEmpty
                || item.rawValue.localizedCaseInsensitiveContains(query)
            return match ? PaletteItem(id: item.rawValue,
                                       icon:  item.systemImage,
                                       title: item.rawValue,
                                       subtitle: "Navigate",
                                       action: { selection = item }) : nil
        }
    }

    private var incidentResults: [PaletteItem] {
        guard !query.isEmpty else { return [] }
        return monitor.incidentManager.incidents
            .filter { $0.reason.localizedCaseInsensitiveContains(query)
                   || $0.subject.localizedCaseInsensitiveContains(query) }
            .prefix(5)
            .map { inc in
                PaletteItem(id: inc.id.uuidString,
                            icon: "exclamationmark.triangle.fill",
                            title: inc.reason,
                            subtitle: "\(inc.subject) · \(inc.formattedDate)",
                            action: { selection = .incidents })
            }
    }

    private var allResults: [PaletteItem] { navResults + incidentResults }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Go to…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { commitFirst() }
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Results
            if allResults.isEmpty {
                Text("No results for \"\(query)\"")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if !navResults.isEmpty {
                            SectionHeader("Navigation")
                            ForEach(Array(navResults.enumerated()), id: \.1.id) { i, item in
                                PaletteRow(item: item, isHovered: hoveredI == i)
                                    .onHover { hoveredI = $0 ? i : nil }
                                    .onTapGesture { commit(item: item) }
                            }
                        }
                        if !incidentResults.isEmpty {
                            SectionHeader("Incidents")
                            ForEach(Array(incidentResults.enumerated()), id: \.1.id) { i, item in
                                let idx = navResults.count + i
                                PaletteRow(item: item, isHovered: hoveredI == idx)
                                    .onHover { hoveredI = $0 ? idx : nil }
                                    .onTapGesture { commit(item: item) }
                            }
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .frame(width: 480)
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
        .onAppear { focused = true }
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
    }

    private func commitFirst() {
        guard let first = allResults.first else { return }
        commit(item: first)
    }

    private func commit(item: PaletteItem) {
        item.action()
        isPresented = false
    }
}

// MARK: - Models

private struct PaletteItem: Identifiable {
    let id:       String
    let icon:     String
    let title:    String
    let subtitle: String
    let action:   () -> Void
}

// MARK: - Sub-views

private struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }
}

private struct PaletteRow: View {
    let item:      PaletteItem
    let isHovered: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.icon)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.callout)
                Text(item.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isHovered {
                Image(systemName: "return")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isHovered ? Color(NSColor.selectedContentBackgroundColor).opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
    }
}
