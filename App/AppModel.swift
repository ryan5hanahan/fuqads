import BlockerCore
import Foundation
import SafariServices
import SwiftUI

/// The app's single source of truth: a projection of the App Group state
/// (BlockerCore.Store) plus the update engine and Safari extension states.
/// The app is throwaway after setup (FR-42): everything persists in the
/// App Group and keeps working without this process.
@MainActor
final class AppModel: ObservableObject {
    @Published var listInfos: [ListInfo] = []
    @Published var updateState = UpdateState()
    @Published var extensionStates: [String: Bool] = [:] // bundleID -> enabled
    @Published private(set) var isUpdating = false
    @Published var errorMessage: String?

    let store: Store
    let engine: UpdateEngine

    private var autoUpdateDone = false

    init() {
        let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Bundles.appGroup
        ) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let store = Store()
        self.store = store
        self.engine = UpdateEngine(
            store: store,
            listStore: ListStore(directory: container.appendingPathComponent("lists")),
            fromBundleURL: Bundle.main.bundleURL
        )
        refresh()
        refreshExtensionStates()
    }

    // MARK: state refresh

    func refresh() {
        listInfos = store.lists.values.sorted { $0.name < $1.name }
        updateState = engine.state
    }

    func refreshExtensionStates() {
        // State arrives via the ObjC bridge on the main queue as plain
        // nonisolated blocks (SafariServices' @MainActor import traps when
        // Safari delivers the XPC reply off-main — see SafariStateBridge.h).
        for shard in Shard.allCases {
            let bundleID = shard.bundleID
            bl0cksh1t_getContentBlockerState(bundleID) { state, _ in
                let enabled = state?.isEnabled ?? false
                MainActor.assumeIsolated {
                    self.extensionStates[bundleID] = enabled
                }
            }
        }
        bl0cksh1t_getWebExtensionState(Bundles.webExtension) { state, _ in
            let enabled = state?.isEnabled ?? false
            MainActor.assumeIsolated {
                self.extensionStates[Bundles.webExtension] = enabled
            }
        }
    }

    // MARK: mutations

    func setEnabled(_ enabled: Bool, for id: String) {
        store.setEnabled(enabled, for: id)
        refresh()
        // Recompile from cached lists — no downloads needed (SPEC §4.1).
        startUpdate(refetch: false)
    }

    func setGlobalDefault(_ value: GlobalDefaultState) {
        store.globalDefault = value
    }

    func setUpdateInterval(_ hours: Double) {
        store.updateIntervalHours = hours
        refresh()
    }

    /// Auto-update on first foregrounding if the last update is stale
    /// (FR-5 is the extension's job; this is the app-side nicety).
    func maybeAutoUpdate() {
        guard !autoUpdateDone else { return }
        autoUpdateDone = true
        let ageHours = engine.state.lastFinished.map { Date().timeIntervalSince($0) / 3600 } ?? .infinity
        if ageHours > store.updateIntervalHours {
            startUpdate(refetch: true)
        }
    }

    func startUpdate(refetch: Bool = true) {
        guard !isUpdating else { return }
        isUpdating = true
        errorMessage = nil
        Task {
            await engine.updateAll(refetch: refetch)
            isUpdating = false
            refresh()
            if let error = engine.state.lastError {
                errorMessage = error
            }
        }
    }

    var allExtensionsEnabled: Bool {
        let all = Shard.allCases.map(\.bundleID) + [Bundles.webExtension]
        return all.allSatisfy { extensionStates[$0] == true }
    }
}
