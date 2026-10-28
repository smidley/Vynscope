import CryptoKit
import Foundation
import Security

/// Sign in with ChatGPT's fixed values, as OpenAI's sign-in pages and its discovery document give them.
public nonisolated enum ChatGPT {
    public static let issuer = "https://auth.openai.com"
    public static let authorizationEndpoint = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    public static let tokenEndpoint = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    public static let revocationEndpoint = URL(string: "https://auth.openai.com/api/accounts/oauth/revoke")!
    public static let jwksURL = URL(string: "https://auth.openai.com/.well-known/jwks.json")!
    public static let resource = "https://api.openai.com/v1"
    public static let scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    /// The grant that lets the app's requests use the owner's ChatGPT plan.
    public static let planScope = "chatgpt.tokens.use.direct"
    public static let agentName = "Vynscope"
    /// The client id that registers the app on a first sign-in; never kept, never used to exchange a code.
    public static let registrationClientID = "dynamic_agent_client"
    public static let callbackPath = "/auth/callback"
}

/// What one sign-in attempt is keyed on; `random()` draws 32 bytes for each from the system generator.
public struct SignInAttempt: Equatable, Sendable {
    public var verifier: String, state: String, nonce: String

    public init(verifier: String, state: String, nonce: String) {
        self.verifier = verifier
        self.state = state
        self.nonce = nonce
    }

    public static func random() -> SignInAttempt {
        // `UInt8.random(in:)` draws from `SystemRandomNumberGenerator`, the system's cryptographic generator.
        let draw = { base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })) }
        return SignInAttempt(verifier: draw(), state: draw(), nonce: draw())
    }

    /// Base64url of SHA-256 of the verifier, unpadded (RFC 7636).
    public var challenge: String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
}

/// The sign-in as kept between launches.
public struct ChatGPTAccount: Codable, Equatable, Sendable {
    /// From the validated ID token; `subject` is the account's identity, `email` may be empty.
    public var email: String, issuer: String, subject: String
    /// The client id issued to this device and its host id.
    public var clientID: String, hostID: String
    /// The ID token of the sign-in, sent back as `id_token_hint` by the next one.
    public var idToken: String?, accessToken: String, refreshToken: String
    public var tokenType: String, expiresIn: Int, scopes: [String], savedAt: Date

    public var expiresAt: Date { savedAt.addingTimeInterval(TimeInterval(expiresIn)) }
    /// Whether the owner let the app use the ChatGPT plan; no request may run on a sign-in without it.
    public var mayUsePlan: Bool { scopes.contains(ChatGPT.planScope) }
}

public enum SignInError: Error, Equatable {
    /// The owner declined in the browser (`error=access_denied`).
    case denied
    /// The browser came back with an `error` other than `access_denied`: it, and its `error_description` when given.
    case callbackError(code: String, description: String?)
    case stateMismatch
    case missingCode
    /// A first sign-in's callback carried no issued client id, or a callback carried the registration's own.
    case registrationIncomplete
    /// The callback named a client id other than the attempt's while an account is held.
    case clientMismatch
    /// A returning sign-in came back as another ChatGPT account than the one held: nothing was replaced.
    case differentAccount
    /// The token endpoint refused: its status, `error` and `error_description`.
    case tokenEndpoint(status: Int, error: String, description: String?)
    /// The ID token failed a check: which one.
    case invalidIDToken(String)
    /// The grant lacks `chatgpt.tokens.use.direct`: the sign-in is kept, but no request may use the plan.
    case planNotGranted
    /// The refresh failed terminally: the tokens are gone, sign in again.
    case signedOut
    /// No answer, or one that cannot be used: what went wrong.
    case network(String)
}

/// What the browser's redirect carried, once checked against the attempt.
public struct Callback: Equatable, Sendable {
    public var code: String, state: String
    /// The issued client id, which a later sign-in's callback may leave out.
    public var clientID: String?
}

/// What the token endpoint answered an exchange or a refresh with.
public struct TokenResponse: Equatable, Sendable {
    public var accessToken: String, refreshToken: String?, idToken: String?
    public var tokenType: String, expiresIn: Int, scopes: [String]

    /// `SignInError.tokenEndpoint(status:error:description:)` when the body is an `error` object, or when it is not
    /// a token at all (`unexpected_response`).
    public static func parse(_ data: Data, status: Int = 200) throws -> TokenResponse {
        let body = try? JSON.parse(data)
        if let error = body?["error"]?.string {
            let description = body?["error_description"]?.string
            throw SignInError.tokenEndpoint(status: status, error: error, description: description)
        }
        guard (200..<300).contains(status), let body, let accessToken = body["access_token"]?.string else {
            throw SignInError.tokenEndpoint(status: status, error: "unexpected_response", description: "HTTP \(status)")
        }
        return TokenResponse(
            accessToken: accessToken, refreshToken: body["refresh_token"]?.string, idToken: body["id_token"]?.string,
            tokenType: body["token_type"]?.string ?? "Bearer", expiresIn: body["expires_in"]?.int ?? 3600,
            scopes: (body["scope"]?.string ?? "").split(separator: " ").map(String.init))
    }
}

/// The claims of a validated ID token.
public struct IDToken: Equatable, Sendable {
    public var issuer: String, audience: [String], subject: String, email: String?, nonce: String?, expires: Date
}

/// The pure steps of the sign-in: the URLs and requests it sends, and the checks on what comes back.
public enum ChatGPTSignIn {
    /// The authorization URL to open in the browser: a first sign-in registers the app, a later one reuses the issued
    /// client and may name the account. The query is in the order OpenAI's sign-in page lists it.
    public static func authorizationURL(
        hostID: String, clientID: String?, attempt: SignInAttempt, redirect: URL, idTokenHint: String?,
        loginHint: String?
    ) -> URL {
        var items = [("client_id", clientID ?? ChatGPT.registrationClientID)]
        if clientID == nil { items.append(("agent_name_hint", ChatGPT.agentName)) }
        items.append(("ext_agent_host_id", hostID))
        if let idTokenHint { items.append(("id_token_hint", idTokenHint)) }
        if let loginHint { items.append(("login_hint", loginHint)) }
        items += [
            ("response_type", "code"), ("redirect_uri", redirect.absoluteString), ("scope", ChatGPT.scope),
            ("resource", ChatGPT.resource), ("state", attempt.state), ("nonce", attempt.nonce),
            ("code_challenge_method", "S256"), ("code_challenge", attempt.challenge),
        ]
        var components = URLComponents(url: ChatGPT.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = form(items)
        return components.url!
    }

    /// The redirect checked as OpenAI's sign-in page orders it: the state first, then an error, then the code and the
    /// client id. A later sign-in's callback may leave the client id out, which keeps the expected one. Another client
    /// id is `clientMismatch` while an account is held; with none held (after a sign-out) it is a new registration.
    public static func parseCallback(
        _ url: URL, expectedState: String, expectedClientID: String?, accountHeld: Bool = true
    ) throws -> Callback {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        guard value("state") == expectedState else { throw SignInError.stateMismatch }
        if let error = value("error") {
            if error == "access_denied" { throw SignInError.denied }
            throw SignInError.callbackError(code: error, description: value("error_description"))
        }
        guard let code = value("code") else { throw SignInError.missingCode }
        let clientID = value("client_id")
        if clientID == ChatGPT.registrationClientID { throw SignInError.registrationIncomplete }
        if expectedClientID == nil, clientID == nil { throw SignInError.registrationIncomplete }
        if accountHeld, let expectedClientID, let clientID, clientID != expectedClientID {
            throw SignInError.clientMismatch
        }
        return Callback(code: code, state: expectedState, clientID: clientID)
    }

    public static func exchangeRequest(
        code: String, attempt: SignInAttempt, clientID: String, redirect: URL
    ) -> URLRequest {
        post(ChatGPT.tokenEndpoint, [
            ("grant_type", "authorization_code"), ("client_id", clientID), ("code", code),
            ("code_verifier", attempt.verifier), ("redirect_uri", redirect.absoluteString),
            ("resource", ChatGPT.resource),
        ])
    }

    /// No `scope`, which keeps the grant as it is.
    public static func refreshRequest(refreshToken: String, clientID: String) -> URLRequest {
        post(ChatGPT.tokenEndpoint, [
            ("grant_type", "refresh_token"), ("client_id", clientID), ("refresh_token", refreshToken),
            ("resource", ChatGPT.resource),
        ])
    }

    public static func revokeRequest(refreshToken: String, clientID: String) -> URLRequest {
        post(ChatGPT.revocationEndpoint, [
            ("token", refreshToken), ("token_type_hint", "refresh_token"), ("client_id", clientID),
        ])
    }

    /// Decodes and checks the token: RS256 signature against the key of `jwks` with the token's `kid`, issuer,
    /// audience, expiry, nonce.
    public static func validate(
        idToken: String, jwks: JSON, clientID: String, nonce: String, now: Date
    ) throws -> IDToken {
        let parts = idToken.split(separator: ".", omittingEmptySubsequences: false)
        let json = { (part: Substring) in base64URLDecoded(part).flatMap { try? JSON.parse($0) } }
        guard parts.count == 3, let header = json(parts[0]), let claims = json(parts[1]) else {
            throw SignInError.invalidIDToken("format")
        }
        guard header["alg"]?.string == "RS256" else { throw SignInError.invalidIDToken("alg") }
        guard let kid = header["kid"]?.string,
              let jwk = jwks["keys"]?.array?.first(where: { $0["kid"]?.string == kid && $0["kty"]?.string == "RSA" }),
              let modulus = jwk["n"]?.string.flatMap({ base64URLDecoded($0) }),
              let exponent = jwk["e"]?.string.flatMap({ base64URLDecoded($0) })
        else { throw SignInError.invalidIDToken("key") }
        let attributes = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary
        let signed = Data("\(parts[0]).\(parts[1])".utf8)
        let publicKey = rsaPublicKey(modulus: modulus, exponent: exponent)
        guard let signature = base64URLDecoded(parts[2]),
              let key = SecKeyCreateWithData(publicKey as CFData, attributes, nil),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, signature as CFData, nil)
        else { throw SignInError.invalidIDToken("signature") }
        guard claims["iss"]?.string == ChatGPT.issuer else { throw SignInError.invalidIDToken("issuer") }
        let audience = claims["aud"]?.string.map { [$0] } ?? claims["aud"]?.array?.compactMap(\.string) ?? []
        guard audience.contains(clientID) else { throw SignInError.invalidIDToken("audience") }
        let expires = claims["exp"]?.int.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? .distantPast
        guard expires > now else { throw SignInError.invalidIDToken("expired") }
        guard claims["nonce"]?.string == nonce else { throw SignInError.invalidIDToken("nonce") }
        guard let subject = claims["sub"]?.string else { throw SignInError.invalidIDToken("subject") }
        return IDToken(
            issuer: ChatGPT.issuer, audience: audience, subject: subject, email: claims["email"]?.string, nonce: nonce,
            expires: expires)
    }

    /// The terminal refresh errors: the tokens are unusable and a new sign-in is needed.
    public static let terminalRefreshErrors: Set<String> = [
        "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated",
        "refresh_token_reused",
    ]

    private static func post(_ url: URL, _ items: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form(items).utf8)
        return request
    }

    /// `name=value&…` with every value percent-encoded but for RFC 3986's unreserved characters, so that `:`, `/`
    /// and `@` are encoded too and a `+` can never be read as a space.
    private static func form(_ items: [(String, String)]) -> String {
        // Cannot fail: a Swift string always converts.
        items.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: unreserved)!)" }.joined(separator: "&")
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// A JWK's `n` and `e` as the PKCS#1 `RSAPublicKey` DER that `SecKeyCreateWithData` takes: a SEQUENCE of two
    /// INTEGERs.
    private static func rsaPublicKey(modulus: Data, exponent: Data) -> Data {
        Data(der(0x30, der(0x02, integer(modulus)) + der(0x02, integer(exponent))))
    }

    /// Big-endian magnitude bytes as a DER INTEGER's content, which is signed: a leading one bit takes a zero byte in
    /// front, and zero is a single zero byte.
    private static func integer(_ bytes: Data) -> [UInt8] {
        let magnitude = Array(bytes.drop { $0 == 0 })
        return (magnitude.first ?? 0x80) >= 0x80 ? [0] + magnitude : magnitude
    }

    /// A DER element: the tag, the length (short form below 128, long form above), the content.
    private static func der(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        guard content.count >= 0x80 else { return [tag, UInt8(content.count)] + content }
        let length = withUnsafeBytes(of: UInt(content.count).bigEndian) { Array($0.drop { $0 == 0 }) }
        return [tag, 0x80 | UInt8(length.count)] + length + content
    }
}

/// Where the account and the per-device ids are kept (the app: the Keychain; tests: memory).
public protocol ChatGPTAccountStore: AnyObject {
    var account: ChatGPTAccount? { get set }
    /// The device's host id and the client id issued to it, kept across sign-outs.
    var hostID: String? { get set }
    var clientID: String? { get set }
}

public enum SignOutResult: Equatable, Sendable { case revoked, unconfirmed }

/// The sign-in's lifecycle on one device: begin, complete, a valid token for a request, sign out. The log gets what
/// happened, never a token, an id or the authorization URL.
public final class ChatGPTSession {
    private let store: any ChatGPTAccountStore
    private let transport: any HTTPTransport
    private let log: Log
    private let now: () -> Date
    private let sleep: (Duration) async throws -> Void
    /// OpenAI's signing keys, fetched by the first sign-in to need them, and again by one whose token they lack.
    private var jwks: JSON?
    /// The refresh in flight, which every caller of `validAccessToken` and `renew` waits on, so a rotated token is used
    /// once.
    private var refreshing: Task<ChatGPTAccount, any Error>?
    /// Set while `signOut` runs: a token asked for meanwhile is refused, so no refresh rotates what it revokes.
    private var signingOut = false

    public init(
        store: any ChatGPTAccountStore, transport: any HTTPTransport, log: Log, now: @escaping () -> Date = { .now },
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.store = store
        self.transport = transport
        self.log = log
        self.now = now
        self.sleep = sleep
    }

    public var account: ChatGPTAccount? { store.account }

    /// The host id, made on first use and kept.
    public func hostID() -> String {
        if let id = store.hostID { return id }
        let id = "urn:uuid:\(UUID().uuidString.lowercased())"
        store.hostID = id
        return id
    }

    /// The URL to open and the attempt to keep for `complete`.
    public func begin(redirect: URL) -> (url: URL, attempt: SignInAttempt) {
        let attempt = SignInAttempt.random()
        let account = store.account
        let url = ChatGPTSignIn.authorizationURL(
            hostID: hostID(), clientID: store.clientID, attempt: attempt, redirect: redirect,
            idTokenHint: account?.idToken, loginHint: account.flatMap { $0.email.isEmpty ? nil : $0.email })
        return (url, attempt)
    }

    /// The callback URL the listener caught: exchanges the code, checks the ID token, keeps the account. Without the
    /// plan grant the account is kept all the same, as OpenAI's errors page says, and `planNotGranted` is thrown. A
    /// returning sign-in must come back as the account held (`differentAccount`), which is otherwise left as it was.
    public func complete(callback: URL, attempt: SignInAttempt, redirect: URL) async throws -> ChatGPTAccount {
        let held = store.account
        let caught = try ChatGPTSignIn.parseCallback(
            callback, expectedState: attempt.state, expectedClientID: store.clientID, accountHeld: held != nil)
        guard let clientID = caught.clientID ?? store.clientID else { throw SignInError.registrationIncomplete }
        // Kept before the exchange: when it fails, the next attempt reuses this registration instead of making another.
        // After a sign-out a new registration replaces the kept one.
        store.clientID = clientID
        let reply = try await send(
            ChatGPTSignIn.exchangeRequest(code: caught.code, attempt: attempt, clientID: clientID, redirect: redirect))
        let tokens: TokenResponse
        do {
            tokens = try TokenResponse.parse(reply.body, status: reply.status)
        } catch {
            // OpenAI no longer knows this registration: the next sign-in registers the app again.
            if case SignInError.tokenEndpoint(_, "invalid_client", _) = error { store.clientID = nil }
            throw error
        }
        let check = { (jwks: JSON) in
            try ChatGPTSignIn.validate(
                idToken: tokens.idToken ?? "", jwks: jwks, clientID: clientID, nonce: attempt.nonce, now: self.now())
        }
        let token: IDToken
        do {
            token = try await check(keys())
        } catch SignInError.invalidIDToken("key") {
            // The kept keys lack the token's kid, as after OpenAI rotates its keys: they are fetched again, once.
            jwks = nil
            token = try await check(keys())
        }
        if let held, held.issuer != token.issuer || held.subject != token.subject {
            throw SignInError.differentAccount
        }
        let account = ChatGPTAccount(
            email: token.email ?? "", issuer: token.issuer, subject: token.subject, clientID: clientID,
            hostID: hostID(), idToken: tokens.idToken, accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken ?? "", tokenType: tokens.tokenType, expiresIn: tokens.expiresIn,
            scopes: tokens.scopes, savedAt: now())
        store.account = account
        guard account.mayUsePlan else {
            log.note("ai: chatgpt signed in without plan usage")
            throw SignInError.planNotGranted
        }
        log.note("ai: chatgpt signed in")
        return account
    }

    /// The access token for a request, refreshed first when it expires within 60 s; `SignInError.signedOut` when the
    /// refresh fails terminally (the account is then dropped, the registration kept) or a sign-out is under way.
    /// `forPlanUse` (a request on the plan) needs the plan grant, `SignInError.planNotGranted` without it; the model
    /// list asks with `false`.
    public func validAccessToken(forPlanUse: Bool = true) async throws -> String {
        let account = try await freshAccount()
        if forPlanUse, !account.mayUsePlan { throw SignInError.planNotGranted }
        return account.accessToken
    }

    /// A new access token for one the API refused before its expiry: the refresh `validAccessToken` runs for an
    /// expiring token, run now, through the one in flight, with the same outcomes: `SignInError.signedOut` when it
    /// fails terminally (the account is then dropped, the registration kept) or a sign-out is under way, `.network`
    /// with the account kept when it fails in passing.
    public func renew() async throws -> String {
        try await freshAccount(renewing: true).accessToken
    }

    /// Forgets the client id issued to this device, the host id kept, so that the next sign-in registers the app again:
    /// the way out when OpenAI no longer knows the registration and its sign-in page stops every attempt.
    public func dropRegistration() { store.clientID = nil }

    /// Revokes the refresh token, up to three tries on a 5xx or no answer, 1 s and then 2 s apart, then drops the
    /// account either way; the registration stays.
    public func signOut() async -> SignOutResult {
        signingOut = true
        defer { signingOut = false }
        // A refresh in flight rotates the refresh token: revoke the one it leaves, after it has written it.
        _ = try? await refreshing?.value
        var result = SignOutResult.unconfirmed
        if let account = store.account, !account.refreshToken.isEmpty {
            let request = ChatGPTSignIn.revokeRequest(refreshToken: account.refreshToken, clientID: account.clientID)
            for tries in 1...3 {
                let reply = try? await transport.send(request)
                if let reply, (200..<300).contains(reply.status) { result = .revoked; break }
                if let reply, reply.status < 500 { break }  // refused: asking again does not change that
                if tries < 3 { try? await sleep(.seconds(tries)) }
            }
        }
        store.account = nil
        log.note("ai: chatgpt signed out (\(result))")
        return result
    }

    /// The account, refreshed first when its token expires within 60 s or `renewing` asks, through the one refresh in
    /// flight.
    private func freshAccount(renewing: Bool = false) async throws -> ChatGPTAccount {
        guard !signingOut else { throw SignInError.signedOut }
        if let refreshing { return try await refreshing.value }
        guard let account = store.account else { throw SignInError.signedOut }
        guard renewing || account.expiresAt <= now().addingTimeInterval(60) else { return account }
        let refresh = Task { try await self.refresh(account) }
        refreshing = refresh
        defer { refreshing = nil }
        return try await refresh.value
    }

    private func refresh(_ account: ChatGPTAccount) async throws -> ChatGPTAccount {
        let reply = try await send(
            ChatGPTSignIn.refreshRequest(refreshToken: account.refreshToken, clientID: account.clientID))
        // A sign-in replaced the account meanwhile, or it is gone: this answer is about tokens no longer kept, and
        // none of it is written.
        guard store.account?.refreshToken == account.refreshToken else { throw SignInError.signedOut }
        if (200..<300).contains(reply.status), let tokens = try? TokenResponse.parse(reply.body) {
            // The access token, its expiry, the grant and the rotated refresh token are replaced together.
            var renewed = account
            renewed.accessToken = tokens.accessToken
            renewed.refreshToken = tokens.refreshToken ?? account.refreshToken
            renewed.tokenType = tokens.tokenType
            renewed.expiresIn = tokens.expiresIn
            if !tokens.scopes.isEmpty { renewed.scopes = tokens.scopes }
            renewed.savedAt = now()
            store.account = renewed
            log.note("ai: chatgpt token refreshed")
            return renewed
        }
        let error = (400..<500).contains(reply.status) ? (try? JSON.parse(reply.body))?["error"]?.string : nil
        if let error, error == "invalid_client" || ChatGPTSignIn.terminalRefreshErrors.contains(error) {
            store.account = nil
            // `invalid_client`: OpenAI no longer knows this registration, so the next sign-in registers the app again.
            if error == "invalid_client" { store.clientID = nil }
            throw SignInError.signedOut
        }
        // A passing failure keeps the tokens: they may well work on the next try.
        throw SignInError.network("refresh failed with status \(reply.status)")
    }

    private func keys() async throws -> JSON {
        if let jwks { return jwks }
        let reply = try await send(URLRequest(url: ChatGPT.jwksURL))
        guard (200..<300).contains(reply.status), let keys = try? JSON.parse(reply.body) else {
            throw SignInError.network("signing keys failed with status \(reply.status)")
        }
        jwks = keys
        return keys
    }

    /// `request` through the transport: no answer is `SignInError.network`, except a cancel, which stays one.
    private func send(_ request: URLRequest) async throws -> HTTPReply {
        do {
            return try await transport.send(request)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw SignInError.network(error.localizedDescription)
        }
    }
}

/// `data` as base64url without padding (RFC 4648 §5).
private func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// The bytes of base64url `text`, padded or not; nil when it is not base64url.
private func base64URLDecoded(_ text: some StringProtocol) -> Data? {
    var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    return Data(base64Encoded: base64)
}
