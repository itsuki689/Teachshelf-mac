import Foundation

/// Suggestions only: course identity and synchronization always use an explicit local UUID.
public enum TeachingCourseMatching {
    public struct Match: Equatable, Sendable {
        public let courseID: UUID
        public let needsReview: Bool
    }

    public static func suggestions(for remoteTitle: String, courses: [Course]) -> [Match] {
        let remote = normalizedTitle(remoteTitle)
        guard !remote.isEmpty else { return [] }
        let year = remoteYear(remoteTitle)
        return courses.filter { course in
            guard !course.isArchived else { return false }
            // A website year does not identify a semester. Keep ambiguous semesters available.
            return year == nil || course.semester.isEmpty || course.semester.contains(year!)
        }.compactMap { course in
            let local = normalizedTitle(course.name)
            if local == remote { return Match(courseID: course.id, needsReview: false) }
            if withoutPartSuffix(local) == withoutPartSuffix(remote) {
                return Match(courseID: course.id, needsReview: true)
            }
            return nil
        }.sorted { !$0.needsReview && $1.needsReview }
    }

    public static func normalizedTitle(_ title: String) -> String {
        var value = title.precomposedStringWithCompatibilityMapping.uppercased()
        value = value.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\(\d{4}\)$"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"[-—－]*\d+班$"#, with: "", options: .regularExpression)
        return value
    }

    private static func remoteYear(_ title: String) -> String? {
        let value = title.precomposedStringWithCompatibilityMapping
        guard let range = value.range(of: #"(?<=\()\d{4}(?=\)\s*$)"#, options: .regularExpression) else { return nil }
        return String(value[range])
    }

    private static func withoutPartSuffix(_ title: String) -> String {
        title.replacingOccurrences(of: #"[-—－]+[上下]$"#, with: "", options: .regularExpression)
    }
}
