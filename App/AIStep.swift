import SwiftUI

/// The AI mechanic. A placeholder until the chat arrives; Settings opens the mechanic's settings.
struct AIStep: View {
    @State private var showingSettings = false

    var body: some View {
        VStack {
            Text("AI")
            Button("Settings") { showingSettings = true }
        }
        .sheet(isPresented: $showingSettings) { AISettingsView() }
    }
}
