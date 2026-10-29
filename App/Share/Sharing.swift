import AppKit
import ScanEngine
import SwiftUI

/// What to share: the app itself (toolbar button) or the space just freed (congratulations card).
enum ShareContent: Equatable {
    case app
    case freed(UInt64)
    /// Lifetime freed space passed a milestone (share nudge).
    case milestone(UInt64)

    static let website = URL(string: "https://diskgarden.app")!

    var title: LocalizedStringKey {
        switch self {
        case .app: "Share DiskGarden"
        case .freed, .milestone: "Share your cleanup"
        }
    }

    /// The post text, without the link (services that take a separate URL get it on its own).
    var message: String {
        switch self {
        case .app:
            String(localized: "DiskGarden shows what's filling up your Mac as one beautiful interactive map, and helps you clear it out. Free for macOS.",
                   comment: "Share text for recommending the app")
        case .freed(let bytes):
            String(localized: "I just freed up \(ByteSize.string(bytes)) on my Mac with DiskGarden 🌱",
                   comment: "Share text after deleting files; the placeholder is a size like 10.7 GB")
        case .milestone(let bytes):
            String(localized: "I've freed up \(ByteSize.string(bytes)) on my Mac so far with DiskGarden 🌱",
                   comment: "Share text at a milestone of total freed space; the placeholder is a size like 52 GB")
        }
    }

    /// Text + link, for services that only take one text field and for the clipboard.
    var messageWithLink: String { "\(message) \(Self.website.absoluteString)" }
}

/// A place to share to. Social networks use their public "share" web links (no SDKs, no accounts); Messages, Mail and
/// "More…" use macOS's own sharing services.
struct ShareTarget: Identifiable {
    enum Kind { case web((ShareContent) -> URL?), service(NSSharingService.Name), copy, more }

    let id: String
    let name: String
    let glyph: Glyph
    let color: Color
    let kind: Kind
    /// Services that only take a link (Facebook, LinkedIn): the text also goes to the clipboard to paste.
    var copiesText = false

    enum Glyph { case text(String), symbol(String) }

    /// Percent-encodes everything but RFC 3986 unreserved ASCII (`.alphanumerics` would let non-ASCII letters through).
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encoded(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    @MainActor static let all: [ShareTarget] = {
        let link = encoded(ShareContent.website.absoluteString)
        return [
            ShareTarget(id: "x", name: "X", glyph: .text("𝕏"), color: Color(hex: 0x000000),
                        kind: .web { URL(string: "https://x.com/intent/post?text=\(encoded($0.message))&url=\(link)") }),
            ShareTarget(id: "threads", name: "Threads", glyph: .text("@"), color: Color(hex: 0x101010),
                        kind: .web { URL(string: "https://www.threads.net/intent/post?text=\(encoded($0.messageWithLink))") }),
            ShareTarget(id: "bluesky", name: "Bluesky", glyph: .text("🦋"), color: Color(hex: 0x1185FE),
                        kind: .web { URL(string: "https://bsky.app/intent/compose?text=\(encoded($0.messageWithLink))") }),
            ShareTarget(id: "facebook", name: "Facebook", glyph: .text("f"), color: Color(hex: 0x1877F2),
                        kind: .web { _ in URL(string: "https://www.facebook.com/sharer/sharer.php?u=\(link)") }, copiesText: true),
            ShareTarget(id: "linkedin", name: "LinkedIn", glyph: .text("in"), color: Color(hex: 0x0A66C2),
                        kind: .web { _ in URL(string: "https://www.linkedin.com/sharing/share-offsite/?url=\(link)") }, copiesText: true),
            ShareTarget(id: "reddit", name: "Reddit", glyph: .text("r/"), color: Color(hex: 0xFF4500),
                        kind: .web { URL(string: "https://www.reddit.com/submit?url=\(link)&title=\(encoded($0.message))") }),
            ShareTarget(id: "whatsapp", name: "WhatsApp", glyph: .symbol("phone.fill"), color: Color(hex: 0x25D366),
                        kind: .web { URL(string: "https://wa.me/?text=\(encoded($0.messageWithLink))") }),
            ShareTarget(id: "telegram", name: "Telegram", glyph: .symbol("paperplane.fill"), color: Color(hex: 0x229ED9),
                        kind: .web { URL(string: "https://t.me/share/url?url=\(link)&text=\(encoded($0.message))") }),
            ShareTarget(id: "messages", name: String(localized: "Messages", comment: "Share target: the Messages app"),
                        glyph: .symbol("message.fill"), color: Color(hex: 0x34C759), kind: .service(.composeMessage)),
            ShareTarget(id: "mail", name: String(localized: "Mail", comment: "Share target: the Mail app"),
                        glyph: .symbol("envelope.fill"), color: Color(hex: 0x3478F6), kind: .service(.composeEmail)),
            ShareTarget(id: "copy", name: String(localized: "Copy", comment: "Share target: copy text and link to the clipboard"),
                        glyph: .symbol("doc.on.doc.fill"), color: Theme.neutralTile, kind: .copy),
            ShareTarget(id: "more", name: String(localized: "More…", comment: "Share target: the macOS share menu"),
                        glyph: .symbol("ellipsis"), color: Theme.neutralTile, kind: .more),
        ]
    }()
}

/// Performs a share. Returns true if the text was put on the clipboard (to show "Copied").
@MainActor
enum Sharer {
    @discardableResult
    static func share(_ content: ShareContent, to target: ShareTarget, anchor: NSView?) -> Bool {
        ShareNudge.shared.didShare()
        switch target.kind {
        case .web(let url):
            if target.copiesText { copy(content) }
            if let url = url(content) { NSWorkspace.shared.open(url) }
            return target.copiesText
        case .service(let name):
            guard let service = NSSharingService(named: name) else { return false }
            if name == .composeEmail { service.subject = String(localized: "DiskGarden", comment: "Email subject when sharing the app") }
            service.perform(withItems: [content.message, ShareContent.website])
            return false
        case .copy:
            copy(content)
            return true
        case .more:
            guard let anchor else { return false }
            let picker = NSSharingServicePicker(items: [content.messageWithLink, ShareContent.website])
            picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
            return false
        }
    }

    static func copy(_ content: ShareContent) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content.messageWithLink, forType: .string)
    }
}

// MARK: - UI

/// The share panel: title, the message preview, and a grid of targets.
struct SharePanel: View {
    let content: ShareContent
    /// Opened by ShareNudge: friendly header (dismissed like any popover: click outside or Esc).
    var isNudge = false
    @State private var copied = false
    @State private var anchor = AnchorBox()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isNudge {
                HStack(spacing: 10) {
                    SproutShape().fill(Theme.accent).frame(width: 18, height: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enjoying DiskGarden?")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Theme.primaryText)
                        Text("Sharing it with a friend helps a small app grow.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
            } else {
                Text(content.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
            }

            Text(verbatim: content.messageWithLink)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.subtleFill))
                .textSelection(.enabled)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(64), spacing: 8), count: 4), spacing: 12) {
                ForEach(ShareTarget.all) { target in
                    ShareTile(target: target) {
                        let didCopy = Sharer.share(content, to: target, anchor: anchor.view)
                        if didCopy { withAnimation { copied = true } }
                    }
                }
            }

            Group {
                if copied {
                    Label("Copied: paste it into your post.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accentText)
                } else {
                    Text("Facebook and LinkedIn only take the link; the text is copied for you to paste.")
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)

        }
        .padding(18)
        .frame(width: 320)
        .background(AnchorView(box: anchor))
        .background(Theme.cardBottom)
    }
}

private struct ShareTile: View {
    let target: ShareTarget
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(target.color)
                    RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.12))
                    switch target.glyph {
                    case .text(let s): Text(verbatim: s).font(.system(size: 19, weight: .heavy, design: .rounded))
                    case .symbol(let name): Image(systemName: name).font(.system(size: 17, weight: .semibold))
                    }
                }
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .scaleEffect(isHovered ? 1.06 : 1)
                Text(verbatim: target.name)
                    .font(.system(size: 11))
                    .foregroundStyle(isHovered ? Theme.primaryText : Theme.secondaryText)
                    .lineLimit(1)
            }
            .frame(width: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering } }
    }
}

/// The round share button in the title band (opens the panel for sharing the app).
/// The toolbar's share button: a green circle that, on `ShareNudge.attention` (launch, after a deletion), expands
/// into a solid green "Share" pill, shakes its icon and collapses again.
struct ShareAppButton: View {
    var content: ShareContent = .app
    @State private var isPresented = false
    @State private var isHovered = false
    @State private var isExpanded = false
    @State private var shakes = 0
    /// Set while the panel is open as a share nudge.
    @State private var nudge: ShareContent?
    private var nudges: ShareNudge { ShareNudge.shared }

    var body: some View {
        Button { isPresented.toggle() } label: {
            ShareButtonLabel(isExpanded: isExpanded, isHighlighted: isHovered || isPresented, shakes: shakes)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(Text("Share DiskGarden"))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            if let nudge {
                SharePanel(content: nudge, isNudge: true)
            } else {
                SharePanel(content: content)
            }
        }
        .onChange(of: nudges.pending) { _, pending in
            guard let pending, !isPresented else { return }
            nudges.pending = nil
            nudge = pending
            isPresented = true
        }
        .onChange(of: isPresented) { _, open in
            if !open { nudge = nil }
        }
        .onChange(of: nudges.attention) { celebrate() }
        .task {
            // `DG_SHARE_PANEL=1` opens the panel at launch (scripted screenshots).
            guard ProcessInfo.processInfo.environment["DG_SHARE_PANEL"] != nil else { return }
            try? await Task.sleep(for: .seconds(1.5))
            isPresented = true
        }
    }

    /// Expand, shake (`ShareNudge.attentionShakes` times), collapse.
    private func celebrate() {
        guard !isPresented, !isExpanded else { return }
        let count = max(1, nudges.attentionShakes)
        Task {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) { isExpanded = true }
            try? await Task.sleep(for: .seconds(0.4))
            for i in 0..<count {
                shakes += 1 // one wiggle takes ~0.5 s
                try? await Task.sleep(for: .seconds(i == count - 1 ? 1.4 : 0.85))
            }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { isExpanded = false }
        }
    }
}

private struct ShareButtonLabel: View {
    var isExpanded: Bool
    var isHighlighted = false
    var shakes = 0
    @Environment(\.colorScheme) private var colorScheme
    /// Light mode rests as a solid green button (the design); dark mode as a green-tinted circle that turns solid
    /// when it expands.
    private var isSolid: Bool { isExpanded || colorScheme == .light }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 13, weight: .semibold))
                .offset(y: -1)
                .keyframeAnimator(initialValue: 0.0, trigger: shakes) { icon, angle in
                    icon.rotationEffect(.degrees(angle), anchor: .bottom)
                } keyframes: { _ in
                    KeyframeTrack {
                        LinearKeyframe(-18, duration: 0.07)
                        LinearKeyframe(16, duration: 0.09)
                        LinearKeyframe(-12, duration: 0.09)
                        LinearKeyframe(9, duration: 0.08)
                        LinearKeyframe(-5, duration: 0.07)
                        LinearKeyframe(0, duration: 0.07)
                    }
                }
            if isExpanded {
                Text("Share")
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize()
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.6, anchor: .leading)),
                        removal: .opacity.animation(.easeOut(duration: 0.1))))
            }
        }
        .foregroundStyle(isSolid ? Theme.onAccent : Theme.accent)
        .padding(.horizontal, isExpanded ? 13 : 0)
        .frame(minWidth: 30, minHeight: 30)
        .background(Capsule().fill(isSolid ? (isHighlighted && !isExpanded ? Theme.accent.lighter(0.05) : Theme.accent)
                                           : Theme.accent.opacity(isHighlighted ? 0.3 : 0.17)))
        .overlay(Capsule().strokeBorder(Theme.accent.opacity(isSolid ? 0 : 0.45), lineWidth: 1))
        .shadow(color: isExpanded ? Theme.accent.opacity(0.55) : isSolid ? Theme.shadow : .clear,
                radius: isExpanded ? 12 : 5, y: isExpanded ? 0 : 2)
        .contentShape(Capsule())
    }
}

/// "DiskGarden ⌄": the brand in the toolbar, also a way into the share panel.
struct BrandShareButton: View {
    @State private var isPresented = false
    @State private var isHovered = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 6) {
                BrandMark()
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isHovered || isPresented ? Theme.primaryText : Theme.secondaryText)
                    .offset(y: 1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(isHovered || isPresented ? Theme.rowHighlight : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(Text("Share DiskGarden"))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) { SharePanel(content: .app) }
    }
}

/// The trailing toolbar group: [DiskGarden ⌄] [share]. Reserves the expanded button's width so the toolbar never
/// re-lays out while the button grows; the brand slides left instead.
struct ShareToolbarCluster: View {
    var showsBrand = false
    var trailingPadding: CGFloat = 12

    var body: some View {
        ZStack(alignment: .trailing) {
            row(ShareButtonLabel(isExpanded: true)).hidden()
            row(ShareAppButton())
        }
        .padding(.trailing, trailingPadding)
    }

    private func row(_ button: some View) -> some View {
        HStack(spacing: 10) {
            RestartToUpdateButton()
            if showsBrand { BrandShareButton() }
            button
        }
    }
}

/// An NSView inside the panel to anchor macOS's share menu ("More…").
@MainActor final class AnchorBox { weak var view: NSView? }

struct AnchorView: NSViewRepresentable {
    let box: AnchorBox
    func makeNSView(context: Context) -> NSView { let v = NSView(); box.view = v; return v }
    func updateNSView(_ nsView: NSView, context: Context) { box.view = nsView }
}
