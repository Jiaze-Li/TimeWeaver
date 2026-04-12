import Foundation

protocol SyncStateStoreProtocol {
    func loadState() -> SyncState
    func saveState(_ state: SyncState)
}

struct DefaultSyncStateStore: SyncStateStoreProtocol {
    func loadState() -> SyncState { SettingsStore.loadState() }
    func saveState(_ state: SyncState) { SettingsStore.saveState(state) }
}
