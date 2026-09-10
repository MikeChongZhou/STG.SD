import CryptoKit
import Foundation
import Security

public struct GoogleDriveAuthorizationRequest: Sendable {
    public var authorizationURL: URL
    public var redirectURI: String
    public var callbackScheme: String
    public var state: String
    public var codeVerifier: String
}

public struct GoogleDriveCredential: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
}

public struct GoogleDriveAccount: Sendable {
    public var displayName: String
    public var email: String
}

public struct GoogleDriveFile: Decodable, Sendable {
    public var id: String
    public var name: String
}

public actor GoogleDriveClient {
    private let clientID: String
    private let clientSecret: String
    private let session: URLSession
    private let scope = "openid email profile https://www.googleapis.com/auth/drive.appdata"

    public init(clientID: String, clientSecret: String = "", session: URLSession = .shared) {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    public func authorizationRequest(callbackScheme: String) throws -> GoogleDriveAuthorizationRequest {
        guard !clientID.isEmpty else { throw STGError.invalidDocument("Google OAuth Client ID is missing from the app configuration") }
        let verifier = try randomURLSafe(byteCount: 48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        let state = try randomURLSafe(byteCount: 24)
        let redirect = "\(callbackScheme):/oauth2redirect"
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state), .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"), .init(name: "include_granted_scopes", value: "true")
        ]
        guard let url = components.url else { throw STGError.invalidDocument("Unable to construct Google sign-in URL") }
        return .init(authorizationURL: url, redirectURI: redirect, callbackScheme: callbackScheme, state: state, codeVerifier: verifier)
    }

    public func credential(callbackURL: URL, request authorization: GoogleDriveAuthorizationRequest) async throws -> GoogleDriveCredential {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw STGError.invalidDocument("Google returned an invalid sign-in response")
        }
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        if let error = values["error"] { throw STGError.invalidDocument("Google sign-in failed: \(error)") }
        guard values["state"] == authorization.state else { throw STGError.invalidDocument("Google sign-in state did not match") }
        guard let code = values["code"], !code.isEmpty else { throw STGError.invalidDocument("Google sign-in returned no authorization code") }
        var tokenItems = [
            "client_id": clientID, "code": code, "code_verifier": authorization.codeVerifier,
            "grant_type": "authorization_code", "redirect_uri": authorization.redirectURI
        ]
        if !clientSecret.isEmpty { tokenItems["client_secret"] = clientSecret }
        let data = try await postForm(url: URL(string: "https://oauth2.googleapis.com/token")!, items: tokenItems)
        return try decodeCredential(data)
    }

    public func refreshed(_ credential: GoogleDriveCredential) async throws -> GoogleDriveCredential {
        if credential.expiresAt.timeIntervalSinceNow > 120 { return credential }
        var tokenItems = [
            "client_id": clientID, "refresh_token": credential.refreshToken, "grant_type": "refresh_token"
        ]
        if !clientSecret.isEmpty { tokenItems["client_secret"] = clientSecret }
        let data = try await postForm(url: URL(string: "https://oauth2.googleapis.com/token")!, items: tokenItems)
        return try decodeCredential(data, fallbackRefreshToken: credential.refreshToken)
    }

    public func account(using credential: GoogleDriveCredential) async throws -> GoogleDriveAccount {
        let data = try await authorizedRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!, credential: credential)
        let profile = try JSONDecoder().decode(ProfileResponse.self, from: data)
        return .init(displayName: profile.name ?? profile.email, email: profile.email)
    }

    public func listFiles(names: Set<String>? = nil, parentID: String? = nil, using credential: GoogleDriveCredential) async throws -> [GoogleDriveFile] {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        var query = "trashed = false"
        if let names, !names.isEmpty {
            let clauses = names.sorted().map { name in
                let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
                return "name = '\(escaped)'"
            }
            query += " and (\(clauses.joined(separator: " or ")))"
        }
        if let parentID { query += " and '\(parentID)' in parents" }
        components.queryItems = [
            .init(name: "spaces", value: "appDataFolder"), .init(name: "fields", value: "files(id,name)"),
            .init(name: "pageSize", value: "1000"), .init(name: "q", value: query)
        ]
        let data = try await authorizedRequest(url: components.url!, credential: credential)
        return try JSONDecoder().decode(FileListResponse.self, from: data).files
    }

    public func ensureFolder(name: String, using credential: GoogleDriveCredential) async throws -> String {
        if let existing = try await listFiles(names: [name], using: credential).first(where: { $0.name == name }) { return existing.id }
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files")!); request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "mimeType": "application/vnd.google-apps.folder", "parents": ["appDataFolder"]])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request); try validate(response, data: data, operation: "create app-data folder")
        return try JSONDecoder().decode(GoogleDriveFile.self, from: data).id
    }

    public func upload(name: String, data: Data, existingFileID: String?, parentID: String? = nil, using credential: GoogleDriveCredential) async throws {
        if let fileID = existingFileID {
            var components = URLComponents(string: "https://www.googleapis.com/upload/drive/v3/files/\(fileID)")!
            components.queryItems = [.init(name: "uploadType", value: "media")]
            var request = URLRequest(url: components.url!); request.httpMethod = "PATCH"; request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            try await send(&request, credential: credential)
            return
        }
        let boundary = "stg-\(UUID().uuidString)"
        var components = URLComponents(string: "https://www.googleapis.com/upload/drive/v3/files")!
        components.queryItems = [.init(name: "uploadType", value: "multipart")]
        let metadata = try JSONSerialization.data(withJSONObject: ["name": name, "parents": [parentID ?? "appDataFolder"]])
        var body = Data(); body.append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(metadata); body.append("\r\n--\(boundary)\r\nContent-Type: application/json\r\n\r\n".data(using: .utf8)!)
        body.append(data); body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var request = URLRequest(url: components.url!); request.httpMethod = "POST"; request.httpBody = body
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        try await send(&request, credential: credential)
    }

    public func delete(fileID: String, using credential: GoogleDriveCredential) async throws {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)")!); request.httpMethod = "DELETE"; request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request); try validate(response, data: data, operation: "delete file")
    }

    public func download(fileID: String, using credential: GoogleDriveCredential) async throws -> Data {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(fileID)")!
        components.queryItems = [.init(name: "alt", value: "media")]
        return try await authorizedRequest(url: components.url!, credential: credential)
    }

    public func revoke(_ credential: GoogleDriveCredential) async {
        var components = URLComponents(string: "https://oauth2.googleapis.com/revoke")!
        components.queryItems = [.init(name: "token", value: credential.refreshToken)]
        var request = URLRequest(url: components.url!); request.httpMethod = "POST"
        _ = try? await session.data(for: request)
    }

    private func authorizedRequest(url: URL, credential: GoogleDriveCredential) async throws -> Data {
        var request = URLRequest(url: url); request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request); try validate(response, data: data, operation: "GET \(url.host ?? "Google API")\(url.path)"); return data
    }

    private func send(_ request: inout URLRequest, credential: GoogleDriveCredential) async throws {
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request); try validate(response, data: data, operation: "upload file")
    }

    private func postForm(url: URL, items: [String: String]) async throws -> Data {
        var components = URLComponents(); components.queryItems = items.map { .init(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url); request.httpMethod = "POST"
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request); try validate(response, data: data, operation: "OAuth token exchange"); return data
    }

    private func decodeCredential(_ data: Data, fallbackRefreshToken: String = "") throws -> GoogleDriveCredential {
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        let refresh = token.refreshToken ?? fallbackRefreshToken
        guard !refresh.isEmpty else { throw STGError.invalidDocument("Google did not return an offline refresh token; revoke access and sign in again") }
        return .init(accessToken: token.accessToken, refreshToken: refresh, expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn)))
    }

    private func validate(_ response: URLResponse, data: Data, operation: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw STGError.invalidDocument("Google \(operation) failed: invalid HTTP response")
        }
        guard 200..<300 ~= http.statusCode else {
            let apiError = try? JSONDecoder().decode(GoogleErrorResponse.self, from: data).error
            let oauthError = try? JSONDecoder().decode(GoogleOAuthErrorResponse.self, from: data)
            let code = apiError?.status ?? oauthError?.error
            let message = apiError?.message ?? oauthError?.errorDescription ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            let codeSuffix = code.map { "; code=\($0)" } ?? ""
            throw STGError.invalidDocument("Google \(operation) failed (HTTP \(http.statusCode)\(codeSuffix)): \(message)")
        }
    }

    private func randomURLSafe(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw STGError.invalidDocument("Unable to create OAuth security nonce") }
        return Data(bytes).base64URLEncodedString()
    }
}

public enum GoogleDriveCredentialStore {
    public static func save(_ credential: GoogleDriveCredential, service: String, accessGroup: String? = nil) throws {
        let data = try JSONEncoder().encode(credential)
        let query = query(service: service, accessGroup: accessGroup)
        SecItemDelete(query as CFDictionary)
        var add = query; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw STGError.invalidDocument("Unable to store Google credential in Keychain") }
    }

    public static func load(service: String, accessGroup: String? = nil) -> GoogleDriveCredential? {
        var query = query(service: service, accessGroup: accessGroup)
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(GoogleDriveCredential.self, from: data)
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

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

private struct TokenResponse: Decodable {
    var accessToken: String; var refreshToken: String?; var expiresIn: Int
    enum CodingKeys: String, CodingKey { case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in" }
}
private struct ProfileResponse: Decodable { var name: String?; var email: String }
private struct FileListResponse: Decodable { var files: [GoogleDriveFile] }
private struct GoogleErrorResponse: Decodable {
    struct Body: Decodable { var message: String; var status: String? }
    var error: Body
}
private struct GoogleOAuthErrorResponse: Decodable {
    var error: String
    var errorDescription: String?
    enum CodingKeys: String, CodingKey { case error, errorDescription = "error_description" }
}
