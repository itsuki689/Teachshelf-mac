import Foundation

/// ditto writes UTF-8 paths without ZIP's language flag. Mark both directory and
/// local headers so Windows and standard ZIP readers interpret Chinese names too.
enum ZipUTF8Names {
    static func mark(in url: URL) throws {
        let file = try FileHandle(forUpdating: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        func invalid() -> LibraryError { .invalidInput("ZIP 文件结构不完整，未写入导出文件。") }
        func read(_ offset: UInt64, _ count: Int) throws -> Data {
            guard offset <= size, UInt64(count) <= size - offset else { throw invalid() }
            try file.seek(toOffset: offset)
            guard let data = try file.read(upToCount: count), data.count == count else { throw invalid() }
            return data
        }
        func number(_ data: Data, _ offset: Int, _ bytes: Int) -> UInt64 {
            (0..<bytes).reduce(0) { $0 | (UInt64(data[offset + $1]) << ($1 * 8)) }
        }
        func flag(at offset: UInt64, current: UInt64) throws {
            let value = current | 0x0800
            try file.seek(toOffset: offset)
            try file.write(contentsOf: Data([UInt8(value & 255), UInt8((value >> 8) & 255)]))
        }
        guard size >= 22 else { throw invalid() }
        let tailStart = size > 65_557 ? size - 65_557 : 0
        let tail = try read(tailStart, Int(size - tailStart))
        guard let end = stride(from: tail.count - 22, through: 0, by: -1).first(where: {
            number(tail, $0, 4) == 0x06054b50 && $0 + 22 + Int(number(tail, $0 + 20, 2)) == tail.count
        }) else { throw invalid() }
        var count = number(tail, end + 10, 2), position = number(tail, end + 16, 4)
        if count == 0xffff || position == 0xffffffff {
            let endOffset = tailStart + UInt64(end)
            guard endOffset >= 20 else { throw invalid() }
            let locator = try read(endOffset - 20, 20)
            guard number(locator, 0, 4) == 0x07064b50 else { throw invalid() }
            let zip64 = try read(number(locator, 8, 8), 56)
            guard number(zip64, 0, 4) == 0x06064b50 else { throw invalid() }
            count = number(zip64, 32, 8); position = number(zip64, 48, 8)
        }
        guard count <= size / 46 else { throw invalid() }
        for _ in 0..<count {
            let header = try read(position, 46)
            guard number(header, 0, 4) == 0x02014b50 else { throw invalid() }
            let nameCount = Int(number(header, 28, 2)), extraCount = Int(number(header, 30, 2)), commentCount = Int(number(header, 32, 2))
            let name = try read(position + 46, nameCount)
            guard String(data: name, encoding: .utf8) != nil else { throw invalid() }
            var local = number(header, 42, 4)
            if local == 0xffffffff {
                let extra = try read(position + 46 + UInt64(nameCount), extraCount)
                var index = 0, found = false
                while index + 4 <= extra.count {
                    let type = number(extra, index, 2), length = Int(number(extra, index + 2, 2))
                    guard index + 4 + length <= extra.count else { throw invalid() }
                    if type == 1 {
                        var value = index + 4
                        if number(header, 24, 4) == 0xffffffff { value += 8 }
                        if number(header, 20, 4) == 0xffffffff { value += 8 }
                        guard value + 8 <= index + 4 + length else { throw invalid() }
                        local = number(extra, value, 8); found = true; break
                    }
                    index += 4 + length
                }
                guard found else { throw invalid() }
            }
            let localHeader = try read(local, 30)
            guard number(localHeader, 0, 4) == 0x04034b50 else { throw invalid() }
            try flag(at: local + 6, current: number(localHeader, 6, 2))
            try flag(at: position + 8, current: number(header, 8, 2))
            position += UInt64(46 + nameCount + extraCount + commentCount)
        }
        try file.synchronize()
    }
}
