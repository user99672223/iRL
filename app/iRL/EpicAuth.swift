import Foundation
import Security

// Epic sign-in for iRL: the auth part of Madeira's SwiftEpic/EpicAPI.swift (itself Legendary's
// flow), nothing else. Web login -> one-use authorization code -> access + refresh token, kept in
// one Keychain item; before each game launch a fresh exchange code for -AUTH_PASSWORD.
// Log lines never contain a token, code, name or account id.

struct EpicSession: Codable, Sendable {
    var accountID: String
    var displayName: String
    var accessToken: String
    var accessExpires: Date
    var refreshToken: String
    var refreshExpires: Date
}

enum EpicAuthError: LocalizedError {
    case signedOut
    case epic(code: String, message: String)
    case http(Int)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .signedOut: return "Sign in to Epic Games to continue."
        case .epic(let code, let message):
            if code.hasSuffix("invalid_grant") || code.hasSuffix("authorization_code_not_found") {
                return "Epic did not accept this sign-in code. Codes work once and expire after a few minutes: sign in again."
            }
            if code.hasSuffix("corrective_action_required") {
                return "Epic needs you to act on your account first (for example to accept new terms). Sign in at epicgames.com, then try again."
            }
            return message.isEmpty ? "Epic refused the request (\(code))." : message
        case .http(let status): return "Epic's server answered with HTTP \(status). Try again later."
        case .invalid(let what): return "Epic sent an unexpected answer (\(what))."
        }
    }
    /// Short and credential-free, for the log.
    var reason: String {
        switch self {
        case .signedOut: return "signed-out"
        case .epic(let code, _): return code.split(separator: ".").suffix(2).joined(separator: ".")
        case .http(let status): return "http-\(status)"
        case .invalid(let what): return "invalid-\(what)"
        }
    }
}

enum EpicTokenStore {
    private static let service = "irl.epic.tokens"
    private static let account = "session"

    static func load() -> EpicSession? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(EpicSession.self, from: data)
    }

    @discardableResult static func save(_ session: EpicSession) -> Bool {
        guard let data = try? JSONEncoder().encode(session) else { return false }
        delete()
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account, kSecValueData as String: data,
                                   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                   kSecAttrSynchronizable as String: false]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

actor EpicAuth {
    static let shared = EpicAuth()

    // The Epic Games Launcher's public client (the one Legendary uses).
    private static let clientID = "34a02cf8f4414e29b15921876da36f9a"
    private static let clientSecret = "daafbccc737745039dffe53d94fc76cf"
    static let userAgent = "UELauncher/11.0.1-14907503+++Portal+Release-Live Windows/10.0.19041.1.256.64bit"
    private static let oauthHost = "https://account-public-service-prod03.ol.epicgames.com"

    static let loginURL: URL = {
        let redirect = "https://www.epicgames.com/id/api/redirect?clientId=\(clientID)&responseType=code"
        let encoded = redirect.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? redirect
        return URL(string: "https://www.epicgames.com/id/login?redirectUrl=\(encoded)")!
    }()

    static func isRedirectPage(_ url: URL?) -> Bool {
        guard let url, url.host?.lowercased() == "www.epicgames.com" else { return false }
        return url.path.lowercased().hasPrefix("/id/api/redirect")
    }

    /// The authorization code in the redirect page's JSON (or a pasted code).
    static func authorizationCode(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = object["authorizationCode"] as? String, !code.isEmpty {
            return code
        }
        if let pattern = try? NSRegularExpression(pattern: "\"authorizationCode\"\\s*:\\s*\"([0-9A-Za-z]+)\""),
           let match = pattern.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let range = Range(match.range(at: 1), in: trimmed) {
            return String(trimmed[range])
        }
        if (20...64).contains(trimmed.count), trimmed.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) {
            return trimmed
        }
        return nil
    }

    private let http: URLSession
    private var session: EpicSession?
    private var loaded = false

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        http = URLSession(configuration: config)
    }

    private func stored() -> EpicSession? {
        if !loaded { session = EpicTokenStore.load(); loaded = true }
        return session
    }

    func account() -> (id: String, name: String)? { stored().map { ($0.accountID, $0.displayName) } }

    func signIn(authorizationCode code: String) async throws {
        _ = try await token(["grant_type": "authorization_code", "code": code, "token_type": "eg1"])
        LogStore.shared.log("[epic] signed in", level: .success)
    }

    func signOut() {
        session = nil; loaded = true
        EpicTokenStore.delete()
        LogStore.shared.log("[epic] signed out")
    }

    /// A session whose access token is good for at least five more minutes.
    func validSession() async throws -> EpicSession {
        guard let current = stored() else { throw EpicAuthError.signedOut }
        if current.accessExpires.timeIntervalSinceNow > 300 { return current }
        guard current.refreshExpires.timeIntervalSinceNow > 60 else { signOut(); throw EpicAuthError.signedOut }
        do {
            let refreshed = try await token(["grant_type": "refresh_token", "refresh_token": current.refreshToken, "token_type": "eg1"])
            LogStore.shared.log("[epic] token refreshed")
            return refreshed
        } catch let error as EpicAuthError {
            if case .epic(let code, _) = error, code.contains("invalid_refresh_token") || code.contains("invalid_grant") || code.contains(".auth_token.") {
                signOut(); throw EpicAuthError.signedOut
            }
            throw error
        }
    }

    /// A one-use code the game trades for its own Epic session (-AUTH_PASSWORD). A new one per launch.
    func exchangeCode() async throws -> String {
        let s = try await validSession()
        var request = URLRequest(url: URL(string: Self.oauthHost + "/account/api/oauth/exchange")!)
        request.setValue("bearer \(s.accessToken)", forHTTPHeaderField: "Authorization")
        let json = try await object(request, method: "exchange")
        guard let code = json["code"] as? String, !code.isEmpty else { throw EpicAuthError.invalid("exchange") }
        return code
    }

    private func token(_ form: [String: String]) async throws -> EpicSession {
        var request = URLRequest(url: URL(string: Self.oauthHost + "/account/api/oauth/token")!)
        request.httpMethod = "POST"
        let basic = Data("\(Self.clientID):\(Self.clientSecret)".utf8).base64EncodedString()
        request.setValue("basic \(basic)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form.map { "\($0.key)=\(Self.formEncode($0.value))" }.sorted().joined(separator: "&").utf8)
        let json = try await object(request, method: "oauth-token")
        guard let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String,
              let account = json["account_id"] as? String else { throw EpicAuthError.invalid("token") }
        let now = Date()
        let s = EpicSession(accountID: account, displayName: json["displayName"] as? String ?? "",
                            accessToken: access,
                            accessExpires: now.addingTimeInterval((json["expires_in"] as? NSNumber)?.doubleValue ?? 3600),
                            refreshToken: refresh,
                            refreshExpires: now.addingTimeInterval((json["refresh_expires"] as? NSNumber)?.doubleValue ?? 8 * 3600))
        session = s; loaded = true
        EpicTokenStore.save(s)
        return s
    }

    private static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private func object(_ request: URLRequest, method: String) async throws -> [String: Any] {
        let (data, response) = try await http.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 400 || status == 0 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let code = json["errorCode"] as? String {
                let error = EpicAuthError.epic(code: code, message: json["errorMessage"] as? String ?? "")
                LogStore.shared.log("[epic] \(method) failed reason=\(error.reason)", level: .error)
                throw error
            }
            LogStore.shared.log("[epic] \(method) failed reason=http-\(status)", level: .error)
            throw EpicAuthError.http(status)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw EpicAuthError.invalid(method) }
        return json
    }
}

/// Legendary's launch argument set for Rocket League (legendary/core.py get_launch_parameters),
/// pointed at RocketLeague.exe instead of the store's Launcher.exe (the EAC bootstrapper): the
/// no-EAC launch Psyonix supports [confirmed].
enum RocketLeagueLaunch {
    static let appName = "Sugar"                                       // Heroic's installed.json
    static let sandboxID = "9773aa1aa54f4f7b80e44bef04986cea"          // Sugar.json namespace

    /// A dummy exchange code for offline launches. Without -AUTH_* the game hands off to the Epic
    /// launcher (LaunchURL) and exits; with the full set and an unknown code it reports
    /// EOS_Auth_ExchangeCodeNotFound and continues offline to the main menu (laptop trace).
    static let offlineCode = String(repeating: "0", count: 32)

    static func arguments(exchangeCode: String?, accountID: String, displayName: String) -> [String] {
        let locale = Locale.current.language.languageCode?.identifier ?? "en"   // Legendary: bare code, e.g. "en"
        var args = [
            "-AUTH_LOGIN=unused",
            "-AUTH_PASSWORD=\(exchangeCode ?? offlineCode)",
            "-AUTH_TYPE=exchangecode",
            "-epicapp=\(appName)",
            "-epicenv=Prod",
            "-EpicPortal",
        ]
        if !displayName.isEmpty { args.append("-epicusername=\(displayName)") }   // unknown offline: omitted
        if !accountID.isEmpty { args.append("-epicuserid=\(accountID)") }
        args.append("-epiclocale=\(locale)")
        args.append("-epicsandboxid=\(sandboxID)")
        return args
    }

    /// Windows command-line quoting (MADEIRA_ARGS is parsed with CommandLineToArgvW rules).
    static func commandLine(_ args: [String]) -> String {
        args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
    }

    /// For logs: the same line with every secret replaced.
    static func redacted(_ args: [String]) -> String {
        args.map { a in
            for key in ["-AUTH_PASSWORD=", "-epicuserid=", "-epicusername="] where a.hasPrefix(key) { return key + "<redacted>" }
            return a
        }.joined(separator: " ")
    }
}
