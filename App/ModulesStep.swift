import BMWCodingCore
import SwiftUI

/// The modules that answer the scan, listed as they answer; a row opens the module's detail.
struct ModulesStep: View {
    @Environment(Flow.self) private var flow

    var body: some View {
        List {
            if flow.discovering, flow.reconnecting {
                Text("Reconnecting to the adapter…")
                    .foregroundStyle(Color.vynMuted)
            } else if flow.discovering {
                ProgressView(value: Double(flow.scanned), total: 255) {
                    Text("Scanning \(String(format: "%02X", flow.scanned)) of FF · \(flow.modules.count) answered so far")
                        .font(.vyn(.footnote))
                        .foregroundStyle(Color.vynMuted)
                }
                .tint(Color.vynOrange)
            } else if flow.modules.isEmpty {
                Button("Scan") { Task { await flow.discover() } }
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
        .task {
            if flow.modules.isEmpty, !flow.discovering, !flow.busy, flow.diag != nil, flow.vin != nil {
                await flow.discover()
            }
        }
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
