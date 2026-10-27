import BMWCodingCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Reads the coding data of every listed module into one backup file.
struct BackupStep: View {
    @Environment(Flow.self) private var flow
    /// The file the last run wrote, read back for the modules it marks partial.
    @State private var saved: Backup? = nil
    @State private var firstBackup = false

    var body: some View {
        let running = flow.backupTask != nil
        Form {
            Section {
                if firstBackup {
                    Text("""
                        The first backup of this car reads every identifier of every module and takes about an hour. \
                        Keep the ignition on and this device near the car. Later backups take minutes.
                        """)
                }
                Button("Back up") { flow.backup(fullRescan: false) }
                    .disabled(running)
                Button("Full rescan") { flow.backup(fullRescan: true) }
                    .disabled(running)
                if running {
                    Button("Cancel", role: .cancel) { flow.cancelBackup() }
                }
                #if os(macOS)
                Button("Choose folder") { chooseFolder() }
                    .disabled(running)
                #endif
            } footer: {
                #if os(macOS)
                Text("""
                    One file per run, in Backups inside the chosen folder (Documents › BMW Coding until one is \
                    chosen). Full rescan reads every identifier again.
                    """)
                #else
                Text("""
                    One file per run, in Files: On My iPhone › BMW Coding › Backups. Full rescan reads every \
                    identifier again.
                    """)
                #endif
            }
            if running, let progress = flow.progress {
                Section {
                    ProgressView(value: overall(progress)) {
                        Text("Module \(progress.moduleIndex + 1) of \(progress.moduleCount)")
                    } currentValueLabel: {
                        Text("\(progress.didsDone) of \(progress.didsTotal) identifiers")
                    }
                }
            }
            Section("Modules") {
                ForEach(flow.modules) { module in
                    BackupRow(
                        title: module.title, state: flow.progress?.states[module.address],
                        partial: partialReason(module.address))
                }
            }
            if let url = flow.lastBackup {
                Section("Saved") {
                    Text(url.path)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .task(id: flow.lastBackup) {
            saved = flow.lastBackup == nil ? nil : flow.latestBackup()
            firstBackup = flow.isFirstBackup()
        }
    }

    /// How far the whole run is: modules done plus the part of the current one.
    private func overall(_ progress: BackupProgress) -> Double {
        let current = progress.didsTotal > 0 ? Double(progress.didsDone) / Double(progress.didsTotal) : 0
        return (Double(progress.moduleIndex) + current) / Double(max(progress.moduleCount, 1))
    }

    /// Why the saved file marks the module at `address` partial, or nil when it is complete or not saved.
    private func partialReason(_ address: UInt8) -> String? {
        guard case .partial(reason: let reason)? = saved?.modules.first(where: { $0.address == address })?.status
        else { return nil }
        return reason
    }

    #if os(macOS)
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { flow.useFolder(url) }
    }
    #endif
}

/// One module of the run: where it stands, and why the file marks it partial when it does.
struct BackupRow: View {
    let title: String
    let state: BackupProgress.ModuleState?
    let partial: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).monospaced()
                Spacer()
                switch state {
                case .waiting?:
                    Text("waiting").foregroundStyle(.secondary)
                case .reading?:
                    Text("reading…")
                case .done(let identifiers, let bytes)?:
                    let mark = partial == nil ? " ✓" : ""
                    Text("^[\(identifiers) identifier](inflect: true) · \(sizeText(bytes))\(mark)")
                case .failed?:
                    Text("failed").foregroundStyle(.red)
                case nil:
                    EmptyView()
                }
            }
            if case .failed(let why)? = state {
                Text(why).font(.caption).foregroundStyle(.red)
            }
            if let partial {
                Text("Partial: \(partial)").font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

/// A byte count as the file system shows sizes: `24 bytes`, `1.2 kB`.
func sizeText(_ bytes: Int) -> String {
    Int64(bytes).formatted(.byteCount(style: .file, spellsOutZero: false))
}
