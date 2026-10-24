import Foundation

extension MaterialOrdering {
    /// Normalize explicit chapter/lesson ordinals, leaving ordinary Chinese words intact.
    public static func compareNames(_ lhs: String, _ rhs: String) -> ComparisonResult {
        chapterSortKey(lhs).localizedStandardCompare(chapterSortKey(rhs))
    }

    public static func sortedFolders(_ folders: [MaterialFolder]) -> [MaterialFolder] {
        folders.map { (folder: $0, key: chapterSortKey($0.name)) }.sorted { lhs, rhs in
            let comparison = lhs.key.localizedStandardCompare(rhs.key)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs.folder.id.uuidString < rhs.folder.id.uuidString
        }.map(\.folder)
    }

    private static let chapterNumeral = try? NSRegularExpression(
        pattern: #"第\s*([零〇一二两兩三四五六七八九十百千]+)\s*(?=章|节|節|回|卷|篇|课|課|讲|講|单元|單元)"#)

    static func chapterSortKey(_ name: String) -> String {
        guard name.contains("第"), let chapterNumeral else { return name }
        let result = NSMutableString(string: name)
        // Reverse replacements preserve the UTF-16 ranges of earlier matches.
        for match in chapterNumeral.matches(in: name, range: NSRange(name.startIndex..., in: name)).reversed() {
            let range = match.range(at: 1)
            guard let value = chineseNumber(result.substring(with: range)) else { continue }
            result.replaceCharacters(in: range, with: String(value))
        }
        return result as String
    }

    private static func chineseNumber(_ text: String) -> Int? {
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "兩": 2,
                                        "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        let units: [Character: Int] = ["十": 10, "百": 100, "千": 1_000]
        if text.allSatisfy({ digits[$0] != nil }) {
            return Int(text.compactMap { digits[$0].map(String.init) }.joined())
        }
        var total = 0, previousUnit = 10_000
        var pending: Int?
        var zero = false
        for character in text {
            if let digit = digits[character] {
                guard pending == nil else { return nil }
                if digit == 0 {
                    guard total > 0, !zero else { return nil }
                    zero = true
                } else { pending = digit }
            } else if let unit = units[character] {
                guard unit < previousUnit,
                      let coefficient = pending ?? (total == 0 && unit == 10 ? 1 : nil) else { return nil }
                total += coefficient * unit
                previousUnit = unit
                pending = nil
                zero = false
            } else { return nil }
        }
        guard !zero || pending != nil else { return nil }
        return total + (pending ?? 0)
    }
}
