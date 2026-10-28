import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import SafariServices
#endif

/// Where OpenAI's pages open. The sign-in page opens in the owner's default browser on the Mac; on the iPhone in a
/// Safari sheet inside the app, which keeps the app, and the listener waiting for the redirect, in the foreground.
enum ChatGPTBrowser {
    /// Where the owner manages the plan's usage and the app's limit.
    static let usagePage = URL(string: "https://chatgpt.com/settings/usage")!

    #if os(macOS)
    /// Opens `url` in the default browser; false when it could not.
    static func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    /// Asks for the app to come back to the front once the browser has handed the sign-in back.
    static func returnToApp() {
        NSApp.activate()
    }
    #else
    /// The sign-in page in `SFSafariViewController`; the sheet that shows it reports its dismissal.
    struct SafariSheet: UIViewControllerRepresentable {
        let url: URL

        func makeUIViewController(context: Context) -> SFSafariViewController {
            SFSafariViewController(url: url)
        }

        func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
    }
    #endif
}

/// For `sheet(item:)`, which shows the sign-in page while the URL is set.
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
