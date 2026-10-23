import BlockerCore
import Foundation
import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()

    private static let extensionRows: [(bundleID: String, name: String)] = [
        (Bundles.contentBlocker(.ads), "bl0cksh1t ads"),
        (Bundles.contentBlocker(.privacy), "bl0cksh1t privacy"),
        (Bundles.contentBlocker(.annoyances), "bl0cksh1t annoyances"),
        (Bundles.contentBlocker(.user), "bl0cksh1t user rules"),
        (Bundles.webExtension, "bl0cksh1t web extension"),
    ]

    var body: some View {
        Form {
            Section("Extensions") {
                if model.allExtensionsEnabled {
                    Label("All extensions enabled — blocking is active.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("Enable the bl0cksh1t extensions in Safari to activate blocking.")
                    Button("Open Extension Settings") { Self.openExtensionSettings() }
                }
                ForEach(Self.extensionRows, id: \.bundleID) { row in
                    HStack {
                        Text(row.name)
                        Spacer()
                        if model.extensionStates[row.bundleID] == true {
                            Text("enabled").foregroundStyle(.secondary)
                        } else {
                            Text("not enabled").foregroundStyle(.orange)
                        }
                    }
                }
            }

            Section("Lists") {
                ForEach(model.listInfos, id: \.id) { info in
                    ListRow(info: info) { enabled in
                        model.setEnabled(enabled, for: info.id)
                    }
                }
            }

            Section("Settings") {
                Picker("Default state for sites without a setting", selection: globalDefaultBinding) {
                    Text("Default — block ads and trackers").tag(GlobalDefaultState.default)
                    Text("Strict — also block third-party scripts").tag(GlobalDefaultState.strict)
                }
                Picker("Update lists every", selection: intervalBinding) {
                    Text("12 hours").tag(12.0)
                    Text("24 hours").tag(24.0)
                    Text("48 hours").tag(48.0)
                }
            }

            Section("Update") {
                HStack {
                    if model.isUpdating {
                        ProgressView()
                        Text("Updating…").foregroundStyle(.secondary)
                    }
                    Button("Update Now") { model.startUpdate() }
                        .disabled(model.isUpdating)
                }
                if let finished = model.updateState.lastFinished {
                    Text("Last update: \(finished.formatted(date: .abbreviated, time: .shortened))")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Never updated — bundled rules are in effect until the first update.")
                        .foregroundStyle(.secondary)
                }
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 600)
        .onAppear {
            model.maybeAutoUpdate()
            model.refreshExtensionStates()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.maybeAutoUpdate()
            model.refreshExtensionStates()
        }
    }

    private var globalDefaultBinding: Binding<GlobalDefaultState> {
        Binding(
            get: { model.store.globalDefault },
            set: { model.setGlobalDefault($0) }
        )
    }

    private var intervalBinding: Binding<Double> {
        Binding(
            get: { model.store.updateIntervalHours },
            set: { model.setUpdateInterval($0) }
        )
    }

    static func openExtensionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Settings.Extensions") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct ListRow: View {
    let info: ListInfo
    let onToggle: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { info.enabled }, set: onToggle)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var detail: String {
        var parts: [String] = []
        if info.ruleCount > 0 {
            parts.append("\(info.ruleCount.formatted()) rules")
        }
        if info.unsupported > 0 {
            parts.append("\(info.unsupported) unsupported")
        }
        if let updated = info.updatedAt {
            parts.append("updated \(updated.formatted(.relative(presentation: .named)))")
        }
        return parts.isEmpty ? "not yet updated" : parts.joined(separator: " · ")
    }
}
