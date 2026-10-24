import Foundation
import Testing
import TeachshelfCore

struct MaterialNameOrderingTests {
    @Test func chineseChaptersSortNumericallyForBothFilesAndFolders() {
        let expected = ["第零章", "第一章", "第二章", "第三章", "第四章", "第五章", "第六章", "第七章",
                        "第八章", "第九章", "第十章", "第十一章", "第十九章", "第二十章", "第二十一章",
                        "第九十九章", "第一百章", "第一百零一章", "第一百一十章", "第两百章",
                        "第九百九十九章", "第一千章", "第一千零一章", "第一千零二十章", "第一千二百三十四章"]
        let records = expected.reversed().map(record)
        let folders = expected.reversed().map { MaterialFolder(courseID: nil, name: $0) }
        #expect(MaterialOrdering.sorted(records, by: .name).map(\.title) == expected)
        #expect(MaterialOrdering.sortedFolders(folders).map(\.name) == expected)
        #expect(records.map(\.title) == Array(expected.reversed()))
    }

    @Test func mixedNumeralsNestedPathsAndSuffixNumbersRemainNatural() {
        let expected = ["📘 第一章 / 第二节 练习2.pdf", "📘 第1章 / 第2节 练习10.pdf",
                        "📘 第1章 / 第十节 练习.pdf", "📘 第二章 / 第一节 练习.pdf",
                        "📘 第10章 / 第一节 练习.pdf", "📘 第十一章 / 第一节 练习.pdf"]
        #expect(expected.reversed().sorted { MaterialOrdering.compareNames($0, $1) == .orderedAscending } == expected)
        #expect(MaterialOrdering.compareNames("第 一〇二 章", "第 102 章") == .orderedSame)
        #expect(MaterialOrdering.compareNames("第二講", "第2講") == .orderedSame)
        #expect(MaterialOrdering.compareNames("第兩百單元", "第200單元") == .orderedSame)
    }

    @Test func ordinaryWordsMalformedNumbersAndOverflowRetainTheirCollation() {
        let names = ["统一理论", "三维图形", "二叉树", "十一月课件", "第十十章", "第百章", "第一百二三章",
                     "第一百零章", "第" + String(repeating: "九", count: 100) + "章", "课件2", "课件10"]
        for name in names {
            #expect(MaterialOrdering.compareNames(name, "第2章") == name.localizedStandardCompare("第2章"))
        }
    }

    @Test func equivalentNumbersRetainStableTieBreaksAndOtherSortModes() {
        var older = record("第二章"), newer = record("第2章"), earlier = record("第一章")
        older.addedAt = Date(timeIntervalSince1970: 1)
        newer.addedAt = Date(timeIntervalSince1970: 2)
        earlier.addedAt = Date(timeIntervalSince1970: 0)
        older.customOrder = 0; newer.customOrder = 1; earlier.customOrder = 2
        let records = [older, earlier, newer]
        #expect(MaterialOrdering.sorted(records, by: .name).map(\.id) == [earlier.id, newer.id, older.id])
        #expect(MaterialOrdering.sorted(records, by: .time).map(\.id) == [newer.id, older.id, earlier.id])
        #expect(MaterialOrdering.sorted(records, by: .custom).map(\.id) == [older.id, newer.id, earlier.id])
        let first = MaterialFolder(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, courseID: nil, name: "第二章")
        let second = MaterialFolder(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, courseID: nil, name: "第2章")
        #expect(MaterialOrdering.sortedFolders([second, first]).map(\.id) == [first.id, second.id])
    }

    private func record(_ name: String) -> MaterialRecord {
        MaterialRecord(title: name, originalName: name + ".txt", sourcePath: "", storedPath: "", isManaged: false)
    }
}
