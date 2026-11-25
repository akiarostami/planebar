import AppKit
import PlanebarCore
import SwiftUI

/// The content of the menu that drops from the menu bar item.
struct MenuView: View {
    @Environment(AppModel.self) private var model
    /// The widest item key on show, so every title starts at the same place.
    @State private var keyWidth: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            if let move = model.move {
                MoveBar(move: move)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .frame(width: 380)
        .fontDesign(.rounded)
        // A mostly solid backing over the panel's blur, so whatever is behind the menu does
        // not wash out the text.
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.82))
        .overlay {
            RoundedRectangle(cornerRadius: MenuPanelController.cornerRadius)
                .strokeBorder(Color.primary.opacity(0.1))
        }
        .focusEffectDisabled()
        .environment(\.keyWidth, keyWidth)
        .onPreferenceChange(KeyWidthKey.self) { keyWidth = $0 }
    }

    /// The count is in the menu bar, right above; the header names the app and holds its buttons.
    private var header: some View {
        HStack(spacing: 10) {
            Text("Planebar").font(.title3.weight(.semibold))
            Spacer()
            HeaderButton(symbol: "arrow.clockwise", help: refreshHelp) {
                model.refresh()
            }
            .opacity(model.isRefreshing ? 0.5 : 1)
            .disabled(!model.hasKey)
            HeaderButton(symbol: "gearshape.fill", help: "Settings (⌘,)") {
                model.openSettings(model.hasKey ? .general : .account)
            }
            HeaderButton(symbol: "power", help: "Quit Planebar (⌘Q)") {
                model.requestQuit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var refreshHelp: String {
        guard let last = model.lastRefresh else { return "Refresh (⌘R)" }
        return "Refresh (⌘R) · read \(Age.short(since: last)) ago"
    }

    @ViewBuilder private var content: some View {
        let hasReading = model.lastRefresh != nil
        if model.connection == .noKey {
            message("Add your Plane API key in Settings.", symbol: "key", action: ("Open Settings", { model.openSettings(.account) }))
        } else if case .failed(let reason) = model.connection, !hasReading {
            message(reason, symbol: "bolt.horizontal.circle", action: ("Try Again", { model.refresh() }))
        } else if !hasReading {
            message("Reading Plane…", symbol: "hourglass")
        } else if model.watchedPhaseNames.isEmpty || model.watchedProjectIDs.isEmpty {
            message(model.watchedProjectIDs.isEmpty ? "No projects chosen." : "No phases chosen.",
                    symbol: "slider.horizontal.3",
                    action: ("Open Settings", { model.openSettings(model.watchedProjectIDs.isEmpty ? .projects : .phases) }))
        } else if model.sections.isEmpty {
            VStack(spacing: 0) {
                warning
                message("Nothing in \(Self.list(model.watchedPhaseNames)).", symbol: "checkmark.circle")
            }
        } else {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    warning
                    ForEach(model.sections) { section in
                        PhaseCard(section: section)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 2)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 560)
            .fixedSize(horizontal: false, vertical: true)
            // Keep the row the keyboard is on in view.
            .onChange(of: model.selectedRow) { _, row in
                if let row {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(row) }
                }
            }
            }
        }
    }

    /// The last reading is still shown when Plane cannot be reached; this says so.
    @ViewBuilder private var warning: some View {
        if case .failed(let reason) = model.connection {
            Label(reason + " Showing the last reading.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
        }
    }

    /// "Review", "Review or Todo", "Todo, Review or QA".
    static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " or " + names.last!
    }

    private func message(_ text: String, symbol: String, action: (String, () -> Void)? = nil) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action.0, action: action.1).controlSize(.small).padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 36)
    }
}

/// The widest item key, measured as the rows lay out.
private struct KeyWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension EnvironmentValues {
    @Entry var keyWidth: CGFloat = 0
}

/// One watched phase, as a card: its items, grouped by project when more than one has any.
private struct PhaseCard: View {
    @Environment(AppModel.self) private var model
    let section: PhaseSection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: section.phase.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(section.phase.colour)
                    .frame(width: 18)
                Text(section.phase.name).font(.headline)
                Text("\(section.count)")
                    .font(.callout.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            ForEach(section.projects) { group in
                if section.projects.count > 1 {
                    Text(group.project.name.isEmpty ? group.project.identifier : group.project.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .padding(.leading, 10)
                        .padding(.top, group.id == section.projects.first?.id ? 0 : 6)
                        .padding(.bottom, 1)
                }
                ForEach(group.items) { item in
                    ItemRow(item: item)
                }
            }
        }
        .padding(4)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)) }
    }
}

/// One item: its key, title and how long since it changed. A click opens out its details;
/// on hover, buttons approve it or open it in Plane.
private struct ItemRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.keyWidth) private var keyWidth
    let item: WorkItem
    @State private var isHovered = false

    /// The height of the row's small buttons: no more than one line of its text, so the row
    /// does not grow, and nothing moves, when they appear under the pointer.
    private static let iconHeight: CGFloat = 16
    private static let descriptionLimit = 1200

    var body: some View {
        let isExpanded = model.expandedRow == item.id
        let next = model.nextState(for: item)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.key)
                    .font(.callout.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: KeyWidthKey.self, value: proxy.size.width)
                    })
                    .frame(width: keyWidth > 0 ? keyWidth : nil, alignment: .leading)
                Text(item.name)
                    .font(.body)
                    .lineLimit(isExpanded ? nil : 1)
                    .fixedSize(horizontal: false, vertical: isExpanded)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isHovered {
                    Button {
                        model.approve(item)
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 20, height: Self.iconHeight)
                            .contentShape(Rectangle().inset(by: -3))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(next == nil ? Color.secondary.opacity(0.4) : Color.secondary)
                    .disabled(next == nil)
                    .help(next.map { "Approve: move to \($0.name)" + (model.approveKey.map { " (\($0.display))" } ?? "") }
                          ?? "Nothing comes after \(item.state.name)")
                    .accessibilityLabel("Approve")
                    Button {
                        model.openInPlane(item)
                    } label: {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 20, height: Self.iconHeight)
                            .contentShape(Rectangle().inset(by: -3))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.secondary)
                    .help("Open in Plane" + (model.openKey.map { " (\($0.display))" } ?? ""))
                    .accessibilityLabel("Open in Plane")
                }
                Text(Age.short(since: item.updatedAt))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(Color.primary.opacity(0.7))
                    .frame(minWidth: 26, minHeight: Self.iconHeight, alignment: .trailing)
            }
            if isExpanded {
                details
                    .padding(.leading, keyWidth + 8)
                    .padding(.top, 4)
                    .padding(.bottom, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(RowHighlight(isHovered: isHovered, isSelected: model.selectedRow == item.id))
        .id(item.id)
        .onHover { isHovered = $0 }
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) { model.toggleExpanded(item.id) }
        }
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if item.description.isEmpty {
                Text("No description.").font(.callout).foregroundStyle(.secondary)
            } else {
                Text(Self.excerpt(item.description))
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            let labels = model.labelNames(item)
            let priority = Priority.title(item.priority)
            if priority != nil || !labels.isEmpty || item.moduleName != nil {
                FlowRow {
                    if let priority {
                        Tag(text: priority, symbol: item.priority == "urgent" ? "exclamationmark.square.fill" : "cellularbars",
                            variable: Self.bars(item.priority), colour: Priority.colour(item.priority))
                    }
                    ForEach(labels) { label in
                        Tag(text: label.name, dot: StateStyle.colour(label.color))
                    }
                    if let module = item.moduleName {
                        Tag(text: module, symbol: "square.stack.3d.up", colour: .secondary)
                    }
                }
            }
        }
    }

    private static func bars(_ priority: String) -> Double {
        switch priority {
        case "high": return 1
        case "medium": return 0.66
        default: return 0.33
        }
    }

    /// The description, cut at a word near the limit.
    static func excerpt(_ text: String) -> String {
        guard text.count > descriptionLimit else { return text }
        let cut = text.prefix(descriptionLimit)
        let end = cut.lastIndex(where: \.isWhitespace) ?? cut.endIndex
        return String(cut[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

/// A small capsule: a priority, a label or a module.
private struct Tag: View {
    let text: String
    var symbol: String?
    var variable: Double?
    var colour: Color = .secondary
    var dot: Color?

    var body: some View {
        HStack(spacing: 4) {
            if let dot {
                Circle().fill(dot).frame(width: 7, height: 7)
            } else if let symbol {
                Image(systemName: symbol, variableValue: variable)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(colour)
            }
            Text(text).font(.caption).foregroundStyle(.primary.opacity(0.8))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.07), in: Capsule())
    }
}

/// Lays its children out left to right, wrapping onto new lines.
private struct FlowRow: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 280
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += line + spacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            line = max(line, size.height)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += line + spacing
                x = bounds.minX
                line = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// The foot of the menu after an approval: where the item went, and Undo. A failure says
/// why instead.
private struct MoveBar: View {
    @Environment(AppModel.self) private var model
    let move: Move

    var body: some View {
        HStack(spacing: 8) {
            if let failure = move.failure {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(failure)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button {
                    model.clearMove()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Dismiss")
            } else {
                Image(systemName: move.isUndo ? "arrow.uturn.backward" : "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(StateStyle.colour(move.to.color))
                Text(move.item.key).font(.callout.weight(.semibold).monospacedDigit())
                Text("→ \(move.to.name)").font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if !move.isUndo {
                    Button("Undo") { model.undoMove() }
                        .controlSize(.small)
                        .help("Undo (⌘Z)")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}
