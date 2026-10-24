import Foundation
import Testing
import TeachshelfCore
@testable import Teachshelf

@Suite(.serialized) @MainActor final class AISettingsTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AISettings-\(UUID())")
    let defaultsName = "AISettings-\(UUID())"
    var defaults: UserDefaults { UserDefaults(suiteName: defaultsName)! }
    let original = AIConfiguration(endpoint: "https://first.example/v1", model: "existing-model")
    deinit {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removePersistentDomain(forName: defaultsName)
    }
    func makeStore() throws -> AppStore {
        let store = AppStore(repository: try LibraryRepository(root: root), remembersLocation: false)
        try original.save(defaults: defaults)
        store.assistant = AIChatController(store: store, defaults: defaults)
        return store
    }

    @Test func existingConfigurationAndDraftSurviveNavigationUntilExplicitSave() throws {
        let store = try makeStore()
        var saves: [(AIConfiguration, String)] = [], reads = 0
        store.assistantSettings = AISettingsModel(controller: store.assistant, readKey: { _ in
            reads += 1; return "existing-key"
        }, persist: { saves.append(($0, $1)) })
        let model = store.assistantSettings
        model.load()
        #expect(model.value == original && model.key == "existing-key" && !model.hasChanges)
        model.value.model = "draft-model"
        store.openSettings(.mcp); store.openSettings(.assistant)
        model.load()
        #expect(store.assistantSettings === model && model.value.model == "draft-model")
        #expect(reads == 1 && saves.isEmpty)
        #expect(AIConfiguration.load(defaults: defaults) == original)
        model.restore()
        #expect(model.value == original && model.key == "existing-key" && !model.hasChanges)
        model.value.endpoint = "https://second.example/v1"
        #expect(model.key.isEmpty) // Never forward the old endpoint's credential.
        model.key = "new-key"; model.save()
        #expect(saves.count == 1 && saves.first?.0 == model.value && saves.first?.1 == "new-key")
        #expect(!model.hasChanges && model.succeeded)
        model.value.model = "another-draft"; model.restore()
        #expect(model.value.model == original.model && model.key == "new-key")
    }

    @Test func unreadKeyCannotBeAccidentallyReplacedWithAnEmptyKey() throws {
        let store = try makeStore()
        var failRead = true, saves = 0
        let model = AISettingsModel(controller: store.assistant, readKey: { _ in
            if failRead { throw PlanMCPError("钥匙串不可用") }
            return "preserved-key"
        }, persist: { _, _ in saves += 1 })
        model.load(); model.value.model = "changed"
        #expect(!model.keyLoaded && !model.canUseConnection)
        model.save(); #expect(saves == 0)
        model.value.endpoint = "https://other.example/v1"
        #expect(model.canUseConnection && model.key.isEmpty)
        model.restore()
        #expect(model.value == original && !model.keyLoaded && !model.canUseConnection)
        failRead = false; model.load()
        #expect(model.key == "preserved-key" && model.canUseConnection && !model.hasChanges)
    }

    @Test func failedSaveKeepsDraftAndOriginalRestorePoint() throws {
        let store = try makeStore()
        let model = AISettingsModel(controller: store.assistant, readKey: { _ in "old-key" }, persist: { _, _ in
            throw PlanMCPError("无法保存密钥")
        })
        model.load(); model.value.model = "edited"; model.key = "edited-key"; model.save()
        #expect(model.hasChanges && !model.succeeded && model.message == "无法保存密钥")
        model.restore()
        #expect(model.value == original && model.key == "old-key" && !model.hasChanges)
    }

    @Test func editingOrLeavingCancelsProbeAndIgnoresLateSuccessWithoutSaving() async throws {
        let store = try makeStore()
        var continuation: CheckedContinuation<Void, Never>?, saves = 0
        let model = AISettingsModel(controller: store.assistant, readKey: { _ in "" }, persist: { _, _ in saves += 1 }, probe: { config, key in
            #expect(config.isConfigured && key.isEmpty)
            await withCheckedContinuation { continuation = $0 }
        })
        model.load()
        for edit in [true, false] {
            model.test()
            for _ in 0..<100 { if continuation != nil { break }; await Task.yield() }
            let response = try #require(continuation); continuation = nil
            #expect(model.testing)
            if edit { model.value.model = "edited" } else { model.cancelTest() }
            response.resume()
            for _ in 0..<20 { await Task.yield() }
            #expect(!model.testing && !model.succeeded && model.message.isEmpty)
        }
        #expect(saves == 0 && AIConfiguration.load(defaults: defaults) == original)
    }

    @Test func modelSettingsShortcutHonorsUnsavedEditorAndBackNavigation() throws {
        let store = try makeStore()
        store.navigate(to: .assistant)
        store.beforeLeavingMaterial = { false }
        store.openSettings(.assistant)
        #expect(store.navigation == .assistant && store.settingsSection == .appearance)
        store.beforeLeavingMaterial = nil
        store.openSettings(.assistant)
        #expect(store.navigation == .settings && store.settingsSection == .assistant)
        store.goBack()
        #expect(store.navigation == .assistant)
    }
}
