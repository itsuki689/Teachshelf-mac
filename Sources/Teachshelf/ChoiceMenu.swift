import SwiftUI
import AppKit
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
        SolidChoiceMenu(title, selection: $selection, options:
            [ChoiceOption(value: nil as UUID?, title: emptyTitle)] + courses.map {
                ChoiceOption(value: Optional($0.id), title: $0.name + ($0.isArchived ? "（已归档）" : ""))
            })
    }
}

struct ChoiceOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var id: Value { value }
}

/// Course selectors use an opaque surface for both the control and its expanded list.
struct SolidChoiceMenu<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [ChoiceOption<Value>]
    let compact: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appTheme) private var theme
    @ViewState private var isPresented = false
    @ViewState private var controlWidth: CGFloat = 200

    init(_ title: String, selection: Binding<Value>, options: [ChoiceOption<Value>], compact: Bool = false) {
        self.title = title
        self._selection = selection
        self.options = options
        self.compact = compact
    }

    private var selectedTitle: String { options.first { $0.value == selection }?.title ?? title }
    private var surface: Color { Color(hex: colorScheme == .dark ? "#292B2D" : "#F5F5F5") }

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 8) {
                Text(selectedTitle).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .font(.system(size: compact ? 12 : 13))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: compact ? 28 : 32)
            .background(surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary, lineWidth: 1).allowsHitTesting(false) }
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(options.isEmpty)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { controlWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, width in controlWidth = width }
            }
        }
        .background {
            SolidChoicePopup(isPresented: $isPresented, title: title,
                             size: CGSize(width: min(max(controlWidth, 200), 360), height: min(CGFloat(options.count) * 32 + 10, 330)),
                             surface: NSColor(surface),
                             content: SolidChoiceList(title: title, selection: $selection, options: options) { isPresented = false }
                                .background(surface)
                                .environment(\.appTheme, theme)
                                .environment(\.colorScheme, colorScheme))
        }
        .onKeyPress(.downArrow) { isPresented = true; return .handled }
        .onKeyPress(.upArrow) { isPresented = true; return .handled }
        .accessibilityLabel(title)
        .accessibilityValue(selectedTitle)
        .accessibilityHint("展开选项，使用上下方向键和回车选择")
        .help("\(title)：\(selectedTitle)")
    }
}

private struct SolidChoiceList<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [ChoiceOption<Value>]
    let dismiss: () -> Void

    @Environment(\.appTheme) private var theme
    @ViewState private var highlighted = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                        Button { choose(option) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .opacity(selection == option.value ? 1 : 0)
                                    .frame(width: 12)
                                Text(option.title).lineLimit(1).truncationMode(.tail)
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 9)
                            .frame(height: 30)
                            .background(highlighted == index ? theme.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in if hovering { highlighted = index } }
                        .accessibilityLabel(option.title)
                        .accessibilityValue(selection == option.value ? "已选中" : "")
                        .accessibilityAddTraits(selection == option.value ? .isSelected : [])
                        .help(option.title)
                        .id(option.id)
                    }
                }
                .padding(6)
            }
            .frame(height: min(CGFloat(options.count) * 32 + 10, 330))
            .onChange(of: highlighted) { _, index in
                if options.indices.contains(index) { proxy.scrollTo(options[index].id) }
            }
            .onAppear {
                highlighted = options.firstIndex { $0.value == selection } ?? 0
                if options.indices.contains(highlighted) { proxy.scrollTo(options[highlighted].id) }
            }
        }
        .background(ChoiceListKeyboardTarget(handleKey: handleKey))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func choose(_ option: ChoiceOption<Value>) {
        selection = option.value
        dismiss()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 125: highlighted = min(highlighted + 1, options.count - 1)
        case 126: highlighted = max(highlighted - 1, 0)
        case 36, 76, 49:
            if options.indices.contains(highlighted) { choose(options[highlighted]) }
        case 53: dismiss()
        default: return false
        }
        return true
    }
}

/// Give the choice window its own responder instead of the sidebar's arrow handler.
private struct ChoiceListKeyboardTarget: NSViewRepresentable {
    let handleKey: (NSEvent) -> Bool

    func makeNSView(context: Context) -> ChoiceKeyView {
        let view = ChoiceKeyView()
        view.handleKey = handleKey
        return view
    }

    func updateNSView(_ view: ChoiceKeyView, context: Context) { view.handleKey = handleKey }

    final class ChoiceKeyView: NSView {
        var handleKey: ((NSEvent) -> Bool)?
        private var keyMonitor: Any?
        override var acceptsFirstResponder: Bool { true }
        override var needsPanelToBecomeKey: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            guard window != nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.window?.isVisible == true else { return event }
                return self.handleKey?(event) == true ? nil : event
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeKey()
                window.makeFirstResponder(self)
            }
        }

        override func keyDown(with event: NSEvent) {
            if handleKey?(event) != true { super.keyDown(with: event) }
        }

        deinit {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        }
    }
}
