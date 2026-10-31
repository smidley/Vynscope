import BMWCodingCore
import SwiftUI

/// The Programming tab's root: Backups, with the date of the car's newest backup, then the modules that answer the
/// scan, listed as they answer; a module's row opens its detail. Scan, or Rescan once modules are listed, in the
/// toolbar.
struct ModulesView: View {
    @Environment(Flow.self) private var flow
    /// The car's newest backup, for the Backups row. Read when the screen appears and when the car or
    /// `Flow.lastBackup` changes, never in `body`, which runs again at every address the scan probes.
    @State private var latest: Backup? = nil

    var body: some View {
        List {
            NavigationLink { BackupsView() } label: {
                LabeledContent("Backups") {
                    Text(latest.map { "last \($0.date.formatted(.dateTime.month(.abbreviated).day()))" }
                        ?? "no backup yet")
                }
            }
            if flow.discovering {
                ScanProgress()
            }
            // Where the first modules will be, until one answers.
            if flow.discovering, flow.modules.isEmpty {
                SkeletonRows()
            }
            ForEach(flow.modules) { module in
                NavigationLink(value: module) {
                    ModuleRow(title: module.title, description: module.description, signed: module.signed)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.vynIvory)
        .connectionLine()
        .navigationDestination(for: DiscoveredModule.self) { ModuleDetailView(module: $0) }
        .toolbar {
            ToolbarItem {
                Button(flow.modules.isEmpty ? "Scan" : "Rescan") { Task { await flow.discover() } }
                    .disabled(flow.busy || flow.diag == nil || flow.gaveUp || flow.vin == nil)
            }
        }
        .task {
            if flow.modules.isEmpty, !flow.discovering, !flow.busy, flow.diag != nil, flow.vin != nil,
               flow.vin != flow.autoScannedVIN {
                flow.autoScannedVIN = flow.vin
                await flow.discover()
            }
        }
        .task(id: [flow.vin, flow.lastBackup?.path]) { latest = flow.latestBackup() }
    }
}

/// A module's name, or its bare address, and what it does, with a badge when its coding is signed.
struct ModuleRow: View {
    let title: String
    let description: String?
    let signed: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title).font(.vynMono(.body))
                if let description {
                    Text(description)
                        .font(.vyn(.caption))
                        .foregroundStyle(Color.vynMuted)
                }
            }
            Spacer()
            if signed {
                Text("signed")
                    .font(.vyn(.caption))
                    .padding(.horizontal, 6)
                    .background(.quaternary, in: .capsule)
            }
        }
    }
}

extension DiscoveredModule {
    /// The name from the module table, or the address when the table has none.
    var title: String { name ?? String(format: "0x%02X", address) }
}

/// For `NavigationLink(value:)`. A scan finds each address once, so the address is enough to hash.
extension DiscoveredModule: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(address) }
}
