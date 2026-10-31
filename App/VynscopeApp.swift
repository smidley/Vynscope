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
            RootView()
                .environment(flow)
                .environment(ai)
                // Text keeps the system's primary color: a foreground style here would recolor every control too,
                // over the tint, a destructive button's red and a prominent button's white label.
                .font(.vyn(.body))
                .background(Color.vynIvory)
                .tint(Color.vynOrange)
        }
        #if os(macOS)
        .defaultSize(width: 720, height: 760)
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

/// The four tabs, a navigation stack each: a tab bar on the iPhone, a sidebar on the Mac. The iPhone's Log sheet
/// opens over whichever tab is on screen. At launch it connects to the saved adapter by itself.
struct RootView: View {
    @Environment(Flow.self) private var flow

    var body: some View {
        @Bindable var flow = flow
        // The owner's own tab pick clears the last action's error, as Next and Back did; a switch the flow makes keeps
        // its reason.
        TabView(selection: Binding(get: { flow.tab }, set: { flow.tab = $0; flow.error = nil })) {
            Tab("Car", systemImage: "car", value: .car) {
                NavigationStack { CarTab().tabRoot("Car") }
            }
            Tab("Diagnostics", systemImage: "stethoscope", value: .diagnostics) {
                NavigationStack { FaultCodesView().tabRoot("Fault codes") }
            }
            Tab("Programming", systemImage: "cpu", value: .programming) {
                NavigationStack { ModulesStep().tabRoot("Modules") }
            }
            Tab("Settings", systemImage: "gear", value: .settings) {
                NavigationStack { AISettingsView().tabRoot("Settings") }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .task {
            // Once per launch, not per window: after that, connecting again is the owner's to ask for, after a
            // Disconnect, a give-up or a Reconnect that failed.
            guard !flow.autoConnectAttempted else { return }
            flow.autoConnectAttempted = true
            if flow.link.state == .off, flow.adapter == nil,
               UserDefaults.standard.string(forKey: Flow.adapterKey) != nil {
                await flow.connect()
            }
        }
        #if os(iOS)
        .sheet(isPresented: $flow.showingLog) {
            NavigationStack { LogView() }
        }
        #endif
    }
}

private extension View {
    /// A tab's root screen: its title inline and Log in the toolbar, over ivory that reaches under the bar, where the
    /// navigation stack paints its own background over the window's.
    func tabRoot(_ title: LocalizedStringKey) -> some View {
        navigationTitle(title)
            .toolbarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem { LogButton() } }
            .background(Color.vynIvory)
    }
}
