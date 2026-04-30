import Foundation

private struct ADCCredentials: Decodable {
    let type: String
    let clientId: String
    let clientSecret: String
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case type
        case clientId = "client_id"
        case clientSecret = "client_secret"
        case refreshToken = "refresh_token"
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Int
    let tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}

/// Fetches OAuth2 access tokens from local Google Application Default Credentials.
@available(
    iOS,
    unavailable,
    message: "Reads local gcloud ADC. On iOS, use the tokenProvider initializer on a Vertex client."
)
public actor GoogleAuthService {
    public enum GoogleAuthError: Error, LocalizedError, Sendable {
        case credentialsFileNotFound(path: String)
        case unsupportedCredentialType(String)
        case refreshFailed(statusCode: Int, body: String)
        case decodingFailed(String)

        public var errorDescription: String? {
            switch self {
            case let .credentialsFileNotFound(path):
                "Google ADC credentials not found at \(path). Run `gcloud auth application-default login`."
            case let .unsupportedCredentialType(type):
                "Unsupported ADC credential type: \(type). Only 'authorized_user' is supported."
            case let .refreshFailed(code, body):
                "Token refresh failed (HTTP \(code)): \(body)"
            case let .decodingFailed(message):
                "Failed to decode ADC credentials: \(message)"
            }
        }
    }

    private let clientID: String
    private let clientSecret: String
    private let refreshToken: String
    private let session: URLSession

    private var cachedAccessToken: String?
    private var tokenExpiry: Date?

    private let refreshMargin: TimeInterval = 300

    private static let tokenEndpoint = URL(validStaticString: "https://oauth2.googleapis.com/token")

    public init(session: URLSession = .shared) throws {
        try self.init(credentialsPath: Self.defaultCredentialsPath(), session: session)
    }

    public init(credentialsPath: String, session: URLSession = .shared) throws {
        guard FileManager.default.fileExists(atPath: credentialsPath) else {
            throw GoogleAuthError.credentialsFileNotFound(path: credentialsPath)
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: credentialsPath))
        } catch {
            throw GoogleAuthError.decodingFailed("Failed to read file: \(error.localizedDescription)")
        }
        let credentials: ADCCredentials
        do {
            credentials = try JSONDecoder().decode(ADCCredentials.self, from: data)
        } catch {
            throw GoogleAuthError.decodingFailed(error.localizedDescription)
        }
        guard credentials.type == "authorized_user" else {
            throw GoogleAuthError.unsupportedCredentialType(credentials.type)
        }
        clientID = credentials.clientId
        clientSecret = credentials.clientSecret
        refreshToken = credentials.refreshToken
        self.session = session
    }

    public func accessToken() async throws -> String {
        if let token = cachedAccessToken,
           let expiry = tokenExpiry,
           Date() < expiry.addingTimeInterval(-refreshMargin) {
            return token
        }
        return try await refreshAccessToken()
    }

    private func refreshAccessToken() async throws -> String {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
        ]

        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleAuthError.refreshFailed(statusCode: 0, body: "Invalid response")
        }
        guard httpResponse.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? "<unreadable>"
            throw GoogleAuthError.refreshFailed(statusCode: httpResponse.statusCode, body: responseBody)
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        cachedAccessToken = tokenResponse.accessToken
        tokenExpiry = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        return tokenResponse.accessToken
    }

    public static func defaultCredentialsPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.config/gcloud/application_default_credentials.json"
    }

    public static func credentialsAvailable() -> Bool {
        FileManager.default.fileExists(atPath: defaultCredentialsPath())
    }
}
