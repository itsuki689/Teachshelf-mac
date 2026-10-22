import Foundation
import Testing
@testable import Teachshelf

@MainActor struct AppearancePreferenceTests {
    @Test func slowSavePublishesImmediatelyAndFlushWaitsWithoutBlockingTheMainActor() async {
        let preference = AppearancePreference(mode: "light"), gate = SaveGate()
        var saved: [String] = [], failures = 0, flushed = false
        preference.request("dark", save: { try gate.save($0) },
                           didSave: { saved.append($0) }, didFail: { _ in failures += 1 })
        #expect(preference.mode == "dark")
        #expect(preference.isSaving)
        await gate.waitForStarts(1)

        var flush: Task<Void, Never>?
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            flush = Task { @MainActor in
                started.resume()
                await preference.flush()
                flushed = true
            }
        }
        let mainActorContinues = await Task { @MainActor in true }.value
        #expect(mainActorContinues)
        #expect(!flushed)
        #expect(saved.isEmpty)
        gate.finishNext()
        await flush?.value
        #expect(flushed)
        #expect(!preference.isSaving)
        #expect(preference.mode == "dark")
        #expect(saved == ["dark"])
        #expect(failures == 0)
    }

    @Test func rapidRequestsKeepOnlyTheLatestPendingWriteAndIgnoreReloadsWhileSaving() async {
        let preference = AppearancePreference(mode: "light"), gate = SaveGate()
        var saved: [String] = [], failures = 0
        let save: @Sendable (String) throws -> Void = { try gate.save($0) }
        let didSave: @MainActor (String) -> Void = { saved.append($0) }
        let didFail: @MainActor (Error) -> Void = { _ in failures += 1 }
        preference.request("dark", save: save, didSave: didSave, didFail: didFail)
        await gate.waitForStarts(1)
        preference.request("light", save: save, didSave: didSave, didFail: didFail)
        preference.request("system", save: save, didSave: didSave, didFail: didFail)
        preference.synchronize("light")
        #expect(preference.mode == "system")
        gate.finishNext()
        await gate.waitForStarts(2)
        #expect(gate.values == ["dark", "system"])
        #expect(gate.maximumConcurrentSaves == 1)
        #expect(preference.mode == "system")
        #expect(saved.isEmpty)
        gate.finishNext()
        await preference.flush()
        #expect(saved == ["system"])
        #expect(failures == 0)
        #expect(preference.mode == "system")
    }

    @Test func aFinalFailureRollsBackToTheLatestSuccessfulDiskWrite() async {
        let preference = AppearancePreference(mode: "light"), gate = SaveGate()
        var saved: [String] = [], failures = 0
        let save: @Sendable (String) throws -> Void = { try gate.save($0) }
        let didSave: @MainActor (String) -> Void = { saved.append($0) }
        let didFail: @MainActor (Error) -> Void = { _ in failures += 1 }
        preference.request("dark", save: save, didSave: didSave, didFail: didFail)
        await gate.waitForStarts(1)
        preference.request("system", save: save, didSave: didSave, didFail: didFail)
        gate.finishNext()
        await gate.waitForStarts(2)
        gate.finishNext(.failure(SaveError.failed))
        await preference.flush()
        #expect(preference.mode == "dark")
        #expect(saved.isEmpty)
        #expect(failures == 1)
        #expect(!preference.isSaving)
    }

    @Test func anIntermediateFailureDoesNotCancelOrRollBackANewerRequest() async {
        let preference = AppearancePreference(mode: "light"), gate = SaveGate()
        var saved: [String] = [], failures = 0
        let save: @Sendable (String) throws -> Void = { try gate.save($0) }
        let didSave: @MainActor (String) -> Void = { saved.append($0) }
        let didFail: @MainActor (Error) -> Void = { _ in failures += 1 }
        preference.request("dark", save: save, didSave: didSave, didFail: didFail)
        await gate.waitForStarts(1)
        preference.request("system", save: save, didSave: didSave, didFail: didFail)
        gate.finishNext(.failure(SaveError.failed))
        await gate.waitForStarts(2)
        #expect(preference.mode == "system")
        #expect(failures == 0)
        gate.finishNext()
        await preference.flush()
        #expect(preference.mode == "system")
        #expect(saved == ["system"])
        #expect(failures == 0)
    }

    @Test func idleSynchronizationUpdatesTheRollbackPointAndInvalidModesNeverSave() async {
        let preference = AppearancePreference(mode: "invalid"), gate = SaveGate()
        var failures = 0, saved: [String] = []
        #expect(preference.mode == "system")
        preference.synchronize("dark")
        preference.synchronize("invalid")
        preference.request("invalid", save: { try gate.save($0) },
                           didSave: { saved.append($0) }, didFail: { _ in failures += 1 })
        await preference.flush()
        #expect(preference.mode == "dark")
        #expect(!preference.isSaving)
        #expect(gate.values.isEmpty)
        #expect(failures == 1)
        preference.request("light", save: { try gate.save($0) },
                           didSave: { saved.append($0) }, didFail: { _ in failures += 1 })
        await gate.waitForStarts(1)
        preference.synchronize("system")
        gate.finishNext(.failure(SaveError.failed))
        await preference.flush()
        #expect(preference.mode == "dark")
        #expect(saved.isEmpty)
        #expect(failures == 2)
    }

    private enum SaveError: Error { case failed }

    /// The worker blocks here; tests wait asynchronously for each write to start.
    private final class SaveGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var recordedValues: [String] = []
        private var outcomes: [Result<Void, Error>] = []
        private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
        private var active = 0, maximumActive = 0

        var values: [String] {
            condition.lock(); defer { condition.unlock() }; return recordedValues
        }
        var maximumConcurrentSaves: Int {
            condition.lock(); defer { condition.unlock() }; return maximumActive
        }

        func save(_ value: String) throws {
            condition.lock()
            active += 1; maximumActive = max(maximumActive, active)
            recordedValues.append(value)
            let ready = waiters.filter { recordedValues.count >= $0.0 }
            waiters.removeAll { recordedValues.count >= $0.0 }
            ready.forEach { $0.1.resume() }
            while outcomes.isEmpty { condition.wait() }
            let result = outcomes.removeFirst()
            active -= 1
            condition.unlock()
            try result.get()
        }

        func waitForStarts(_ count: Int) async {
            await withCheckedContinuation { continuation in
                condition.lock()
                if recordedValues.count >= count {
                    condition.unlock(); continuation.resume()
                } else {
                    waiters.append((count, continuation)); condition.unlock()
                }
            }
        }

        func finishNext(_ result: Result<Void, Error> = .success(())) {
            condition.lock()
            outcomes.append(result)
            condition.signal()
            condition.unlock()
        }
    }
}
