import SwiftUI
import TeachshelfCore

/// A consistent dropdown surface, with native keyboard navigation and checked menu items.
struct ChoiceMenu<Selection: Hashable, Options: View>: View {
    let title: String
    @Binding var selection: Selection
    let selectedTitle: String
    let compact: Bool
    let options: () -> Options

    init(_ title: String, selection: Binding<Selection>, selectedTitle: String, compact: Bool = false,
         @ViewBuilder options: @escaping () -> Options) {
        self.title = title; self._selection = selection; self.selectedTitle = selectedTitle
        self.compact = compact; self.options = options
    }

    var body: some View {
        Menu {
            Picker(title, selection: $selection) { options() }.pickerStyle(.inline)
        } label: {
            HStack(spacing: 8) {
                Text(selectedTitle).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .font(.system(size: compact ? 12 : 13))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: compact ? 28 : 32)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary, lineWidth: 1) }
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(selectedTitle)
        .help("\(title)：\(selectedTitle)")
    }
}

struct CourseMenu: View {
    @Binding var selection: UUID?
    let courses: [Course]
    var emptyTitle = "所有课程"
    var title = "课程"

    var body: some View {
        ChoiceMenu(title, selection: $selection, selectedTitle: courses.first { $0.id == selection }?.name ?? emptyTitle) {
            Text(emptyTitle).tag(nil as UUID?)
            ForEach(courses) { course in
                Text(course.name + (course.isArchived ? "（已归档）" : "")).tag(Optional(course.id))
            }
        }
    }
}
