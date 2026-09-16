import Foundation

/// Minimal RAR 4 writer using the "store" method (no compression), which is all the format
/// allows without a licensed encoder. Output opens in The Unarchiver, libarchive and WinRAR.
enum Rar {
    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data, seed: UInt32 = 0) -> UInt32 {
        var c = ~seed
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return ~c
    }

    private static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    private static func le32(_ v: UInt32) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]) }

    /// DOS date/time packed the way RAR expects.
    private static func dosTime(_ date: Date) -> UInt32 {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let y = UInt32(max(0, (c.year ?? 1980) - 1980)), m = UInt32(c.month ?? 1), d = UInt32(c.day ?? 1)
        let h = UInt32(c.hour ?? 0), mi = UInt32(c.minute ?? 0), s = UInt32((c.second ?? 0) / 2)
        return (y << 25) | (m << 21) | (d << 16) | (h << 11) | (mi << 5) | s
    }

    private static func block(type: UInt8, flags: UInt16, body: Data) -> Data {
        // HEAD_CRC(2) HEAD_TYPE(1) HEAD_FLAGS(2) HEAD_SIZE(2) + body
        var head = Data([type]) + le16(flags) + le16(UInt16(7 + body.count))
        head += body
        let crc = UInt16(crc32(head) & 0xFFFF)
        return le16(crc) + head
    }

    static func write(directory: URL, to out: URL, job: Job?) throws {
        var data = Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00])          // marker block
        data += block(type: 0x73, flags: 0x0000, body: Data([0, 0, 0, 0, 0, 0])) // main archive header
        let fm = FileManager.default
        let base = directory.standardizedFileURL.path
        guard let e = fm.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { throw ConvError.failed("Cannot read files") }
        var entries: [URL] = []
        for case let url as URL in e { entries.append(url) }
        entries.sort { $0.path < $1.path }
        var handle: FileHandle
        try data.write(to: out)
        handle = try FileHandle(forWritingTo: out)
        try handle.seekToEnd()
        for (i, url) in entries.enumerated() {
            try job?.checkCancelled()
            job?.progress = Double(i) / Double(max(1, entries.count))
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let isDir = values.isDirectory ?? false
            var rel = String(url.standardizedFileURL.path.dropFirst(base.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            rel = rel.replacingOccurrences(of: "/", with: "\\")
            let name = Data(rel.utf8)
            let content = isDir ? Data() : try Data(contentsOf: url)
            var body = Data()
            body += le32(UInt32(content.count))            // PACK_SIZE
            body += le32(UInt32(content.count))            // UNP_SIZE
            body += Data([3])                               // HOST_OS: Unix
            body += le32(isDir ? 0 : crc32(content))       // FILE_CRC
            body += le32(dosTime(values.contentModificationDate ?? Date()))
            body += Data([20])                              // UNP_VER 2.0
            body += Data([0x30])                            // METHOD: store
            body += le16(UInt16(name.count))
            body += le32(isDir ? 0x4000 | 0o755 : 0x8000 | 0o644)   // ATTR (unix mode)
            body += name
            // flags: 0x8000 (LONG_BLOCK) | dictionary bits 0x00E0 mean directory
            let flags: UInt16 = 0x8000 | (isDir ? 0x00E0 : 0x0000)
            handle.write(block(type: 0x74, flags: flags, body: body))
            if !isDir { handle.write(content) }
        }
        handle.write(block(type: 0x7B, flags: 0x4000, body: Data()))  // end of archive
        try handle.close()
    }
}
