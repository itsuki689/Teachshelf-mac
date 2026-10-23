import SwiftUI

/// Keep the click feedback in its own transaction, before constructing the WebKit sheet.
@MainActor final class ToolbarUpdateFeedback: ObservableObject {
    @Published private(set) var rotation: Double = 0
    private var requestID: UUID?

    func start(reduceMotion: Bool, present: @escaping () -> Void) {
        guard requestID == nil else { return }
        guard !reduceMotion else { present(); return }
        let id = UUID()
        requestID = id
        withAnimation(.linear(duration: 0.4), completionCriteria: .removed) {
            rotation += 360
        } completion: { [weak self] in
            guard let self, self.requestID == id else { return }
            self.requestID = nil
            present()
        }
    }

    func cancel() { requestID = nil }
}
