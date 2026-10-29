import Darwin
import Foundation
import Synchronization
import Testing
@testable import ScanEngine

/// Builds a throwaway directory tree and removes it afterwards.
final class Fixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dgtest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func file(_ path: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Random bytes so APFS can't compress or dedupe them.
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) }
        try data.write(to: url)
        return url
    }

    func dir(_ path: String) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
    }

    /// Allocated size as `du` sees it.
    static func allocated(_ url: URL) -> UInt64 {
        var st = stat()
        return lstat(url.path, &st) == 0 ? UInt64(st.st_blocks) * 512 : 0
    }
}

func scan(_ fixture: Fixture, workers: Int = 4) throws -> FileTree {
    try DiskScanner(path: fixture.root.path, options: ScanOptions(workerCount: workers)).run()
}

@Suite struct ScannerTests {
    @Test func sizesMatchAllocatedBlocks() throws {
        let f = try Fixture()
        let a = try f.file("a.bin", bytes: 10_000)
        let b = try f.file("sub/b.bin", bytes: 200_000)
        let c = try f.file("sub/deeper/c.bin", bytes: 1)
        let tree = try scan(f)

        let expected = Fixture.allocated(a) + Fixture.allocated(b) + Fixture.allocated(c)
        #expect(tree.size(tree.root) == expected)
        let sub = try #require(tree.lookup(components: ["sub"]))
        #expect(tree.size(sub) == Fixture.allocated(b) + Fixture.allocated(c))
        #expect(tree.descendantCount(tree.root) == 5) // a.bin, sub, b.bin, deeper, c.bin
    }

    @Test func childrenAreSortedBySizeDescending() throws {
        let f = try Fixture()
        for (i, size) in [5_000, 900_000, 40_000, 300_000, 70_000].enumerated() {
            try f.file("f\(i).bin", bytes: size)
        }
        try f.file("big/x.bin", bytes: 2_000_000)
        let tree = try scan(f)
        let sizes = tree.children(tree.root).map(tree.size)
        #expect(sizes == sizes.sorted(by: >))
        #expect(tree.name(tree.children(tree.root)[0]) == "big")
    }

    @Test func parentPointersSurviveSorting() throws {
        let f = try Fixture()
        for i in 0..<20 {
            try f.file("d\(i)/inner/file.bin", bytes: (i + 1) * 5_000)
        }
        let tree = try scan(f)
        var stack = [tree.root]
        var visited = 0
        while let node = stack.popLast() {
            for child in tree.children(node) {
                #expect(tree.parent(child) == node)
                stack.append(child)
                visited += 1
            }
        }
        #expect(visited == tree.descendantCount(tree.root))
        let deep = try #require(tree.lookup(components: ["d19", "inner", "file.bin"]))
        #expect(tree.path(deep) == f.root.path + "/d19/inner/file.bin")
    }

    @Test func hardLinksAreCountedOnce() throws {
        let f = try Fixture()
        let original = try f.file("original.bin", bytes: 500_000)
        try f.dir("links")
        for i in 0..<3 {
            #expect(link(original.path, f.root.appendingPathComponent("links/l\(i)").path) == 0)
        }
        let tree = try scan(f)
        #expect(tree.size(tree.root) == Fixture.allocated(original))
        let links = try #require(tree.lookup(components: ["links"]))
        let duplicates = tree.children(links).filter { tree.flags($0).contains(.hardLinkDuplicate) }
            + tree.children(tree.root).filter { tree.flags($0).contains(.hardLinkDuplicate) }
        #expect(duplicates.count == 3)
    }

    @Test func symlinksAreNotFollowed() throws {
        let f = try Fixture()
        try f.file("target/big.bin", bytes: 1_000_000)
        try FileManager.default.createSymbolicLink(
            at: f.root.appendingPathComponent("alias"), withDestinationURL: f.root.appendingPathComponent("target"))
        let tree = try scan(f)
        let alias = try #require(tree.lookup(components: ["alias"]))
        #expect(tree.flags(alias).contains(.symlink))
        #expect(!tree.isDirectory(alias))
        #expect(tree.size(alias) < 100_000)
    }

    @Test func unreadableDirectoryIsMarkedRestricted() throws {
        let f = try Fixture()
        try f.file("locked/secret.bin", bytes: 10_000)
        let locked = f.root.appendingPathComponent("locked")
        chmod(locked.path, 0o000)
        defer { chmod(locked.path, 0o755) }
        let tree = try scan(f)
        let node = try #require(tree.lookup(components: ["locked"]))
        #expect(tree.flags(node).contains(.restricted))
        #expect(tree.children(node).isEmpty)
    }

    @Test func unicodeNamesRoundTrip() throws {
        let f = try Fixture()
        let names = ["café.txt", "日本語", "emoji 🌼.bin", "space name"]
        for name in names { try f.file(name, bytes: 100) }
        let tree = try scan(f)
        let scanned = Set(tree.children(tree.root).map(tree.name))
        // APFS preserves the normalization it was given; compare canonically.
        #expect(Set(scanned.map { $0.precomposedStringWithCanonicalMapping })
            == Set(names.map { $0.precomposedStringWithCanonicalMapping }))
    }

    @Test func manyEntriesAcrossWorkersAndPages() throws {
        let f = try Fixture()
        // > one node page (8192) spread over many directories.
        for d in 0..<40 {
            try f.dir("d\(d)")
            for i in 0..<250 {
                FileManager.default.createFile(atPath: f.root.appendingPathComponent("d\(d)/f\(i)").path, contents: Data([1]))
            }
        }
        for workers in [1, 3, 12] {
            let tree = try scan(f, workers: workers)
            #expect(tree.descendantCount(tree.root) == 40 + 40 * 250)
            #expect(tree.children(tree.root).count == 40)
        }
    }

    @Test func removeAndRestoreAdjustAncestors() throws {
        let f = try Fixture()
        try f.file("a/b/c.bin", bytes: 300_000)
        try f.file("a/other.bin", bytes: 50_000)
        let tree = try scan(f)
        let a = try #require(tree.lookup(components: ["a"]))
        let b = try #require(tree.lookup(components: ["a", "b"]))
        let before = (root: tree.size(tree.root), a: tree.size(a))
        let removed = tree.remove(b)
        #expect(removed > 0)
        #expect(tree.size(tree.root) == before.root - removed)
        #expect(tree.size(a) == before.a - removed)
        #expect(tree.flags(b).contains(.removed))
        tree.restore(b)
        #expect(tree.size(tree.root) == before.root)
        #expect(tree.size(a) == before.a)
    }

    @Test func missingRootThrows() {
        #expect(throws: ScanError.self) {
            try DiskScanner(path: "/definitely/not/here-\(UUID())").run()
        }
    }

    @Test func cancellationThrows() throws {
        let scanner = DiskScanner(path: NSHomeDirectory())
        scanner.cancel()
        #expect(throws: ScanError.cancelled) { try scanner.run() }
    }
}

@Suite struct ByteSizeTests {
    @Test(arguments: [
        (UInt64(0), "0", "bytes"),
        (UInt64(999), "999", "bytes"),
        (UInt64(16_400), "16.4", "KB"),
        (UInt64(209_800_000), "209.8", "MB"),
        (UInt64(7_000_000_000), "7", "GB"),
        (UInt64(505_200_000_000), "505.2", "GB"),
        (UInt64(999_960), "1", "MB"),
    ])
    func formats(bytes: UInt64, number: String, unit: String) {
        #expect(ByteSize.parts(bytes) == ByteSize.Parts(number: number, unit: unit))
    }
}

@Suite struct VolumeCatalogTests {
    @Test func startupDiskIsListedFirst() throws {
        let volumes = VolumeCatalog.mountedVolumes()
        let first = try #require(volumes.first)
        #expect(first.isRoot)
        #expect(first.path == "/")
        #expect(first.kind == .startupDisk)
        #expect(first.totalCapacity > first.usedBytes)
        #expect(first.descriptor.hasSuffix("startup disk"))
        print(volumes.map { "\($0.name) — \(ByteSize.string(UInt64($0.totalCapacity))) \($0.descriptor), free \(ByteSize.string(UInt64($0.freeBytes))), ssd \(String(describing: $0.isSolidState)), workers \($0.recommendedWorkerCount)" })
        #expect(first.isSolidState == true) // internal Mac storage is solid state
    }
}

@Suite struct SunburstLayoutTests {
    /// big (60%), mid (30%), several tiny files, one small folder
    func fixtureTree() throws -> (Fixture, FileTree) {
        let f = try Fixture()
        try f.file("big/a.bin", bytes: 600_000)
        try f.file("big/b.bin", bytes: 200_000)
        try f.file("mid.bin", bytes: 300_000)
        for i in 0..<5 { try f.file("tiny\(i).bin", bytes: 4096) }
        return (f, try scan(f))
    }

    @Test func childrenFillTheSweepInOrder() throws {
        let (_, tree) = try fixtureTree()
        let layout = SunburstLayout(tree: tree, focus: tree.root, options: .init(minAngle: 0.05))
        let ring = layout.topLevel
        #expect(ring.first?.node.map(tree.name) == "big")
        #expect(abs(ring.first!.start) < 1e-9)
        #expect(abs(ring.last!.end - 2 * .pi) < 1e-9)
        for (a, b) in zip(ring, ring.dropFirst()) { #expect(abs(a.end - b.start) < 1e-9) }
    }

    @Test func tinySiblingsMergeIntoSmallerObjects() throws {
        let (_, tree) = try fixtureTree()
        let layout = SunburstLayout(tree: tree, focus: tree.root, options: .init(minAngle: 0.05))
        let smaller = try #require(layout.segment(for: .smaller(tree.root)))
        #expect(smaller.kind == .smallerObjects)
        #expect(smaller.mergedCount == 5)
        #expect(layout.topLevel.count == 3) // big, mid, smaller objects
    }

    @Test func aSingleTinyItemIsNotMerged() throws {
        let f = try Fixture()
        try f.file("huge.bin", bytes: 2_000_000)
        try f.file(".DS_Store", bytes: 100)
        let tree = try scan(f)
        let layout = SunburstLayout(tree: tree, focus: tree.root, options: .init(minAngle: 0.05))
        #expect(layout.topLevel.count == 2)
        #expect(layout.segment(for: .smaller(tree.root)) == nil)
    }

    @Test func childrenNestWithinParents() throws {
        let (_, tree) = try fixtureTree()
        let layout = SunburstLayout(tree: tree, focus: tree.root, options: .init(minAngle: 0.001))
        let big = try #require(tree.lookup(components: ["big"]))
        let parent = try #require(layout.segment(for: .node(big)))
        let kids = layout.rings[1].filter { $0.start >= parent.start - 1e-9 && $0.end <= parent.end + 1e-9 }
        #expect(kids.count == 2)
        #expect(abs(kids.last!.end - parent.end) < 1e-9)
        #expect(kids.allSatisfy { $0.depth == 2 })
    }

    @Test func rootSweepAndHiddenSpace() throws {
        let (_, tree) = try fixtureTree()
        let rootSize = tree.size(tree.root)
        let layout = SunburstLayout(tree: tree, focus: tree.root,
                                    options: .init(minAngle: 0.01, hiddenBytes: rootSize, rootSweepFraction: 0.5))
        #expect(abs(layout.sweep - .pi) < 1e-9)
        let hidden = try #require(layout.segment(for: .hidden))
        #expect(abs(hidden.start - .pi / 2) < 1e-6)
        #expect(abs(hidden.end - .pi) < 1e-9)
        // Hidden bytes don't leak into sub-folder layouts.
        let big = try #require(tree.lookup(components: ["big"]))
        let zoomed = SunburstLayout(tree: tree, focus: big, options: .init(hiddenBytes: rootSize, rootSweepFraction: 0.5))
        #expect(zoomed.sweep == 2 * .pi)
        #expect(zoomed.segment(for: .hidden) == nil)
    }

    @Test func huesAreGlobalAcrossZoomLevels() throws {
        let (_, tree) = try fixtureTree()
        let big = try #require(tree.lookup(components: ["big"]))
        let a = try #require(tree.lookup(components: ["big", "a.bin"]))
        let rootLayout = SunburstLayout(tree: tree, focus: tree.root, options: .init(minAngle: 0.001))
        let zoomed = SunburstLayout(tree: tree, focus: big, options: .init(minAngle: 0.001))
        let h1 = try #require(rootLayout.segment(for: .node(a))).hue
        let h2 = try #require(zoomed.segment(for: .node(a))).hue
        #expect(abs(h1 - h2) < 1e-9)
    }

    @Test func hitTestFindsSegmentsByRingAndAngle() throws {
        let (_, tree) = try fixtureTree()
        let layout = SunburstLayout(tree: tree, focus: tree.root, options: .init(minAngle: 0.05))
        let first = layout.topLevel[0]
        #expect(layout.hitTest(depth: 1, angle: (first.start + first.end) / 2)?.key == first.key)
        let second = layout.topLevel[1]
        #expect(layout.hitTest(depth: 1, angle: second.start + 1e-6)?.key == second.key)
        #expect(layout.hitTest(depth: 1, angle: -0.1) == nil)
        #expect(layout.hitTest(depth: 7, angle: 1) == nil)
    }

    @Test func angleRangeMatchesDrawnSegments() throws {
        let (_, tree) = try fixtureTree()
        let layout = SunburstLayout(tree: tree, focus: tree.root, options: .init(minAngle: 0.001))
        let b = try #require(tree.lookup(components: ["big", "b.bin"]))
        let drawn = try #require(layout.segment(for: .node(b)))
        let computed = try #require(layout.angleRange(of: b, in: tree))
        #expect(abs(computed.lowerBound - drawn.start) < 1e-9)
        #expect(abs(computed.upperBound - drawn.end) < 1e-9)
        #expect(layout.relativeDepth(of: b, in: tree) == 2)
    }

    @Test func removedItemsDisappear() throws {
        let (_, tree) = try fixtureTree()
        let mid = try #require(tree.lookup(components: ["mid.bin"]))
        tree.remove(mid)
        let layout = SunburstLayout(tree: tree, focus: tree.root, options: .init(minAngle: 0.05))
        #expect(layout.segment(for: .node(mid)) == nil)
        #expect(abs(layout.topLevel.last!.end - 2 * .pi) < 1e-9)
    }
}

@Suite struct DeleterTests {
    @Test func permanentDeletionRemovesTrees() throws {
        let f = try Fixture()
        try f.file("victim/a/b/c.bin", bytes: 10_000)
        try f.file("victim/d.bin", bytes: 10_000)
        try f.file("keep.bin", bytes: 10)
        let victim = f.root.appendingPathComponent("victim").path
        let outcomes = Deleter.delete([victim], mode: .permanent)
        #expect(outcomes == [DeletionOutcome(path: victim, error: nil)])
        #expect(!FileManager.default.fileExists(atPath: victim))
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("keep.bin").path))
    }

    @Test func missingPathCountsAsSuccess() {
        let path = "/tmp/dg-definitely-missing-\(UUID())"
        let allGood = Deleter.delete([path], mode: .permanent).allSatisfy { $0.succeeded }
        #expect(allGood)
    }

    @Test func lockedFilesAreUnlockedAndRemoved() throws {
        let f = try Fixture()
        let locked = try f.file("locked/stuck.bin", bytes: 100)
        #expect(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
        let dir = f.root.appendingPathComponent("locked").path
        let outcomes = Deleter.delete([dir], mode: .permanent)
        let allGood = outcomes.allSatisfy { $0.succeeded }
        #expect(allGood, "\(outcomes)")
        #expect(!FileManager.default.fileExists(atPath: dir))
    }

    @Test func reportsProgressPerItem() throws {
        let f = try Fixture()
        let paths = try (0..<3).map { try f.file("p\($0).bin", bytes: 10).path }
        let counter = Mutex<[Int]>([])
        _ = Deleter.delete(paths, mode: .permanent) { n in counter.withLock { $0.append(n) } }
        let calls = counter.withLock { $0 }
        #expect(calls == [1, 2, 3])
    }
}

@Suite struct ContainerTests {
    @Test func startupContainerSplitsIntoFixedAndOther() {
        let volumes = APFSContainer.volumes(sharingContainerWith: "/")
        guard !volumes.isEmpty else { return } // non-APFS CI machine
        #expect(volumes.contains { $0.roles.contains("Data") })
        let accounting = ContainerAccounting(root: "/", volumes: volumes)
        // Data and System are scanned directly, never double counted.
        #expect(!accounting.fixedSizeMountPoints.keys.contains("/System/Volumes/Data"))
        #expect(accounting.otherVolumes.allSatisfy { !$0.roles.contains("Data") && !$0.roles.contains("System") })
        print("fixed:", accounting.fixedSizeMountPoints, "other:", accounting.otherVolumes.map { "\($0.name) \($0.bytesInUse)" })
    }
}

@Suite struct ArchiveTests {
    func archiveURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("dg-\(UUID()).bin") }

    @Test func roundTripsAFullTree() throws {
        let f = try Fixture()
        try f.file("a/b/c.bin", bytes: 50_000)
        try f.file("a/d.bin", bytes: 10_000)
        try f.file("e 🌼.bin", bytes: 7_000)
        let original = try scan(f)
        let url = archiveURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try TreeArchive.write([(original.rootPath, original)], to: url)

        let entries = try TreeArchive.read(try Data(contentsOf: url))
        #expect(entries.count == 1)
        let copy = try FileTree.fromArchive(entries[0])
        #expect(copy.size(copy.root) == original.size(original.root))
        #expect(copy.descendantCount(copy.root) == original.descendantCount(original.root))
        let c = try #require(copy.lookup(components: ["a", "b", "c.bin"]))
        #expect(copy.path(c) == f.root.path + "/a/b/c.bin")
        #expect(copy.lookup(components: ["e 🌼.bin"]) != nil)
        // Parent links and ordering survive.
        var stack = [copy.root]
        while let n = stack.popLast() {
            let kids = copy.children(n)
            #expect(kids.map(copy.size) == kids.map(copy.size).sorted(by: >))
            for k in kids { #expect(copy.parent(k) == n); stack.append(k) }
        }
    }

    @Test func graftFillsARestrictedFolderAndUpdatesAncestors() throws {
        let f = try Fixture()
        try f.file("outer/locked/inner/x.bin", bytes: 300_000)
        try f.file("outer/locked/y.bin", bytes: 20_000)
        try f.file("outer/free.bin", bytes: 5_000)
        let locked = f.root.appendingPathComponent("outer/locked")
        chmod(locked.path, 0o000)
        let restricted = try scan(f)
        chmod(locked.path, 0o755)

        let node = try #require(restricted.lookup(components: ["outer", "locked"]))
        #expect(restricted.flags(node).contains(.restricted))
        #expect(restricted.restrictedNodes() == [node])
        let before = restricted.size(restricted.root)

        // "Helper" scan of just that folder (now readable), archived and grafted back.
        let sub = try DiskScanner(path: locked.path, options: ScanOptions(workerCount: 2)).run()
        let url = archiveURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try TreeArchive.write([(locked.path, sub)], to: url)
        let entry = try #require(TreeArchive.read(try Data(contentsOf: url)).first)
        try restricted.graft(entry, at: node)

        #expect(!restricted.flags(node).contains(.restricted))
        #expect(restricted.size(node) == sub.size(sub.root))
        #expect(restricted.size(restricted.root) == before + sub.size(sub.root))
        let x = try #require(restricted.lookup(components: ["outer", "locked", "inner", "x.bin"]))
        #expect(restricted.path(x) == locked.path + "/inner/x.bin")
        #expect(restricted.restrictedNodes().isEmpty)
        // The grafted subtree lays out like any other.
        let layout = SunburstLayout(tree: restricted, focus: restricted.root, options: .init(minAngle: 0.001))
        #expect(layout.segment(for: .node(x)) != nil)
    }

    @Test func rejectsGarbage() {
        #expect(throws: TreeArchive.ArchiveError.badMagic) { try TreeArchive.read(Data("nope".utf8)) }
        #expect(throws: TreeArchive.ArchiveError.truncated) { try TreeArchive.read(Data("DGT1".utf8) + Data([1, 0, 0, 0, 9])) }
    }
}

@Suite struct CSVTests {
    @Test func writesEveryItemWithQuotedPaths() throws {
        let f = try Fixture()
        try f.file("dir/a \"quoted\", name.bin", bytes: 20_000)
        try f.file("b.bin", bytes: 5_000)
        let tree = try scan(f)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dg-\(UUID()).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try CSVWriter.write(tree: tree, from: tree.root, to: url)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.first == "Path,Size (bytes),Size,Items,Kind")
        #expect(lines.count == 1 + 4) // root, dir, a, b
        #expect(lines[1].hasPrefix("\"\(f.root.path)\",\(tree.size(tree.root)),"))
        #expect(lines.contains { $0.contains("a \"\"quoted\"\", name.bin\"") && $0.hasSuffix(",File") })
        #expect(lines.contains { $0.hasSuffix("/dir\",\(tree.size(tree.lookup(components: ["dir"])!)),\"\(ByteSize.string(tree.size(tree.lookup(components: ["dir"])!)))\",1,Folder") })
    }
}

@Suite struct SmallerObjectsTests {
    @Test func expandingSmallerObjectsLaysOutOnlyTheMergedItems() throws {
        let f = try Fixture()
        try f.file("huge.bin", bytes: 3_000_000)
        for i in 0..<6 { try f.file("small\(i).bin", bytes: 8_000 + i * 1_000) }
        let tree = try scan(f)
        let full = SunburstLayout(tree: tree, focus: tree.root, options: .init(minAngle: 0.1))
        let smaller = try #require(full.segment(for: .smaller(tree.root)))
        #expect(smaller.mergedCount == 6)
        let first = try #require(smaller.firstMerged)

        let expanded = SunburstLayout(tree: tree, focus: tree.root, options: .init(minAngle: 0.01, subsetStart: first))
        #expect(expanded.subsetStart == first)
        #expect(expanded.topLevel.count == 6)
        #expect(expanded.totalBytes == smaller.size)
        #expect(abs(expanded.topLevel.last!.end - 2 * .pi) < 1e-9)
        // Hues continue the global wheel: the expanded items keep roughly the smaller-objects hue slice.
        let hues = expanded.topLevel.map(\.hue)
        #expect(hues.allSatisfy { $0 >= smaller.hue - 0.05 && $0 <= smaller.hue + 0.05 })
        // Items outside the subset have no angle range; items inside do.
        let huge = try #require(tree.lookup(components: ["huge.bin"]))
        #expect(expanded.angleRange(of: huge, in: tree) == nil)
        let small = try #require(expanded.topLevel.first?.node)
        let range = try #require(expanded.angleRange(of: small, in: tree))
        #expect(abs(range.lowerBound) < 1e-9)
    }
}

@Suite struct ScanStoreTests {
    @Test func savesAndReloadsCompressedScansWithoutCollectedItems() throws {
        let f = try Fixture()
        try f.file("keep/a.bin", bytes: 40_000)
        try f.file("gone/b.bin", bytes: 30_000)
        try f.file("c.bin", bytes: 1_000)
        let tree = try scan(f)
        let gone = try #require(tree.lookup(components: ["gone"]))
        tree.remove(gone) // e.g. collected

        let store = ScanStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("dg-store-\(UUID())"))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let info = SavedScanInfo(rootPath: tree.rootPath, totalBytes: tree.size(tree.root),
                                 nodeCount: UInt64(tree.descendantCount(tree.root) + 1),
                                 volumeUUID: ScanStore.volumeUUID(for: tree.rootPath), collectedPaths: [tree.path(gone)])
        try store.save(tree, info: info)

        let loadedInfo = try #require(store.info(for: tree.rootPath))
        #expect(loadedInfo == info)
        let loaded = try store.loadTree(for: tree.rootPath)
        #expect(loaded.size(loaded.root) == tree.size(tree.root))
        #expect(loaded.lookup(components: ["gone"]) == nil)
        #expect(loaded.lookup(components: ["keep", "a.bin"]) != nil)
        #expect(loaded.descendantCount(loaded.root) == tree.descendantCount(tree.root))

        store.delete(tree.rootPath)
        #expect(store.info(for: tree.rootPath) == nil)
    }

    @Test func ignoresScansOfAnotherVolume() throws {
        let f = try Fixture()
        try f.file("x.bin", bytes: 100)
        let tree = try scan(f)
        let store = ScanStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("dg-store-\(UUID())"))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.save(tree, info: SavedScanInfo(rootPath: tree.rootPath, totalBytes: 1, nodeCount: 2, volumeUUID: "NOT-THIS-VOLUME"))
        #expect(store.info(for: tree.rootPath) == nil)
    }

    @Test func nearlyFullDiskKeepsTheScanInMemoryOnly() throws {
        let f = try Fixture()
        try f.file("x.bin", bytes: 100)
        let tree = try scan(f)
        var store = ScanStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("dg-store-\(UUID())"))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let info = SavedScanInfo(rootPath: tree.rootPath, totalBytes: 1, nodeCount: 2, volumeUUID: nil)
        try store.save(tree, info: info)
        #expect(store.info(for: tree.rootPath) != nil)

        store.reservedFreeSpace = .max / 2 // more than any disk has free
        #expect(throws: CocoaError.self) { try store.save(tree, info: info) }
        #expect(store.info(for: tree.rootPath) == nil) // the older copy is gone too
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        #expect(leftovers.isEmpty)
    }
}

@Suite struct LiveRefreshTests {
    /// Refreshes every folder whose listing changed, the way the app does for FSEvents batches.
    func refresh(_ tree: FileTree, folders: [[String]]) throws {
        for components in folders {
            let node = try #require(tree.lookup(components: components))
            let path = tree.path(node)
            let entries = try #require(DirectoryReader.list(path))
            // Scan folders that appeared since, as the app does in the background before applying.
            let existing = Set(tree.children(node).map(tree.name))
            var subtrees: [String: FileTree] = [:]
            for entry in entries where entry.isDirectory && !existing.contains(entry.name) {
                subtrees[entry.name] = try DiskScanner(path: path + "/" + entry.name, options: ScanOptions(workerCount: 2)).run()
            }
            let result = tree.applyListing(entries, to: node, newSubtrees: subtrees)
            #expect(result.newDirectories.isEmpty)
        }
    }

    @Test func refreshedFoldersMatchAFreshScan() throws {
        let f = try Fixture()
        try f.file("a/keep.bin", bytes: 40_000)
        try f.file("a/sub/deep.bin", bytes: 70_000)
        try f.file("a/doomed.bin", bytes: 30_000)
        try f.file("b/grow.bin", bytes: 1_000)
        let tree = try scan(f)
        let deep = try #require(tree.lookup(components: ["a", "sub", "deep.bin"]))

        // Changes on disk after the scan.
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("a/doomed.bin"))
        try f.file("a/new.bin", bytes: 12_000)
        try f.file("a/newdir/x/y.bin", bytes: 90_000)
        try f.file("b/grow.bin", bytes: 500_000)

        try refresh(tree, folders: [["a"], ["b"]])
        let fresh = try scan(f)
        #expect(tree.size(tree.root) == fresh.size(fresh.root))
        #expect(tree.descendantCount(tree.root) == fresh.descendantCount(fresh.root))
        #expect(tree.lookup(components: ["a", "doomed.bin"]) == nil)
        #expect(tree.lookup(components: ["a", "newdir", "x", "y.bin"]) != nil)
        // The untouched deep file kept its identity; its parent chain was re-pointed after the move.
        #expect(tree.isAttached(deep))
        #expect(tree.path(deep) == f.root.path + "/a/sub/deep.bin")
        // Ancestors whose sizes changed are shown in the new order (b grew past a).
        let top = SunburstLayout(tree: tree, focus: tree.root, options: .init(minAngle: 0.0001)).topLevel
        #expect(top.map(\.size) == top.map(\.size).sorted(by: >))
        #expect(top.first?.node.map(tree.name) == "b")
    }

    @Test func collectedItemsStayCollectedAndGoneOnesAreReported() throws {
        let f = try Fixture()
        try f.file("d/kept.bin", bytes: 50_000)
        try f.file("d/vanishes.bin", bytes: 20_000)
        let tree = try scan(f)
        let kept = try #require(tree.lookup(components: ["d", "kept.bin"]))
        let vanishes = try #require(tree.lookup(components: ["d", "vanishes.bin"]))
        tree.remove(kept)
        tree.remove(vanishes)
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("d/vanishes.bin"))

        let d = try #require(tree.lookup(components: ["d"]))
        let result = tree.applyListing(try #require(DirectoryReader.list(tree.path(d))), to: d)
        let newKept = try #require(result.remap[kept])
        #expect(tree.flags(newKept).contains(.removed))
        #expect(result.dropped == [vanishes])
        #expect(tree.size(d) == 0) // the only remaining item is collected
        #expect(!tree.isAttached(vanishes))
    }

    @Test func sizeOnlyChangesRefreshInPlace() throws {
        let f = try Fixture()
        try f.file("x/a.bin", bytes: 100_000)
        try f.file("x/b.bin", bytes: 50_000)
        try f.file("x/sub/deep.bin", bytes: 70_000)
        let tree = try scan(f)
        let x = try #require(tree.lookup(components: ["x"]))
        let b = try #require(tree.lookup(components: ["x", "b.bin"]))

        try f.file("x/b.bin", bytes: 900_000) // grows past a.bin and sub: the order changes
        let result = tree.applyListing(try #require(DirectoryReader.list(tree.path(x))), to: x)

        #expect(tree.liveNodeCount == 0) // nothing appended
        #expect(tree.garbageNodeCount == 0)
        #expect(result.dropped.isEmpty)
        let movedB = result.remap[b] ?? b
        #expect(tree.name(movedB) == "b.bin")
        #expect(tree.children(x).first == movedB)
        // Subtrees follow their folder to its new slot.
        let deep = try #require(tree.lookup(components: ["x", "sub", "deep.bin"]))
        #expect(tree.isAttached(deep))
        let fresh = try scan(f)
        #expect(tree.size(tree.root) == fresh.size(fresh.root))
        #expect(tree.descendantCount(tree.root) == fresh.descendantCount(fresh.root))
    }

    @Test func repeatedSizeChangesDontGrowTheTree() throws {
        let f = try Fixture()
        for i in 0..<50 { try f.file("busy/f\(i).bin", bytes: 1_000 + i) }
        let tree = try scan(f)
        let busy = try #require(tree.lookup(components: ["busy"]))
        for round in 0..<1_000 {
            try f.file("busy/f\(round % 50).bin", bytes: 1_000 + (round * 7919) % 200_000)
            _ = tree.applyListing(try #require(DirectoryReader.list(tree.path(busy))), to: busy)
        }
        #expect(tree.liveNodeCount == 0)
        let fresh = try scan(f)
        #expect(tree.size(tree.root) == fresh.size(fresh.root))
    }

    @Test func manyRefreshesDontExhaustArenas() throws {
        let f = try Fixture()
        try f.file("x/a.bin", bytes: 100)
        let tree = try scan(f)
        for i in 0..<200 {
            try f.file("x/f\(i).bin", bytes: 100)
            try refresh(tree, folders: [["x"]])
        }
        #expect(tree.children(try #require(tree.lookup(components: ["x"]))).count == 201)
        #expect(tree.garbageNodeCount == (1...200).reduce(0, +)) // each refresh retires the previous listing
    }

    @Test func watcherReportsChangedFolders() async throws {
        let f = try Fixture()
        try f.dir("watched")
        let seen = Mutex<[String]>([])
        let watcher = FileWatcher(path: f.root.path, latency: 0.2) { changes in
            seen.withLock { $0.append(contentsOf: changes.map(\.path)) }
        }
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))
        try f.file("watched/new.bin", bytes: 10)
        let target = f.root.resolvingSymlinksInPath().appendingPathComponent("watched").path
        var found = false
        for _ in 0..<50 where !found {
            try await Task.sleep(for: .milliseconds(100))
            found = seen.withLock { $0.contains { $0.hasSuffix("/watched") || $0 == target } }
        }
        #expect(found)
    }
}

@Suite struct FirmlinkTests {
    @Test func firmlinkedDataEntriesAreRecognised() {
        #expect(Firmlinks.dataTargets.contains("/System/Volumes/Data/Users"))
        #expect(Firmlinks.isFirmlinked("Users", in: "/System/Volumes/Data"))
        #expect(Firmlinks.isFirmlinked("local", in: "/System/Volumes/Data/usr"))
        #expect(!Firmlinks.isFirmlinked("macOS Install Data", in: "/System/Volumes/Data"))
        #expect(!Firmlinks.isFirmlinked("Users", in: "/Users")) // only inside the Data volume
    }

    @Test func eventPathsMapBackOnlyForFirmlinkedContent() {
        #expect(Firmlinks.pathInScanOfRoot("/System/Volumes/Data/Users/me/a.txt") == "/Users/me/a.txt")
        #expect(Firmlinks.pathInScanOfRoot("/System/Volumes/Data/usr/local/bin") == "/usr/local/bin")
        // Data-only items stay under the Data volume, where a scan of / now shows them.
        #expect(Firmlinks.pathInScanOfRoot("/System/Volumes/Data/macOS Install Data/x") == "/System/Volumes/Data/macOS Install Data/x")
        #expect(Firmlinks.pathInScanOfRoot("/tmp/x") == "/tmp/x")
    }
}
