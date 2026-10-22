import Combine
import TeachshelfCore

/// Publish the requested theme immediately while serializing its disk writes off the main actor.
@MainActor final class AppearancePreference: ObservableObject {
    @Published private(set) var mode: String
    private var worker: Task<Void, Never>?
    private var lastSavedMode: String
    private var pending: Request?
    private var flushWaiters: [CheckedContinuation<Void, Never>] = []

    var isSaving: Bool { worker != nil }

    private struct Request {
        let value: String
        let save: @Sendable (String) throws -> Void
        let didSave: @MainActor (String) -> Void
        let didFail: @MainActor (Error) -> Void
    }

    init(mode: String) {
        let mode = Self.isValid(mode) ? mode : "system"
        self.mode = mode
        lastSavedMode = mode
    }

    func request(_ value: String, save: @escaping @Sendable (String) throws -> Void,
                 didSave: @escaping @MainActor (String) -> Void, didFail: @escaping @MainActor (Error) -> Void) {
        guard Self.isValid(value) else {
            didFail(LibraryError.invalidInput("未知的外观设置。"))
            return
        }
        guard mode != value else { return }
        mode = value
        pending = Request(value: value, save: save, didSave: didSave, didFail: didFail)
        guard worker == nil else { return }
        worker = Task { await drain() }
    }

    /// A reload must not replace an optimistic preference while its writes are pending.
    func synchronize(_ value: String) {
        guard !isSaving, Self.isValid(value) else { return }
        if mode != value { mode = value }
        lastSavedMode = value
    }

    func flush() async {
        while isSaving {
            await withCheckedContinuation { flushWaiters.append($0) }
        }
    }

    private func drain() async {
        while let request = pending {
            pending = nil
            let save = request.save, value = request.value
            let result: Result<Void, Error>
            do {
                try await Task.detached(priority: .userInitiated) { try save(value) }.value
                lastSavedMode = value
                result = .success(())
            } catch {
                result = .failure(error)
            }
            // The latest request owns the UI and callbacks; stale completions only
            // update the durable rollback point and allow the queued write to proceed.
            guard pending == nil else { continue }
            switch result {
            case .success: request.didSave(value)
            case .failure(let error):
                mode = lastSavedMode
                request.didFail(error)
            }
        }
        worker = nil
        let waiters = flushWaiters
        flushWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private static func isValid(_ value: String) -> Bool { ["system", "light", "dark"].contains(value) }
}
