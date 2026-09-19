import CryptoKit
import Foundation
import Security

public struct OneDriveAuthorizationRequest: Sendable {
    public var authorizationURL: URL
    public var redirectURI: String
    public var callbackScheme: String
    public var state: String
    public var codeVerifier: String
}

public struct OneDriveDeviceCode: Sendable {
    public var deviceCode: String
    public var userCode: String
    public var verificationURL: URL
    public var message: String
    public var expiresIn: Int
    public var interval: Int
}

public struct OneDriveCredential: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
}

public struct OneDriveAccount: Sendable {
    public var displayName: String
    public var email: String
}

public actor OneDriveClient {
    private let clientID: String
    private let session: URLSession
    private let scope = "offline_access User.Read Files.ReadWrite.AppFolder"
    private var appRootIsReady = false

    public init(clientID: String, session: URLSession = .shared) {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    public func authorizationRequest(callbackScheme: String) throws -> OneDriveAuthorizationRequest {
        guard !clientID.isEmpty else { throw STGError.invalidDocument("Microsoft OneDrive Client ID is missing from the app configuration") }
        let verifier = try randomURLSafe(byteCount: 48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        let state = try randomURLSafe(byteCount: 24)
        let redirect = "\(callbackScheme)://auth"
        var components = URLComponents(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirect), .init(name: "response_mode", value: "query"),
            .init(name: "scope", value: scope), .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "state", value: state),
            .init(name: "prompt", value: "select_account")
        ]
        guard let url = components.url else { throw STGError.invalidDocument("Unable to construct Microsoft sign-in URL") }
        return .init(authorizationURL: url, redirectURI: redirect, callbackScheme: callbackScheme, state: state, codeVerifier: verifier)
    }

    public func credential(callbackURL: URL, request authorization: OneDriveAuthorizationRequest) async throws -> OneDriveCredential {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw STGError.invalidDocument("Microsoft returned an invalid sign-in response")
        }
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        if let error = values["error"] {
            let detail = values["error_description"].flatMap { $0.isEmpty ? nil : $0 } ?? error
            throw STGError.invalidDocument("Microsoft sign-in failed: \(detail)")
        }
        guard values["state"] == authorization.state else { throw STGError.invalidDocument("Microsoft sign-in state did not match") }
        guard let code = values["code"], !code.isEmpty else { throw STGError.invalidDocument("Microsoft sign-in returned no authorization code") }
        let data = try await postForm(url: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!, items: [
            "client_id": clientID, "code": code, "code_verifier": authorization.codeVerifier,
            "grant_type": "authorization_code", "redirect_uri": authorization.redirectURI, "scope": scope
        ])
        return try credential(from: data)
    }

    public func requestDeviceCode() async throws -> OneDriveDeviceCode {
        guard !clientID.isEmpty else { throw STGError.invalidDocument("Microsoft OneDrive Client ID is missing from the app configuration") }
        let data = try await postForm(url: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/devicecode")!, items: ["client_id": clientID, "scope": scope])
        let value = try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
        guard let url = URL(string: value.verificationURI) else { throw STGError.invalidDocument("Microsoft returned an invalid verification URL") }
        return OneDriveDeviceCode(deviceCode: value.deviceCode, userCode: value.userCode, verificationURL: url, message: value.message, expiresIn: value.expiresIn, interval: value.interval)
    }

    public func waitForAuthorization(_ code: OneDriveDeviceCode) async throws -> OneDriveCredential {
        let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
        var interval = max(3, code.interval)
        while Date() < deadline {
            try Task.checkCancellation()
            do {
                let data = try await postForm(url: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!, items: [
                    "client_id": clientID,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                    "device_code": code.deviceCode
                ])
                return try credential(from: data)
            } catch let error as OAuthPendingError {
                if error.code == "slow_down" { interval += 5 }
                else if error.code != "authorization_pending" { throw STGError.invalidDocument("Microsoft sign-in failed: \(error.description)") }
            }
            try await Task.sleep(for: .seconds(interval))
        }
        throw STGError.invalidDocument("Microsoft sign-in code expired")
    }

    public func refreshed(_ credential: OneDriveCredential) async throws -> OneDriveCredential {
        if credential.expiresAt.timeIntervalSinceNow > 120 { return credential }
        let data = try await postForm(url: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!, items: [
            "client_id": clientID, "grant_type": "refresh_token", "refresh_token": credential.refreshToken, "scope": scope
        ])
        return try self.credential(from: data, fallbackRefreshToken: credential.refreshToken)
    }

    public func account(using credential: OneDriveCredential) async throws -> OneDriveAccount {
        let data = try await graph(path: "/v1.0/me?$select=displayName,mail,userPrincipalName", operation: "read account profile", credential: credential)
        let profile = try JSONDecoder().decode(ProfileResponse.self, from: data)
        return OneDriveAccount(displayName: profile.displayName, email: profile.mail ?? profile.userPrincipalName ?? "Microsoft account")
    }

    public func listFiles(using credential: OneDriveCredential) async throws -> [OneDriveFile] {
        try await ensureAppRoot(using: credential)
        let data = try await graph(path: "/v1.0/me/drive/special/approot/children?$select=id,name,lastModifiedDateTime", operation: "list App Folder", credential: credential)
        return try JSONDecoder().decode(FileListResponse.self, from: data).value
    }

    public func listFiles(folderID: String, using credential: OneDriveCredential) async throws -> [OneDriveFile] {
        let data = try await graph(path: "/v1.0/me/drive/items/\(folderID)/children?$select=id,name,lastModifiedDateTime", operation: "list folder", credential: credential)
        return try JSONDecoder().decode(FileListResponse.self, from: data).value
    }

    public func ensureFolder(name: String, using credential: OneDriveCredential) async throws -> String {
        if let existing = try await listFiles(using: credential).first(where: { $0.name == name }) { return existing.id }
        let rootData = try await graph(path: "/v1.0/me/drive/special/approot?$select=id,name", operation: "read App Folder identity", credential: credential)
        let rootID = try JSONDecoder().decode(OneDriveFile.self, from: rootData).id
        var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/\(rootID)/children")!); request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "folder": [:], "@microsoft.graph.conflictBehavior": "replace"])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request); try Self.validate(response, data: data, operation: "create App Folder subfolder")
        return try JSONDecoder().decode(OneDriveFile.self, from: data).id
    }

    public func upload(name: String, data: Data, using credential: OneDriveCredential) async throws {
        try await ensureAppRoot(using: credential)
        let escaped = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/drive/special/approot:/\(escaped):/content")!)
        request.httpMethod = "PUT"; request.httpBody = data
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (responseData, response) = try await session.data(for: request); try Self.validate(response, data: responseData, operation: "upload App Folder file")
    }

    public func upload(name: String, data: Data, folderID: String, using credential: OneDriveCredential) async throws {
        let escaped = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/\(folderID):/\(escaped):/content")!)
        request.httpMethod = "PUT"; request.httpBody = data; request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (responseData, response) = try await session.data(for: request); try Self.validate(response, data: responseData, operation: "upload folder file")
    }

    public func delete(fileID: String, using credential: OneDriveCredential) async throws {
        var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/\(fileID)")!); request.httpMethod = "DELETE"; request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request); try Self.validate(response, data: data, operation: "delete file")
    }

    public func download(fileID: String, using credential: OneDriveCredential) async throws -> Data {
        try await graph(path: "/v1.0/me/drive/items/\(fileID)/content", operation: "download file", credential: credential)
    }

    public func download(name: String, using credential: OneDriveCredential) async throws -> Data? {
        try await ensureAppRoot(using: credential)
        let escaped = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/drive/special/approot:/\(escaped):/content")!)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return nil }
        try Self.validate(response, data: data, operation: "download App Folder file")
        return data
    }

    private func graph(path: String, operation: String, credential: OneDriveCredential) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://graph.microsoft.com\(path)")!)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request); try Self.validate(response, data: data, operation: operation); return data
    }

    /// Microsoft Graph creates an app's special App Folder on first access to
    /// the folder itself. Addressing a child path before that provisioning call
    /// can fail even though account authorization succeeded.
    private func ensureAppRoot(using credential: OneDriveCredential) async throws {
        guard !appRootIsReady else { return }
        let retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8)]
        for attempt in 0...retryDelays.count {
            do {
                _ = try await graph(
                    path: "/v1.0/me/drive/special/approot?$select=id,name,specialFolder",
                    operation: "open App Folder",
                    credential: credential
                )
                appRootIsReady = true
                return
            } catch {
                guard Self.isPendingProvisioning(error) else { throw error }
                if attempt == 0 {
                    // Reading the drive root gives Graph a chance to finish provisioning
                    // before the special App Folder is requested again.
                    _ = try? await graph(
                        path: "/v1.0/me/drive?$select=id,driveType",
                        operation: "initialize OneDrive",
                        credential: credential
                    )
                }
                guard attempt < retryDelays.count else {
                    throw STGError.invalidDocument(
                        "OneDrive is still preparing this account. Open OneDrive once with the same Microsoft account, wait for its Files page to load, then return to STG and sync again."
                    )
                }
                try await Task.sleep(for: retryDelays[attempt])
            }
        }
    }

    private static func isPendingProvisioning(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("pending provisioning") ||
            (message.contains("servicenotavailable") && message.contains("http 503"))
    }

    private func postForm(url: URL, items: [String: String]) async throws -> Data {
        var components = URLComponents(); components.queryItems = items.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url); request.httpMethod = "POST"
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode { return data }
        if let error = try? JSONDecoder().decode(OAuthErrorResponse.self, from: data) { throw OAuthPendingError(code: error.error, description: error.errorDescription ?? error.error) }
        try Self.validate(response, data: data, operation: "OAuth token request"); return data
    }

    private func credential(from data: Data, fallbackRefreshToken: String = "") throws -> OneDriveCredential {
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        let refresh = token.refreshToken ?? fallbackRefreshToken
        guard !refresh.isEmpty else { throw STGError.invalidDocument("Microsoft did not return an offline refresh token; sign in again") }
        return OneDriveCredential(accessToken: token.accessToken, refreshToken: refresh, expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn)))
    }

    private func randomURLSafe(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw STGError.invalidDocument("Unable to create Microsoft OAuth security nonce")
        }
        return Data(bytes).base64URLEncodedString()
    }

    private static func validate(_ response: URLResponse, data: Data, operation: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw STGError.invalidDocument("Microsoft \(operation) failed: invalid HTTP response")
        }
        guard 200..<300 ~= http.statusCode else {
            let graphError = try? JSONDecoder().decode(GraphErrorResponse.self, from: data).error
            let message = graphError?.message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            let codeSuffix = graphError.map { "; code=\($0.code)" } ?? ""
            let requestIDSuffix = http.value(forHTTPHeaderField: "request-id").map { "; request_id=\($0)" } ?? ""
            throw STGError.invalidDocument("Microsoft \(operation) failed (HTTP \(http.statusCode)\(codeSuffix)\(requestIDSuffix)): \(message)")
        }
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

public struct OneDriveFile: Decodable, Sendable {
    public var id: String
    public var name: String
}

public enum OneDriveCredentialStore {
    public static func save(_ credential: OneDriveCredential, service: String, accessGroup: String? = nil) throws {
        let data = try JSONEncoder().encode(credential)
        let query = query(service: service, accessGroup: accessGroup)
        SecItemDelete(query as CFDictionary)
        var add = query; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            let systemMessage = SecCopyErrorMessageString(status, nil) as String? ?? "unknown Keychain error"
            throw STGError.invalidDocument("Unable to store Microsoft credential in Keychain: \(systemMessage) (OSStatus \(status))")
        }
    }

    public static func load(service: String, accessGroup: String? = nil) -> OneDriveCredential? {
        var query = query(service: service, accessGroup: accessGroup)
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(OneDriveCredential.self, from: data)
    }

    public static func remove(service: String, accessGroup: String? = nil) {
        SecItemDelete(query(service: service, accessGroup: accessGroup) as CFDictionary)
    }

    private static func query(service: String, accessGroup: String?) -> [String: Any] {
        var value: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let accessGroup, !accessGroup.isEmpty { value[kSecAttrAccessGroup as String] = accessGroup }
        return value
    }
}

private struct DeviceCodeResponse: Decodable {
    var deviceCode: String; var userCode: String; var verificationURI: String; var expiresIn: Int; var interval: Int; var message: String
    enum CodingKeys: String, CodingKey { case deviceCode = "device_code", userCode = "user_code", verificationURI = "verification_uri", expiresIn = "expires_in", interval, message }
}
private struct TokenResponse: Decodable {
    var accessToken: String; var refreshToken: String?; var expiresIn: Int
    enum CodingKeys: String, CodingKey { case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in" }
}
private struct OAuthErrorResponse: Decodable {
    var error: String; var errorDescription: String?
    enum CodingKeys: String, CodingKey { case error, errorDescription = "error_description" }
}
private struct OAuthPendingError: Error { var code: String; var description: String }
private struct ProfileResponse: Decodable { var displayName: String; var mail: String?; var userPrincipalName: String? }
private struct FileListResponse: Decodable { var value: [OneDriveFile] }
private struct GraphErrorResponse: Decodable {
    struct Body: Decodable { var code: String; var message: String }
    var error: Body
}
