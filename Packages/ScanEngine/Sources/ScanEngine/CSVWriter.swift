import Foundation

/// Streams every item under `focus` as CSV: Path, Size (bytes), Size, Items, Kind. Depth-first, children by size.
public enum CSVWriter {
    public static func write(tree: FileTree, from focus: NodeRef, to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var buffer = "Path,Size (bytes),Size,Items,Kind\n"
        func flush(_ force: Bool = false) throws {
            if force || buffer.utf8.count > 1 << 20 {
                try handle.write(contentsOf: Data(buffer.utf8))
                buffer.removeAll(keepingCapacity: true)
            }
        }
        var stack: [(NodeRef, String)] = [(focus, tree.path(focus))]
        while let (node, path) = stack.popLast() {
            let flags = tree.flags(node)
            if flags.contains(.removed) { continue }
            let size = tree.size(node)
            buffer += "\(quote(path)),\(size),\(quote(ByteSize.string(size))),\(tree.descendantCount(node)),\(kind(flags))\n"
            try flush()
            for child in tree.children(node).reversed() {
                stack.append((child, path == "/" ? "/" + tree.name(child) : path + "/" + tree.name(child)))
            }
        }
        try flush(true)
    }

    static func kind(_ flags: NodeFlags) -> String {
        if flags.contains(.otherVolume) { return "Volume" }
        if flags.contains(.symlink) { return "Symlink" }
        if flags.contains(.directory) { return flags.contains(.restricted) ? "Restricted Folder" : "Folder" }
        return "File"
    }

    static func quote(_ field: String) -> String {
        "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
