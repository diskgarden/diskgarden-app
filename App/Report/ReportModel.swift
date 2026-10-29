import AppKit
import Observation
import ScanEngine
import SwiftUI

/// State of one open report: which folder is focused, what's hovered, navigation history.
@MainActor @Observable
final class ReportModel {
    let source: Source
    let tree: FileTree

    private(set) var focus: NodeRef
    /// When set, the chart shows only the focus' children from this one on — an expanded "small items…".
    private(set) var subsetStart: NodeRef?

    /// A navigation stop: a folder, optionally narrowed to its "small items".
    struct Place: Equatable {
        var node: NodeRef
        var subsetStart: NodeRef? = nil
    }

    var place: Place { Place(node: focus, subsetStart: subsetStart) }
    private(set) var layout: SunburstLayout
    /// Bumped whenever the chart should animate to a new layout.
    private(set) var layoutVersion = 0

    /// Segment under the mouse in the chart — drives the legend content.
    var chartHover: SegmentKey?
    /// Row under the mouse in the legend — highlights the matching wedge.
    var listHover: SegmentKey?
    /// Last wedge the mouse rested on; kept while a context menu is open (hover ends when the menu appears).
    var chartMenuTarget: SegmentKey?

    // MARK: Collector state

    struct CollectedItem: Identifiable, Equatable {
        let id: NodeRef
        let name: String
        let path: String
        let size: UInt64
        let color: Color
        var error: String?
    }

    enum DeletionPhase: Equatable {
        case idle
        case countdown(startedAt: Date)
        case deleting(done: Int, total: Int)
        case finished(freed: UInt64, failures: Int)
    }

    private(set) var collected: [CollectedItem] = []
    private(set) var deletionPhase: DeletionPhase = .idle
    /// Short-lived message shown in the collector bar (e.g. why an item can't be collected).
    private(set) var notice: String?
    @ObservationIgnored private var deletionTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// Called with the bytes actually freed after a deletion finishes.
    @ObservationIgnored var onDeleted: ((UInt64) -> Void)?
    /// Called whenever the Collector's contents change (to remember them with the saved scan).
    @ObservationIgnored var onCollectionChanged: (([String]) -> Void)?

    static let countdownSeconds = 3

    private(set) var backStack: [Place] = []
    private(set) var forwardStack: [Place] = []

    init(source: Source, tree: FileTree) {
        self.source = source
        self.tree = tree
        focus = tree.root
        layout = SunburstLayout(tree: tree, focus: tree.root)
        layout = makeLayout(focus: tree.root)
    }

    // MARK: Volume-root extras

    private var isVolumeRoot: Bool { source.volume?.path == tree.rootPath }

    /// Used space the scan didn't find (only meaningful at a volume root). Includes other volumes in the container.
    var hiddenBytes: UInt64 {
        guard isVolumeRoot, let v = source.volume else { return 0 }
        let used = UInt64(max(0, v.usedBytes))
        // Collected items are still on disk until deleted: count them as scanned, not hidden.
        let scanned = tree.size(tree.root) + collectedBytes
        return used > scanned ? used - scanned : 0
    }

    // MARK: Hidden space breakdown

    /// Shows the hidden-space breakdown in place of the chart (Back / Esc / ⌘↑ return).
    var showsHiddenInfo = false {
        didSet { if showsHiddenInfo { chartHover = nil; loadSnapshots() } }
    }
    /// Local APFS/Time Machine snapshots on the volume (names), loaded lazily.
    private(set) var snapshots: [String]?

    var otherVolumes: [APFSVolume] { isVolumeRoot ? source.accounting.otherVolumes : [] }
    var otherVolumesBytes: UInt64 { min(hiddenBytes, isVolumeRoot ? source.accounting.otherVolumesBytes : 0) }
    var purgeableBytes: UInt64 {
        guard let free = freeBytes, let both = freePlusPurgeableBytes, both > free else { return 0 }
        return both - free
    }
    /// Hidden space not explained by other volumes.
    var unexplainedHiddenBytes: UInt64 { hiddenBytes - otherVolumesBytes }
    /// Purgeable data inside hidden space (macOS frees it on demand).
    var hiddenPurgeableBytes: UInt64 { min(purgeableBytes, unexplainedHiddenBytes) }
    /// What's left once purgeable space and other volumes are accounted for.
    var stillHiddenBytes: UInt64 { unexplainedHiddenBytes - hiddenPurgeableBytes }

    func loadSnapshots() {
        guard snapshots == nil, isVolumeRoot else { return }
        let volume = tree.rootPath
        Task { [weak self] in
            let names = await Task.detached { Self.listSnapshots(volume) }.value
            self?.snapshots = names
        }
    }

    nonisolated static func listSnapshots(_ volume: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["listlocalsnapshots", volume]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return output.split(separator: "\n").map(String.init).filter { $0.hasPrefix("com.apple.") }
    }

    /// Terminal script DaisyDisk-style: delete local snapshots (needs an admin password).
    var snapshotDeletionScript: String {
        "for d in $(tmutil listlocalsnapshotdates \(tree.rootPath) | tail -n +2); do sudo tmutil deletelocalsnapshots \"$d\"; done"
    }

    var freeBytes: UInt64? { isVolumeRoot ? source.volume.map { UInt64(max(0, $0.availableCapacity)) } : nil }
    var freePlusPurgeableBytes: UInt64? { isVolumeRoot ? source.volume.map { UInt64(max(0, $0.importantAvailableCapacity)) } : nil }

    /// DaisyDisk merges items narrower than ~1.5° of the chart on screen into "smaller objects" (our "small items").
    static let minAngle = 1.5 * .pi / 180

    private func makeLayout(focus: NodeRef, maxDepth: Int = RingGeometry.maxDepth, minAngle: Double = ReportModel.minAngle,
                            subsetStart: NodeRef? = nil, hueRange: ClosedRange<Double>? = nil) -> SunburstLayout {
        var options = SunburstLayout.Options(maxDepth: maxDepth, minAngle: minAngle, subsetStart: subsetStart, hueRange: hueRange)
        if isVolumeRoot, let v = source.volume, v.totalCapacity > 0 {
            options.hiddenBytes = hiddenBytes
            options.rootSweepFraction = Double(v.usedBytes) / Double(v.totalCapacity)
        }
        return SunburstLayout(tree: tree, focus: focus, options: options)
    }

    /// One-level layout of any directory for the legend. Uses the *current chart's* angular scale, so the list
    /// shows exactly the children big enough to be drawn where the item sits in the chart (as DaisyDisk does).
    func listing(for node: NodeRef) -> SunburstLayout {
        if node == focus { return makeLayout(focus: node, maxDepth: 1, subsetStart: subsetStart, hueRange: chartHueRange) }
        guard let range = layout.angleRange(of: node, in: tree) else {
            return makeLayout(focus: node, maxDepth: 1, hueRange: hueRange(of: node))
        }
        let spanInChart = max(1e-6, range.upperBound - range.lowerBound)
        let fullSweep = node == tree.root ? layout.sweep : 2 * .pi
        return makeLayout(focus: node, maxDepth: 1, minAngle: Self.minAngle * fullSweep / spanInChart, hueRange: hueRange(of: node))
    }

    // MARK: Colors

    /// Inside a folder, its contents are spread over most of the color wheel, so subfolders get the same variety of
    /// colors as the top level instead of shades of the folder's own hue. (Not all of it: the wheel wraps, and the
    /// first and last items would both be red.) nil at the top level: the global wheel.
    var chartHueRange: ClosedRange<Double>? {
        focus == tree.root && subsetStart == nil ? nil : 0...0.9
    }

    /// The color-wheel slice the current chart gives `node` (its wedge's hue span).
    func hueRange(of node: NodeRef) -> ClosedRange<Double> {
        let global = SunburstLayout.hueRange(tree: tree, node: node, hiddenBytes: hiddenBytes)
        guard let local = chartHueRange, node != focus, tree.ancestry(node).contains(focus) else { return global }
        // The chart spreads the focus' content (after any skipped "small items" siblings) over `local`.
        let focusRange = SunburstLayout.hueRange(tree: tree, node: focus, hiddenBytes: hiddenBytes)
        let denominator = Double(max(1, tree.size(tree.root) + hiddenBytes))
        let contentStart = focusRange.lowerBound + Double(layout.skippedBytes) / denominator
        let scale = (local.upperBound - local.lowerBound) / max(1e-12, focusRange.upperBound - contentStart)
        func map(_ x: Double) -> Double { local.lowerBound + (x - contentStart) * scale }
        return map(global.lowerBound)...max(map(global.lowerBound), map(global.upperBound))
    }

    // MARK: Display helpers

    func displayName(_ node: NodeRef) -> String { node == tree.root ? source.name : tree.name(node) }

    func size(of node: NodeRef) -> UInt64 {
        node == tree.root ? tree.size(node) + hiddenBytes : tree.size(node)
    }

    func color(of node: NodeRef) -> Color {
        guard node != tree.root else { return Theme.primaryText }
        if !tree.isDirectory(node) { return Color(dark: SunburstPalette.file.color, light: SunburstPalette.fileLight.color) }
        let range = hueRange(of: node)
        return SunburstPalette.directoryColor(hue: (range.lowerBound + range.upperBound) / 2, depth: 1)
    }

    /// Header summary: "51% full" at a volume root, otherwise the share of the parent ("74% of Macintosh HD").
    /// nil at the root of a folder scan.
    func shareSummary(of node: NodeRef) -> String? {
        if node == tree.root {
            guard isVolumeRoot, let v = source.volume else { return nil }
            return String(localized: "\(Self.percent(v.usedFraction)) full", comment: "Legend header at a disk: how full it is, e.g. 51% full")
        }
        guard let parent = tree.parent(node) else { return nil }
        let share = Self.percent(Double(size(of: node)) / Double(max(1, size(of: parent))))
        return String(localized: "\(share) of \(displayName(parent))", comment: "Share of the parent folder, e.g. 74% of Macintosh HD")
    }

    /// Second line of the chart's center disc: "of 994.6 GB used" at a volume root, the share of the parent inside.
    var centerCaption: String? {
        if subsetStart != nil { return String(localized: "in small items", comment: "Chart center caption inside the smaller-objects group") }
        if focus == tree.root {
            guard isVolumeRoot, let v = source.volume else { return nil }
            return String(localized: "of \(ByteSize.string(UInt64(max(0, v.totalCapacity)))) used", comment: "Chart center caption under the used size, e.g. of 994.6 GB used")
        }
        return shareSummary(of: focus)
    }

    /// Name shown for a chart segment.
    func title(of segment: SunburstSegment) -> String {
        switch segment.key {
        case .node(let ref): tree.name(ref)
        case .smaller: String(localized: "small items…", comment: "Group of items too small to show separately")
        case .hidden: String(localized: "hidden space…", comment: "Used space the scan couldn't attribute to files")
        }
    }

    /// Hover label detail: "377.1 GB · 74% of used" at a volume root, "12 GB · 3.2% of Users" inside a folder.
    func tooltipDetail(of segment: SunburstSegment) -> String {
        let share = Self.percent(Double(segment.size) / Double(max(1, focusSize)))
        let detail = focus == tree.root && subsetStart == nil && isVolumeRoot
            ? String(localized: "\(share) of used", comment: "Hover label: share of the disk's used space, e.g. 74% of used")
            : String(localized: "\(share) of \(displayName(focus))", comment: "Share of the parent folder, e.g. 74% of Macintosh HD")
        return "\(ByteSize.string(segment.size)) · \(detail)"
    }

    /// "74%", "8%", "3.6%", "1%", "0.4%", "<0.1%": one decimal below 5%, dropping a trailing ".0".
    static func percent(_ fraction: Double) -> String { L10n.percent(fraction) }

    /// The item the legend describes: the hovered wedge's node if any, otherwise the focus.
    var legendNode: NodeRef {
        if case .node(let node)? = chartHover { return node }
        return focus
    }

    var highlighted: SegmentKey? { chartHover ?? listHover }

    // MARK: Navigation

    func zoom(to node: NodeRef, recordHistory: Bool = true) {
        guard tree.isDirectory(node) || node == tree.root else { return }
        go(to: Place(node: node), recordHistory: recordHistory)
    }

    /// Expands a "small items…" wedge into its individual items.
    func expandSmaller(_ segment: SunburstSegment) {
        guard segment.kind == .smallerObjects, let first = segment.firstMerged, let parent = tree.parent(first) else { return }
        go(to: Place(node: parent, subsetStart: first))
    }

    private func go(to place: Place, recordHistory: Bool = true) {
        if showsHiddenInfo { showsHiddenInfo = false; if place == self.place { return } }
        guard place != self.place else { return }
        if recordHistory {
            backStack.append(self.place)
            forwardStack.removeAll()
        }
        focus = place.node
        subsetStart = place.subsetStart
        chartHover = nil
        listHover = nil
        layout = makeLayout(focus: focus, subsetStart: subsetStart, hueRange: chartHueRange)
        layoutVersion += 1
    }

    func zoomOut() {
        if showsHiddenInfo { showsHiddenInfo = false; return }
        if subsetStart != nil {
            go(to: Place(node: focus))
        } else if let parent = tree.parent(focus) {
            zoom(to: parent)
        }
    }

    /// Size shown in the center: the whole focus, or just the expanded "small items".
    var focusSize: UInt64 { subsetStart == nil ? size(of: focus) : layout.totalBytes }

    /// At the top of the scanned disk or folder (Back then leaves for the Volumes page).
    var isAtRoot: Bool { focus == tree.root && subsetStart == nil && !showsHiddenInfo }
    var canGoBack: Bool { !backStack.isEmpty || showsHiddenInfo }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func goBack() {
        if showsHiddenInfo { showsHiddenInfo = false; return }
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(place)
        go(to: previous, recordHistory: false)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(place)
        go(to: next, recordHistory: false)
    }

    // MARK: Item actions

    func url(of node: NodeRef) -> URL { URL(fileURLWithPath: tree.path(node)) }

    /// What Space previews: the item under the mouse (chart or list), else the focused folder.
    var previewTarget: NodeRef {
        if case .node(let node)? = chartHover ?? listHover { return node }
        return focus
    }

    func preview(_ node: NodeRef) { QuickLook.shared.toggle(url(of: node)) }

    func showInFinder(_ node: NodeRef) {
        NSWorkspace.shared.activateFileViewerSelecting([url(of: node)])
    }

    func openInTerminal(_ node: NodeRef) {
        let directory = tree.isDirectory(node) || node == tree.root ? url(of: node) : url(of: node).deletingLastPathComponent()
        let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
            ?? URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([directory], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Whether ⌘↓ / pinch-out has something to open under the pointer.
    var canExpandHovered: Bool {
        switch chartHover ?? listHover {
        case .node(let node)?: tree.isDirectory(node)
        case .smaller?: true
        default: false
        }
    }

    /// Expands the hovered folder or "small items…" (⌘↓).
    func expandHovered() {
        guard let key = chartHover ?? listHover else { return }
        switch key {
        case .node(let node) where tree.isDirectory(node): zoom(to: node)
        case .smaller:
            if let segment = layout.segment(for: key) ?? listing(for: legendNode).segment(for: key) { expandSmaller(segment) }
        default: break
        }
    }

    // MARK: Collector

    var collectedBytes: UInt64 { collected.reduce(0) { $0 + $1.size } }

    var isDeleting: Bool {
        switch deletionPhase {
        case .countdown, .deleting: true
        default: false
        }
    }

    /// Why `node` can't be collected, or nil if it can.
    func collectionBlocker(_ node: NodeRef) -> String? {
        let name = displayName(node)
        if node == tree.root || tree.ancestry(focus).contains(node) {
            return String(localized: "“\(name)” is the folder being shown", comment: "Notice: an item can't go in the Waste bin")
        }
        if ProtectedPaths.isProtected(tree.path(node)) {
            return String(localized: "macOS needs “\(name)” — DiskGarden won't remove it", comment: "Notice: an item can't go in the Waste bin")
        }
        return nil
    }

    func collect(_ node: NodeRef) {
        guard !isDeleting else { return }
        if let reason = collectionBlocker(node) {
            show(notice: reason)
            return
        }
        guard !tree.flags(node).contains(.removed) else { return }
        // Collecting a folder absorbs anything already collected inside it.
        let inside = collected.filter { tree.ancestry($0.id).dropLast().contains(node) }
        for item in inside { tree.restore(item.id) }
        collected.removeAll { item in inside.contains { $0.id == item.id } }

        let color = color(of: node)
        let path = tree.path(node)
        let name = displayName(node)
        tree.remove(node)
        collected.append(CollectedItem(id: node, name: name, path: path, size: tree.size(node), color: color))
        if case .finished = deletionPhase { deletionPhase = .idle }
        chartHover = nil
        listHover = nil
        relayout()
        onCollectionChanged?(collected.map(\.path))
    }

    /// Re-collects items by path after a rescan or when a saved scan is opened. Missing items are reported.
    func recollect(paths: [String]) {
        var missing = 0
        for path in paths {
            if let node = node(forPath: path), collectionBlocker(node) == nil, !tree.flags(node).contains(.removed) {
                let color = color(of: node)
                let name = displayName(node)
                tree.remove(node)
                collected.append(CollectedItem(id: node, name: name, path: path, size: tree.size(node), color: color))
            } else {
                missing += 1
            }
        }
        relayout()
        if missing > 0 {
            show(notice: String(localized: "\(missing) items in the Waste bin no longer exist", comment: "Notice after reopening a scan; plural"))
        }
    }

    /// Node for an absolute path inside this scan.
    func node(forPath path: String) -> NodeRef? {
        let root = tree.rootPath
        if path == root { return tree.root }
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return tree.lookup(components: path.dropFirst(prefix.count).split(separator: "/").map(String.init))
    }

    /// Collects a file dropped from Finder, if it's part of this scan.
    func collect(path: String) {
        let root = tree.rootPath
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix) else {
            show(notice: String(localized: "“\((path as NSString).lastPathComponent)” isn't part of this scan", comment: "Notice when a file from another disk is dropped"))
            return
        }
        let components = path.dropFirst(prefix.count).split(separator: "/").map(String.init)
        guard let node = tree.lookup(components: components) else {
            show(notice: String(localized: "“\((path as NSString).lastPathComponent)” wasn't found in the scan. Rescan recommended.", comment: "Notice when a dropped file is newer than the scan"))
            return
        }
        collect(node)
    }

    func uncollect(_ node: NodeRef) {
        guard !isDeleting, collected.contains(where: { $0.id == node }) else { return }
        tree.restore(node)
        collected.removeAll { $0.id == node }
        relayout()
        onCollectionChanged?(collected.map(\.path))
    }

    /// ⌘⌫ — collects whatever is under the mouse.
    func collectHovered() {
        if case .node(let node)? = chartHover ?? listHover { collect(node) }
    }

    func startDeletion(mode: DeletionMode) {
        guard !collected.isEmpty, !isDeleting else { return }
        deletionPhase = .countdown(startedAt: Date())
        deletionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.countdownSeconds))
            guard !Task.isCancelled else { return }
            await self?.performDeletion(mode: mode)
        }
    }

    func stopDeletion() {
        guard case .countdown = deletionPhase else { return }
        deletionTask?.cancel()
        deletionPhase = .idle
    }

    private func performDeletion(mode: DeletionMode) async {
        let items = collected
        deletionPhase = .deleting(done: 0, total: items.count)
        let paths = items.map(\.path)
        let progress = AsyncStream<Int>.makeStream()
        let outcomes = await Task.detached(priority: .userInitiated) {
            let result = Deleter.delete(paths, mode: mode) { progress.continuation.yield($0) }
            progress.continuation.finish()
            return result
        }.value
        for await _ in progress.stream {} // drain

        var freed: UInt64 = 0
        var failed: [CollectedItem] = []
        for (item, outcome) in zip(items, outcomes) {
            if outcome.succeeded {
                freed += item.size
            } else {
                var item = item
                item.error = outcome.error
                failed.append(item)
            }
        }
        collected = failed
        deletionPhase = .finished(freed: freed, failures: failed.count)
        onDeleted?(freed)
        relayout()
        if !failed.isEmpty { show(notice: String(localized: "Some files were not deleted", comment: "Notice after emptying the Waste bin")) }
    }

    func show(notice text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: Live refresh

    @ObservationIgnored private var refreshedAway: [NodeRef] = []

    /// Follows nodes that a folder refresh moved to new slots; notes the ones that vanished.
    func applyRefresh(_ change: RefreshResult) {
        guard !change.remap.isEmpty || !change.dropped.isEmpty else { return }
        func map(_ ref: NodeRef) -> NodeRef { change.remap[ref] ?? ref }
        focus = map(focus)
        subsetStart = subsetStart.map(map)
        backStack = backStack.map { Place(node: map($0.node), subsetStart: $0.subsetStart.map(map)) }
        forwardStack = forwardStack.map { Place(node: map($0.node), subsetStart: $0.subsetStart.map(map)) }
        collected = collected.map { item in
            var item = item
            let moved = map(item.id)
            if moved != item.id { item = CollectedItem(id: moved, name: item.name, path: item.path, size: item.size, color: item.color, error: item.error) }
            return item
        }
        refreshedAway.append(contentsOf: change.dropped)
        // Keep what's under the mouse: follow moved nodes, forget only ones that vanished.
        let dropped = Set(change.dropped)
        func mapKey(_ key: SegmentKey?) -> SegmentKey? {
            switch key {
            case .node(let ref)?: dropped.contains(ref) ? nil : .node(map(ref))
            case .smaller(let ref)?: dropped.contains(ref) ? nil : .smaller(map(ref))
            case .hidden?: .hidden
            case nil: nil
            }
        }
        chartHover = mapKey(chartHover)
        listHover = mapKey(listHover)
        chartMenuTarget = mapKey(chartMenuTarget)
    }

    /// After a batch of refreshes: step out of folders that no longer exist, drop vanished collected items,
    /// and re-animate the chart if the change is big enough to see.
    func finishRefresh(visibleChange: UInt64) {
        defer { refreshedAway.removeAll() }
        var moved = false
        if !tree.isAttached(focus) {
            focus = tree.nearestAttached(focus)
            subsetStart = nil
            moved = true
        }
        if let start = subsetStart, !tree.isAttached(start) { subsetStart = nil; moved = true }
        // Hovered items deeper inside a vanished folder are orphaned now.
        func stillThere(_ key: SegmentKey?) -> SegmentKey? {
            switch key {
            case .node(let ref)?, .smaller(let ref)?: tree.isAttached(ref) ? key : nil
            default: key
            }
        }
        chartHover = stillThere(chartHover)
        listHover = stillThere(listHover)
        chartMenuTarget = stillThere(chartMenuTarget)
        backStack = backStack.filter { tree.isAttached($0.node) }
        forwardStack = forwardStack.filter { tree.isAttached($0.node) }
        let before = collected.count
        collected.removeAll { !tree.isAttached($0.id) }
        if collected.count < before {
            let gone = before - collected.count
            show(notice: String(localized: "\(gone) items in the Waste bin were removed outside DiskGarden", comment: "Notice during live updates; plural"))
            onCollectionChanged?(collected.map(\.path))
        }
        let threshold = max(1_000_000, focusSize / 2000)
        if moved || visibleChange >= threshold { relayout() }
    }

    /// Re-lays out the chart at the same focus (animated) after the tree's sizes changed.
    func relayout() {
        layout = makeLayout(focus: focus, subsetStart: subsetStart, hueRange: chartHueRange)
        layoutVersion += 1
    }

    /// Path from the root to the focus, for the path bar.
    var breadcrumb: [NodeRef] { tree.ancestry(focus) }
}
