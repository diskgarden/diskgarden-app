import AppKit
import Observation
import ScanEngine

/// One row in the Sources list: a mounted volume or a folder the user added.
@MainActor @Observable
final class Source: Identifiable {
    enum Kind {
        case volume(VolumeInfo)
        case folder
    }

    enum State {
        case idle
        case scanning
        case scanned(FileTree)
        case failed(String)
    }

    let id: String // absolute path
    var kind: Kind
    var name: String
    var icon: NSImage
    var state: State = .idle
    /// 0…1 for volumes (scanned bytes / used bytes); nil for folders, whose size is unknown up front.
    var progress: Double?
    var isFavorite = false
    /// How the rest of the APFS container relates to this scan (volume sources only).
    var accounting: ContainerAccounting = .empty
    /// Folders the last scan couldn't open, and a sample of their paths.
    var restrictedCount = 0
    var restrictedPaths: [String] = []
    /// Set while an administrator rescan is running (spinner / disabled menu items).
    var adminActivity: String?
    /// Last administrator-action error, shown on the row / in the report.
    var adminError: String?
    /// A saved result on disk for this source (from an earlier session), not necessarily loaded.
    var savedInfo: SavedScanInfo?
    /// When the current (or saved) result was scanned.
    var scanDate: Date?
    /// Collector contents to restore into the next report (after a rescan or loading a saved scan).
    var pendingCollectedPaths: [String] = []
    /// Status while loading a saved scan.
    var isLoadingSaved = false
    /// The result came from an earlier session, so changes made while DiskGarden was closed are missing.
    var isFromSavedScan = false

    /// Results older than this may have missed changes; the report quietly suggests a rescan.
    static let outdatedAfter: TimeInterval = 4 * 3600

    /// Whether the result may have drifted from the disk: old, and not kept current by live updates the whole time.
    func isOutdated(now: Date = Date(), updatesLive: Bool) -> Bool {
        guard let scanDate, now.timeIntervalSince(scanDate) > Self.outdatedAfter else { return false }
        return isFromSavedScan || !updatesLive
    }

    @ObservationIgnored var scanner: DiskScanner?
    @ObservationIgnored var scanTask: Task<Void, Never>?

    var url: URL { URL(fileURLWithPath: id) }

    var volume: VolumeInfo? {
        if case .volume(let v) = kind { return v }
        return nil
    }

    var tree: FileTree? {
        if case .scanned(let t) = state { return t }
        return nil
    }

    /// Has a result to show — loaded or saved on disk.
    var hasResult: Bool { tree != nil || savedInfo != nil }

    var isScanning: Bool {
        if case .scanning = state { return true }
        return false
    }

    init(volume: VolumeInfo) {
        id = volume.path
        kind = .volume(volume)
        name = volume.name
        icon = NSWorkspace.shared.icon(forFile: volume.path)
    }

    init(folder url: URL) {
        id = url.standardizedFileURL.path
        kind = .folder
        name = FileManager.default.displayName(atPath: url.path)
        icon = NSWorkspace.shared.icon(forFile: url.path)
    }
}

@MainActor @Observable
final class AppModel {
    enum Page: Equatable {
        case sources
        case report(Source.ID)
    }

    private(set) var page: Page = .sources
    private(set) var sources: [Source] = []
    /// One report per scanned source, kept alive so focus, history and the Collector survive leaving the page.
    @ObservationIgnored private var reports: [Source.ID: ReportModel] = [:]

    private static let favoritesKey = "favoriteFolders"
    private static let deletionModeKey = "deletionMode"
    private static let recoveredBytesKey = "recoveredBytes"
    private static let recoveredSinceKey = "recoveredSince"

    /// Move to Trash is the default while DiskGarden is young; DaisyDisk's behavior is `.permanent`.
    /// `DG_DELETION_MODE=permanent|moveToTrash` overrides it for scripted tests without touching preferences.
    var deletionMode: DeletionMode = DeletionMode(rawValue: ProcessInfo.processInfo.environment["DG_DELETION_MODE"] ?? "")
        ?? DeletionMode(rawValue: UserDefaults.standard.string(forKey: AppModel.deletionModeKey) ?? "")
        ?? .moveToTrash {
        didSet { UserDefaults.standard.set(deletionMode.rawValue, forKey: Self.deletionModeKey) }
    }

    /// Show a "Congrats!" card after freeing more than `congratulationsThreshold`.
    /// Settings → Appearance (dark by default).
    var appearance: AppAppearance = AppAppearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .dark {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "appearance")
            applyAppearance()
        }
    }

    func applyAppearance() {
        NSApp.appearance = appearance.nsAppearance
    }

    var showsCongratulations: Bool = UserDefaults.standard.object(forKey: "showsCongratulations") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsCongratulations, forKey: "showsCongratulations") }
    }
    static let congratulationsThreshold: UInt64 = 5_000_000_000
    /// Bytes to congratulate the user on (drives the card); nil when not showing.
    var congratulations: UInt64?

    /// Display sizes in 1024-based units instead of Finder's 1000-based units.
    var usesBinarySizes: Bool = UserDefaults.standard.bool(forKey: "usesBinarySizes") {
        didSet {
            UserDefaults.standard.set(usesBinarySizes, forKey: "usesBinarySizes")
            ByteSize.defaultBase = usesBinarySizes ? 1024 : 1000
            sizeUnitsVersion += 1
        }
    }
    /// Bumped when size formatting changes so views re-render.
    private(set) var sizeUnitsVersion = 0

    static let shared = AppModel()

    /// Saved scan results live in ~/Library/Application Support/DiskGarden/Scans ("DiskGarden Debug" for the debug app).
    let store = ScanStore.standard(appFolder: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "DiskGarden")

    /// How the Volumes page shows its items. Grid only fits a few: with more, the page falls back to the list.
    enum VolumesLayout: String { case grid, list }
    static let maxGridItems = 3

    var volumesLayout: VolumesLayout = VolumesLayout(rawValue: UserDefaults.standard.string(forKey: "volumesLayout") ?? "") ?? .grid {
        didSet { UserDefaults.standard.set(volumesLayout.rawValue, forKey: "volumesLayout") }
    }
    /// Whether the grid is possible at all (the switch is hidden otherwise).
    var canShowVolumesGrid: Bool { sources.count <= Self.maxGridItems }
    /// The layout actually shown.
    var showsVolumesGrid: Bool { volumesLayout == .grid && canShowVolumesGrid }

    /// Watch scanned folders and update results when files change.
    var updatesLive: Bool = UserDefaults.standard.object(forKey: "updatesLive") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(updatesLive, forKey: "updatesLive")
            for source in sources { updatesLive ? startWatching(source) : stopWatching(source) }
        }
    }
    @ObservationIgnored private var updaters: [Source.ID: LiveUpdater] = [:]

    func startWatching(_ source: Source) {
        guard updatesLive, source.tree != nil, updaters[source.id] == nil else { return }
        updaters[source.id] = LiveUpdater(model: self, source: source)
    }

    func stopWatching(_ source: Source) {
        updaters.removeValue(forKey: source.id)?.stop()
    }

    /// The report for a source if one has been opened (doesn't create one).
    func existingReport(for id: Source.ID) -> ReportModel? { reports[id] }

    /// Keep scan results between launches.
    var remembersScans: Bool = UserDefaults.standard.object(forKey: "remembersScans") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(remembersScans, forKey: "remembersScans")
            if !remembersScans { for source in sources { store.delete(source.id); source.savedInfo = nil } }
        }
    }

    /// Lifetime total shown in About ("75.7 GB recovered since 8 Oct 2024").
    private(set) var recoveredBytes = UInt64(UserDefaults.standard.double(forKey: AppModel.recoveredBytesKey))
    var recoveredSince: Date? { UserDefaults.standard.object(forKey: Self.recoveredSinceKey) as? Date }

    init() {
        ByteSize.defaultBase = UserDefaults.standard.bool(forKey: "usesBinarySizes") ? 1024 : 1000
        // Results scanned with different access would show different folders and hidden space: start fresh.
        if Self.fullDiskAccessChanged() { store.deleteAll() }
        // A day-old result has likely drifted far from the disk: start each day fresh (only at launch, never mid-session).
        store.deleteScans(olderThan: Date().addingTimeInterval(-Self.savedScanLifetime))
        reloadVolumes()
        for path in UserDefaults.standard.stringArray(forKey: Self.favoritesKey) ?? []
        where FileManager.default.fileExists(atPath: path) {
            let source = Source(folder: URL(fileURLWithPath: path))
            source.isFavorite = true
            source.savedInfo = remembersScans ? store.info(for: source.id) : nil
            sources.append(source)
        }
        // Full Disk Access can also change while DiskGarden runs (macOS then offers to quit and reopen it).
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Self.fullDiskAccessChanged() else { return }
                self.forgetAllScans()
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadVolumes() }
            }
        }
    }

    func source(_ id: Source.ID) -> Source? { sources.first { $0.id == id } }

    // MARK: App-wide state for quit guards

    var isScanningAnything: Bool { sources.contains { $0.isScanning || $0.adminActivity != nil } }
    var isDeletingAnything: Bool { reports.values.contains { $0.isDeleting } }
    var hasCollectedItems: Bool { reports.values.contains { !$0.collected.isEmpty } }

    /// The report currently on screen, if any.
    var currentReport: ReportModel? { currentSource.flatMap { reports[$0.id] } }

    func report(for source: Source) -> ReportModel? {
        guard let tree = source.tree else { return nil }
        if let existing = reports[source.id], existing.tree === tree { return existing }
        let report = ReportModel(source: source, tree: tree)
        report.onDeleted = { [weak self, weak source] freed in
            self?.didFree(freed)
            if let source { self?.persist(source) }
        }
        if !source.pendingCollectedPaths.isEmpty {
            report.recollect(paths: source.pendingCollectedPaths)
            source.pendingCollectedPaths = []
        }
        report.onCollectionChanged = { [weak self, weak source] paths in
            guard let self, let source, var info = source.savedInfo, self.remembersScans else { return }
            info.collectedPaths = paths
            source.savedInfo = info
            self.store.updateInfo(info)
        }
        reports[source.id] = report
        return report
    }

    private func didFree(_ bytes: UInt64) {
        guard bytes > 0 else { return }
        let showsCard = showsCongratulations && bytes >= Self.congratulationsThreshold
        if showsCard { congratulations = bytes }
        if recoveredSince == nil { UserDefaults.standard.set(Date(), forKey: Self.recoveredSinceKey) }
        recoveredBytes += bytes
        UserDefaults.standard.set(Double(recoveredBytes), forKey: Self.recoveredBytesKey)
        ShareNudge.shared.didFreeSpace(total: recoveredBytes, showedCard: showsCard)
        reloadVolumes() // free space changed
    }

    var currentSource: Source? {
        if case .report(let id) = page { return source(id) }
        return nil
    }

    // MARK: Volumes

    /// Refreshes the volume rows, keeping scan state for volumes that are still mounted.
    func reloadVolumes() {
        let volumes = VolumeCatalog.mountedVolumes()
        var existing = Dictionary(uniqueKeysWithValues: sources.compactMap { s in s.volume.map { _ in (s.id, s) } })
        let volumeSources = volumes.map { v -> Source in
            if let s = existing.removeValue(forKey: v.path) {
                s.kind = .volume(v)
                s.name = v.name
                return s
            }
            let source = Source(volume: v)
            source.savedInfo = remembersScans ? store.info(for: source.id) : nil
            return source
        }
        // Volumes that disappeared: stop their scans and leave the report if it was showing one.
        for gone in existing.values {
            gone.scanner?.cancel()
            stopWatching(gone)
            if page == .report(gone.id) { page = .sources }
        }
        let folders = sources.filter { $0.volume == nil }
        sources = volumeSources + folders
    }

    // MARK: Folders

    /// Adds a folder row (or reuses the existing one) and starts scanning it.
    func addFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        if let volumeSource = sources.first(where: { $0.volume != nil && $0.id == path }) {
            scan(volumeSource.id)
            return
        }
        if let existing = source(path) {
            if existing.tree != nil { view(existing.id) } else { scan(existing.id) }
            return
        }
        let source = Source(folder: url)
        sources.append(source)
        scan(source.id)
    }

    func toggleFavorite(_ id: Source.ID) {
        guard let s = source(id), s.volume == nil else { return }
        s.isFavorite.toggle()
        saveFavorites()
    }

    private func saveFavorites() {
        UserDefaults.standard.set(sources.filter(\.isFavorite).map(\.id), forKey: Self.favoritesKey)
    }

    // MARK: Scanning

    func scan(_ id: Source.ID) {
        guard let source = source(id), !source.isScanning else { return }
        stopWatching(source)
        source.state = .scanning
        source.progress = source.volume == nil ? nil : 0
        let expectedBytes = source.volume.map { Double(max(1, $0.usedBytes)) }
        let isVolume = source.volume != nil
        let root = source.id
        // Fewer parallel reads on spinning disks, network shares and optical media.
        let workers = (source.volume ?? VolumeCatalog.volume(containing: URL(fileURLWithPath: root)))?.recommendedWorkerCount
            ?? ScanOptions.defaultWorkerCount

        source.scanTask = Task { [weak self, weak source] in
            // Sibling APFS volumes (VM, Preboot, …) get their real size instead of showing as empty mount points.
            let accounting = isVolume
                ? await Task.detached { ContainerAccounting(root: root, volumes: APFSContainer.volumes(sharingContainerWith: root)) }.value
                : .empty
            let scanner = DiskScanner(path: root, options: ScanOptions(workerCount: workers,
                                                                       fixedSizeMountPoints: accounting.fixedSizeMountPoints,
                                                                       startupDisk: root == "/"))
            guard !Task.isCancelled else { source?.state = .idle; return }
            if ProcessInfo.processInfo.environment["DG_TRACE"] != nil {
                NSLog("DG scan %@: fixed mounts %@, other volumes %d", root, "\(accounting.fixedSizeMountPoints)", accounting.otherVolumes.count)
            }
            source?.scanner = scanner
            source?.accounting = accounting
            let poller = Task { @MainActor [weak source] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let source, let expectedBytes else { continue }
                    source.progress = min(0.98, Double(scanner.progress.byteCount) / expectedBytes)
                }
            }
            defer { poller.cancel() }
            do {
                let tree = try await scanner.scan()
                guard let source else { return }
                source.progress = 1
                source.restrictedCount = scanner.progress.restrictedCount
                source.restrictedPaths = scanner.progress.restrictedPaths
                source.state = .scanned(tree)
                source.scanDate = Date()
                source.isFromSavedScan = false
                source.scanner = nil
                self?.persist(source)
                self?.startWatching(source)
                // Like DaisyDisk: a finished scan opens its map if the user is still on the Sources page.
                if self?.page == .sources { self?.view(source.id) }
            } catch ScanError.cancelled {
                source?.state = .idle
                source?.scanner = nil
            } catch ScanError.cannotOpen(_, let code) {
                source?.state = .failed(String(cString: strerror(code)))
                source?.scanner = nil
            } catch {
                CrashReporter.record(error, context: "scan")
                source?.state = .failed(error.localizedDescription)
                source?.scanner = nil
            }
        }
    }

    // MARK: Administrator scans

    /// Rescans only the folders the last scan couldn't open, as root, and grafts them into the existing tree.
    func quickRescanAsAdministrator(_ id: Source.ID) {
        guard let source = source(id), let tree = source.tree, source.adminActivity == nil else { return }
        let nodes = tree.restrictedNodes()
        guard !nodes.isEmpty else { return }
        let paths = nodes.map(tree.path)
        source.adminActivity = String(localized: "Rescanning \(nodes.count) restricted folders as administrator…", comment: "Status line; plural")
        source.adminError = nil
        Task { [weak self, weak source] in
            do {
                let entries = try await AdminRunner.scan(
                    paths: paths,
                    reason: String(localized: "DiskGarden needs administrator access to scan folders it isn't allowed to read.", comment: "Shown in the macOS password prompt"))
                guard let source, source.tree === tree else { return }
                var byPath: [String: NodeRef] = [:]
                for (node, path) in zip(nodes, paths) { byPath[path] = node }
                for entry in entries {
                    if let node = byPath[entry.path] { try? tree.graft(entry, at: node) }
                }
                let remaining = tree.restrictedNodes()
                source.restrictedCount = remaining.count
                source.restrictedPaths = remaining.prefix(50).map(tree.path)
                self?.reports[id]?.relayout()
                self?.persist(source)
                if ProcessInfo.processInfo.environment["DG_TRACE"] != nil {
                    NSLog("DG quick-admin: %d entries grafted, %d still restricted, root now %llu bytes, hidden %llu",
                          entries.count, remaining.count, tree.size(tree.root), self?.reports[id]?.hiddenBytes ?? 0)
                }
            } catch {
                if !Self.isCancellation(error) { CrashReporter.record(error, context: "quick-admin-rescan") }
                source?.adminError = error.localizedDescription
                if ProcessInfo.processInfo.environment["DG_TRACE"] != nil { NSLog("DG quick-admin failed: %@", "\(error)") }
            }
            source?.adminActivity = nil
        }
    }

    /// Scans the whole source as root (also used for "Full Deep Scan (Admin)").
    func scanAsAdministrator(_ id: Source.ID) {
        guard let source = source(id), !source.isScanning, source.adminActivity == nil else { return }
        let root = source.id
        let isVolume = source.volume != nil
        let previous = source.state
        source.state = .scanning
        source.progress = nil
        stopWatching(source)
        source.adminActivity = String(localized: "Scanning as administrator…", comment: "Status line")
        source.adminError = nil
        if let collected = reports[id]?.collected.map(\.path), !collected.isEmpty { source.pendingCollectedPaths = collected }
        reports[id] = nil
        Task { [weak self, weak source] in
            do {
                let accounting = isVolume
                    ? await Task.detached { ContainerAccounting(root: root, volumes: APFSContainer.volumes(sharingContainerWith: root)) }.value
                    : .empty
                let entries = try await AdminRunner.scan(
                    paths: [root], fixedMountPoints: accounting.fixedSizeMountPoints,
                    reason: String(localized: "DiskGarden needs administrator access to scan all of “\(source?.name ?? root)”.", comment: "Shown in the macOS password prompt"))
                guard let entry = entries.first else { throw AdminRunner.Failure.failed(String(localized: "The helper returned no results.", comment: "Admin scan error")) }
                let tree = try await Task.detached { try FileTree.fromArchive(entry) }.value
                guard let source else { return }
                source.accounting = accounting
                let remaining = tree.restrictedNodes()
                source.restrictedCount = remaining.count
                source.restrictedPaths = remaining.prefix(50).map(tree.path)
                source.state = .scanned(tree)
                source.scanDate = Date()
                source.progress = 1
                source.adminActivity = nil
                self?.persist(source)
                self?.startWatching(source)
                if self?.page == .sources { self?.view(source.id) }
            } catch {
                if !Self.isCancellation(error) { CrashReporter.record(error, context: "admin-scan") }
                source?.state = previous
                source?.adminError = error.localizedDescription
                source?.adminActivity = nil
            }
        }
    }

    func cancelScan(_ id: Source.ID) {
        guard let source = source(id) else { return }
        source.scanner?.cancel()
        source.scanTask?.cancel() // also covers the brief container-inspection step before the scanner exists
        if source.scanner == nil { source.state = .idle }
    }

    func rescan(_ id: Source.ID) {
        guard let source = source(id) else { return }
        // Keep the Collector: its items are re-collected by path once the new scan finishes.
        if let collected = reports[id]?.collected.map(\.path), !collected.isEmpty { source.pendingCollectedPaths = collected }
        // Watch progress on the Volumes page (the report would be empty meanwhile); the new map opens when it's done.
        if page == .report(id) { showSources() }
        reports[id] = nil
        source.state = .idle
        scan(id)
    }

    private static let fullDiskAccessKey = "fullDiskAccessGranted"
    /// Saved results older than this are deleted at launch.
    static let savedScanLifetime: TimeInterval = 24 * 3600

    /// Whether Full Disk Access was granted or revoked since the last check (records the current state).
    static func fullDiskAccessChanged() -> Bool {
        let granted = FullDiskAccess.isGranted
        let previous = UserDefaults.standard.object(forKey: fullDiskAccessKey) as? Bool
        UserDefaults.standard.set(granted, forKey: fullDiskAccessKey)
        return previous != nil && previous != granted
    }

    /// Forgets every scan result (Full Disk Access changed): they no longer match what a scan would see.
    func forgetAllScans() {
        for source in sources where source.tree != nil || source.savedInfo != nil || source.isScanning {
            forget(source.id)
        }
        store.deleteAll()
        page = .sources
    }

    /// Drops the scan result. Folder rows that aren't favorites disappear entirely.
    func forget(_ id: Source.ID) {
        guard let source = source(id) else { return }
        reports[id] = nil
        store.delete(id)
        stopWatching(source)
        source.savedInfo = nil
        source.scanDate = nil
        source.pendingCollectedPaths = []
        source.scanner?.cancel()
        source.state = .idle
        source.progress = nil
        if page == .report(id) { page = .sources }
        if source.volume == nil && !source.isFavorite {
            sources.removeAll { $0.id == id }
        }
    }

    // MARK: Navigation

    func view(_ id: Source.ID) {
        guard let source = source(id) else { return }
        if source.tree != nil {
            page = .report(id)
        } else if source.savedInfo != nil {
            loadSaved(source)
        }
    }

    // MARK: Saved scans

    /// Loads a saved result (~0.5 s for a full disk) and opens it.
    private func loadSaved(_ source: Source) {
        guard let info = source.savedInfo, !source.isLoadingSaved, !source.isScanning else { return }
        source.isLoadingSaved = true
        source.state = .scanning
        source.progress = nil
        let store = self.store
        let trace = ProcessInfo.processInfo.environment["DG_TRACE"] != nil
        if trace { NSLog("DG load saved %@: start", info.rootPath) }
        Task { [weak self, weak source] in
            do {
                let started = Date()
                let tree = try await Task.detached { try store.loadTree(for: info.rootPath) }.value
                if trace { NSLog("DG load saved %@: done in %.2fs, source alive %d", info.rootPath, Date().timeIntervalSince(started), source == nil ? 0 : 1) }
                guard let source else { return }
                source.accounting = ContainerAccounting(restoring: info)
                source.restrictedCount = info.restrictedCount
                source.restrictedPaths = info.restrictedPaths
                source.pendingCollectedPaths = info.collectedPaths
                source.scanDate = info.date
                source.isFromSavedScan = true
                source.state = .scanned(tree)
                source.isLoadingSaved = false
                self?.startWatching(source)
                if self?.page == .sources { self?.view(source.id) }
            } catch {
                // Keep the files: a failure can be transient (e.g. another instance replacing the scan right now).
                if trace { NSLog("DG load saved %@: failed %@", info.rootPath, "\(error)") }
                CrashReporter.record(error, context: "load-saved-scan")
                source?.isLoadingSaved = false
                source?.state = .failed(String(localized: "Couldn't open the saved scan. Try again or rescan.", comment: "Error on a volume card"))
            }
        }
    }

    /// Saves the source's current result in the background (collector contents are remembered by path).
    private var saveTasks: [Source.ID: Task<Void, Never>] = [:]

    /// The user dismissed the administrator password prompt: not an error worth reporting.
    static func isCancellation(_ error: Error) -> Bool {
        if case AdminRunner.Failure.cancelled? = error as? AdminRunner.Failure { return true }
        return false
    }

    func persist(_ source: Source) {
        guard remembersScans, let tree = source.tree else { return }
        let collected = reports[source.id]?.collected.map(\.path) ?? source.pendingCollectedPaths
        let info = SavedScanInfo(
            rootPath: source.id, date: source.scanDate ?? Date(), totalBytes: tree.size(tree.root),
            nodeCount: UInt64(tree.descendantCount(tree.root) + 1), volumeUUID: ScanStore.volumeUUID(for: source.id),
            restrictedCount: source.restrictedCount, restrictedPaths: source.restrictedPaths,
            fixedSizeMountPoints: source.accounting.fixedSizeMountPoints, otherVolumes: source.accounting.otherVolumes,
            collectedPaths: collected)
        source.savedInfo = info
        let store = self.store
        // Reads the tree off the main thread. Nothing may edit it meanwhile: live refresh awaits `finishSaving` first
        // (an edit racing the archive walk wrote inconsistent, unloadable scans). Saves of one source never overlap.
        let previous = saveTasks[source.id]
        saveTasks[source.id] = Task.detached(priority: .utility) { [weak source] in
            await previous?.value
            do {
                try store.save(tree, info: info)
            } catch {
                // Not saved (e.g. the disk is nearly full): the result stays in memory only, until the app quits.
                await MainActor.run { if source?.savedInfo == info { source?.savedInfo = nil } }
            }
        }
    }

    /// Waits until no saved-scan write is reading `id`'s tree.
    func finishSaving(_ id: Source.ID) async {
        while let task = saveTasks[id] {
            await task.value
            if saveTasks[id] == task { saveTasks[id] = nil }
        }
    }

    func showSources() { page = .sources }

    // MARK: Finder

    func showInFinder(_ id: Source.ID) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: id)])
    }

    func getInfo(_ id: Source.ID) {
        let escaped = id.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Finder"
            activate
            open information window of (POSIX file "\(escaped)" as alias)
        end tell
        """
        Task.detached {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Scan", comment: "Open panel button: scan the chosen folder")
        panel.message = String(localized: "Choose a folder to scan", comment: "Open panel message")
        if panel.runModal() == .OK, let url = panel.url {
            addFolder(url)
        }
    }
}
