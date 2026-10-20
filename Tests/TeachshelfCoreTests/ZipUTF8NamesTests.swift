import Foundation
import Testing
@testable import TeachshelfCore

struct ZipUTF8NamesTests {
    @Test(arguments: [false, true]) func languageFlagIsMarkedInClassicAndZip64Headers(zip64: Bool) throws {
        func put(_ value: UInt64, width: Int, in data: inout Data, at offset: Int) {
            for index in 0..<width { data[offset + index] = UInt8((value >> (index * 8)) & 255) }
        }
        let name = Data("中文课件.txt".utf8)
        var local = Data(repeating: 0, count: 30)
        put(0x04034b50, width: 4, in: &local, at: 0); put(UInt64(name.count), width: 2, in: &local, at: 26)
        local.append(name)
        var central = Data(repeating: 0, count: 46)
        put(0x02014b50, width: 4, in: &central, at: 0); put(UInt64(name.count), width: 2, in: &central, at: 28)
        if zip64 {
            put(28, width: 2, in: &central, at: 30)
            for offset in [20, 24, 42] { put(0xffffffff, width: 4, in: &central, at: offset) }
        }
        central.append(name)
        if zip64 {
            var extra = Data(repeating: 0, count: 28)
            put(1, width: 2, in: &extra, at: 0); put(24, width: 2, in: &extra, at: 2)
            central.append(extra)
        }
        var archive = local + central
        if zip64 {
            let recordOffset = archive.count
            var record = Data(repeating: 0, count: 56)
            put(0x06064b50, width: 4, in: &record, at: 0); put(44, width: 8, in: &record, at: 4)
            put(1, width: 8, in: &record, at: 24); put(1, width: 8, in: &record, at: 32)
            put(UInt64(central.count), width: 8, in: &record, at: 40); put(UInt64(local.count), width: 8, in: &record, at: 48)
            var locator = Data(repeating: 0, count: 20)
            put(0x07064b50, width: 4, in: &locator, at: 0); put(UInt64(recordOffset), width: 8, in: &locator, at: 8)
            archive.append(record); archive.append(locator)
        }
        var end = Data(repeating: 0, count: 22)
        put(0x06054b50, width: 4, in: &end, at: 0)
        put(zip64 ? 0xffff : 1, width: 2, in: &end, at: 10)
        put(zip64 ? 0xffffffff : UInt64(local.count), width: 4, in: &end, at: 16)
        archive.append(end)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Teachshelf-utf8-\(UUID()).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try archive.write(to: url)
        try ZipUTF8Names.mark(in: url)
        let result = try Data(contentsOf: url)
        #expect(result[7] & 8 == 8 && result[local.count + 9] & 8 == 8)
        #expect(result.subdata(in: 30..<local.count) == name)
        #expect(result.count == archive.count)
    }

    @Test func truncatedArchivesAreRejected() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Teachshelf-bad-zip-\(UUID()).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([1, 2, 3]).write(to: url)
        #expect(throws: (any Error).self) { try ZipUTF8Names.mark(in: url) }
    }
}
