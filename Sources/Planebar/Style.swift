import AppKit
import PlanebarCore
import SwiftUI

extension Color {
    /// A colour from Plane's "#RRGGBB", or nil when the text is not one.
    init?(hex: String?) {
        guard let nsColour = NSColor(hex: hex) else { return nil }
        self.init(nsColor: nsColour)
    }
}

extension NSColor {
    convenience init?(hex: String?) {
        guard var text = hex?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

enum StateStyle {
    /// Plane's own icons for its state groups, as near as SF Symbols get.
    static func symbol(group: String) -> String {
        switch group {
        case "backlog": return "circle.dotted"
        case "unstarted": return "circle"
        case "started": return "circle.lefthalf.filled"
        case "completed": return "checkmark.circle.fill"
        case "cancelled": return "xmark.circle.fill"
        default: return "circle"
        }
    }

    static func colour(_ hex: String?) -> Color { Color(hex: hex) ?? .secondary }
}

extension Phase {
    var symbol: String { StateStyle.symbol(group: group) }
    var colour: Color { StateStyle.colour(color) }
}

enum Priority {
    static func title(_ priority: String) -> String? {
        switch priority {
        case "urgent": return "Urgent"
        case "high": return "High"
        case "medium": return "Medium"
        case "low": return "Low"
        default: return nil
        }
    }

    static func colour(_ priority: String) -> Color {
        switch priority {
        case "urgent": return .red
        case "high": return .orange
        case "medium": return .yellow
        default: return .secondary
        }
    }
}

enum Age {
    /// "<1m", "9m", "3h", "2d": how long ago.
    static func short(since date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 60 * 24 { return "\(minutes / 60)h" }
        return "\(minutes / (60 * 24))d"
    }
}

/// The background of a row: tinted when the keyboard is on it, faint under the pointer.
struct RowHighlight: View {
    var isHovered: Bool
    var isSelected = false

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(isHovered ? 0.07 : 0))
    }
}

/// A round icon button for the top of the menu. Its name is shown as a tooltip.
struct HeaderButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(isHovered ? 0.14 : 0.07), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
