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
    @Environment(AIFlow.self) private var ai
    @State private var showingSettings = false

    var body: some View {
        @Bindable var flow = flow
        NavigationStack {
            VStack(spacing: 0) {
                StepIndicator()
                if let error = flow.error ?? reconnectReason {
                    Text(error)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }
                if reconnectReason != nil {
                    Button(flow.busy ? "Reconnecting…" : "Reconnect") {
                        Task {
                            await flow.reconnect()
                            if flow.diag != nil { ai.error = nil }  // the AI step's line that asked for it
                        }
                    }
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

    /// Why the step offers Reconnect, on any step but Connect (whose adapter row says how the link is): the link's
    /// message once it has given up, else, while an action's error dropped the adapter (`Flow.explain`), that it needs
    /// setting up. It stands in for the error when none shows: nothing was running, or Back or Next cleared it.
    private var reconnectReason: String? {
        guard flow.step != .connect else { return nil }
        if case .failed(let message) = flow.link.state { return message }
        return flow.diag == nil ? "The adapter needs to be set up again." : nil
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
