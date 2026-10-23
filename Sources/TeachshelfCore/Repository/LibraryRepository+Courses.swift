import Foundation

extension LibraryRepository {
    public func saveCourse(_ course: Course) throws {
        try commit { state in
            guard !course.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.invalidInput("请输入课程名称。") }
            if let folder = course.homeworkFolder,
               folder != state.courses.first(where: { $0.id == course.id })?.homeworkFolder {
                try validateMount(URL(fileURLWithPath: folder), for: course.id, in: state)
            }
            if let index = state.courses.firstIndex(where: { $0.id == course.id }) { state.courses[index] = course }
            else { state.courses.append(course) }
            for index in state.tasks.indices where state.tasks[index].courseID == course.id && !state.tasks[index].isArchived { state.tasks[index].courseNameSnapshot = course.name }
            for index in state.tasks.indices where !state.tasks[index].isArchived {
                for e in state.tasks[index].exceptions.indices where state.tasks[index].exceptions[e].details?.courseID == course.id {
                    state.tasks[index].exceptions[e].details?.courseNameSnapshot = course.name
                }
            }
        }
    }

    public func deleteCourse(id: UUID) throws {
        try commit { state in
            guard let course = state.courses.first(where: { $0.id == id }) else { throw LibraryError.missingRecord("课程") }
            state.courses.removeAll { $0.id == id }
            state.teachingConnections.removeAll { $0.courseID == id }
            state.materialFolders.removeAll { $0.courseID == id }
            for index in state.materials.indices where state.materials[index].courseID == id {
                state.materials[index].folderID = nil
                state.materials[index].customOrder = nil
                state.materials[index].courseID = nil
            }
            for index in state.tasks.indices where state.tasks[index].courseID == id {
                state.tasks[index].courseID = nil
                if !state.tasks[index].isArchived || state.tasks[index].courseNameSnapshot == nil { state.tasks[index].courseNameSnapshot = course.name }
            }
            for index in state.tasks.indices {
                for e in state.tasks[index].exceptions.indices where state.tasks[index].exceptions[e].details?.courseID == id {
                    state.tasks[index].exceptions[e].details?.courseID = nil
                    if !state.tasks[index].isArchived || state.tasks[index].exceptions[e].details?.courseNameSnapshot == nil {
                        state.tasks[index].exceptions[e].details?.courseNameSnapshot = course.name
                    }
                }
            }
            for termIndex in state.timetableTerms.indices {
                for meetingIndex in state.timetableTerms[termIndex].meetings.indices where state.timetableTerms[termIndex].meetings[meetingIndex].courseID == id {
                    state.timetableTerms[termIndex].meetings[meetingIndex].courseID = nil
                }
                for index in state.timetableTerms[termIndex].reschedules.indices where state.timetableTerms[termIndex].reschedules[index].meeting.courseID == id {
                    state.timetableTerms[termIndex].reschedules[index].meeting.courseID = nil
                }
                for index in state.timetableTerms[termIndex].cancellations.indices where state.timetableTerms[termIndex].cancellations[index].savedReschedule?.meeting.courseID == id {
                    state.timetableTerms[termIndex].cancellations[index].savedReschedule?.meeting.courseID = nil
                }
            }
        }
    }

    public func archiveCourse(id: UUID, archived: Bool) throws {
        try commit { state in
            guard let index = state.courses.firstIndex(where: { $0.id == id }) else { throw LibraryError.missingRecord("课程") }
            state.courses[index].isArchived = archived
        }
    }

    func ensureCourse(_ id: UUID?) throws {
        if let id, !snapshot.courses.contains(where: { $0.id == id }) { throw LibraryError.missingRecord("课程") }
    }
}
