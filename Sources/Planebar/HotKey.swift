import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A keyboard shortcut: a key plus at least one modifier.
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    /// NSEvent.ModifierFlags raw value, limited to Control, Option, Shift and Command.
    var modifiers: UInt
    /// The key's name as shown to the user, such as "C" or "F5".
    var key: String

    static let allowed: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    /// For example "⌃⌥C".
    var display: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + key
    }

    var carbonModifiers: UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var carbon = 0
        if flags.contains(.control) { carbon |= controlKey }
        if flags.contains(.option) { carbon |= optionKey }
        if flags.contains(.shift) { carbon |= shiftKey }
        if flags.contains(.command) { carbon |= cmdKey }
        return UInt32(carbon)
    }

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags = [], key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers.rawValue
        self.key = key
    }

    /// A combo from a key press. A system-wide shortcut needs Control, Option or Command
    /// (Shift alone would take over ordinary typing), so without one this is nil unless
    /// `allowsPlain` is set, as for keys used only inside the menu.
    init?(event: NSEvent, allowsPlain: Bool = false) {
        let flags = event.modifierFlags.intersection(Self.allowed)
        guard allowsPlain || !flags.intersection([.control, .option, .command]).isEmpty else { return nil }
        keyCode = UInt32(event.keyCode)
        modifiers = flags.rawValue
        key = Self.name(for: event)
    }

    /// Whether a key press is this combo, modifiers and all.
    func matches(_ event: NSEvent) -> Bool {
        UInt32(event.keyCode) == keyCode && event.modifierFlags.intersection(Self.allowed).rawValue == modifiers
    }

    private static let named: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static func name(for event: NSEvent) -> String {
        if let name = named[Int(event.keyCode)] { return name }
        let characters = event.charactersIgnoringModifiers?.uppercased() ?? ""
        return characters.isEmpty ? "Key \(event.keyCode)" : characters
    }
}

/// System-wide shortcuts, registered with the Carbon hot key API (which needs no
/// Accessibility permission). Each shortcut has a numeric slot, one per menu item.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var references: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var handlerInstalled = false

    /// Registers `combo` for `slot`, replacing what was there; nil removes it.
    /// Returns false when the system refuses, usually because another app holds the shortcut.
    @discardableResult
    func set(slot: UInt32, combo: KeyCombo?, action: @escaping () -> Void) -> Bool {
        if let reference = references.removeValue(forKey: slot) {
            UnregisterEventHotKey(reference)
        }
        actions[slot] = nil
        guard let combo else { return true }
        installHandler()
        var reference: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x504C_4E42), id: slot)  // "PLNB"
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else { return false }
        references[slot] = reference
        actions[slot] = action
        return true
    }

    fileprivate func fire(_ slot: UInt32) {
        actions[slot]?()
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            if status == noErr {
                let slot = id.id
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { HotKeyCenter.shared.fire(slot) }
                }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// A button that records a shortcut: click it, then press the keys. Esc cancels.
struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo?
    /// Accept keys without Control, Option or Command, for keys used only inside the menu.
    var allowsPlain = false
    /// Says why a key cannot be used, or nil when it can.
    var refuse: (KeyCombo) -> String? = { _ in nil }
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                isRecording ? stop() : start()
            } label: {
                Text(isRecording ? "Press shortcut…" : (combo?.display ?? "Record Shortcut"))
                    .frame(minWidth: 110)
            }
            if combo != nil && !isRecording {
                Button {
                    combo = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Remove the shortcut")
            }
            if let hint, isRecording {
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        hint = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Int(event.keyCode) == kVK_Escape {
                stop()
            } else if let recorded = KeyCombo(event: event, allowsPlain: allowsPlain) {
                if let reason = refuse(recorded) {
                    hint = reason
                } else {
                    combo = recorded
                    stop()
                }
            } else {
                hint = "Include ⌃, ⌥ or ⌘"
            }
            return nil  // swallow the key while recording
        }
    }

    private func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
    }
}
