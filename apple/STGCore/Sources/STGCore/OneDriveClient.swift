import Foundation
import Security

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

    public init(clientID: String, session: URLSession = .shared) {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
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
        let data = try await graph(path: "/v1.0/me?$select=displayName,mail,userPrincipalName", credential: credential)
        let profile = try JSONDecoder().decode(ProfileResponse.self, from: data)
        return OneDriveAccount(displayName: profile.displayName, email: profile.mail ?? profile.userPrincipalName ?? "Microsoft account")
    }

    public func listFiles(using credential: OneDriveCredential) async throws -> [OneDriveFile] {
        let data = try await graph(path: "/v1.0/me/drive/special/approot/children?$select=id,name,lastModifiedDateTime", credential: credential)
        return try JSONDecoder().decode(FileListResponse.self, from: data).value
    }

    public func upload(name: String, data: Data, using credential: OneDriveCredential) async throws {
        let escaped = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/drive/special/approot:/\(escaped):/content")!)
        request.httpMethod = "PUT"; request.httpBody = data
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.data(for: request); try Self.validate(response)
    }

    public func download(fileID: String, using credential: OneDriveCredential) async throws -> Data {
        try await graph(path: "/v1.0/me/drive/items/\(fileID)/content", credential: credential)
    }

    public func download(name: String, using credential: OneDriveCredential) async throws -> Data? {
        let escaped = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/drive/special/approot:/\(escaped):/content")!)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return nil }
        try Self.validate(response)
        return data
    }

    private func graph(path: String, credential: OneDriveCredential) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://graph.microsoft.com\(path)")!)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request); try Self.validate(response); return data
    }

    private func postForm(url: URL, items: [String: String]) async throws -> Data {
        var components = URLComponents(); components.queryItems = items.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url); request.httpMethod = "POST"
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode { return data }
        if let error = try? JSONDecoder().decode(OAuthErrorResponse.self, from: data) { throw OAuthPendingError(code: error.error, description: error.errorDescription ?? error.error) }
        try Self.validate(response); return data
    }

    private func credential(from data: Data, fallbackRefreshToken: String = "") throws -> OneDriveCredential {
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        return OneDriveCredential(accessToken: token.accessToken, refreshToken: token.refreshToken ?? fallbackRefreshToken, expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn)))
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw STGError.invalidDocument("Microsoft Graph request failed") }
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
