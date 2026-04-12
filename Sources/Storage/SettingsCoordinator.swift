import Foundation

@MainActor
final class SettingsCoordinator {
    private let loadSettingsImpl: () -> AppSettings
    private let loadAIAPIKeyImpl: () -> String
    private let saveAIAPIKeyImpl: @Sendable (String) -> Void
    private let saveSettingsImpl: @Sendable (AppSettings) -> Void
    private let persistExecutor: (@escaping @Sendable () -> Void) -> Void

    private var lastPersistedSettingsData = Data()
    private var lastPersistedAIAPIKey = ""

    init(
        loadSettings: @escaping () -> AppSettings = { SettingsStore.loadSettings() },
        loadAIAPIKey: @escaping () -> String = { KeychainStore.loadAIAPIKey() },
        saveAIAPIKey: @escaping @Sendable (String) -> Void = { KeychainStore.saveAIAPIKey($0) },
        saveSettings: @escaping @Sendable (AppSettings) -> Void = { SettingsStore.saveSettings($0) },
        persistExecutor: @escaping (@escaping @Sendable () -> Void) -> Void = { work in
            Task.detached(priority: .utility) {
                work()
            }
        }
    ) {
        self.loadSettingsImpl = loadSettings
        self.loadAIAPIKeyImpl = loadAIAPIKey
        self.saveAIAPIKeyImpl = saveAIAPIKey
        self.saveSettingsImpl = saveSettings
        self.persistExecutor = persistExecutor
    }

    func loadSettings() -> AppSettings {
        loadSettingsImpl()
    }

    func loadAIAPIKey() -> String {
        loadAIAPIKeyImpl()
    }

    func persistIfNeeded(settings: AppSettings, encodedData: Data, aiAPIKey: String) {
        guard encodedData != lastPersistedSettingsData || aiAPIKey != lastPersistedAIAPIKey else {
            return
        }
        lastPersistedSettingsData = encodedData
        lastPersistedAIAPIKey = aiAPIKey
        let saveAIAPIKey = saveAIAPIKeyImpl
        let saveSettings = saveSettingsImpl
        persistExecutor {
            saveAIAPIKey(aiAPIKey)
            saveSettings(settings)
        }
    }
}
