import Foundation

@MainActor
final class CommandCodeProvider: ProviderRuntime {
    let provider = Provider(
        id: "commandcode",
        displayName: "Command Code",
        icon: .providerMark("commandcode"),
        links: [
            ProviderLink(label: "Dashboard", url: "https://commandcode.ai/settings/usage")
        ]
    )

    let authStore: CommandCodeAuthStore
    let usageClient: CommandCodeUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: CommandCodeAuthStore = CommandCodeAuthStore(),
        usageClient: CommandCodeUsageClient = CommandCodeUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .boundedDollars(id: "commandcode.credits", provider: provider, title: "Credits",
                            metricLabel: "Credits", limit: 80)
                .exportingLimit("credits", unit: "usd"),
            .percent(id: "commandcode.fiveHour", provider: provider, title: "5-Hour",
                     metricLabel: "5-Hour")
                .exportingLimit("fiveHour", unit: "percent"),
            .percent(id: "commandcode.weekly", provider: provider, title: "Weekly",
                     metricLabel: "Weekly")
                .exportingLimit("weekly", unit: "percent"),
            .values(id: "commandcode.requests", provider: provider, title: "Requests",
                    metricLabel: "Requests", selection: .kind(.count)),
            .values(id: "commandcode.spend", provider: provider, title: "Spend This Period",
                    metricLabel: "Spend This Period", selection: .kind(.dollars), valueWord: "spent"),
            .boundedDollars(id: "commandcode.orgLimit", provider: provider, title: "Org Spend Limit",
                            metricLabel: "Org Spend Limit", limit: 100, valueWord: "spent")
                .exportingLimit("orgLimit", unit: "usd")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // Same sources as `refresh()`: a saved key, `COMMAND_CODE_API_KEY`, or the CLI's login.
        await loadOffMainActor { [authStore] in authStore.loadAPIKey() } != nil
    }

    func refresh() async -> ProviderSnapshot {
        guard let auth = await loadOffMainActor({ [authStore] in authStore.loadAPIKey() }) else {
            return ProviderSnapshot.error(provider: provider, error: CommandCodeAuthError.missingKey)
        }
        let key = auth.apiKey

        // Same order as the CLI: whoami scopes the billing calls to the key's org, and the summary
        // needs the billing period start from the subscription.
        let whoami = await load { try await usageClient.fetchWhoami(apiKey: key) }
        if whoami.isAuthFailure {
            return ProviderSnapshot.error(provider: provider, error: CommandCodeAuthError.invalidKey)
        }
        let orgID = CommandCodeUsageMapper.orgID(fromWhoami: whoami.body)

        let credits = await load { try await usageClient.fetchCredits(apiKey: key, orgID: orgID) }
        let subscription = await load { try await usageClient.fetchSubscription(apiKey: key, orgID: orgID) }
        if credits.isAuthFailure || subscription.isAuthFailure {
            return ProviderSnapshot.error(provider: provider, error: CommandCodeAuthError.invalidKey)
        }
        // Billing data is the card's core. With neither call answering there's nothing to meter, so
        // surface the failure instead of a card of blank rows.
        guard credits.body != nil || subscription.body != nil else {
            let error = credits.failureError ?? subscription.failureError ?? CommandCodeUsageError.invalidResponse
            return ProviderSnapshot.error(provider: provider, error: error)
        }

        let since = CommandCodeUsageMapper.periodStart(fromSubscription: subscription.body)
        let summary = await load { try await usageClient.fetchSummary(apiKey: key, orgID: orgID, since: since) }

        for (name, result) in [("whoami", whoami), ("summary", summary)] {
            if let error = result.failureError {
                AppLog.error(LogTag.plugin("commandcode"), "Command Code \(name) request failed: \(error.localizedDescription)")
            }
        }

        do {
            let mapped = try CommandCodeUsageMapper.map(
                whoami: whoami.body,
                credits: credits.body,
                subscription: subscription.body,
                summary: summary.body
            )
            return ProviderSnapshot.make(provider: provider, plan: mapped.plan, lines: mapped.lines, refreshedAt: now())
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    /// Run one call and classify it: the body on 2xx, an auth failure on 401/403, or a typed failure.
    private func load(_ call: () async throws -> HTTPResponse) async -> EndpointResult {
        do {
            let response = try await call()
            if response.statusCode == 401 || response.statusCode == 403 { return .authFailure }
            guard (200..<300).contains(response.statusCode) else {
                return .failed(.requestFailed(response.statusCode))
            }
            return .success(response.body)
        } catch {
            return .failed(.connectionFailed)
        }
    }
}

extension CommandCodeProvider: APIKeyManaging {
    var apiKeyStatus: APIKeyStatus { authStore.keyStatus() }
    var externalKeySourceHint: String {
        authStore.keySource() == .cli ? "From Command Code CLI" : "From Your Environment"
    }
    func currentAPIKey() -> String? { authStore.currentAPIKey() }
    func saveAPIKey(_ key: String) throws { try authStore.saveAPIKey(key) }
    func deleteAPIKey() throws { try authStore.deleteAPIKey() }
}

private enum EndpointResult {
    case success(Data)
    case authFailure
    case failed(CommandCodeUsageError)

    var body: Data? {
        if case .success(let data) = self { return data }
        return nil
    }

    var isAuthFailure: Bool {
        if case .authFailure = self { return true }
        return false
    }

    var failureError: CommandCodeUsageError? {
        if case .failed(let error) = self { return error }
        return nil
    }
}
