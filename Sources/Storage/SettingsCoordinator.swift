import Foundation

final class SettingsCoordinator {
    private let loadSettingsImpl: () -> AppSettings
    private let loadAIAPIKeyImpl: () -> String
    private let saveAIAPIKeyImpl: (String) -> Void
    private let saveSettingsImpl: (AppSettings) -> Void
    private let persistExecutor: (@escaping () -> Void) -> Void

    private var lastPersistedSettingsData = Data()
    private var lastPersistedAIAPIKey = ""

    init(
        loadSettings: @escaping () -> AppSettings = { SettingsStore.loadSettings() },
        loadAIAPIKey: @escaping () -> String = { KeychainStore.loadAIAPIKey() },
        saveAIAPIKey: @escaping (String) -> Void = { KeychainStore.saveAIAPIKey($0) },
        saveSettings: @escaping (AppSettings) -> Void = { SettingsStore.saveSettings($0) },
        persistExecutor: @escaping (@escaping () -> Void) -> Void = { work in
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
        persistExecutor { [saveAIAPIKeyImpl, saveSettingsImpl] in
            saveAIAPIKeyImpl(aiAPIKey)
            saveSettingsImpl(settings)
        }
    }
}
