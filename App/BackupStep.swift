import BMWCodingCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Reads the coding data of every listed module into one backup file.
struct BackupStep: View {
    @Environment(Flow.self) private var flow
    /// The file the last run wrote, read back for the modules it marks complete or partial.
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
                    One file per run, in Backups inside the chosen folder (Documents › Vynscope until one is \
                    chosen). Full rescan reads every identifier again.
                    """)
                    .font(.vyn(.footnote))
                    .foregroundStyle(Color.vynMuted)
                #else
                Text("""
                    One file per run, in Files: On My iPhone › Vynscope › Backups. Full rescan reads every \
                    identifier again.
                    """)
                    .font(.vyn(.footnote))
                    .foregroundStyle(Color.vynMuted)
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
                        status: status(module.address))
                }
            }
            if let url = flow.lastBackup {
                Section("Saved") {
                    Text(url.path)
                        .font(.vyn(.caption))
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.vynIvory)
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

    /// What the saved file says of the module at `address`, or nil when there is no file (a run going on, or one
    /// that ended without writing it) or the module is not in it.
    private func status(_ address: UInt8) -> ModuleBackup.Status? {
        saved?.modules.first(where: { $0.address == address })?.status
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

/// One module of the run: where it stands, and what the saved file says of it: a mark when it is complete, why when
/// it is partial. Without a saved file there is neither, so counts in a run or after an aborted one carry no mark.
struct BackupRow: View {
    let title: String
    let state: BackupProgress.ModuleState?
    let status: ModuleBackup.Status?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.vynMono(.body))
                Spacer()
                switch state {
                case .waiting?:
                    Text("waiting").foregroundStyle(Color.vynMuted)
                case .reading?:
                    Text("reading…")
                case .done(let identifiers, let bytes)?:
                    let mark = status == .complete ? " ✓" : ""
                    Text("^[\(identifiers) identifier](inflect: true) · \(sizeText(bytes))\(mark)")
                case .failed?:
                    Text("failed").foregroundStyle(.red)
                case nil:
                    EmptyView()
                }
            }
            if case .failed(let why)? = state {
                Text(why).font(.vyn(.caption)).foregroundStyle(.red)
            }
            if case .partial(let reason)? = status {
                Text("Partial: \(reason)").font(.vyn(.caption)).foregroundStyle(Color.vynOrangeDark)
            }
        }
    }
}

/// A byte count as the file system shows sizes: `24 bytes`, `1.2 kB`.
func sizeText(_ bytes: Int) -> String {
    Int64(bytes).formatted(.byteCount(style: .file, spellsOutZero: false))
}
