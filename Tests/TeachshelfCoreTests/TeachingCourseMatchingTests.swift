import Foundation
import Testing
@testable import TeachshelfCore

struct TeachingCourseMatchingTests {
    @Test func matchesCurrentWebsiteTitlesToExistingCourses() {
        let pairs = [
            ("计算机系统基础实验选修(2026)", "计算机系统基础实验选修01班"),
            ("数据库系统概论(2026)", "数据库系统概论01班"),
            ("计算系统基础Ⅱ--1班(2026)", "计算系统基础 II01班"),
            ("数据结构与算法(2026)", "数据结构与算法01班"),
            ("软件工程伦理(2026)", "软件工程伦理01班"),
            ("数理逻辑(2026)", "数理逻辑01班")
        ]
        let courses = pairs.map { Course(name: $0.1, semester: "2026-2027学年 第1学期") }
        for (index, pair) in pairs.enumerated() {
            #expect(TeachingCourseMatching.suggestions(for: pair.0, courses: courses) == [.init(courseID: courses[index].id, needsReview: false)])
        }
    }

    @Test func partDifferenceRequiresExplicitReviewAndKeepsLevelsDistinct() {
        let course = Course(name: "软件工程与计算 II01班")
        #expect(TeachingCourseMatching.suggestions(for: "软件工程与计算Ⅱ-下(2026)", courses: [course]) == [.init(courseID: course.id, needsReview: true)])
        #expect(TeachingCourseMatching.suggestions(for: "软件工程与计算I(2026)", courses: [course]).isEmpty)
        #expect(TeachingCourseMatching.suggestions(for: "计算机系统基础(2026)", courses: [Course(name: "计算机系统基础实验01班")]).isEmpty)
    }

    @Test func repeatedNamesKeepAllSemesterCandidatesAndExcludeArchivedOrUnrelatedYears() {
        let courses = [
            Course(name: "数据库系统概论01班", semester: "2025-2026学年 第2学期"),
            Course(name: "数据库系统概论02班", semester: "2026-2027学年 第1学期"),
            Course(name: "数据库系统概论03班", semester: "2024-2025学年 第1学期"),
            Course(name: "数据库系统概论04班", semester: "2026-2027学年 第1学期", isArchived: true)
        ]
        #expect(Set(TeachingCourseMatching.suggestions(for: "数据库系统概论（2026）", courses: courses).map(\.courseID)) == Set(courses.prefix(2).map(\.id)))
        #expect(TeachingCourseMatching.suggestions(for: "WEB开发--暑期学校(2026)", courses: courses).isEmpty)
        #expect(TeachingCourseMatching.suggestions(for: "智能化软件工程师训练营-软件学院(2026)", courses: courses).isEmpty)
    }
}
