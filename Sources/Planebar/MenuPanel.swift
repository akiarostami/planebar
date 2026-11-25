import AppKit
import SwiftUI

/// Appends to the file named by PLANEBAR_DEBUG_LOG; does nothing when that is not set.
enum DebugLog {
    static let path = ProcessInfo.processInfo.environment["PLANEBAR_DEBUG_LOG"]

    /// Saves a picture of a view as a PNG, for checking layouts without looking at the screen.
    @MainActor
    static func snapshot(_ view: NSView?, to path: String) {
        // Always at twice the point size, so pictures are sharp whichever display the window is on.
        guard let view, view.bounds.width > 0, view.bounds.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2),
                                         pixelsHigh: Int(view.bounds.height * 2), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    static func write(_ line: String) {
        guard let path, let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}

/// Carries the measured size of the SwiftUI content out to the panel controller.
@MainActor
private final class SizeRelay {
    var onChange: ((CGSize) -> Void)?
}

/// A borderless panel that can take keyboard input, unlike a plain borderless window.
/// With the non-activating style it does so without bringing its app to the front.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The menu that drops from the menu bar item: a rounded, blurred panel with no arrow.
///
/// It sizes itself to its SwiftUI content, stays anchored under the menu bar item, and
/// closes on a click elsewhere or when it stops being the key window.
@MainActor
final class MenuPanelController: NSObject, NSWindowDelegate {
    static let cornerRadius: CGFloat = 16
    private static let gap: CGFloat = 6       // between the menu bar and the panel
    private static let margin: CGFloat = 8    // kept from the screen edges

    private let panel: KeyPanel
    private let host: NSHostingController<AnyView>
    /// The content's own size, as SwiftUI last measured it.
    private var contentSize = CGSize.zero
    private let sizeRelay = SizeRelay()
    private var monitors: [Any] = []
    private weak var anchor: NSStatusBarButton?
    /// When the panel last closed; lets the caller ignore the click that closed it.
    private(set) var lastClosed = Date.distantPast

    var isShown: Bool { panel.isVisible }
    var window: NSWindow { panel }
    var contentView: NSView { host.view }
    var debugState: String { "panel \(panel.frame) host \(host.view.frame) content \(contentSize) measured \(measuredSize())" }

    init<Content: View>(content: Content) {
        // The content is laid out at its own size and reports every change of it, so the panel
        // can follow. Its view is placed by hand, pinned to the panel's top left, so it never
        // appears shifted while the panel catches up.
        let relay = sizeRelay
        host = NSHostingController(rootView: AnyView(
            content
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    relay.onChange?(size)
                }
        ))
        host.sizingOptions = []

        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
                         styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                         backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        let effect = NSVisualEffectView(frame: panel.contentLayoutRect)
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.roundedMask(radius: Self.cornerRadius)
        host.view.autoresizingMask = []
        host.view.frame = effect.bounds  // non-empty, so SwiftUI lays the content out
        effect.addSubview(host.view)
        panel.contentView = effect

        super.init()
        panel.delegate = self
        sizeRelay.onChange = { [weak self] size in
            DebugLog.write("geometry: \(size)")
            guard let self, size.width > 1, size.height > 1, size != self.contentSize else { return }
            self.contentSize = size
            self.layout()
            DebugLog.write("after layout: panel \(self.panel.frame) host \(self.host.view.frame) measured \(self.measuredSize())")
        }
    }

    /// A stretchable rounded rectangle, used to clip the blurred background.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    func show(below button: NSStatusBarButton) {
        anchor = button
        // Measure afresh: the content may have changed while the panel was hidden, when
        // SwiftUI does not report sizes.
        let fitting = measuredSize()
        if fitting.width > 1, fitting.height > 1 {
            contentSize = fitting
        }
        layout()
        DebugLog.write("show: fitting \(fitting) content \(contentSize) panel \(panel.frame) host \(host.view.frame)")
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        installMonitors()
    }

    func close() {
        guard panel.isVisible else { return }
        removeMonitors()
        panel.orderOut(nil)
        lastClosed = Date()
    }

    /// The size the content wants, asked of SwiftUI directly. This works while the panel is
    /// hidden, when the content does not report its size by itself.
    private func measuredSize() -> CGSize {
        host.sizeThatFits(in: CGSize(width: 2000, height: 4000))
    }

    /// Asks the content for its size again and resizes the panel if it changed. Called when
    /// something the menu shows has changed, as a second line after the content's own reports.
    func remeasure() {
        guard panel.isVisible else { return }
        let size = measuredSize()
        guard size.width > 1, size.height > 1, size != contentSize else { return }
        DebugLog.write("remeasure: \(size)")
        contentSize = size
        layout()
    }

    /// Sizes the panel to its content and places it under the menu bar item, inside the screen.
    private func layout() {
        guard let button = anchor, let buttonWindow = button.window else { return }
        var size = contentSize
        if size.width < 1 || size.height < 1 {
            size = measuredSize()
        }
        guard size.width > 1, size.height > 1 else { return }
        size = CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var x = buttonRect.midX - size.width / 2
        if let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame {
            x = min(max(x, visible.minX + Self.margin), visible.maxX - size.width - Self.margin)
        }
        let frame = NSRect(x: x.rounded(), y: (buttonRect.minY - Self.gap - size.height).rounded(),
                           width: size.width, height: size.height)
        if frame != panel.frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
        // The content view keeps its own size, against the top left of the panel.
        let container = panel.contentView?.bounds ?? NSRect(origin: .zero, size: size)
        host.view.frame = NSRect(x: 0, y: container.height - size.height, width: size.width, height: size.height)
    }

    // MARK: Closing

    private func installMonitors() {
        removeMonitors()
        let mouseDown: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // A click in another app.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) {
            monitors.append(monitor)
        }
        // A click in another window of this app. The menu bar item's own click is left to
        // its action, which toggles the panel.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mouseDown, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.window !== self.panel, event.window !== self.anchor?.window {
                    self.close()
                }
            }
            return event
        }) {
            monitors.append(monitor)
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}
