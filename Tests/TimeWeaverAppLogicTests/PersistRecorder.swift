import Foundation
@testable import TimeWeaverAppLogic

final class PersistRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var settingsCountValue = 0
    private var aiKeysValue: [String] = []

    var settingsCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return settingsCountValue
    }

    var aiKeys: [String] {
        lock.lock()
        defer { lock.unlock() }
        return aiKeysValue
    }

    func saveSettings(_ settings: AppSettings) {
        lock.lock()
        settingsCountValue += 1
        lock.unlock()
    }

    func saveAIAPIKey(_ key: String) {
        lock.lock()
        aiKeysValue.append(key)
        lock.unlock()
    }
}
