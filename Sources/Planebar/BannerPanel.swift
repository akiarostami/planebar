import AppKit
import Observation
import PlanebarCore
import SwiftUI

/// Planebar's notifications: cards that drop under the menu bar item and leave after a few
/// seconds. The panel never takes the keyboard or the focus.
@MainActor
final class BannerPanelController {
    private let panel: NSPanel
    private let host: NSHostingController<AnyView>
    private let model: AppModel
    private weak var anchor: NSStatusBarButton?
    private var size = CGSize.zero
    private var relay: Relay?
    private var hide: DispatchWorkItem?

    @MainActor
    private final class Relay {
        var onChange: ((CGSize) -> Void)?
    }

    init(model: AppModel, anchor: NSStatusBarButton?) {
        self.model = model
        self.anchor = anchor
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 80),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let relay = Relay()
        host = NSHostingController(rootView: AnyView(
            BannerStack()
                .environment(model)
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { relay.onChange?($0) }
        ))
        host.sizingOptions = []
        panel.contentView = host.view
        relay.onChange = { [weak self] size in
            // While the last banner is leaving, keep the panel's size so it is not clipped mid-way.
            guard let self, size.width > 1, size.height > 1, !self.model.banners.isEmpty else { return }
            self.size = size
            self.layout()
        }
        self.relay = relay
        track()
    }

    /// Shows or hides the panel as banners come and go.
    private func track() {
        let hasBanners = withObservationTracking {
            !model.banners.isEmpty
        } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
        if hasBanners {
            hide?.cancel()
            size = host.sizeThatFits(in: CGSize(width: 2000, height: 4000))
            layout()
            panel.orderFrontRegardless()
        } else {
            // Let the last banner finish leaving before the panel goes.
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.model.banners.isEmpty else { return }
                self.panel.orderOut(nil)
            }
            hide = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    /// Hangs the panel under Planebar's menu bar icon, inside the screen.
    private func layout() {
        guard size.width > 1, size.height > 1, let button = anchor, let window = button.window,
              let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let icon = window.convertToScreen(button.convert(button.bounds, to: nil))
        let width = size.width.rounded(.up)
        let height = size.height.rounded(.up)
        let x = min(max(icon.midX - width / 2, visible.minX + 8), visible.maxX - width - 8)
        let y = icon.minY - 6 - height
        panel.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: width, height: height), display: true)
    }
}

/// The banners on screen, newest at the bottom.
private struct BannerStack: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.banners) { notice in
                BannerCard(notice: notice)
                    // Drops in from the top with a little spring; fades and slips back up.
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.94, anchor: .top)),
                        removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)).combined(with: .offset(y: -8))))
            }
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
        .padding(.bottom, 14)
        .frame(width: 376, alignment: .top)
        .fontDesign(.rounded)
    }
}

struct BannerCard: View {
    @Environment(AppModel.self) private var model
    let notice: Notice
    @State private var isHovered = false

    var body: some View {
        let item = notice.item
        let colour = StateStyle.colour(item.state.color)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: StateStyle.symbol(group: item.state.group))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(colour)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.key).font(.headline).foregroundStyle(.white)
                    Text("In \(item.state.name)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(colour)
                }
                Text(item.name)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !item.description.isEmpty {
                    Text(item.description)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button {
                model.dismiss(notice)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(14)
        .frame(width: 372, alignment: .leading)
        .background {
            ZStack {
                Color(white: 0.08)
                colour.opacity(0.16)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(colour.opacity(isHovered ? 0.9 : 0.55)) }
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onHover { hovering in
            isHovered = hovering
            model.hold(notice, hovering)
        }
        .onTapGesture {
            model.dismiss(notice)
            model.showItem(item.id)
        }
        .help("Show in the menu")
    }
}
