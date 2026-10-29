import Foundation
import ScanEngine

/// Keeps one scanned source up to date: FSEvents → batched folder re-listings → in-place tree edits.
@MainActor
final class LiveUpdater {
    private weak var model: AppModel?
    private weak var source: Source?
    private var watcher: FileWatcher?
    private var pending: [String: Bool] = [:] // path → recursive
    private var flushTask: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?
    private var isApplying = false
    /// FSEvents reports canonical paths (e.g. /private/tmp for /tmp); map them back onto the tree's root path.
    private let root: String
    private let canonicalRoot: String
    private let trace = ProcessInfo.processInfo.environment["DG_TRACE"] != nil

    static let batchDelay: Duration = .seconds(2)
    static let maxFoldersPerBatch = 300
    /// FSEvents asks for a full subtree recheck when it drops events (often for "/"). Past this many items that
    /// would mean rescanning most of the disk, so such folders only get their own listing refreshed.
    static let maxRecursiveItems = 200_000
    /// A folder is re-listed at most this often, and wholly rescanned (FSEvents "recheck subtree") less often still:
    /// busy folders (browser caches, logs, temp files) would otherwise append fresh listings every couple of seconds.
    static let minFolderInterval: Duration = .seconds(15)
    static let minRecursiveInterval: Duration = .seconds(120)
    /// Replaced listings stay in memory (see FileTree.garbageNodeCount). Past this many, live updates pause for this
    /// source rather than keep growing; a rescan starts fresh.
    static let maxGarbageNodes = 20_000_000
    private var lastRefresh: [String: ContinuousClock.Instant] = [:]

    init(model: AppModel, source: Source) {
        self.model = model
        self.source = source
        root = source.id
        // realpath(3), not URL.resolvingSymlinksInPath (which strips /private again).
        canonicalRoot = realpath(source.id, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? source.id
        let watcher = FileWatcher(path: source.id) { [weak self] changes in
            Task { @MainActor in self?.enqueue(changes) }
        }
        watcher.start()
        self.watcher = watcher
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        flushTask?.cancel()
        persistTask?.cancel()
    }

    private func enqueue(_ changes: [FileWatcher.Change]) {
        for change in changes {
            var path = change.path
            if canonicalRoot != root, path == canonicalRoot || path.hasPrefix(canonicalRoot + "/") {
                path = root + path.dropFirst(canonicalRoot.count)
            }
            pending[path] = (pending[path] ?? false) || change.recursive
        }
        if trace && !changes.isEmpty { NSLog("DG live: %d changes queued (%@…)", changes.count, changes[0].path) }
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.batchDelay)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    private func flush() async {
        flushTask = nil
        guard !isApplying, let model, let source, let tree = source.tree, !source.isScanning, source.adminActivity == nil else {
            if trace { NSLog("DG live: flush postponed (applying %d, source %d, tree %d)", isApplying ? 1 : 0, source == nil ? 0 : 1, source?.tree == nil ? 0 : 1) }
            if !pending.isEmpty { enqueue([]) } // try again later
            return
        }
        let report = model.existingReport(for: source.id)
        if report?.isDeleting == true { enqueue([]); return } // let the deletion finish first

        // Map changed paths to the nearest folder we know, skipping places we can't or shouldn't re-list.
        var jobs: [(path: String, recursive: Bool, existing: Set<String>)] = []
        var seen = Set<String>()
        var deferred: [String: Bool] = [:]
        let now = ContinuousClock.now
        for (path, recursive) in pending {
            guard let node = nearestFolder(for: path, in: tree) else { continue }
            let flags = tree.flags(node)
            if flags.contains(.mountPoint) || flags.contains(.otherVolume) || flags.contains(.removed) { continue }
            let folderPath = tree.path(node)
            guard seen.insert(folderPath).inserted else { continue }
            let deep = recursive && tree.descendantCount(node) <= Self.maxRecursiveItems
            // Refreshed recently: try again once the interval has passed.
            // Bigger folders wait longer (each refresh retires a copy of the whole listing): ~15 s per 2,000 items.
            let items = deep ? tree.descendantCount(node) : tree.children(node).count
            let base = deep ? Self.minRecursiveInterval : Self.minFolderInterval
            let interval = min(base * max(1, items / 2_000), .seconds(900))
            if let last = lastRefresh[folderPath], now - last < interval {
                deferred[path] = (deferred[path] ?? false) || recursive
                seen.remove(folderPath)
                continue
            }
            lastRefresh[folderPath] = now
            jobs.append((folderPath, deep, deep ? [] : Set(tree.children(node).map(tree.name))))
            if jobs.count >= Self.maxFoldersPerBatch { break }
        }
        if trace { NSLog("DG live: %d pending paths → %d folders (root %@, first %@)", pending.count, jobs.count, tree.rootPath, pending.keys.first ?? "-") }
        pending = deferred
        if lastRefresh.count > 2_000 { lastRefresh = lastRefresh.filter { now - $0.value < .seconds(900) } }
        if !deferred.isEmpty { enqueue([]) } // check again on the next batch
        guard !jobs.isEmpty else { return }

        isApplying = true
        defer { isApplying = false }
        // Sibling APFS volumes mounted inside rescanned folders keep their real sizes (e.g. /System/Volumes/VM).
        let fixedMounts = source.accounting.fixedSizeMountPoints
        let startupDisk = tree.rootPath == "/" // the Data volume's firmlinked entries are counted at /
        // Background: one directory read per folder, plus full scans of folders that are new (or wholly changed).
        let results = await Task.detached(priority: .utility) {
            jobs.compactMap { job -> (path: String, recursive: Bool, entries: [DirectoryEntry], subtrees: [String: FileTree])? in
                guard let entries = DirectoryReader.list(job.path, startupDisk: startupDisk) else { return nil }
                var subtrees: [String: FileTree] = [:]
                for entry in entries where entry.isDirectory && !entry.isMountPoint && !job.existing.contains(entry.name) {
                    let childPath = job.path == "/" ? "/" + entry.name : job.path + "/" + entry.name
                    subtrees[entry.name] = try? DiskScanner(path: childPath, options: ScanOptions(
                        workerCount: 4, fixedSizeMountPoints: fixedMounts, startupDisk: startupDisk)).run()
                }
                return (job.path, job.recursive, entries, subtrees)
            }
        }.value

        // Main thread: apply in place, never while a saved-scan write is walking the tree.
        // The tree may have been replaced meanwhile (rescan) — then drop the results.
        await model.finishSaving(source.id)
        guard source.tree === tree else { return }
        var visibleChange: Int64 = 0
        for result in results {
            guard let node = report?.node(forPath: result.path) ?? lookup(result.path, in: tree),
                  tree.isDirectory(node) || node == tree.root else { continue }
            let change = tree.applyListing(result.entries, to: node, newSubtrees: result.subtrees,
                                           replaceDirectories: result.recursive)
            report?.applyRefresh(change)
            if let report, tree.ancestry(node).contains(report.focus) || tree.ancestry(report.focus).contains(node) {
                visibleChange += abs(change.sizeDelta)
            }
        }
        if trace { NSLog("DG live: refreshed %d folders, visible change %lld bytes, %d replaced nodes", results.count, visibleChange, tree.garbageNodeCount) }
        if tree.garbageNodeCount > Self.maxGarbageNodes {
            NSLog("DG live: pausing live updates for %@ (%d replaced nodes in memory); a rescan resumes them", source.id, tree.garbageNodeCount)
            CrashReporter.log("Live updates paused: \(tree.garbageNodeCount) replaced nodes")
            stop()
            report?.show(notice: String(localized: "Live updates paused to save memory. Rescan to resume them.",
                                        comment: "Notice when a long-running scan stops following file changes"))
        }
        model.reloadVolumes() // free/used space changed too
        if let report {
            report.finishRefresh(visibleChange: UInt64(visibleChange))
        }
        schedulePersist()
    }

    private func nearestFolder(for path: String, in tree: FileTree) -> NodeRef? {
        var current = path
        let root = tree.rootPath
        while current.count >= root.count {
            if let node = lookup(current, in: tree), tree.isDirectory(node) || node == tree.root { return node }
            if current == root || current == "/" { return nil }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    private func lookup(_ path: String, in tree: FileTree) -> NodeRef? {
        let root = tree.rootPath
        if path == root { return tree.root }
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return tree.lookup(components: path.dropFirst(prefix.count).split(separator: "/").map(String.init))
    }

    /// Saved scans are refreshed at most every 30 s while files keep changing.
    private func schedulePersist() {
        guard persistTask == nil else { return }
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, let model = self.model, let source = self.source else { return }
            self.persistTask = nil
            model.persist(source)
        }
    }
}
