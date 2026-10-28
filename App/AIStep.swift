import BMWCodingCore
import SwiftUI

/// The AI mechanic: the notice to sign in, the health check as it runs, or the chat about the connected car, with
/// Settings and New conversation in the toolbar.
struct AIStep: View {
    @Environment(Flow.self) private var flow
    @Environment(AIFlow.self) private var ai
    @State private var showingSettings = false
    @State private var confirmingNew = false

    var body: some View {
        // One container for every state, so that `.task` and `.onDisappear` follow the step, not the state.
        VStack(spacing: 0) {
            if !ai.hasCredentials {
                Form {
                    Section {
                        switch ai.settings.provider {
                        case .anthropic: Text("Enter your Anthropic API key in Settings to switch on the AI mechanic.")
                        case .openai: Text("Sign in to ChatGPT in Settings to switch on the AI mechanic.")
                        }
                        Button("Settings") { showingSettings = true }
                    }
                }
                .formStyle(.grouped)
            } else if flow.diag == nil {
                Form { Text("Not connected") }
                    .formStyle(.grouped)
            } else if case .checking(let step) = ai.phase {
                Form {
                    Section {
                        ProgressView(step)
                        Button("Stop") { ai.stop() }
                    }
                }
                .formStyle(.grouped)
            } else if ai.phase == .idle, ai.conversation == nil {
                Form {
                    Section {
                        Button("Run health check") { Task { await ai.healthCheck() } }
                            .disabled(flow.busy)
                        if let error = ai.error {
                            Text(error).foregroundStyle(.red)
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                ChatView()
            }
        }
        .task { await ai.enter() }
        // Leaving the step (Back, Done) stops a check or a turn. The step change that leaves also removes this view,
        // which then need not see the change; its own disappearance it always sees.
        .onDisappear { ai.stop() }
        .toolbar {
            ToolbarItem {
                Button("Settings", systemImage: "gear") { showingSettings = true }
            }
            ToolbarItem {
                Button("New conversation", systemImage: "square.and.pencil") { confirmingNew = true }
                    .disabled(flow.busy || flow.diag == nil || !ai.hasCredentials)
            }
        }
        .confirmationDialog("Start a new conversation?", isPresented: $confirmingNew) {
            Button("New conversation", role: .destructive) { Task { await ai.newConversation() } }
        } message: {
            Text("This car's conversation is deleted and the health check runs again.")
        }
        .sheet(isPresented: $showingSettings) { AISettingsView() }
    }
}
