import AppKit
import CryptoKit
import Network
import Security

enum GoogleService: String, CaseIterable {
    case calendar, gmail, drive

    var scope: String {
        switch self {
        case .calendar: "https://www.googleapis.com/auth/calendar.events.readonly"
        case .gmail: "https://www.googleapis.com/auth/gmail.metadata"
        case .drive: "https://www.googleapis.com/auth/drive.metadata.readonly"
        }
    }
}

struct GoogleWidgetData {
    let account: String
    let headline: String
    let lines: [String]
}

private struct GoogleToken: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var account: String
}

private enum GoogleWorkspaceError: LocalizedError {
    case missingClient, invalidClient, authorizationFailed(String), missingRefreshToken
    case missingToken, invalidResponse, http(Int)

    var errorDescription: String? {
        switch self {
        case .missingClient: "Choose a Google Desktop OAuth client in the Webby menu first."
        case .invalidClient: "Choose the JSON for a Google Desktop OAuth client."
        case .authorizationFailed(let message): "Google authorization failed: \(message)"
        case .missingRefreshToken: "Google did not provide offline access. Reconnect this account."
        case .missingToken: "Connect this Google service for the current Webby profile."
        case .invalidResponse: "Google returned an incomplete response."
        case .http(let code): "Google returned HTTP \(code). Reconnect or check API access."
        }
    }
}

/// Receives one OAuth redirect on 127.0.0.1. The random `state` prevents a
/// different local request from completing this account connection.
@MainActor private final class GoogleLoopback {
    private let expectedState: String
    private let completed: (Result<String, Error>) -> Void
    private var listener: NWListener?
    private var done = false

    init(state: String, completed: @escaping (Result<String, Error>) -> Void) {
        expectedState = state
        self.completed = completed
    }

    func start(ready: @escaping (UInt16) -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, !self.done else { return }
                switch state {
                case .ready:
                    if let port = self.listener?.port?.rawValue { ready(port) }
                    else { self.finish(.failure(GoogleWorkspaceError.invalidResponse)) }
                case .failed(let error): self.finish(.failure(error))
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
                Task { @MainActor [weak self] in
                guard let self, !self.done else { connection.cancel(); return }
                let firstLine = data.flatMap { String(data: $0, encoding: .utf8) }?
                    .components(separatedBy: "\r\n").first ?? ""
                let path = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let query = URLComponents(string: "http://127.0.0.1\(path)")?.queryItems ?? []
                let returnedState = query.first { $0.name == "state" }?.value
                let code = query.first { $0.name == "code" }?.value
                let oauthError = query.first { $0.name == "error" }?.value
                let valid = returnedState == self.expectedState
                let message = valid && code != nil ? "Webby is connected. You can close this tab." :
                    "Webby could not connect this account. Return to Webby and try again."
                let body = "<html><body style='font:16px system-ui;padding:40px'>\(message)</body></html>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    Task { @MainActor in
                        connection.cancel()
                        if !valid { self.finish(.failure(GoogleWorkspaceError.authorizationFailed(error?.localizedDescription ?? "Invalid callback state"))) }
                        else if let code { self.finish(.success(code)) }
                        else { self.finish(.failure(GoogleWorkspaceError.authorizationFailed(oauthError ?? "Access denied"))) }
                    }
                })
                }
            }
        }
        listener.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [weak self] in
            guard let self, !self.done else { return }
            self.finish(.failure(GoogleWorkspaceError.authorizationFailed("Timed out")))
        }
    }

    private func finish(_ result: Result<String, Error>) {
        guard !done else { return }
        done = true
        listener?.cancel()
        listener = nil
        completed(result)
    }
}

@MainActor final class GoogleWorkspace {
    static let shared = GoogleWorkspace()
    private let clientKey = "webbyGoogleOAuthClientID"
    private let keychainService = "local.plainwebkit.browser.googleOAuth"
    private var loopback: GoogleLoopback?

    var hasClient: Bool { clientID != nil }

    private var clientID: String? {
        guard let id = UserDefaults.standard.string(forKey: clientKey),
              id.hasSuffix(".apps.googleusercontent.com") else { return nil }
        return id
    }

    func configureClient(from url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let installed = root["installed"] as? [String: Any],
              let id = installed["client_id"] as? String,
              id.hasSuffix(".apps.googleusercontent.com") else { throw GoogleWorkspaceError.invalidClient }
        // Desktop client secrets are not confidential. Webby only needs the
        // public client ID with PKCE; never copy the JSON or its secret into Git.
        UserDefaults.standard.set(id, forKey: clientKey)
    }

    func isConnected(_ service: GoogleService, profile: UUID) -> Bool {
        token(service, profile: profile) != nil
    }

    func disconnect(_ service: GoogleService, profile: UUID) {
        let query = keychainQuery(service, profile: profile)
        SecItemDelete(query as CFDictionary)
    }

    func deleteProfile(_ profile: UUID) {
        for service in GoogleService.allCases { disconnect(service, profile: profile) }
    }

    func connect(_ service: GoogleService, profile: UUID,
                 completion: @escaping (Result<String, Error>) -> Void) {
        guard let clientID else { completion(.failure(GoogleWorkspaceError.missingClient)); return }
        guard loopback == nil else {
            completion(.failure(GoogleWorkspaceError.authorizationFailed("Finish the current Google connection first.")))
            return
        }
        let verifier = randomVerifier()
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let state = UUID().uuidString + UUID().uuidString
        var redirectPort: UInt16 = 0
        let attempt = GoogleLoopback(state: state) { [weak self] result in
            self?.loopback = nil
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let code):
                Task {
                    do {
                        let redirect = "http://127.0.0.1:\(redirectPort)/oauth"
                        let token = try await self?.exchangeCode(code, clientID: clientID,
                                                                  verifier: verifier, redirect: redirect)
                        guard var token else { throw GoogleWorkspaceError.invalidResponse }
                        token.account = try await self?.accountEmail(accessToken: token.accessToken) ?? "Google account"
                        guard self?.save(token, service: service, profile: profile) == errSecSuccess else {
                            throw GoogleWorkspaceError.authorizationFailed("Could not save token in Keychain")
                        }
                        completion(.success(token.account))
                    } catch { completion(.failure(error)) }
                }
            }
        }
        loopback = attempt
        do {
            try attempt.start { [weak self] port in
                redirectPort = port
                var parts = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
                parts.queryItems = [
                    URLQueryItem(name: "client_id", value: clientID),
                    URLQueryItem(name: "redirect_uri", value: "http://127.0.0.1:\(port)/oauth"),
                    URLQueryItem(name: "response_type", value: "code"),
                    URLQueryItem(name: "scope", value: "openid email \(service.scope)"),
                    URLQueryItem(name: "access_type", value: "offline"),
                    URLQueryItem(name: "prompt", value: "consent select_account"),
                    URLQueryItem(name: "code_challenge", value: challenge),
                    URLQueryItem(name: "code_challenge_method", value: "S256"),
                    URLQueryItem(name: "state", value: state)
                ]
                guard let url = parts.url, NSWorkspace.shared.open(url) else {
                    self?.loopback = nil
                    completion(.failure(GoogleWorkspaceError.authorizationFailed("Could not open the system browser")))
                    return
                }
            }
        } catch {
            loopback = nil
            completion(.failure(error))
        }
    }

    func load(_ service: GoogleService, profile: UUID,
              completion: @escaping (Result<GoogleWidgetData, Error>) -> Void) {
        Task {
            do {
                let access = try await validAccessToken(service, profile: profile)
                let account = token(service, profile: profile)?.account ?? "Google account"
                let data: GoogleWidgetData
                switch service {
                case .calendar: data = try await calendarData(access: access, account: account)
                case .gmail: data = try await gmailData(access: access, account: account)
                case .drive: data = try await driveData(access: access, account: account)
                }
                completion(.success(data))
            } catch { completion(.failure(error)) }
        }
    }

    private func calendarData(access: String, account: String) async throws -> GoogleWidgetData {
        var parts = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        parts.queryItems = [URLQueryItem(name: "timeMin", value: ISO8601DateFormatter().string(from: Date())),
                            URLQueryItem(name: "singleEvents", value: "true"),
                            URLQueryItem(name: "orderBy", value: "startTime"),
                            URLQueryItem(name: "maxResults", value: "3")]
        let json = try await getJSON(parts.url!, access: access)
        let events = json["items"] as? [[String: Any]] ?? []
        let parser = ISO8601DateFormatter()
        let time = DateFormatter()
        time.dateStyle = .short; time.timeStyle = .short
        let lines = events.compactMap { event -> String? in
            guard let title = event["summary"] as? String else { return nil }
            let start = event["start"] as? [String: Any] ?? [:]
            let raw = start["dateTime"] as? String ?? start["date"] as? String ?? ""
            let date = parser.date(from: raw) ?? ISO8601DateFormatter().date(from: raw + "T00:00:00Z")
            return "\(date.map(time.string(from:)) ?? raw)  ·  \(title)"
        }
        return GoogleWidgetData(account: account, headline: "Upcoming", lines: lines.isEmpty ? ["No upcoming events"] : lines)
    }

    private func gmailData(access: String, account: String) async throws -> GoogleWidgetData {
        let label = try await getJSON(URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/labels/INBOX")!, access: access)
        let unread = label["messagesUnread"] as? Int ?? 0
        var parts = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        parts.queryItems = [URLQueryItem(name: "maxResults", value: "2"),
                            URLQueryItem(name: "labelIds", value: "INBOX")]
        let list = try await getJSON(parts.url!, access: access)
        let messages = list["messages"] as? [[String: Any]] ?? []
        var lines: [String] = []
        for message in messages {
            guard let id = message["id"] as? String,
                  let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { continue }
            let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(encoded)?format=metadata&metadataHeaders=From&metadataHeaders=Subject")!
            let detail = try await getJSON(url, access: access)
            let headers = (detail["payload"] as? [String: Any])?["headers"] as? [[String: String]] ?? []
            let subject = headers.first { $0["name"]?.lowercased() == "subject" }?["value"] ?? "(No subject)"
            let sender = headers.first { $0["name"]?.lowercased() == "from" }?["value"] ?? ""
            lines.append("\(sender)  ·  \(subject)")
        }
        return GoogleWidgetData(account: account, headline: "\(unread) unread", lines: lines.isEmpty ? ["Inbox is empty"] : lines)
    }

    private func driveData(access: String, account: String) async throws -> GoogleWidgetData {
        var parts = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        parts.queryItems = [URLQueryItem(name: "pageSize", value: "5"),
                            URLQueryItem(name: "q", value: "trashed = false"),
                            URLQueryItem(name: "orderBy", value: "modifiedTime desc"),
                            URLQueryItem(name: "fields", value: "files(id,name,mimeType,modifiedTime,webViewLink)")]
        let json = try await getJSON(parts.url!, access: access)
        let files = json["files"] as? [[String: Any]] ?? []
        let names = files.compactMap { $0["name"] as? String }
        return GoogleWidgetData(account: account, headline: "Recent files",
                                lines: names.isEmpty ? ["No recent files"] : names)
    }

    private func validAccessToken(_ service: GoogleService, profile: UUID) async throws -> String {
        guard var current = token(service, profile: profile) else { throw GoogleWorkspaceError.missingToken }
        if current.expiresAt.timeIntervalSinceNow > 90 { return current.accessToken }
        guard let clientID else { throw GoogleWorkspaceError.missingClient }
        let json = try await postForm(URL(string: "https://oauth2.googleapis.com/token")!, values: [
            "client_id": clientID, "refresh_token": current.refreshToken,
            "grant_type": "refresh_token"
        ])
        guard let access = json["access_token"] as? String else { throw GoogleWorkspaceError.invalidResponse }
        current.accessToken = access
        current.expiresAt = Date().addingTimeInterval((json["expires_in"] as? Double) ?? 3600)
        guard save(current, service: service, profile: profile) == errSecSuccess else {
            throw GoogleWorkspaceError.authorizationFailed("Could not update Keychain")
        }
        return access
    }

    private func exchangeCode(_ code: String, clientID: String, verifier: String,
                              redirect: String) async throws -> GoogleToken {
        let json = try await postForm(URL(string: "https://oauth2.googleapis.com/token")!, values: [
            "client_id": clientID, "code": code, "code_verifier": verifier,
            "redirect_uri": redirect, "grant_type": "authorization_code"
        ])
        guard let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String else { throw GoogleWorkspaceError.missingRefreshToken }
        return GoogleToken(accessToken: access, refreshToken: refresh,
                           expiresAt: Date().addingTimeInterval((json["expires_in"] as? Double) ?? 3600),
                           account: "Google account")
    }

    private func accountEmail(accessToken: String) async throws -> String {
        let json = try await getJSON(URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!, access: accessToken)
        return json["email"] as? String ?? "Google account"
    }

    private func getJSON(_ url: URL, access: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        return try await responseJSON(request)
    }

    private func postForm(_ url: URL, values: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var parts = URLComponents()
        parts.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((parts.percentEncodedQuery ?? "").utf8)
        return try await responseJSON(request)
    }

    private func responseJSON(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GoogleWorkspaceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw GoogleWorkspaceError.http(http.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoogleWorkspaceError.invalidResponse
        }
        return json
    }

    private func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func keychainQuery(_ service: GoogleService, profile: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: "\(profile.uuidString)|\(service.rawValue)"]
    }

    private func token(_ service: GoogleService, profile: UUID) -> GoogleToken? {
        var query = keychainQuery(service, profile: profile)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(GoogleToken.self, from: data)
    }

    private func save(_ token: GoogleToken, service: GoogleService, profile: UUID) -> OSStatus {
        let key = keychainQuery(service, profile: profile)
        guard let data = try? JSONEncoder().encode(token) else { return errSecParam }
        let status = SecItemAdd(key.merging([kSecValueData as String: data]) { _, value in value } as CFDictionary, nil)
        if status == errSecDuplicateItem {
            return SecItemUpdate(key as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        return status
    }
}
