import AppKit
import Observation
import PlanebarCore
import SwiftUI

@main
struct PlanebarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The menu bar item, menu, banners and settings window are managed by AppDelegate;
        // an App needs a scene, and this one shows nothing.
        Settings { EmptyView() }
    }
}

/// Owns the menu bar item, the menu that drops from it, the banner panel and the settings window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem!
    private var menu: MenuPanelController!
    private var banners: BannerPanelController!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // A fixed name, matching the label's accessibility description, so menu bar managers
        // and macOS file the item under the same name.
        statusItem.autosaveName = "Planebar"
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(toggleMenu)
        }

        model.openSettings = { [weak self] pane in
            self?.model.settingsPane = pane
            self?.showSettings()
        }
        model.requestQuit = { [weak self] in self?.confirmQuit() }
        model.showItem = { [weak self] id in self?.showItem(id) }
        menu = MenuPanelController(content: MenuView().environment(model))
        banners = BannerPanelController(model: model, anchor: statusItem.button)

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(closeMenu), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        trackLabel()
        trackHotKey()
        trackMenuContent()
        runSelfCheckIfAsked()
        if !model.hasKey, !DemoData.isOn { model.openSettings(.account) }

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) == true ? nil : event
        }
    }

    // MARK: Menu bar label

    private func trackLabel() {
        withObservationTracking {
            statusItem.button?.image = Self.label(count: model.hasKey ? model.count : nil,
                                                  stale: { if case .failed = model.connection { return true }; return false }(),
                                                  waiting: LabelColour.colour(for: model.labelColour))
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackLabel() }
        }
    }

    /// The app icon's three columns of cards, with a tick in the third column's empty third
    /// slot, and the number of items in the watched phases when there are any. It is drawn
    /// each time it is shown, so it takes the menu bar's own text colour. The glyph alone
    /// means nothing is waiting; a dimmed glyph means no key, or Plane cannot be reached.
    /// While items wait, glyph and count take the `waiting` colour.
    static func label(count: Int?, stale: Bool = false, waiting: NSColor = .labelColor) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let connected = count != nil && !stale
        let text = count.flatMap { $0 > 0 ? "\($0)" as NSString : nil }
        let symbolSize: CGFloat = 16
        let gap: CGFloat = 4
        let textWidth = text.map { ceil($0.size(withAttributes: [.font: font]).width) } ?? 0
        let width = symbolSize + (text == nil ? 0 : gap + textWidth)
        let image = NSImage(size: NSSize(width: width, height: 18), flipped: false) { rect in
            let colour = !connected ? NSColor.tertiaryLabelColor : text == nil ? NSColor.labelColor : waiting
            Self.drawGlyph(in: NSRect(x: 0, y: (rect.height - 13.4) / 2, width: symbolSize, height: 13.4),
                           colour: colour)
            if let text {
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour]
                let size = text.size(withAttributes: attributes)
                text.draw(at: NSPoint(x: symbolSize + gap, y: (rect.height - size.height) / 2), withAttributes: attributes)
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Planebar"
        return image
    }

    /// The columns glyph, 16 × 13.4 pt, with its origin at the bottom left of `rect`.
    static func drawGlyph(in rect: NSRect, colour: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(colour.cgColor)
        context.setStrokeColor(colour.cgColor)
        let cardWidth: CGFloat = 4.4, gap: CGFloat = 1.4, cardHeight: CGFloat = 3.6, rowGap: CGFloat = 1.3
        let top = rect.maxY
        for (column, cards) in [3, 2, 1].enumerated() {
            let x = rect.minX + CGFloat(column) * (cardWidth + gap)
            for row in 0..<cards {
                let card = CGRect(x: x, y: top - cardHeight - CGFloat(row) * (cardHeight + rowGap),
                                  width: cardWidth, height: cardHeight)
                context.addPath(CGPath(roundedRect: card, cornerWidth: 1.1, cornerHeight: 1.1, transform: nil))
                context.fillPath()
            }
        }
        let centre = CGPoint(x: rect.minX + 2 * (cardWidth + gap) + cardWidth / 2,
                             y: top - cardHeight / 2 - 2 * (cardHeight + rowGap))
        let size: CGFloat = 4.0
        context.setLineWidth(1.4)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: CGPoint(x: centre.x - size * 0.5, y: centre.y))
        context.addLine(to: CGPoint(x: centre.x - size * 0.12, y: centre.y - size * 0.38))
        context.addLine(to: CGPoint(x: centre.x + size * 0.55, y: centre.y + size * 0.4))
        context.strokePath()
    }

    // MARK: Shortcut and keys

    /// Registers the shortcut now and again whenever it changes.
    private func trackHotKey() {
        let combo = withObservationTracking {
            model.hotKey
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackHotKey() }
        }
        model.hotKeyRefused = !HotKeyCenter.shared.set(slot: 1, combo: combo) { [weak self] in
            self?.toggleMenu()
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard menu.isShown, event.window === menu.window else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command {
            switch event.keyCode {
            case 43: model.openSettings(model.settingsPane)  // Command-comma
            case 6: model.navigate(.undo)                    // Command-Z
            case 15: model.refresh()                         // Command-R
            case 12: NSApp.terminate(nil)                    // Command-Q
            default: return false
            }
            return true
        }
        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 125: model.navigate(.down)
        case 126: model.navigate(.up)
        case 123: withAnimation(.easeOut(duration: 0.15)) { model.navigate(.left) }
        case 124: withAnimation(.easeOut(duration: 0.15)) { model.navigate(.right) }
        case 36, 76, 49:                       // Return, Enter, Space
            withAnimation(.easeOut(duration: 0.15)) { model.navigate(.activate) }
        case 0: model.navigate(.approve)       // A
        case 31:                               // O
            let opens = model.item(model.selectedRow) != nil
            model.navigate(.open)
            if opens { closeMenu() }
        case 53: closeMenu()                   // Esc
        default: return false
        }
        return true
    }

    // MARK: Menu

    /// Has the menu check its size whenever what it shows changes.
    private func trackMenuContent() {
        withObservationTracking {
            _ = (model.items, model.overrides, model.connection, model.expandedRow, model.move,
                 model.chosenPhases, model.chosenProjects, model.labels, model.lastRefresh)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.trackMenuContent()
                for delay in [0.0, 0.05, 0.25] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.menu.remeasure()
                    }
                }
            }
        }
    }

    @objc private func toggleMenu() {
        if menu.isShown {
            menu.close()
            return
        }
        guard Date().timeIntervalSince(menu.lastClosed) > 0.25 else { return }
        openMenu()
    }

    private func openMenu() {
        guard let button = statusItem.button else { return }
        // Banners say what the menu is about to show.
        for notice in model.banners { model.dismiss(notice) }
        model.selectedRow = nil
        model.expandedRow = nil
        model.menuWillOpen()
        menu.show(below: button)
    }

    /// Opens the menu on one item, selected and opened out; from a banner.
    private func showItem(_ id: String) {
        if !menu.isShown { openMenu() }
        model.selectedRow = id
        model.expandedRow = id
    }

    @objc private func closeMenu() {
        menu.close()
    }

    // MARK: Quit and settings

    private func confirmQuit() {
        closeMenu()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Quit Planebar?"
        alert.informativeText = "Its count leaves the menu bar and notifications stop until you open Planebar again."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
    }

    private func showSettings() {
        closeMenu()
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView().environment(model)))
            window.title = "Planebar Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        settingsWindow = nil
        model.settingsPane = model.hasKey ? .general : .account
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Self-check

    /// With PLANEBAR_SNAPSHOT_DIR set, the app opens its menu and each settings page in turn
    /// and saves a PNG of each there. Combine with PLANEBAR_DEMO for invented data.
    private func runSelfCheckIfAsked() {
        guard let directory = ProcessInfo.processInfo.environment["PLANEBAR_SNAPSHOT_DIR"] else { return }
        let steps: [(String, () -> Void)] = [
            ("menu", { [weak self] in self?.toggleMenu() }),
            ("menu-expanded", { [weak self] in
                guard let self, let item = self.model.sections.last?.items.first else { return }
                self.model.selectedRow = item.id
                self.model.expandedRow = item.id
            }),
            ("menu-approved", { [weak self] in
                // Only invented items are ever moved by the self-check.
                guard let self, DemoData.isOn, let item = self.model.item(self.model.selectedRow) else { return }
                self.model.approve(item)
            }),
            ("menu-undone", { [weak self] in
                guard let self, DemoData.isOn else { return }
                self.model.undoMove()
            }),
            ("settings-account", { [weak self] in self?.model.openSettings(.account) }),
            ("settings-projects", { [weak self] in self?.model.openSettings(.projects) }),
            ("settings-phases", { [weak self] in self?.model.openSettings(.phases) }),
            ("settings-general", { [weak self] in self?.model.openSettings(.general) }),
        ]
        // Starts once the first reading is in and the app has settled, or after 20 seconds.
        let start = Date()
        func waitForReading() {
            let waited = Date().timeIntervalSince(start)
            if (model.lastRefresh == nil || waited < 3), waited < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { waitForReading() }
            } else {
                run()
            }
        }
        func run() {
            for (index, step) in steps.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(index) * 3) { [weak self] in
                    step.1()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        guard let self else { return }
                        let view = step.0.hasPrefix("menu") ? self.menu.contentView : self.settingsWindow?.contentView
                        DebugLog.snapshot(view, to: "\(directory)/\(step.0).png")
                        if step.0 == "menu" {
                            // Whether the menu has the keyboard, and whether arrow keys reach it.
                            self.model.navigate(.down)
                            let report = "menu is key window: \(self.menu.window.isKeyWindow)\napp is active: \(NSApp.isActive)\nrows: \(self.model.navigableRows.count)\nselected after Down: \(self.model.item(self.model.selectedRow)?.key ?? "none")\nconnection: \(self.model.connection)\nitems: \(self.model.shownItems.map(\.key).joined(separator: " "))\n"
                            try? report.write(toFile: "\(directory)/keyboard.txt", atomically: true, encoding: .utf8)
                            self.model.selectedRow = nil
                        }
                    }
                }
            }
            // The menu bar label and a banner, drawn straight to files.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let label = NSImageView(image: Self.label(count: self.model.count, waiting: LabelColour.colour(for: self.model.labelColour)))
                label.frame = NSRect(origin: .zero, size: label.image?.size ?? .zero)
                DebugLog.snapshot(label, to: "\(directory)/label.png")
                if let item = self.model.shownItems.first(where: { !$0.description.isEmpty }) {
                    let card = NSHostingView(rootView: BannerCard(notice: Notice(item: item)).environment(self.model).fontDesign(.rounded))
                    card.frame = NSRect(origin: .zero, size: card.fittingSize)
                    DebugLog.snapshot(card, to: "\(directory)/banner.png")
                }
            }
        }
        waitForReading()
    }
}
