import Foundation
import Combine

/// Keep unsaved connection edits when switching settings tabs or returning to chat.
@MainActor final class AISettingsModel: ObservableObject {
    @Published var value: AIConfiguration {
        didSet {
            guard !restoring, value != oldValue else { return }
            if value.endpoint != oldValue.endpoint { key = ""; keyLoaded = true; loaded = true }
            cancelTest()
        }
    }
    @Published var key = "" { didSet { if !restoring, key != oldValue { cancelTest() } } }
    @Published private(set) var message = ""
    @Published private(set) var testing = false
    @Published private(set) var keyLoaded = false
    @Published private(set) var succeeded = false
    private var savedValue: AIConfiguration
    private var savedKey = ""
    private var savedKeyLoaded = false
    private var loaded = false
    private var restoring = false
    private var testTask: Task<Void, Never>?
    private var generation = UUID()
    private let controller: AIChatController
    private let readKey: (AIConfiguration) throws -> String
    private let persist: (AIConfiguration, String) throws -> Void
    private let probe: (AIConfiguration, String) async throws -> Void

    init(controller: AIChatController,
         readKey: @escaping (AIConfiguration) throws -> String = AIKeychain.read,
         persist: ((AIConfiguration, String) throws -> Void)? = nil,
         probe: ((AIConfiguration, String) async throws -> Void)? = nil) {
        self.controller = controller
        value = controller.configuration; savedValue = controller.configuration
        self.readKey = readKey
        self.persist = persist ?? { try controller.updateConfiguration($0, key: $1) }
        self.probe = probe ?? { try await AIChatClient(configuration: $0, key: $1).testConnection() }
    }
    deinit { testTask?.cancel() }
    var hasChanges: Bool { value != savedValue || key != savedKey }
    var canUseConnection: Bool { loaded && keyLoaded && value.isConfigured && !testing && !controller.isRunning }

    func load() {
        guard !loaded else { return }
        restoring = true
        defer { restoring = false }
        do {
            key = value.isConfigured ? try readKey(value) : ""
            savedKey = key; savedKeyLoaded = true; keyLoaded = true; loaded = true; message = ""
        } catch {
            keyLoaded = false; message = error.localizedDescription + " 解锁钥匙串后点击重新读取。"
        }
    }
    func restore() {
        cancelTest(); restoring = true
        value = savedValue; key = savedKey
        keyLoaded = savedKeyLoaded; loaded = savedKeyLoaded
        restoring = false
        // Retry a previous keychain failure instead of treating an unread key as empty.
        if !loaded { load() }
    }
    func save() {
        guard canUseConnection, hasChanges else { return }
        do {
            try persist(value, key)
            savedValue = value; savedKey = key; savedKeyLoaded = true
            succeeded = true; message = "配置已保存，可返回 AI 助手开始对话。"
        } catch { succeeded = false; message = error.localizedDescription }
    }
    func cancelTest() {
        generation = UUID(); testTask?.cancel(); testTask = nil
        testing = false; message = ""; succeeded = false
    }
    func test() {
        guard canUseConnection else { return }
        cancelTest(); testing = true
        let expected = generation, configuration = value, credential = key, probe = probe
        testTask = Task { [weak self] in
            do {
                try await probe(configuration, credential)
                guard !Task.isCancelled, let self, self.generation == expected else { return }
                self.succeeded = true; self.message = "连接成功，模型支持工具调用。"
            } catch {
                guard !Task.isCancelled, let self, self.generation == expected else { return }
                self.succeeded = false; self.message = error.localizedDescription
            }
            guard let self, self.generation == expected else { return }
            self.testing = false; self.testTask = nil
        }
    }
}
