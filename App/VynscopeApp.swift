import SwiftUI

@main
struct VynscopeApp: App {
    @State private var flow: Flow
    @State private var ai: AIFlow

    init() {
        let flow = Flow()
        self.flow = flow
        ai = AIFlow(flow: flow)
    }

    var body: some Scene {
        WindowGroup {
            FlowView()
                .environment(flow)
                .environment(ai)
                // Text keeps the system's primary color: a foreground style here would recolor every control too,
                // over the tint, a destructive button's red and a prominent button's white label.
                .font(.vyn(.body))
                .background(Color.vynIvory)
                .tint(Color.vynOrange)
        }
        #if os(macOS)
        .defaultSize(width: 420, height: 760)
        #endif

        #if os(macOS)
        // One log window: Log brings it to the front rather than opening another.
        Window("Log", id: "log") {
            LogView()
                .environment(flow)
        }
        #endif
    }
}

/// The current step under the step indicator and its error, with Reconnect there while the adapter is gone, and Back,
/// Log, Settings (the AI step has its own) and Next in the toolbar.
struct FlowView: View {
    @Environment(Flow.self) private var flow
    @State private var showingSettings = false

    var body: some View {
        @Bindable var flow = flow
        NavigationStack {
            VStack(spacing: 0) {
                StepIndicator()
                if let error = flow.error ?? gaveUp {
                    Text(error)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }
                if flow.step != .connect, flow.diag == nil || gaveUp != nil {
                    Button("Reconnect") { Task { await flow.reconnect() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(flow.busy || flow.reconnecting)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.top, 4)
                }
                switch flow.step {
                case .connect: ConnectStep()
                case .car: CarStep()
                case .modules: ModulesStep()
                case .backup: BackupStep()
                case .ai: AIStep()
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            // The navigation stack paints its own background over the window's; this one reaches under its bar.
            .background(Color.vynIvory)
            .navigationTitle(Text(flow.step.title))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                if flow.step != .connect {
                    ToolbarItem(placement: .navigation) {
                        Button("Back") { flow.back() }
                            .disabled(flow.backupTask != nil)
                    }
                }
                ToolbarItem { LogButton() }
                if flow.step != .ai {
                    ToolbarItem {
                        Button("Settings", systemImage: "gear") { showingSettings = true }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(flow.step == .ai ? "Done" : "Next") { flow.next() }
                        .disabled(!flow.canGoNext)
                }
            }
            .sheet(isPresented: $showingSettings) { AISettingsView() }
        }
        #if os(iOS)
        .sheet(isPresented: $flow.showingLog) {
            NavigationStack { LogView() }
        }
        #endif
    }

    /// The link's message once it has given up, on any step but Connect, whose adapter row says it; it stands in for
    /// the error when no action failed with it, as when nothing was running.
    private var gaveUp: String? {
        guard flow.step != .connect, case .failed(let message) = flow.link.state else { return nil }
        return message
    }
}

/// The steps by number and title, the current one bold in the accent; Connect in the warning color while the link
/// reconnects or warns, unless it is the current one.
struct StepIndicator: View {
    @Environment(Flow.self) private var flow

    var body: some View {
        HStack {
            ForEach(Step.allCases, id: \.self) { step in
                let current = step == flow.step
                let warned = step == .connect && (flow.reconnecting || flow.link.warning != nil)
                Text(step.indicatorLabel)
                    .font(current ? .vyn(.caption, weight: .bold) : .vyn(.caption))
                    .foregroundStyle(current ? Color.vynOrange : warned ? Color.vynOrangeDark : Color.vynMuted)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 8)
    }
}
