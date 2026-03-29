import Foundation
import Security

private let defaultBundleIdentifier = "com.jiaze.timeweaver"
private let legacyAppSupportDirectoryName = "PPMSCalendarSync"
private let appBundleIdentifier = Bundle.main.bundleIdentifier ?? defaultBundleIdentifier

private let appSupportDirectory = appSupportBaseDirectory()
    .appendingPathComponent(appBundleIdentifier, isDirectory: true)
private let legacyAppSupportDirectory = appSupportBaseDirectory()
    .appendingPathComponent(legacyAppSupportDirectoryName, isDirectory: true)
private let settingsURL = appSupportDirectory.appendingPathComponent("settings.json")
private let stateURL = appSupportDirectory.appendingPathComponent("sync-state.json")

private let aiKeychainService = "TimeWeaver"
private let aiKeychainServiceLegacy = "PPMSCalendarSync"
private let aiKeychainAccount = "ai-api-key"

final class KeychainStore {
    static func loadAIAPIKey() -> String {
        // Try current service name first
        if let value = readKeychainItem(service: aiKeychainService) {
            return value
        }
        // Migrate from legacy service name silently
        if let value = readKeychainItem(service: aiKeychainServiceLegacy) {
            saveAIAPIKey(value)
            deleteKeychainItem(service: aiKeychainServiceLegacy)
            return value
        }
        return ""
    }

    private static func readKeychainItem(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: aiKeychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func deleteKeychainItem(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: aiKeychainAccount,
            kSecUseDataProtectionKeychain as String: true
        ]
        SecItemDelete(query as CFDictionary)
        // Also delete from legacy keychain (no data protection) in case it exists there
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: aiKeychainAccount
        ]
        SecItemDelete(legacyQuery as CFDictionary)
    }

    static func saveAIAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: aiKeychainService,
            kSecAttrAccount as String: aiKeychainAccount,
            kSecUseDataProtectionKeychain as String: true
        ]

        if trimmed.isEmpty {
            SecItemDelete(query as CFDictionary)
            return
        }

        let data = Data(trimmed.utf8)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}

final class SettingsStore {
    private static var migrationChecked = false

    private static func ensureStorageReady() throws {
        if !migrationChecked {
            try migrateLegacyStorageIfNeeded()
            migrationChecked = true
        }
        try FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
    }

    private static func migrateLegacyStorageIfNeeded() throws {
        guard legacyAppSupportDirectory != appSupportDirectory else { return }

        var isLegacyDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: legacyAppSupportDirectory.path, isDirectory: &isLegacyDirectory),
              isLegacyDirectory.boolValue else {
            return
        }

        let destinationExists = FileManager.default.fileExists(atPath: appSupportDirectory.path)
        if !destinationExists {
            try FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        }

        let contents = (try? FileManager.default.contentsOfDirectory(at: legacyAppSupportDirectory, includingPropertiesForKeys: nil)) ?? []
        for sourceURL in contents {
            let destinationURL = appSupportDirectory.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: false)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                continue
            }
            try? FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }
    }

    static func loadSettings() -> AppSettings {
        try? ensureStorageReady()
        guard let data = try? Data(contentsOf: settingsURL) else {
            return AppSettings(
                sources: defaultSources(),
                workdayHours: defaultWorkdayHours(),
                schedulingTimeZoneIdentifier: defaultSchedulingTimeZoneIdentifier,
                autoSyncEnabled: false,
                autoSyncMinutes: 15,
                upcomingOnly: true,
                confirmBeforeSync: true,
                confirmBeforeDeletion: true,
                menuBarModeEnabled: false,
                parserMode: .auto,
                aiParser: AIParserSettings(),
                aiApprovals: [],
                lastDraft: nil
            )
        }

        guard let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings(
                sources: defaultSources(),
                workdayHours: defaultWorkdayHours(),
                schedulingTimeZoneIdentifier: defaultSchedulingTimeZoneIdentifier,
                autoSyncEnabled: false,
                autoSyncMinutes: 15,
                upcomingOnly: true,
                confirmBeforeSync: true,
                confirmBeforeDeletion: true,
                menuBarModeEnabled: false,
                parserMode: .auto,
                aiParser: AIParserSettings(),
                aiApprovals: [],
                lastDraft: nil
            )
        }

        let legacyObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let needsWorkdayMigration = legacyObject?["workdayHours"] == nil
        if needsWorkdayMigration {
            var migrated = settings
            migrated.workdayHours = defaultWorkdayHours()
            saveSettings(migrated)
            return migrated
        }

        return settings
    }

    static func saveSettings(_ settings: AppSettings) {
        do {
            try ensureStorageReady()
            let data = try JSONEncoder().encode(settings)
            try data.write(to: settingsURL, options: .atomic)
        } catch {
        }
    }

    static func loadState() -> SyncState {
        try? ensureStorageReady()
        guard
            let data = try? Data(contentsOf: stateURL),
            let state = try? JSONDecoder().decode(SyncState.self, from: data)
        else {
            return SyncState(events: [:])
        }
        return state
    }

    static func saveState(_ state: SyncState) {
        do {
            try ensureStorageReady()
            let data = try JSONEncoder().encode(state)
            try data.write(to: stateURL, options: .atomic)
        } catch {
        }
    }
}

private func appSupportBaseDirectory() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
}
