import SwiftUI

@main
struct SpikeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .onAppear { model.start() }
                .frame(minWidth: 760, minHeight: 560)
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                statusSection
                s4Section
                s3Section
                s2Section
                s5Section
                errorSection
            }
            .padding()
        }
    }

    private var statusSection: some View {
        GroupBox("Status") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Server", value: model.isServerRunning
                    ? "http://127.0.0.1:\(Server.port)"
                    : "starting…")
                LabeledContent("SpikeCB enabled in Safari",
                               value: map(model.cbEnabled))
                LabeledContent("Group container", value: model.groupDir.path)
            }
        }
    }

    private func map(_ b: Bool?) -> String {
        switch b {
        case true: return "yes"
        case false: return "NO — enable in Safari › Settings › Extensions"
        case nil: return "unknown"
        }
    }

    private var s4Section: some View {
        GroupBox("S4 — allowlist (ignore-previous-rules + if-top-url)") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Button rewrites SpikeCB's blockerList.json, reloads, then: open the page in Safari and reload it.")
                HStack {
                    Button("Apply: block mode") { model.apply(mode: .s4Block) }
                    Button("Apply: allow mode") { model.apply(mode: .s4Allow) }
                    Button("Open s4.html") {
                        NSWorkspace.shared.open(model.pagesURL.appendingPathComponent("s4.html"))
                    }
                }
                Text("PASS: block mode → red ad pixel missing + green box hidden; allow mode → both visible.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var s3Section: some View {
        GroupBox("S3 — reload from native handler + 150k latency") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Handler probe rewrites the CB list from the web extension's native handler process. Trigger via Safari extension message (needs extension enabled) or via this app.")
                HStack {
                    Button("App: rewrite + reload 150k") { model.apply(mode: .s3150k) }
                    Button("App: rewrite + reload trivial") { model.apply(mode: .s3Trivial) }
                    Button("Handler: probe 150k (via extension)") { model.triggerHandlerProbe(size: "150k") }
                    Button("Handler: probe trivial (via extension)") { model.triggerHandlerProbe(size: "trivial") }
                }
                Text("Handler probes also run automatically every 5 min while Safari is open (s5-quick alarm).")
                    .font(.callout).foregroundStyle(.secondary)
                LogView(lines: model.s3Lines, placeholder: "no s3.jsonl entries yet")
            }
        }
    }

    private var s2Section: some View {
        GroupBox("S2 — dNR modifyHeaders / initiatorDomains / requestDomains / domainType") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Rules are registered by background.js on install. Open the page in Safari — it self-reports into the log below.")
                HStack {
                    Button("Open s2.html") {
                        NSWorkspace.shared.open(model.pagesURL.appendingPathComponent("s2.html"))
                    }
                }
                LogView(lines: model.s2Lines, placeholder: "no s2.jsonl entries yet (enable the web extension first)")
            }
        }
    }

    private var s5Section: some View {
        GroupBox("S5 — alarms in non-persistent background, app closed") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Alarms: s5-quick every 5 min, s5-hourly every 60 min. To test: QUIT this app, keep Safari open, check back in 48 h (5-min entries appear while Safari is open).")
                LogView(lines: model.s5Lines, placeholder: "no s5.jsonl entries yet")
            }
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let error = model.lastError {
            Text("last error: \(error)")
                .foregroundStyle(.red)
                .font(.callout)
        }
    }
}

struct LogView: View {
    let lines: [String]
    let placeholder: String

    var body: some View {
        ScrollView {
            Text(lines.isEmpty ? placeholder : lines.joined(separator: "\n"))
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 180)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
