import AppKit
import SwiftUI

// MARK: - Button styles

/// The mock's pill button: a raised dark capsule with a hairline border and a bold label.
/// `tint` fills it with a color instead (the accent for a primary action, red for a destructive one).
struct PillButtonStyle: ButtonStyle {
    var tint: Color?
    var height: CGFloat = 30
    var horizontalPadding: CGFloat = 14

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, tint: tint, height: height, horizontalPadding: horizontalPadding)
    }

    private struct PillBody: View {
        let configuration: Configuration
        let tint: Color?
        let height: CGFloat
        let horizontalPadding: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint == Theme.accent ? Theme.onAccent : Theme.primaryText)
                .opacity(isEnabled ? 1 : 0.4)
                .padding(.horizontal, horizontalPadding)
                .frame(height: height)
                .background(Capsule().fill(fill))
                .overlay(Capsule().strokeBorder(Theme.controlBorder, lineWidth: 1))
                .shadow(color: Theme.shadow.opacity(0.7), radius: 4, y: 2)
                .contentShape(Capsule())
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovered)
        }

        private var fill: Color {
            if let tint {
                return configuration.isPressed ? tint.opacity(0.8) : isHovered ? tint.lighter(0.05) : tint
            }
            return configuration.isPressed ? Theme.controlFillPressed : isHovered && isEnabled ? Theme.controlFillHover : Theme.controlFill
        }
    }
}

/// One segment of a split pill: fills only its own part, rounded on the given ends.
private struct SegmentStyle: ButtonStyle {
    let edges: Edge.Set

    func makeBody(configuration: Configuration) -> some View {
        SegmentBody(configuration: configuration, edges: edges)
    }

    private struct SegmentBody: View {
        let configuration: Configuration
        let edges: Edge.Set
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .frame(maxHeight: .infinity)
                .background(CapsuleSegmentShape(edges: edges).fill(
                    configuration.isPressed ? Theme.controlFillPressed : isHovered ? Theme.controlFillHover : Theme.controlFill))
                .contentShape(CapsuleSegmentShape(edges: edges))
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovered)
        }
    }
}

/// A capsule with only some ends rounded, so two buttons can form one split control.
struct CapsuleSegmentShape: Shape {
    var edges: Edge.Set

    func path(in rect: CGRect) -> Path {
        let r = rect.height / 2
        return Path(roundedRect: rect, cornerRadii: RectangleCornerRadii(
            topLeading: edges.contains(.leading) ? r : 0,
            bottomLeading: edges.contains(.leading) ? r : 0,
            bottomTrailing: edges.contains(.trailing) ? r : 0,
            topTrailing: edges.contains(.trailing) ? r : 0))
    }
}

// MARK: - Split button with a native pop-up menu

enum MenuEntry {
    case item(String, enabled: Bool = true, action: () -> Void)
    case separator
}

/// "Scan | ⌄" — the main part triggers `action`, the chevron pops up a native NSMenu under the control.
struct SplitButton: View {
    let title: LocalizedStringKey
    var minTitleWidth: CGFloat = 58
    let action: () -> Void
    let menu: () -> [MenuEntry]

    @State private var anchor = MenuAnchor.Box()

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                // Grows with the label: translations are often longer than "Scan" / "View".
                Text(title).lineLimit(1).fixedSize().padding(.horizontal, 12).frame(minWidth: minTitleWidth)
            }
            .buttonStyle(SegmentStyle(edges: .leading))

            Theme.controlDivider.frame(width: 1)

            Button {
                anchor.popUp(menu())
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 30)
            }
            .buttonStyle(SegmentStyle(edges: .trailing))
        }
        .frame(height: 30)
        .overlay(Capsule().strokeBorder(Theme.controlBorder, lineWidth: 1))
        .shadow(color: Theme.shadow.opacity(0.7), radius: 4, y: 2)
        .background(MenuAnchor(box: anchor))
    }
}

/// Invisible AppKit view used as the positioning anchor for pop-up menus.
struct MenuAnchor: NSViewRepresentable {
    @MainActor final class Box {
        weak var view: NSView?

        func popUp(_ entries: [MenuEntry]) {
            guard let view else { return }
            let menu = NSMenu()
            menu.autoenablesItems = false
            for entry in entries {
                switch entry {
                case .separator:
                    menu.addItem(.separator())
                case let .item(title, enabled, action):
                    let item = ClosureMenuItem(title: title, action: action)
                    item.isEnabled = enabled
                    menu.addItem(item)
                }
            }
            let y: CGFloat = view.isFlipped ? view.bounds.height + 4 : -4
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: view)
        }
    }

    let box: Box

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { box.view = nsView }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

// MARK: - Bars

enum UsageSeverity {
    case normal, low, critical

    init(freeFraction: Double) {
        self = freeFraction < 0.05 ? .critical : freeFraction < 0.15 ? .low : .normal
    }

    var fill: Color {
        switch self {
        case .normal: Theme.accent
        case .low: Theme.warning
        case .critical: Theme.critical
        }
    }

    /// Color of the "free" caption: plain text normally, the warning color (and semibold) when space is low.
    var labelColor: Color {
        switch self {
        case .normal: Theme.primaryText
        case .low: Theme.warning
        case .critical: Theme.critical
        }
    }
}

/// Rounded 6 pt track.
struct BarTrack: View {
    var body: some View {
        Capsule().fill(Theme.track).frame(height: 6)
    }
}

struct UsageBar: View {
    let fraction: Double
    let severity: UsageSeverity

    var body: some View {
        BarTrack()
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(severity.fill)
                        .frame(width: max(6, geo.size.width * min(1, max(0, fraction))))
                }
            }
            .frame(height: 6)
            .animation(.easeOut(duration: 0.4), value: fraction)
    }
}

/// Animated striped bar shown while scanning. `progress == nil` means indeterminate (full width).
struct ScanningBar: View {
    let progress: Double?

    var body: some View {
        BarTrack()
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    let width = geo.size.width * min(1, max(0.03, progress ?? 1))
                    TimelineView(.animation) { timeline in
                        Canvas { context, size in
                            let period: CGFloat = 10
                            let phase = CGFloat(timeline.date.timeIntervalSinceReferenceDate * 16)
                                .truncatingRemainder(dividingBy: period)
                            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.accent.opacity(0.55)))
                            var x = -size.height - period + phase
                            while x < size.width {
                                var stripe = Path()
                                stripe.move(to: CGPoint(x: x, y: size.height))
                                stripe.addLine(to: CGPoint(x: x + size.height, y: 0))
                                stripe.addLine(to: CGPoint(x: x + size.height + period / 2, y: 0))
                                stripe.addLine(to: CGPoint(x: x + period / 2, y: size.height))
                                stripe.closeSubpath()
                                context.fill(stripe, with: .color(Theme.accent))
                                x += period
                            }
                        }
                    }
                    .frame(width: width, height: 6)
                    .clipShape(Capsule())
                    .animation(.linear(duration: 0.25), value: width)
                }
            }
            .frame(height: 6)
    }
}
