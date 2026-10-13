import SwiftUI
import TeachshelfCore

struct MaterialCoverCard: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var hovered = false
    let material: MaterialRecord
    let url: URL?
    let courseName: String
    let courseColor: Color
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            CoverThumbnail(material: material, url: url, color: courseColor)
                .frame(height: 205)
                .shadow(color: .black.opacity(hovered ? 0.17 : 0.09), radius: hovered ? 10 : 6, x: 0, y: hovered ? 6 : 3)
                .offset(y: hovered && !reduceMotion ? -3 : 0)
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 21, height: 21).background(theme.controlAccent, in: Circle())
                            .padding(6).transition(.opacity)
                    }
                }
            Text(material.title).font(.system(size: 13, weight: .medium)).lineLimit(2).frame(height: 34, alignment: .topLeading)
            HStack {
                Text(courseName).lineLimit(1)
                Spacer(minLength: 0)
                if material.isFavorite { Image(systemName: "star.fill").foregroundStyle(.orange) }
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(10)
            .background(selected ? theme.selection : (hovered ? theme.ink.opacity(0.035) : .clear), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? theme.selectionBorder : (hovered ? theme.ink.opacity(0.2) : .clear), lineWidth: 1)
            }
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: hovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: selected)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(material.title)
            .accessibilityValue("\(courseName)\(selected ? "，已选中" : "")")
            .accessibilityAddTraits([.isButton])
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
