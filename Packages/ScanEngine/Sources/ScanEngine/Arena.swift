import Foundation

/// Compact reference to a node: the top 6 bits select the arena, the low 26 bits the index within it.
/// Children of a directory are always stored contiguously in one arena, so `raw + i` addresses the i-th child.
public struct NodeRef: Hashable, Comparable, Sendable {
    public let raw: UInt32

    static let indexBits: UInt32 = 26
    static let indexMask: UInt32 = (1 << indexBits) - 1
    static let maxArenas = 63 // arena 63 is reserved so `.none` can never collide with a real node

    public static let none = NodeRef(raw: .max)

    public init(raw: UInt32) { self.raw = raw }
    init(arena: Int, index: Int) { raw = UInt32(arena) << Self.indexBits | UInt32(index) }

    @inline(__always) var arena: Int { Int(raw >> Self.indexBits) }
    @inline(__always) var index: Int { Int(raw & Self.indexMask) }
    public var isNone: Bool { raw == .max }

    @inline(__always) func advanced(by n: Int) -> NodeRef { NodeRef(raw: raw &+ UInt32(n)) }

    public static func < (lhs: NodeRef, rhs: NodeRef) -> Bool { lhs.raw < rhs.raw }
}

public struct NodeFlags: OptionSet, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let directory = NodeFlags(rawValue: 1 << 0)
    /// The directory could not be opened (permissions / TCC); its content is unknown.
    public static let restricted = NodeFlags(rawValue: 1 << 1)
    /// The directory is a mount point of another volume and was not descended into.
    public static let mountPoint = NodeFlags(rawValue: 1 << 2)
    /// Another link to the same inode was already counted; this node's size is 0.
    public static let hardLinkDuplicate = NodeFlags(rawValue: 1 << 3)
    public static let symlink = NodeFlags(rawValue: 1 << 4)
    /// Enumeration failed part-way through; the listing may be incomplete.
    public static let partial = NodeFlags(rawValue: 1 << 5)
    /// Removed from the visible tree (e.g. moved to the Collector). Size already subtracted from ancestors.
    public static let removed = NodeFlags(rawValue: 1 << 6)
    /// A mount point of another volume in the same container, sized from the volume's usage rather than scanned
    /// (e.g. /System/Volumes/VM). Shown as a single block, like DaisyDisk's fixed-size items.
    public static let otherVolume = NodeFlags(rawValue: 1 << 7)
}

/// 32-byte node record.
struct Node {
    var size: UInt64
    var parent: NodeRef
    var firstChild: NodeRef
    var childCount: UInt32
    /// Number of items (files + folders) below this node, excluding itself.
    var descendantCount: UInt32
    var nameOffset: UInt32
    var nameLength: UInt16
    var flags: NodeFlags
}

/// Append-only storage owned by a single writer thread.
///
/// Pages never move once allocated, so other threads may safely read or write *distinct* node slots
/// that were published to them through a synchronizing handoff (the scanner's work stack lock).
final class Arena: @unchecked Sendable {
    static let nodePageShift = 13
    static let nodesPerPage = 1 << nodePageShift
    static let maxNodePages = 1 << (Int(NodeRef.indexBits) - nodePageShift)

    static let namePageShift = 18
    static let namePageSize = 1 << namePageShift
    static let maxNamePages = 1 << (32 - namePageShift)

    let id: Int
    private let nodePages: UnsafeMutablePointer<UnsafeMutablePointer<Node>?>
    private let namePages: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>
    private(set) var nodeCount = 0
    private var nameEnd = 0
    private var allocatedNodePages = 0
    private var allocatedNamePages = 0

    /// Open-addressing table of names already stored in this arena, so repeated names ("index.js",
    /// "node_modules", …) share one copy. Measured on a real home folder: 275 MB of names → 43 MB unique.
    /// Slot layout: `offset + 1` (32 bits) | length (16 bits) | hash tag (16 bits); 0 = empty.
    private var internSlots: UnsafeMutablePointer<UInt64>?
    private var internCapacity = 0
    private var internCount = 0
    static let maxInternedLength = 96

    init(id: Int) {
        precondition(id < NodeRef.maxArenas)
        self.id = id
        nodePages = .allocate(capacity: Self.maxNodePages)
        nodePages.initialize(repeating: nil, count: Self.maxNodePages)
        namePages = .allocate(capacity: Self.maxNamePages)
        namePages.initialize(repeating: nil, count: Self.maxNamePages)
    }

    deinit {
        internSlots?.deallocate()
        for i in 0..<allocatedNodePages { nodePages[i]?.deallocate() }
        for i in 0..<Self.maxNamePages where namePages[i] != nil { namePages[i]?.deallocate() }
        nodePages.deallocate()
        namePages.deallocate()
    }

    @inline(__always) func pointer(_ index: Int) -> UnsafeMutablePointer<Node> {
        nodePages[index >> Self.nodePageShift].unsafelyUnwrapped + (index & (Self.nodesPerPage - 1))
    }

    @inline(__always) func append(_ node: Node) -> NodeRef {
        let index = nodeCount
        precondition(index <= Int(NodeRef.indexMask), "arena \(id) is full")
        if index & (Self.nodesPerPage - 1) == 0 {
            nodePages[index >> Self.nodePageShift] = .allocate(capacity: Self.nodesPerPage)
            allocatedNodePages += 1
        }
        pointer(index).initialize(to: node)
        nodeCount = index + 1
        return NodeRef(arena: id, index: index)
    }

    /// Copies `count` bytes of UTF-8 into the name pages. Names never straddle a page.
    @inline(__always) func appendName(_ bytes: UnsafeRawPointer, count: Int) -> UInt32 {
        var start = nameEnd
        if (start & (Self.namePageSize - 1)) + count > Self.namePageSize {
            start = ((start >> Self.namePageShift) + 1) << Self.namePageShift
        }
        let page = start >> Self.namePageShift
        precondition(page < Self.maxNamePages, "arena \(id) name storage is full")
        if namePages[page] == nil {
            namePages[page] = .allocate(capacity: Self.namePageSize)
            allocatedNamePages += 1
        }
        (namePages[page].unsafelyUnwrapped + (start & (Self.namePageSize - 1)))
            .update(from: bytes.assumingMemoryBound(to: UInt8.self), count: count)
        nameEnd = start + count
        return UInt32(start)
    }

    /// Stores a name, reusing an identical earlier one when possible. Only the owning thread may call this.
    @inline(__always) func internName(_ bytes: UnsafeRawPointer, count: Int) -> UInt32 {
        guard count > 0, count <= Self.maxInternedLength else { return appendName(bytes, count: count) }
        if internCount * 10 >= internCapacity * 7 { growInternTable() }
        let hash = Self.hash(bytes, count)
        let tag = UInt64(hash >> 48)
        let mask = internCapacity - 1
        var slot = Int(truncatingIfNeeded: hash) & mask
        while true {
            let entry = internSlots.unsafelyUnwrapped[slot]
            if entry == 0 {
                let offset = appendName(bytes, count: count)
                internSlots.unsafelyUnwrapped[slot] = (UInt64(offset) + 1) << 32 | UInt64(count) << 16 | tag
                internCount += 1
                return offset
            }
            if entry & 0xFFFF == tag, Int((entry >> 16) & 0xFFFF) == count {
                let offset = UInt32((entry >> 32) - 1)
                let stored = nameBytes(offset: offset, length: UInt16(count))
                if memcmp(stored.baseAddress!, bytes, count) == 0 { return offset }
            }
            slot = (slot + 1) & mask
        }
    }

    /// Frees the intern table once the arena stops growing (after a scan or graft).
    func dropInternTable() {
        internSlots?.deallocate()
        internSlots = nil
        internCapacity = 0
        internCount = 0
    }

    private func growInternTable() {
        let old = internSlots
        let oldCapacity = internCapacity
        internCapacity = max(1 << 14, oldCapacity * 2)
        internSlots = .allocate(capacity: internCapacity)
        internSlots!.initialize(repeating: 0, count: internCapacity)
        internCount = 0
        guard let old else { return }
        let mask = internCapacity - 1
        for i in 0..<oldCapacity where old[i] != 0 {
            let entry = old[i]
            let offset = UInt32((entry >> 32) - 1)
            let length = Int((entry >> 16) & 0xFFFF)
            let name = nameBytes(offset: offset, length: UInt16(length))
            var slot = Int(truncatingIfNeeded: Self.hash(UnsafeRawPointer(name.baseAddress!), length)) & mask
            while internSlots![slot] != 0 { slot = (slot + 1) & mask }
            internSlots![slot] = entry
            internCount += 1
        }
        old.deallocate()
    }

    /// FNV-1a, finished with a multiply-xorshift so both the low bits (slot) and high bits (tag) mix well.
    @inline(__always) static func hash(_ bytes: UnsafeRawPointer, _ count: Int) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        let p = bytes.assumingMemoryBound(to: UInt8.self)
        for i in 0..<count { h = (h ^ UInt64(p[i])) &* 0x100_0000_01b3 }
        h ^= h >> 32
        h = h &* 0xd6e8_feb8_6659_fd93
        return h ^ (h >> 29)
    }

    var internTableFootprint: Int { internCapacity * MemoryLayout<UInt64>.stride }

    @inline(__always) func nameBytes(offset: UInt32, length: UInt16) -> UnsafeBufferPointer<UInt8> {
        let o = Int(offset)
        let base = namePages[o >> Self.namePageShift].unsafelyUnwrapped + (o & (Self.namePageSize - 1))
        return UnsafeBufferPointer(start: base, count: Int(length))
    }

    var memoryFootprint: Int {
        allocatedNodePages * Self.nodesPerPage * MemoryLayout<Node>.stride
            + allocatedNamePages * Self.namePageSize
    }
}
