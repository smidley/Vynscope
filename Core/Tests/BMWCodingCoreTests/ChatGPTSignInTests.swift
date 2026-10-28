import Foundation
import Testing
@testable import BMWCodingCore

let redirect = URL(string: "http://127.0.0.1:1455/auth/callback")!
let attempt = SignInAttempt(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "st4te", nonce: "n0nce")

@Test func thePKCEChallengeFollowsRFC7636() {
    #expect(attempt.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    let random = SignInAttempt.random()
    #expect(random.verifier.count >= 43 && random.state != random.nonce)
}

@Test func theFirstSignInRegistersAndALaterOneReusesTheClient() throws {
    let first = ChatGPTSignIn.authorizationURL(hostID: "urn:uuid:1234", clientID: nil, attempt: attempt, redirect: redirect, idTokenHint: nil, loginHint: nil)
    let query = try #require(URLComponents(url: first, resolvingAgainstBaseURL: false)?.queryItems).reduce(into: [String: String]()) { $0[$1.name] = $1.value }
    #expect(first.absoluteString.hasPrefix("https://auth.openai.com/api/accounts/authorize?"))
    #expect(query["client_id"] == "dynamic_agent_client" && query["agent_name_hint"] == "Vynscope")
    #expect(query["ext_agent_host_id"] == "urn:uuid:1234" && query["response_type"] == "code")
    #expect(query["redirect_uri"] == "http://127.0.0.1:1455/auth/callback" && query["resource"] == "https://api.openai.com/v1")
    #expect(query["scope"] == "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
    #expect(query["state"] == "st4te" && query["nonce"] == "n0nce")
    #expect(query["code_challenge"] == attempt.challenge && query["code_challenge_method"] == "S256")
    let later = ChatGPTSignIn.authorizationURL(hostID: "urn:uuid:1234", clientID: "oaiapp_abc", attempt: attempt, redirect: redirect, idTokenHint: "eyJ.id.token", loginHint: "scott@example.com")
    let laterQuery = try #require(URLComponents(url: later, resolvingAgainstBaseURL: false)?.queryItems).reduce(into: [String: String]()) { $0[$1.name] = $1.value }
    #expect(laterQuery["client_id"] == "oaiapp_abc" && laterQuery["agent_name_hint"] == nil)
    #expect(laterQuery["id_token_hint"] == "eyJ.id.token" && laterQuery["login_hint"] == "scott@example.com")
    // In the order of OpenAI's sign-in page, every value percent-encoded (the page's own example: user%40example.com).
    #expect(URLComponents(url: later, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) == [
        "client_id", "ext_agent_host_id", "id_token_hint", "login_hint", "response_type", "redirect_uri", "scope", "resource",
        "state", "nonce", "code_challenge_method", "code_challenge",
    ])
    #expect(later.absoluteString.contains("login_hint=scott%40example.com"))
}

@Test func theCallbackIsCheckedBeforeAnythingIsExchanged() throws {
    let good = URL(string: "http://127.0.0.1:1455/auth/callback?code=c0de&state=st4te&scope=openid&client_id=oaiapp_abc")!
    #expect(try ChatGPTSignIn.parseCallback(good, expectedState: "st4te", expectedClientID: nil) == Callback(code: "c0de", state: "st4te", clientID: "oaiapp_abc"))
    #expect(throws: SignInError.stateMismatch) { try ChatGPTSignIn.parseCallback(good, expectedState: "other", expectedClientID: nil) }
    #expect(throws: SignInError.denied) { try ChatGPTSignIn.parseCallback(URL(string: "http://127.0.0.1:1455/auth/callback?error=access_denied&state=st4te")!, expectedState: "st4te", expectedClientID: nil) }
    // OpenAI's sign-in page: the state is checked before an `error` is believed.
    #expect(throws: SignInError.stateMismatch) { try ChatGPTSignIn.parseCallback(URL(string: "http://127.0.0.1:1455/auth/callback?error=access_denied&state=forged")!, expectedState: "st4te", expectedClientID: nil) }
    #expect(throws: SignInError.registrationIncomplete) { try ChatGPTSignIn.parseCallback(URL(string: "http://127.0.0.1:1455/auth/callback?code=c&state=st4te")!, expectedState: "st4te", expectedClientID: nil) }
    #expect(throws: SignInError.clientMismatch) { try ChatGPTSignIn.parseCallback(good, expectedState: "st4te", expectedClientID: "oaiapp_other") }
    // With no account held (after a sign-out) another client id is a new registration.
    #expect(try ChatGPTSignIn.parseCallback(good, expectedState: "st4te", expectedClientID: "oaiapp_other", accountHeld: false).clientID == "oaiapp_abc")
    #expect(try ChatGPTSignIn.parseCallback(URL(string: "http://127.0.0.1:1455/auth/callback?code=c&state=st4te")!, expectedState: "st4te", expectedClientID: "oaiapp_abc").clientID == nil)
    // The registration's own client id is never the issued one, whatever is held.
    let registration = URL(string: "http://127.0.0.1:1455/auth/callback?code=c&state=st4te&client_id=dynamic_agent_client")!
    #expect(throws: SignInError.registrationIncomplete) { try ChatGPTSignIn.parseCallback(registration, expectedState: "st4te", expectedClientID: nil) }
    #expect(throws: SignInError.registrationIncomplete) { try ChatGPTSignIn.parseCallback(registration, expectedState: "st4te", expectedClientID: "oaiapp_abc", accountHeld: false) }
    #expect(throws: SignInError.registrationIncomplete) { try ChatGPTSignIn.parseCallback(registration, expectedState: "st4te", expectedClientID: "oaiapp_abc") }
}

@Test func everyCallbackErrorIsReported() {
    let parse = { (query: String) in
        try ChatGPTSignIn.parseCallback(URL(string: "http://127.0.0.1:1455/auth/callback?\(query)&state=st4te")!, expectedState: "st4te", expectedClientID: nil)
    }
    #expect(throws: SignInError.callbackError(code: "server_error", description: "Try later")) { try parse("error=server_error&error_description=Try%20later") }
    #expect(throws: SignInError.callbackError(code: "temporarily_unavailable", description: nil)) { try parse("error=temporarily_unavailable") }
    #expect(throws: SignInError.denied) { try parse("error=access_denied") }
}

@Test func theTokenRequestsAreFormEncodedWithoutASecret() throws {
    let exchange = ChatGPTSignIn.exchangeRequest(code: "c0de", attempt: attempt, clientID: "oaiapp_abc", redirect: redirect)
    #expect(exchange.url == ChatGPT.tokenEndpoint && exchange.httpMethod == "POST")
    #expect(exchange.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    let form = String(decoding: try #require(exchange.httpBody), as: UTF8.self)
    #expect(form.contains("grant_type=authorization_code") && form.contains("code=c0de") && form.contains("client_id=oaiapp_abc"))
    #expect(form.contains("code_verifier=\(attempt.verifier)") && form.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A1455%2Fauth%2Fcallback"))
    #expect(form.contains("resource=https%3A%2F%2Fapi.openai.com%2Fv1") && !form.contains("client_secret"))
    let refresh = String(decoding: try #require(ChatGPTSignIn.refreshRequest(refreshToken: "rt", clientID: "oaiapp_abc").httpBody), as: UTF8.self)
    #expect(refresh.contains("grant_type=refresh_token") && refresh.contains("refresh_token=rt") && !refresh.contains("scope="))
    let revoke = ChatGPTSignIn.revokeRequest(refreshToken: "rt", clientID: "oaiapp_abc")
    #expect(revoke.url == ChatGPT.revocationEndpoint)
    #expect(String(decoding: try #require(revoke.httpBody), as: UTF8.self) == "token=rt&token_type_hint=refresh_token&client_id=oaiapp_abc")
}

@Test func aTokenResponseParsesAndAnErrorOneThrows() throws {
    let data = Data(#"{"access_token":"at","refresh_token":"rt","id_token":"it","token_type":"Bearer","expires_in":3600,"scope":"openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"}"#.utf8)
    let response = try TokenResponse.parse(data)
    #expect(response.accessToken == "at" && response.refreshToken == "rt" && response.expiresIn == 3600)
    #expect(response.scopes.contains("chatgpt.tokens.use.direct"))
    #expect(throws: SignInError.tokenEndpoint(status: 400, error: "invalid_grant", description: "expired")) {
        try TokenResponse.parse(Data(#"{"error":"invalid_grant","error_description":"expired"}"#.utf8), status: 400)
    }
}

/// A token signed by a throwaway 2048-bit RSA key made with `openssl` when this test was written, with iss
/// https://auth.openai.com, aud oaiapp_abc, sub user_1, nonce n0nce, email scott@example.com, exp
/// 2030-01-01T00:00:00Z; the JWK holds that key's n and e under kid "k1". The private key was not kept.
enum signedIDToken {
    static let jwt = "eyJhbGciOiJSUzI1NiIsImtpZCI6ImsxIiwidHlwIjoiSldUIn0.eyJpc3MiOiJodHRwczovL2F1dGgub3BlbmFpLmNvbSIsImF1ZCI6Im9haWFwcF9hYmMiLCJzdWIiOiJ1c2VyXzEiLCJlbWFpbCI6InNjb3R0QGV4YW1wbGUuY29tIiwibm9uY2UiOiJuMG5jZSIsImlhdCI6MTcwMDAwMDAwMCwiZXhwIjoxODkzNDU2MDAwfQ.YhwJRqzjBX1QlTHPcmNhEBbSHrFaMemtdfEzi3O_QZLurY4St5ph-pSvOrZiFJAGaTcLsriqf8X9UWBfz-7jlUJEhuwMZHvRdPiijcWfxB-pBGTK8sIgay3PUADl5f3euoVr5hLwICtW450Juv5hQckN6-u8l92mgXeLrb46g_cl0VRmuEV-S2YNwLq5mTRaNBRe2KYKETLyd_LNy29wdMD-sXBvKc69Gn6Anrqx23Qz-gXe2iYoBANshYuw0h-rPxK3aJUC8qJWR0elWb-BVhPKb73qgk0vpVgVofANCKk6BAMlwLSNifwmIGU7UyxkVGpnfeomYjQkci4TIihs8Q"
    /// `jwt` with the fifth character of its signature changed.
    static let tampered = "eyJhbGciOiJSUzI1NiIsImtpZCI6ImsxIiwidHlwIjoiSldUIn0.eyJpc3MiOiJodHRwczovL2F1dGgub3BlbmFpLmNvbSIsImF1ZCI6Im9haWFwcF9hYmMiLCJzdWIiOiJ1c2VyXzEiLCJlbWFpbCI6InNjb3R0QGV4YW1wbGUuY29tIiwibm9uY2UiOiJuMG5jZSIsImlhdCI6MTcwMDAwMDAwMCwiZXhwIjoxODkzNDU2MDAwfQ.YhwJSqzjBX1QlTHPcmNhEBbSHrFaMemtdfEzi3O_QZLurY4St5ph-pSvOrZiFJAGaTcLsriqf8X9UWBfz-7jlUJEhuwMZHvRdPiijcWfxB-pBGTK8sIgay3PUADl5f3euoVr5hLwICtW450Juv5hQckN6-u8l92mgXeLrb46g_cl0VRmuEV-S2YNwLq5mTRaNBRe2KYKETLyd_LNy29wdMD-sXBvKc69Gn6Anrqx23Qz-gXe2iYoBANshYuw0h-rPxK3aJUC8qJWR0elWb-BVhPKb73qgk0vpVgVofANCKk6BAMlwLSNifwmIGU7UyxkVGpnfeomYjQkci4TIihs8Q"
    static let jwks = JSON.object(["keys": .array([.object([
        "kty": .string("RSA"), "kid": .string("k1"), "alg": .string("RS256"), "use": .string("sig"), "e": .string("AQAB"),
        "n": .string("wDvXQiNHwOeXiwFoayEVPvS1XSeSzIP4JAQufr_K_U2KMijPfAgMTfrf1drLk-IFIX8t8d4bA2XKP-1FPi92WqfntPcmwjZH9YIoUG50BULWVANC6QjVN8RANQ-_K8xJOZcruAc5vvj3ipZwNAINxqWWebV5PYFoMFWLY6DCmkkcM7vUv_BzPUeIFuSpnzs0TyNWSkhMNPlP2Ylmo8eygpnpKPTMF7nDhAxkdLRZB1q2SELbV0MNfnqL6Gs8JeQRhSWqTbBv-5BXiPXHa3UYME8k0z1mRqA0s0sWdiIde5x2n0HWVIcuGOm2yajN39I8Ma02EScz9yCSfgwkMqhnuw"),
    ])])])
    /// `jwt`'s claims signed the same way by a second throwaway key, under kid "k2": a key OpenAI rotated in. The
    /// private key was not kept either.
    static let rotatedJWT = "eyJhbGciOiJSUzI1NiIsImtpZCI6ImsyIiwidHlwIjoiSldUIn0.eyJpc3MiOiJodHRwczovL2F1dGgub3BlbmFpLmNvbSIsImF1ZCI6Im9haWFwcF9hYmMiLCJzdWIiOiJ1c2VyXzEiLCJlbWFpbCI6InNjb3R0QGV4YW1wbGUuY29tIiwibm9uY2UiOiJuMG5jZSIsImlhdCI6MTcwMDAwMDAwMCwiZXhwIjoxODkzNDU2MDAwfQ.ApesXTTLMbnVLCBZB1_ecJACXM_FuYkeMIoXNLWueG4nlnCUkXjFZvsnXN_9fAzMH-ItcN_jlbGaHLMQP6xiDFIwxzi-ZTwb_4hylxGirX89Slt32Ud7-HRdXM-bZ2M5GSn2GQfT7e5JeAU1fjvXFA_wyxBWHX36HHewpPzZ5deas6aZ36MZ3MsTo2FeVxCdgy6tFEL-mppNdaqynGzg32PQrcQZ-sGfnBaC2fsOrl6-fDYwGmcMcMAYvvbQJ2Jp8Imaq4-3SMZALtPGnuh-TF9q86PyFjuwRd1MEFEUeSlUvPJN-zb8VtLTyRlTpckCjj9vqLzi-EKDNA2dG30KTg"
    /// The JWK of `rotatedJWT`'s key.
    static let rotatedKey = JSON.object([
        "kty": .string("RSA"), "kid": .string("k2"), "alg": .string("RS256"), "use": .string("sig"), "e": .string("AQAB"),
        "n": .string("tqyGU6Bi2DMLPc3KCQ0h7s8LZjb_93duVvTBFCA4WpTmX7XxTTSxJcZZgBZsorsLiZI4YxCflqxzGMNnLHSOHJCTDWRKKWLinruj6tOoOGa0bbpQEp0H7cKEtuGZdb0MZ5oV0DzKi-QEtSbuX6ayjVTQv28MMp69wz5LgwzHsgiGLxDynEJXtxaYcw9GF6d3SyMjSTcVxUqKox3LnHc1xrOlbm5_6_zzNHOS5fqwUTf-Mx00j4LM1xygEmqGp20HxPwr-OUmOSy45d1Hzob0B6d9H-Oamnv7vKyJJTQoPO1U5pzVpO5eKX1Ui04ZgZaTXS67TTIUIFx2bD5PCf2lkw"),
    ])
}

@Test func theIDTokenIsCheckedAgainstTheJWKSAndTheAttempt() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let token = try ChatGPTSignIn.validate(idToken: signedIDToken.jwt, jwks: signedIDToken.jwks, clientID: "oaiapp_abc", nonce: "n0nce", now: now)
    #expect(token.issuer == "https://auth.openai.com" && token.audience == ["oaiapp_abc"] && token.email == "scott@example.com")
    #expect(throws: SignInError.invalidIDToken("nonce")) { try ChatGPTSignIn.validate(idToken: signedIDToken.jwt, jwks: signedIDToken.jwks, clientID: "oaiapp_abc", nonce: "other", now: now) }
    #expect(throws: SignInError.invalidIDToken("audience")) { try ChatGPTSignIn.validate(idToken: signedIDToken.jwt, jwks: signedIDToken.jwks, clientID: "oaiapp_zzz", nonce: "n0nce", now: now) }
    #expect(throws: SignInError.invalidIDToken("expired")) { try ChatGPTSignIn.validate(idToken: signedIDToken.jwt, jwks: signedIDToken.jwks, clientID: "oaiapp_abc", nonce: "n0nce", now: Date(timeIntervalSince1970: 2_000_000_000)) }
    #expect(throws: SignInError.invalidIDToken("signature")) { try ChatGPTSignIn.validate(idToken: signedIDToken.tampered, jwks: signedIDToken.jwks, clientID: "oaiapp_abc", nonce: "n0nce", now: now) }
    #expect(throws: SignInError.invalidIDToken("key")) { try ChatGPTSignIn.validate(idToken: signedIDToken.jwt, jwks: .object(["keys": .array([])]), clientID: "oaiapp_abc", nonce: "n0nce", now: now) }
}

final class MemoryAccountStore: ChatGPTAccountStore {
    var account: ChatGPTAccount?
    var hostID: String?
    var clientID: String?
}

/// A session over a scripted transport, its clock at `now`.
func session(_ store: MemoryAccountStore, _ transport: FakeHTTPTransport, now: Date = Date(timeIntervalSince1970: 1_800_000_000), log: Log = Log()) -> ChatGPTSession {
    ChatGPTSession(store: store, transport: transport, log: log, now: { now }, sleep: { _ in })
}
let tokenJSON = #"{"access_token":"at1","refresh_token":"rt1","id_token":"\#(signedIDToken.jwt)","token_type":"Bearer","expires_in":3600,"scope":"openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"}"#
let jwksJSON = String(decoding: signedIDToken.jwks.encoded(), as: UTF8.self)
/// A refresh's answer that leaves the grant as it was.
let renewedJSON = #"{"access_token":"at2","refresh_token":"rt2","token_type":"Bearer","expires_in":3600}"#

/// A kept sign-in saved at 1_800_000_000 (it expires at 1_800_003_600), the plan granted unless `scopes` says otherwise.
func heldAccount(subject: String = "sub", scopes: [String] = [ChatGPT.planScope], savedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> ChatGPTAccount {
    ChatGPTAccount(email: "scott@example.com", issuer: ChatGPT.issuer, subject: subject, clientID: "oaiapp_abc", hostID: "urn:uuid:1", idToken: nil, accessToken: "at1", refreshToken: "rt1", tokenType: "Bearer", expiresIn: 3600, scopes: scopes, savedAt: savedAt)
}

@Test func aFirstSignInRegistersExchangesChecksAndKeepsTheAccount() async throws {
    let store = MemoryAccountStore()
    let transport = FakeHTTPTransport([reply(200, tokenJSON), reply(200, String(decoding: signedIDToken.jwks.encoded(), as: UTF8.self))])
    let log = Log()
    let session = session(store, transport, log: log)
    let (url, attempt) = session.begin(redirect: redirect)
    #expect(url.absoluteString.contains("client_id=dynamic_agent_client") && store.hostID?.hasPrefix("urn:uuid:") == true)
    // The test's attempt replaces the random one so that the signed token's nonce matches.
    let fixed = SignInAttempt(verifier: attempt.verifier, state: attempt.state, nonce: "n0nce")
    let callback = URL(string: "http://127.0.0.1:1455/auth/callback?code=c0de&state=\(attempt.state)&client_id=oaiapp_abc")!
    let account = try await session.complete(callback: callback, attempt: fixed, redirect: redirect)
    #expect(account.email == "scott@example.com" && account.clientID == "oaiapp_abc" && account.mayUsePlan)
    #expect(store.account == account && store.clientID == "oaiapp_abc")
    #expect(transport.requests[0].url == ChatGPT.tokenEndpoint && transport.requests[1].url == ChatGPT.jwksURL)
    // No token, no authorization URL and no identity reaches the log.
    #expect(log.entries.map(\.text) == ["ai: chatgpt signed in"])
}

@Test func aSignInWithoutThePlanGrantIsRefused() async throws {
    let store = MemoryAccountStore()
    store.hostID = "urn:uuid:1"; store.clientID = "oaiapp_abc"
    let noPlan = tokenJSON.replacingOccurrences(of: " chatgpt.tokens.use.direct", with: "")
    let transport = FakeHTTPTransport([reply(200, noPlan), reply(200, String(decoding: signedIDToken.jwks.encoded(), as: UTF8.self))])
    let session = session(store, transport)
    let (url, attempt) = session.begin(redirect: redirect)
    #expect(url.absoluteString.contains("client_id=oaiapp_abc"))
    let fixed = SignInAttempt(verifier: attempt.verifier, state: attempt.state, nonce: "n0nce")
    await #expect(throws: SignInError.planNotGranted) {
        try await session.complete(callback: URL(string: "http://127.0.0.1:1455/auth/callback?code=c&state=\(attempt.state)")!, attempt: fixed, redirect: redirect)
    }
    // As OpenAI's errors page says: the sign-in is kept with plan usage off, and no inference runs on it.
    #expect(store.account?.mayUsePlan == false && store.clientID == "oaiapp_abc")
}

@Test func aFailedExchangeKeepsTheIssuedClientForTheNextAttempt() async throws {
    let store = MemoryAccountStore()
    let session = session(store, FakeHTTPTransport([reply(400, #"{"error":"invalid_grant","error_description":"code expired"}"#)]))
    let (_, attempt) = session.begin(redirect: redirect)
    let callback = URL(string: "http://127.0.0.1:1455/auth/callback?code=c&state=\(attempt.state)&client_id=oaiapp_abc")!
    await #expect(throws: SignInError.tokenEndpoint(status: 400, error: "invalid_grant", description: "code expired")) {
        try await session.complete(callback: callback, attempt: attempt, redirect: redirect)
    }
    #expect(store.account == nil && store.clientID == "oaiapp_abc")
    #expect(session.begin(redirect: redirect).url.absoluteString.contains("client_id=oaiapp_abc"))
}

@Test func anExpiringTokenIsRefreshedAndATerminalFailureSignsOut() async throws {
    let store = MemoryAccountStore()
    let saved = Date(timeIntervalSince1970: 1_800_000_000)
    store.hostID = "urn:uuid:1"; store.clientID = "oaiapp_abc"
    store.account = ChatGPTAccount(email: "scott@example.com", issuer: ChatGPT.issuer, subject: "sub", clientID: "oaiapp_abc", hostID: "urn:uuid:1", idToken: nil, accessToken: "at1", refreshToken: "rt1", tokenType: "Bearer", expiresIn: 3600, scopes: [ChatGPT.planScope], savedAt: saved)
    let fresh = session(store, FakeHTTPTransport([]), now: saved.addingTimeInterval(1000))
    #expect(try await fresh.validAccessToken() == "at1")
    let rotated = #"{"access_token":"at2","refresh_token":"rt2","token_type":"Bearer","expires_in":3600,"scope":"openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"}"#
    let transport = FakeHTTPTransport([reply(200, rotated)])
    let expiring = session(store, transport, now: saved.addingTimeInterval(3560))
    #expect(try await expiring.validAccessToken() == "at2")
    #expect(store.account?.refreshToken == "rt2" && store.account?.savedAt == saved.addingTimeInterval(3560))
    #expect(String(decoding: try #require(transport.requests[0].httpBody), as: UTF8.self).contains("refresh_token=rt1"))
    let failing = session(store, FakeHTTPTransport([reply(400, #"{"error":"refresh_token_expired"}"#)]), now: saved.addingTimeInterval(10_000))
    await #expect(throws: SignInError.signedOut) { try await failing.validAccessToken() }
    #expect(store.account == nil && store.clientID == "oaiapp_abc" && store.hostID == "urn:uuid:1")
    store.account = ChatGPTAccount(email: "scott@example.com", issuer: ChatGPT.issuer, subject: "sub", clientID: "oaiapp_abc", hostID: "urn:uuid:1", idToken: nil, accessToken: "at1", refreshToken: "rt1", tokenType: "Bearer", expiresIn: 3600, scopes: [ChatGPT.planScope], savedAt: saved)
    let flaky = session(store, FakeHTTPTransport([reply(503, "")]), now: saved.addingTimeInterval(10_000))
    await #expect(throws: SignInError.network("refresh failed with status 503")) { try await flaky.validAccessToken() }
    #expect(store.account != nil)
}

@Test func twoCallersShareOneRefresh() async throws {
    let store = MemoryAccountStore()
    let saved = Date(timeIntervalSince1970: 1_800_000_000)
    store.account = ChatGPTAccount(email: "scott@example.com", issuer: ChatGPT.issuer, subject: "sub", clientID: "oaiapp_abc", hostID: "urn:uuid:1", idToken: nil, accessToken: "at1", refreshToken: "rt1", tokenType: "Bearer", expiresIn: 3600, scopes: [ChatGPT.planScope], savedAt: saved)
    let transport = FakeHTTPTransport([reply(200, #"{"access_token":"at2","refresh_token":"rt2","token_type":"Bearer","expires_in":3600}"#)])
    let session = session(store, transport, now: saved.addingTimeInterval(3560))
    async let first = session.validAccessToken()
    async let second = session.validAccessToken()
    #expect(try await [first, second] == ["at2", "at2"] && transport.requests.count == 1)
    #expect(store.account?.scopes == [ChatGPT.planScope])
}

@Test func signOutRevokesClearsTheTokensAndKeepsTheRegistration() async throws {
    let store = MemoryAccountStore()
    store.hostID = "urn:uuid:1"; store.clientID = "oaiapp_abc"
    store.account = ChatGPTAccount(email: "e", issuer: ChatGPT.issuer, subject: "s", clientID: "oaiapp_abc", hostID: "urn:uuid:1", idToken: "it", accessToken: "at", refreshToken: "rt", tokenType: "Bearer", expiresIn: 3600, scopes: [], savedAt: .now)
    let transport = FakeHTTPTransport([reply(503, ""), reply(200, "")])
    #expect(await session(store, transport).signOut() == .revoked)
    #expect(transport.requests.count == 2 && store.account == nil && store.clientID == "oaiapp_abc" && store.hostID == "urn:uuid:1")
    store.account = ChatGPTAccount(email: "e", issuer: ChatGPT.issuer, subject: "s", clientID: "oaiapp_abc", hostID: "urn:uuid:1", idToken: nil, accessToken: "at", refreshToken: "rt", tokenType: "Bearer", expiresIn: 3600, scopes: [], savedAt: .now)
    var waits: [Duration] = []
    let unconfirmed = ChatGPTSession(store: store, transport: FakeHTTPTransport([reply(503, ""), reply(503, ""), reply(503, "")]), log: Log(), sleep: { waits.append($0) })
    #expect(await unconfirmed.signOut() == .unconfirmed)
    // The retries back off: 1 s, then 2 s.
    #expect(store.account == nil && waits == [.seconds(1), .seconds(2)])
}

@Test func aTokenAskedForDuringASignOutIsRefused() async throws {
    let store = MemoryAccountStore()
    store.hostID = "urn:uuid:1"; store.clientID = "oaiapp_abc"; store.account = heldAccount()
    // The second reply is what a refresh started during the sign-out would get.
    let transport = FakeHTTPTransport([reply(200, ""), reply(200, renewedJSON)])
    let session = session(store, transport, now: Date(timeIntervalSince1970: 1_800_003_560))
    transport.hold = true
    let signingOut = Task { await session.signOut() }
    for _ in 0..<100 where transport.requests.isEmpty { await Task.yield() }
    transport.hold = false
    // The revoke is still open: a refresh now would rotate the very token being revoked.
    await #expect(throws: SignInError.signedOut) { try await session.validAccessToken() }
    transport.release()
    #expect(await signingOut.value == .revoked)
    #expect(transport.requests.count == 1 && store.account == nil)
    // Once the sign-out is over, a token is served again.
    store.account = heldAccount(savedAt: Date(timeIntervalSince1970: 1_800_003_000))
    #expect(try await session.validAccessToken() == "at1")
}

@Test func aRefreshAnsweredAfterTheAccountIsGoneWritesNothingBack() async throws {
    let store = MemoryAccountStore()
    store.hostID = "urn:uuid:1"; store.clientID = "oaiapp_abc"; store.account = heldAccount()
    let transport = FakeHTTPTransport([reply(200, renewedJSON)])
    let session = session(store, transport, now: Date(timeIntervalSince1970: 1_800_003_560))
    transport.hold = true
    let refreshing = Task { try await session.validAccessToken() }
    for _ in 0..<100 where transport.requests.isEmpty { await Task.yield() }
    store.account = nil  // the record is gone meanwhile
    transport.release()
    await #expect(throws: SignInError.signedOut) { try await refreshing.value }
    #expect(transport.requests.count == 1 && store.account == nil)
}

@Test func anInvalidClientExchangeDropsTheRegistration() async throws {
    let store = MemoryAccountStore()
    store.hostID = "urn:uuid:1"; store.clientID = "oaiapp_abc"
    let session = session(store, FakeHTTPTransport([reply(401, #"{"error":"invalid_client"}"#)]))
    let (_, attempt) = session.begin(redirect: redirect)
    await #expect(throws: SignInError.tokenEndpoint(status: 401, error: "invalid_client", description: nil)) {
        try await session.complete(callback: URL(string: "http://127.0.0.1:1455/auth/callback?code=c&state=\(attempt.state)")!, attempt: attempt, redirect: redirect)
    }
    #expect(store.clientID == nil && store.hostID == "urn:uuid:1")
    #expect(session.begin(redirect: redirect).url.absoluteString.contains("client_id=dynamic_agent_client"))
}

@Test func anInvalidClientRefreshSignsOutAndDropsTheRegistration() async throws {
    let store = MemoryAccountStore()
    store.hostID = "urn:uuid:1"; store.clientID = "oaiapp_abc"; store.account = heldAccount()
    let session = session(store, FakeHTTPTransport([reply(401, #"{"error":"invalid_client"}"#)]), now: Date(timeIntervalSince1970: 1_800_003_560))
    await #expect(throws: SignInError.signedOut) { try await session.validAccessToken() }
    #expect(store.account == nil && store.clientID == nil && store.hostID == "urn:uuid:1")
}

@Test func aReturningSignInMustComeBackAsTheHeldAccount() async throws {
    let store = MemoryAccountStore()
    let held = heldAccount(subject: "someone_else")
    store.hostID = "urn:uuid:1"; store.clientID = "oaiapp_abc"; store.account = held
    let transport = FakeHTTPTransport([reply(200, tokenJSON), reply(200, jwksJSON)])
    let session = session(store, transport)
    let (_, attempt) = session.begin(redirect: redirect)
    let fixed = SignInAttempt(verifier: attempt.verifier, state: attempt.state, nonce: "n0nce")
    // While an account is held, another client id is refused before anything is exchanged.
    await #expect(throws: SignInError.clientMismatch) {
        try await session.complete(callback: URL(string: "http://127.0.0.1:1455/auth/callback?code=c&state=\(attempt.state)&client_id=oaiapp_other")!, attempt: fixed, redirect: redirect)
    }
    #expect(transport.requests.isEmpty)
    // The token is user_1's, not the held account's: nothing is replaced.
    await #expect(throws: SignInError.differentAccount) {
        try await session.complete(callback: URL(string: "http://127.0.0.1:1455/auth/callback?code=c&state=\(attempt.state)")!, attempt: fixed, redirect: redirect)
    }
    #expect(store.account == held && store.clientID == "oaiapp_abc")
}

@Test func afterASignOutANewClientIDIsANewRegistration() async throws {
    let store = MemoryAccountStore()
    store.hostID = "urn:uuid:1"; store.clientID = "oaiapp_old"
    let transport = FakeHTTPTransport([reply(200, tokenJSON), reply(200, jwksJSON)])
    let session = session(store, transport)
    let (url, attempt) = session.begin(redirect: redirect)
    #expect(url.absoluteString.contains("client_id=oaiapp_old"))
    let fixed = SignInAttempt(verifier: attempt.verifier, state: attempt.state, nonce: "n0nce")
    let account = try await session.complete(callback: URL(string: "http://127.0.0.1:1455/auth/callback?code=c&state=\(attempt.state)&client_id=oaiapp_abc")!, attempt: fixed, redirect: redirect)
    #expect(account.clientID == "oaiapp_abc" && store.clientID == "oaiapp_abc")
    #expect(String(decoding: try #require(transport.requests[0].httpBody), as: UTF8.self).contains("client_id=oaiapp_abc"))
}

@Test func noTokenServesThePlanWithoutItsGrant() async throws {
    let store = MemoryAccountStore()
    store.hostID = "urn:uuid:1"; store.clientID = "oaiapp_abc"; store.account = heldAccount()
    let noPlan = #"{"access_token":"at2","refresh_token":"rt2","token_type":"Bearer","expires_in":3600,"scope":"openid profile email offline_access resource.invoke"}"#
    let session = session(store, FakeHTTPTransport([reply(200, noPlan)]), now: Date(timeIntervalSince1970: 1_800_003_560))
    // The renewed grant is the one checked.
    await #expect(throws: SignInError.planNotGranted) { try await session.validAccessToken() }
    #expect(store.account?.accessToken == "at2" && store.account?.mayUsePlan == false)
}

@Test func theModelListMayHaveATokenWithoutThePlanGrant() async throws {
    let store = MemoryAccountStore()
    store.account = heldAccount(scopes: ["openid", "profile", "email", "offline_access", "resource.invoke"])
    let session = session(store, FakeHTTPTransport([]), now: Date(timeIntervalSince1970: 1_800_000_100))
    #expect(try await session.validAccessToken(forPlanUse: false) == "at1")
    await #expect(throws: SignInError.planNotGranted) { try await session.validAccessToken() }
}

@Test func aRenewalRefreshesATokenThatIsNotExpiring() async throws {
    let store = MemoryAccountStore()
    store.hostID = "urn:uuid:1"; store.clientID = "oaiapp_abc"; store.account = heldAccount()
    let transport = FakeHTTPTransport([reply(200, renewedJSON)])
    // 100 s into a token that lasts an hour: refused by the API all the same, so renewed.
    let renewing = session(store, transport, now: Date(timeIntervalSince1970: 1_800_000_100))
    #expect(try await renewing.renew() == "at2")
    let refresh = try #require(transport.requests.first)
    #expect(transport.requests.count == 1 && refresh.url == ChatGPT.tokenEndpoint)
    #expect(String(decoding: try #require(refresh.httpBody), as: UTF8.self).contains("refresh_token=rt1"))
    #expect(store.account?.accessToken == "at2" && store.account?.refreshToken == "rt2")
    #expect(store.account?.savedAt == Date(timeIntervalSince1970: 1_800_000_100) && store.account?.mayUsePlan == true)
}

@Test func aRenewalThatFailsTerminallySignsOutAndOneThatFailsInPassingKeepsTheAccount() async throws {
    let store = MemoryAccountStore()
    store.hostID = "urn:uuid:1"; store.clientID = "oaiapp_abc"; store.account = heldAccount()
    let now = Date(timeIntervalSince1970: 1_800_000_100)
    let flaky = session(store, FakeHTTPTransport([reply(503, "")]), now: now)
    await #expect(throws: SignInError.network("refresh failed with status 503")) { try await flaky.renew() }
    #expect(store.account == heldAccount())
    let failing = session(store, FakeHTTPTransport([reply(400, #"{"error":"refresh_token_reused"}"#)]), now: now)
    await #expect(throws: SignInError.signedOut) { try await failing.renew() }
    #expect(store.account == nil && store.clientID == "oaiapp_abc" && store.hostID == "urn:uuid:1")
}

@Test func droppingTheRegistrationMakesTheNextSignInRegisterAgain() throws {
    let store = MemoryAccountStore()
    store.hostID = "urn:uuid:1"; store.clientID = "oaiapp_abc"
    let session = session(store, FakeHTTPTransport([]))
    session.dropRegistration()
    #expect(store.clientID == nil && store.hostID == "urn:uuid:1")
    let url = session.begin(redirect: redirect).url
    let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems).reduce(into: [String: String]()) { $0[$1.name] = $1.value }
    #expect(query["client_id"] == "dynamic_agent_client" && query["agent_name_hint"] == "Vynscope")
    #expect(query["ext_agent_host_id"] == "urn:uuid:1")
}

@Test func anIDTokenWithoutRS256AKeyIDOrThreePartsIsRefused() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let parts = signedIDToken.jwt.split(separator: ".").map(String.init)
    /// `json` as a JWT part: base64url without padding.
    func part(_ json: String) -> String {
        Data(json.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    let validate = { (token: String) in
        try ChatGPTSignIn.validate(idToken: token, jwks: signedIDToken.jwks, clientID: "oaiapp_abc", nonce: "n0nce", now: now)
    }
    #expect(throws: SignInError.invalidIDToken("alg")) { try validate([part(#"{"alg":"none","typ":"JWT"}"#), parts[1], ""].joined(separator: ".")) }
    #expect(throws: SignInError.invalidIDToken("key")) { try validate([part(#"{"alg":"RS256","typ":"JWT"}"#), parts[1], parts[2]].joined(separator: ".")) }
    #expect(throws: SignInError.invalidIDToken("format")) { try validate([parts[0], parts[1]].joined(separator: ".")) }
}

@Test func aReturningSignInAsTheHeldAccountReplacesItsTokens() async throws {
    let store = MemoryAccountStore()
    store.hostID = "urn:uuid:1"; store.clientID = "oaiapp_abc"; store.account = heldAccount(subject: "user_1")
    let newTokens = tokenJSON.replacingOccurrences(of: #""access_token":"at1","refresh_token":"rt1""#, with: #""access_token":"at3","refresh_token":"rt3""#)
    let transport = FakeHTTPTransport([reply(200, newTokens), reply(200, jwksJSON)])
    let session = session(store, transport)
    let (_, attempt) = session.begin(redirect: redirect)
    let fixed = SignInAttempt(verifier: attempt.verifier, state: attempt.state, nonce: "n0nce")
    let account = try await session.complete(callback: URL(string: "http://127.0.0.1:1455/auth/callback?code=c&state=\(attempt.state)")!, attempt: fixed, redirect: redirect)
    #expect(account.subject == "user_1" && account.accessToken == "at3" && account.refreshToken == "rt3" && account.idToken == signedIDToken.jwt)
    #expect(store.account == account && store.clientID == "oaiapp_abc")
}

@Test func aSigningKeyTheKeptSetLacksIsFetchedOnceMore() async throws {
    /// A JWKS answer holding `keys`.
    func keysAnswer(_ keys: JSON...) -> HTTPReply {
        reply(200, String(decoding: JSON.object(["keys": .array(keys)]).encoded(), as: UTF8.self))
    }
    let k1 = try #require(signedIDToken.jwks["keys"]?.array?.first)
    let rotated = tokenJSON.replacingOccurrences(of: signedIDToken.jwt, with: signedIDToken.rotatedJWT)
    let store = MemoryAccountStore()
    let transport = FakeHTTPTransport([
        reply(200, tokenJSON), keysAnswer(k1), reply(200, rotated), keysAnswer(signedIDToken.rotatedKey),
        reply(200, tokenJSON), keysAnswer(signedIDToken.rotatedKey), reply(200, rotated),
    ])
    let session = session(store, transport)
    func signIn(nonce: String = "n0nce") async throws -> ChatGPTAccount {
        let (_, attempt) = session.begin(redirect: redirect)
        let fixed = SignInAttempt(verifier: attempt.verifier, state: attempt.state, nonce: nonce)
        return try await session.complete(callback: URL(string: "http://127.0.0.1:1455/auth/callback?code=c&state=\(attempt.state)&client_id=oaiapp_abc")!, attempt: fixed, redirect: redirect)
    }
    let keyRequests = { transport.requests.filter { $0.url == ChatGPT.jwksURL }.count }
    #expect(try await signIn().idToken == signedIDToken.jwt && keyRequests() == 1)
    // OpenAI rotated its keys: the token is signed with k2, which the kept set lacks, so the set is fetched once more.
    #expect(try await signIn().idToken == signedIDToken.rotatedJWT && keyRequests() == 2)
    // A kid that neither the kept set nor a fresh one holds fails as before, after one fetch.
    await #expect(throws: SignInError.invalidIDToken("key")) { try await signIn() }
    #expect(keyRequests() == 3 && store.account?.idToken == signedIDToken.rotatedJWT)
    // Any other failure fetches nothing.
    await #expect(throws: SignInError.invalidIDToken("nonce")) { try await signIn(nonce: "other") }
    #expect(keyRequests() == 3 && transport.requests.count == 7)
}
