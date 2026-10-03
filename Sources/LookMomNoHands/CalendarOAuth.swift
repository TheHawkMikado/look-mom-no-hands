import Foundation
import AppKit
import CryptoKit
import Network

/// OAuth 2.0 authorization-code flow with PKCE for native apps, done the way
/// Google and Microsoft require it on desktop: open the system browser and
/// catch the redirect on a one-shot localhost listener. No embedded webview
/// (both providers block them), no external dependencies.
enum CalendarOAuth {

    enum OAuthError: Error, CustomStringConvertible {
        case listenFailed
        case timedOut
        case badRedirect(String)
        case tokenExchange(String)

        var description: String {
            switch self {
            case .listenFailed: return "couldn't open a local port for the sign-in redirect"
            case .timedOut: return "sign-in timed out — the browser window was never completed"
            case .badRedirect(let m): return "sign-in redirect was invalid: \(m)"
            case .tokenExchange(let m): return "token exchange failed: \(m)"
            }
        }
    }

    struct TokenResponse: Sendable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: TimeInterval
        let idToken: String?
    }

    // MARK: PKCE (pure — unit-tested)

    /// RFC 7636 base64url, no padding.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func codeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// The authorization URL the browser opens. Pure — unit-tested.
    static func authorizationURL(endpoint: String, clientID: String, redirectURI: String,
                                 scope: String, state: String, challenge: String,
                                 extra: [String: String] = [:]) -> URL? {
        var comps = URLComponents(string: endpoint)
        var items = [URLQueryItem(name: "client_id", value: clientID),
                     URLQueryItem(name: "redirect_uri", value: redirectURI),
                     URLQueryItem(name: "response_type", value: "code"),
                     URLQueryItem(name: "scope", value: scope),
                     URLQueryItem(name: "state", value: state),
                     URLQueryItem(name: "code_challenge", value: challenge),
                     URLQueryItem(name: "code_challenge_method", value: "S256")]
        items += extra.map { URLQueryItem(name: $0.key, value: $0.value) }.sorted { $0.name < $1.name }
        comps?.queryItems = items
        return comps?.url
    }

    /// Pulls `code` out of the redirect's request line, refusing a mismatched
    /// `state` (a stray tab from an older attempt must not complete this one)
    /// and surfacing the provider's `error` param. Pure — unit-tested.
    static func extractCode(fromRequestLine line: String, expectedState: String) throws -> String {
        // "GET /?code=…&state=… HTTP/1.1"
        let parts = line.split(separator: " ")
        guard parts.count >= 2,
              let comps = URLComponents(string: String(parts[1])) else {
            throw OAuthError.badRedirect("unparseable request")
        }
        let q = { (name: String) in comps.queryItems?.first { $0.name == name }?.value }
        if let err = q("error") { throw OAuthError.badRedirect(err) }
        guard q("state") == expectedState else { throw OAuthError.badRedirect("state mismatch") }
        guard let code = q("code"), !code.isEmpty else { throw OAuthError.badRedirect("no code") }
        return code
    }

    /// Form-encodes a token request body. Pure — unit-tested.
    static func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let s = fields.sorted { $0.key < $1.key }.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&")
        return Data(s.utf8)
    }

    /// The claims payload of a JWT, undecoded middle segment → JSON. Used only
    /// to read the signed-in email out of an id_token we just received over
    /// TLS from the token endpoint — NOT signature-verified, and must never
    /// gate anything security-relevant. Pure — unit-tested.
    static func jwtClaims(_ jwt: String) -> [String: Any]? {
        let segments = jwt.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var b64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: The interactive flow

    /// Opens the browser and waits (up to 5 minutes) for the provider to
    /// redirect back to the loopback listener, then exchanges the code.
    /// `redirectHost` differs per provider: Google documents 127.0.0.1,
    /// Microsoft registers `http://localhost`.
    static func run(authEndpoint: String, tokenEndpoint: String, clientID: String,
                    clientSecret: String?, scope: String, redirectHost: String,
                    extraAuthParams: [String: String] = [:]) async throws -> TokenResponse {
        let verifier = codeVerifier()
        let state = base64URL(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))

        let listener = try? NWListener(using: .tcp, on: .any)
        guard let listener else { throw OAuthError.listenFailed }

        // The bound port must be captured while the listener is alive — it's
        // nil again after cancel(), and the token exchange needs the EXACT
        // redirect_uri the browser was sent or the provider rejects the code.
        final class PortBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value: UInt16 = 0
            func set(_ v: UInt16) { lock.lock(); value = v; lock.unlock() }
            func get() -> UInt16 { lock.lock(); defer { lock.unlock() }; return value }
        }
        let portBox = PortBox()

        // One-shot HTTP server: first connection wins, everything is torn down
        // after a single request line is read and answered.
        let requestLine: String = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                    let done = NSLock()
                    var finished = false
                    func finish(_ result: Result<String, Error>) {
                        done.lock(); defer { done.unlock() }
                        guard !finished else { return }
                        finished = true
                        cont.resume(with: result)
                    }
                    listener.newConnectionHandler = { conn in
                        conn.start(queue: .global(qos: .userInitiated))
                        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                            let text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                            let line = text.split(separator: "\r\n").first.map(String.init) ?? ""
                            let html = """
                            HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n
                            <html><body style="font-family:-apple-system;margin:40px">
                            <h2>Connected.</h2><p>You can close this tab and go back to Look Ma, No Hands.</p>
                            </body></html>
                            """
                            conn.send(content: Data(html.utf8), completion: .contentProcessed { _ in
                                conn.cancel()
                            })
                            finish(.success(line))
                        }
                    }
                    listener.stateUpdateHandler = { st in
                        if case .failed = st { finish(.failure(OAuthError.listenFailed)) }
                    }
                    listener.start(queue: .global(qos: .userInitiated))
                    // The listener needs a beat to bind before we can read the
                    // port; poll briefly rather than racing start().
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                        guard let port = listener.port?.rawValue else {
                            finish(.failure(OAuthError.listenFailed)); return
                        }
                        portBox.set(port)
                        let redirect = "http://\(redirectHost):\(port)"
                        guard let url = authorizationURL(endpoint: authEndpoint, clientID: clientID,
                                                         redirectURI: redirect, scope: scope,
                                                         state: state,
                                                         challenge: codeChallenge(for: verifier),
                                                         extra: extraAuthParams) else {
                            finish(.failure(OAuthError.badRedirect("bad auth url"))); return
                        }
                        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 300_000_000_000)   // 5 min
                throw OAuthError.timedOut
            }
            defer { listener.cancel() }
            guard let first = try await group.next() else { throw OAuthError.timedOut }
            group.cancelAll()
            return first
        }

        let port = portBox.get()
        let code = try extractCode(fromRequestLine: requestLine, expectedState: state)
        var fields = ["grant_type": "authorization_code",
                      "code": code,
                      "client_id": clientID,
                      "redirect_uri": "http://\(redirectHost):\(port)",
                      "code_verifier": verifier]
        if let clientSecret { fields["client_secret"] = clientSecret }
        return try await exchange(tokenEndpoint: tokenEndpoint, fields: fields)
    }

    /// Token endpoint POST, shared by the initial exchange and refreshes.
    static func exchange(tokenEndpoint: String, fields: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formBody(fields)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = json["access_token"] as? String else {
            throw OAuthError.tokenExchange("HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        return TokenResponse(accessToken: access,
                             refreshToken: json["refresh_token"] as? String,
                             expiresIn: (json["expires_in"] as? Double) ?? 3600,
                             idToken: json["id_token"] as? String)
    }
}
