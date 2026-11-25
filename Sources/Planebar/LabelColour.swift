import AppKit

/// The colours the menu bar icon and count can take while items wait.
enum LabelColour {
    /// Named choices, in the order Settings shows them. "plain" is the menu bar's own text
    /// colour. The system colours adjust to light and dark menu bars.
    static let presets: [(name: String, colour: NSColor)] = [
        ("plain", .labelColor),
        ("blue", .systemBlue),
        ("purple", .systemPurple),
        ("pink", .systemPink),
        ("red", .systemRed),
        ("orange", .systemOrange),
        ("yellow", .systemYellow),
        ("green", .systemGreen),
        ("teal", .systemTeal),
    ]

    static func colour(for value: String) -> NSColor {
        if let preset = presets.first(where: { $0.name == value }) { return preset.colour }
        return NSColor(hex: value) ?? .systemBlue
    }

    static func hex(_ colour: NSColor) -> String {
        let rgb = colour.usingColorSpace(.sRGB) ?? colour
        return String(format: "#%02X%02X%02X", Int(round(rgb.redComponent * 255)),
                      Int(round(rgb.greenComponent * 255)), Int(round(rgb.blueComponent * 255)))
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
