import ScanEngine
import SwiftUI

/// Dark About window with the lifetime "recovered" counter, like DaisyDisk's.
struct AboutView: View {
    @Environment(AppModel.self) private var model

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?", build = info?["CFBundleVersion"] as? String ?? "?"
        return String(localized: "version \(short) (\(build))", comment: "About window: version and build number")
    }

    var body: some View {
        VStack(spacing: 8) {
            // From the asset catalog: NSApp.applicationIconImage can be a stale copy from the system's icon cache.
            Image(nsImage: AppIconImage.current)
                .resizable()
                .frame(width: 120, height: 120)
            Text(verbatim: "DiskGarden")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Theme.primaryText)
            Text(version)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
            Group {
                if model.recoveredBytes > 0 {
                    VStack(spacing: 3) {
                        Text(ByteSize.string(model.recoveredBytes))
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(Theme.accentText)
                        Text(recoveredCaption)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryText)
                    }
                } else {
                    Text("Nothing recovered yet. Put something big in the Waste bin and empty it.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 20)
            .glassCard(radius: 16)
            .padding(.top, 14)
        }
        .padding(32)
        .frame(width: 400)
        .background(Theme.windowBackground)
    }

    private var recoveredCaption: String {
        guard let since = model.recoveredSince else { return String(localized: "recovered", comment: "About window: under the total size of deleted files") }
        let date = since.formatted(.dateTime.day().month(.abbreviated).year())
        return String(localized: "recovered since \(date)", comment: "About window: under the total size of deleted files")
    }
}

/// The app's icon from the asset catalog (NSApp.applicationIconImage can be a stale copy from the system's icon cache);
/// the debug app has its own, with a DEBUG band.
@MainActor
enum AppIconImage {
    static var current: NSImage {
        #if DEBUG
        NSImage(named: "AppIconDebug") ?? NSApp.applicationIconImage
        #else
        NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
        #endif
    }
}
