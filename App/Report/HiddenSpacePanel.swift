import AppKit
import ScanEngine
import SwiftUI

/// "hidden space…": used space the scan couldn't attribute to visible files. Opening it swaps the chart for a donut
/// of its parts and the legend for their sizes, a short explanation and — when folders were off limits — one button
/// to Full Disk Access (like DaisyDisk).
enum HiddenSpace {
    struct Part: Identifiable {
        let id: String
        let title: String
        let bytes: UInt64
        /// Shown as a count instead of a size (snapshots).
        var count: Int? = nil
        let shade: Double
    }

    @MainActor static func parts(_ report: ReportModel) -> [Part] {
        [
            Part(id: "purgeable", title: String(localized: "purgeable space"), bytes: report.hiddenPurgeableBytes, shade: 1.0),
            Part(id: "snapshots", title: String(localized: "snapshots…"), bytes: 0, count: report.snapshots?.count, shade: 0.8),
            Part(id: "volumes", title: String(localized: "other volumes"), bytes: report.otherVolumesBytes, shade: 0.62),
            Part(id: "hidden", title: String(localized: "still hidden"), bytes: report.stillHiddenBytes, shade: 0.45),
        ]
    }

    static func color(_ shade: Double) -> Color {
        let base = SunburstPalette.hiddenSpace
        return Color(.displayP3, red: base.r * (0.55 + 0.75 * shade), green: base.g * (0.55 + 0.75 * shade),
                     blue: base.b * (0.55 + 0.75 * shade))
    }
}

/// Replaces the legend while hidden space is open.
struct HiddenSpaceLegend: View {
    let report: ReportModel

    var body: some View {
        let restricted = !FullDiskAccess.isGranted
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle().fill(HiddenSpace.color(0.8)).frame(width: 10, height: 10)
                Text("hidden space…")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.hiddenSpaceText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                SizeText(parts: ByteSize.parts(report.hiddenBytes), fontSize: 20, weight: .bold)
                    .fixedSize()
                    .layoutPriority(1)
            }
            .padding(.bottom, 12)

            ForEach(HiddenSpace.parts(report)) { part in
                HStack(spacing: 10) {
                    Circle().fill(HiddenSpace.color(part.shade)).frame(width: 7, height: 7)
                    Text(part.title).font(.system(size: 14)).foregroundStyle(Theme.hiddenSpaceText.opacity(0.6 + 0.4 * part.shade))
                    Spacer(minLength: 8)
                    if part.id == "snapshots" {
                        Text(part.count.map { "\($0)" } ?? "…").font(.system(size: 14)).monospacedDigit()
                            .foregroundStyle(Theme.secondaryText)
                    } else {
                        SizeText(parts: ByteSize.parts(part.bytes), fontSize: 14)
                    }
                }
                .frame(height: 28)
                .padding(.leading, 2)
            }

            Theme.divider.frame(height: 1).padding(.vertical, 14)

            VStack(alignment: .leading, spacing: 10) {
                if restricted {
                    Text("Some folders weren't scanned because DiskGarden doesn't have full access to your disk.")
                    Text("Turn on DiskGarden in System Settings › Privacy & Security › Full Disk Access, then reopen DiskGarden and rescan.")
                } else {
                    Text("This is space used by macOS itself, other users and the file system's own bookkeeping, which apps can't see.")
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            if restricted {
                Button("Open Full Disk Access Settings…") { FullDiskAccess.openSystemSettings() }
                    .buttonStyle(PillButtonStyle(tint: Theme.accent))
                    .padding(.top, 16)
            }
        }
        .padding(20)
        .glassCard(radius: Theme.panelRadius)
    }
}

/// Replaces the chart while hidden space is open: a ring of the parts with the total in the middle.
struct HiddenSpaceDonut: View {
    let report: ReportModel
    @State private var grow: Double = 0

    var body: some View {
        let parts = HiddenSpace.parts(report).filter { $0.bytes > 0 }
        let total = Double(max(1, parts.reduce(0) { $0 + $1.bytes }))
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let ring = side * 0.085, radius = side * 0.17
            ZStack {
                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    var angle = Angle.degrees(180 - 4)
                    for part in parts {
                        let sweep = Angle.degrees(360 * Double(part.bytes) / total * grow)
                        var path = Path()
                        path.addArc(center: center, radius: radius + ring / 2, startAngle: angle, endAngle: angle + sweep, clockwise: false)
                        context.stroke(path, with: .color(HiddenSpace.color(part.shade)), style: StrokeStyle(lineWidth: ring))
                        angle += sweep
                    }
                }
                VStack(spacing: 2) {
                    Text(ByteSize.string(report.hiddenBytes))
                        .font(.system(size: max(16, radius * 0.32), weight: .bold))
                        .foregroundStyle(Theme.hiddenSpaceText)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.6)
                        .frame(width: radius * 1.6)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .onAppear { withAnimation(.easeOut(duration: 0.7)) { grow = 1 } }
    }
}
