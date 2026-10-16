import Foundation

/// Calls the same four endpoints the Command Code CLI's `/usage` screen uses. They live under
/// `/alpha/` (undocumented, may change), and authenticate with the user's API key as a Bearer token.
struct CommandCodeUsageClient: Sendable {
    static let baseURL = URL(string: "https://api.commandcode.ai")!
    static let whoamiPath = "/alpha/whoami"
    static let creditsPath = "/alpha/billing/credits"
    static let subscriptionPath = "/alpha/billing/subscriptions"
    static let summaryPath = "/alpha/usage/summary"

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// Account identity (org id/login, username) plus org spend limits (`limits=1`).
    func fetchWhoami(apiKey: String) async throws -> HTTPResponse {
        try await get(Self.whoamiPath, query: ["limits": "1"], apiKey: apiKey)
    }

    /// Remaining credits by bucket, the 5-hour/weekly windows, and the plan id.
    func fetchCredits(apiKey: String, orgID: String?) async throws -> HTTPResponse {
        try await get(Self.creditsPath, query: ["orgId": orgID], apiKey: apiKey)
    }

    /// Plan id, status, and the current billing period.
    func fetchSubscription(apiKey: String, orgID: String?) async throws -> HTTPResponse {
        try await get(Self.subscriptionPath, query: ["orgId": orgID], apiKey: apiKey)
    }

    /// Spend and request count since `since` (the billing period start).
    func fetchSummary(apiKey: String, orgID: String?, since: String?) async throws -> HTTPResponse {
        try await get(Self.summaryPath, query: ["orgId": orgID, "since": since], apiKey: apiKey)
    }

    /// Builds the URL like the CLI does: nil parameters are dropped, so a personal account (no org)
    /// calls the bare path.
    static func url(path: String, query: [String: String?]) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        let items = query.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
            .sorted { $0.name < $1.name }
        components.queryItems = items.isEmpty ? nil : items
        return components.url!
    }

    private func get(_ path: String, query: [String: String?], apiKey: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET",
            url: Self.url(path: path, query: query),
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Accept": "application/json"
            ],
            timeout: 15
        ))
    }
}

enum CommandCodeUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        case .invalidResponse:
            return ProviderUsageErrorText.invalidResponse
        case .requestFailed(let status):
            return ProviderUsageErrorText.requestFailed(statusCode: status)
        }
    }
}
