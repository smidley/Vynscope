import Foundation
import Testing
@testable import BMWCodingCore

@Test func theListenerCatchesTheRedirectAndAnswersWithAPage() async throws {
    let listener = LoopbackListener()
    let redirect = try await listener.start()
    #expect(redirect.host == "127.0.0.1" && redirect.path == "/auth/callback" && (redirect.port ?? 0) > 0)
    async let caught = listener.callback()
    let other = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(redirect.port ?? 0)/favicon.ico")!)
    #expect((other.1 as? HTTPURLResponse)?.statusCode == 404)
    let hit = URL(string: redirect.absoluteString + "?code=c0de&state=s")!
    let (data, response) = try await URLSession.shared.data(from: hit)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(String(decoding: data, as: UTF8.self).contains("You can close this page"))
    let url = try await caught
    #expect(url.query == "code=c0de&state=s")
    let waiting = Task { try await listener.callback() }
    waiting.cancel()
    await #expect(throws: CancellationError.self) { try await waiting.value }
    listener.stop()
}
