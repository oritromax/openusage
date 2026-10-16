import XCTest
@testable import OpenUsage

// Payload shapes follow the fields the Command Code CLI (v1.82.5) reads for its `/usage` screen.
private let whoamiJSON = #"""
{"org":{"id":"org_123","login":"acme"},"user":{"userName":"dev"},
 "orgLimits":[
   {"scope":"model","model":"claude-opus","spent":40,"limit":50,"resetAt":"2026-11-01T00:00:00Z"},
   {"scope":"org","spent":12.5,"limit":200,"resetInterval":"monthly","resetAt":"2026-11-01T00:00:00Z"}
 ]}
"""#
private let personalWhoamiJSON = #"{"org":null,"user":{"userName":"dev"},"orgLimits":[]}"#
private let creditsJSON = #"""
{"credits":{"planId":"individual-pro-v1","monthlyCredits":50,"purchasedCredits":5,"freeCredits":0},
 "windowLimits":{"limited":true,
   "fiveHour":{"used":3.5,"cap":14,"resetAt":1792000000000},
   "weekly":{"used":7,"cap":35,"resetAt":1792500000000}}}
"""#
private let subscriptionJSON = #"""
{"data":{"planId":"individual-pro-v1","status":"active",
 "currentPeriodStart":"2026-10-01T00:00:00Z","currentPeriodEnd":"2026-10-31T00:00:00Z"}}
"""#
private let summaryJSON = #"{"totalCost":30.25,"totalCount":412,"periodBasis":"billing-period"}"#

private func data(_ json: String) -> Data { Data(json.utf8) }

private func jsonResponse(_ json: String, status: Int = 200) -> HTTPResponse {
    HTTPResponse(statusCode: status, headers: [:], body: Data(json.utf8))
}

private func progress(_ lines: [MetricLine], _ label: String)
    -> (used: Double, limit: Double, format: ProgressFormat, resetsAt: Date?, periodDurationMs: Int?)? {
    guard case .progress(_, let used, let limit, let format, let resetsAt, let periodDurationMs, _) =
        lines.first(where: { $0.label == label }) else { return nil }
    return (used, limit, format, resetsAt, periodDurationMs)
}

private func metricValues(_ lines: [MetricLine], _ label: String) -> [MetricValue]? {
    guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else { return nil }
    return values
}

// MARK: - CommandCodeAuthStoreTests

final class CommandCodeAuthStoreTests: XCTestCase {
    private let cliAuth = #"{"apiKey":"user_cli","userId":"u1","userName":"dev","keyName":"cli","openai":"sk-byok"}"#

    func testReadsCLILoginFile() {
        let store = CommandCodeAuthStore(files: FakeFiles([CommandCodeAuthStore.cliAuthPath: cliAuth]),
                                         environment: FakeEnvironment())
        XCTAssertEqual(store.loadAPIKey()?.apiKey, "user_cli")
        XCTAssertEqual(store.keySource(), .cli)
        XCTAssertEqual(store.keyStatus(), .fromEnvironment)
    }

    func testCLIFileWithoutAPIKeyIsSignedOut() {
        // Logout strips `apiKey` but can leave bring-your-own-key entries behind; those aren't a login.
        let store = CommandCodeAuthStore(files: FakeFiles([CommandCodeAuthStore.cliAuthPath: #"{"openai":"sk-byok"}"#]),
                                         environment: FakeEnvironment())
        XCTAssertNil(store.loadAPIKey())
        XCTAssertEqual(store.keyStatus(), .notSet)
    }

    func testPrecedenceIsSavedThenEnvironmentThenCLI() throws {
        let files = FakeFiles([CommandCodeAuthStore.cliAuthPath: cliAuth])
        let store = CommandCodeAuthStore(files: files,
                                         environment: FakeEnvironment(["COMMAND_CODE_API_KEY": "user_env"]))
        XCTAssertEqual(store.loadAPIKey()?.apiKey, "user_env")
        XCTAssertEqual(store.keySource(), .environment)

        try store.saveAPIKey("  user_saved  ")
        XCTAssertEqual(files.files[CommandCodeAuthStore.savedKeyPath], #"{"apiKey":"user_saved"}"#)
        XCTAssertEqual(store.loadAPIKey()?.apiKey, "user_saved")
        XCTAssertEqual(store.keySource(), .saved)
        XCTAssertEqual(store.keyStatus(), .overrideActive)
    }

    func testAPIOnlyUserSavesKeyWithoutCLI() throws {
        let store = CommandCodeAuthStore(files: FakeFiles(), environment: FakeEnvironment())
        XCTAssertEqual(store.keyStatus(), .notSet)

        try store.saveAPIKey("user_saved")

        XCTAssertEqual(store.loadAPIKey()?.apiKey, "user_saved")
        XCTAssertEqual(store.keyStatus(), .saved)
    }

    func testDeleteNeverTouchesTheCLILogin() throws {
        let files = FakeFiles([
            CommandCodeAuthStore.cliAuthPath: cliAuth,
            CommandCodeAuthStore.savedKeyPath: #"{"apiKey":"user_saved"}"#
        ])
        let store = CommandCodeAuthStore(files: files, environment: FakeEnvironment())

        try store.deleteAPIKey()

        XCTAssertNil(files.files[CommandCodeAuthStore.savedKeyPath])
        XCTAssertEqual(files.files[CommandCodeAuthStore.cliAuthPath], cliAuth)
        XCTAssertEqual(store.loadAPIKey()?.apiKey, "user_cli")
        XCTAssertEqual(store.keyStatus(), .fromEnvironment)
    }

    func testSaveRejectsEmptyKey() {
        let store = CommandCodeAuthStore(files: FakeFiles(), environment: FakeEnvironment())
        XCTAssertThrowsError(try store.saveAPIKey("  ")) { error in
            XCTAssertEqual(error as? CommandCodeAuthError, .missingKey)
        }
    }
}

// MARK: - CommandCodeUsageMapperTests

final class CommandCodeUsageMapperTests: XCTestCase {
    func testMapsEveryMetric() throws {
        let mapped = try CommandCodeUsageMapper.map(
            whoami: data(whoamiJSON), credits: data(creditsJSON),
            subscription: data(subscriptionJSON), summary: data(summaryJSON)
        )

        XCTAssertEqual(mapped.plan, "Pro")

        // Active Pro v1: pool = max($80 allowance, $50 monthly left) + $5 purchased = $85; left = $55.
        let credits = try XCTUnwrap(progress(mapped.lines, "Credits"))
        XCTAssertEqual(credits.used, 30, accuracy: 0.001)
        XCTAssertEqual(credits.limit, 85, accuracy: 0.001)
        XCTAssertEqual(credits.format, .dollars)
        XCTAssertEqual(credits.resetsAt, OpenUsageISO8601.date(from: "2026-10-31T00:00:00Z"))
        XCTAssertEqual(credits.periodDurationMs, 30 * 24 * 60 * 60 * 1000)

        let fiveHour = try XCTUnwrap(progress(mapped.lines, "5-Hour"))
        XCTAssertEqual(fiveHour.used, 25, accuracy: 0.001)
        XCTAssertEqual(fiveHour.format, .percent)
        XCTAssertEqual(fiveHour.periodDurationMs, CommandCodeUsageMapper.fiveHourPeriodMs)
        XCTAssertEqual(try XCTUnwrap(fiveHour.resetsAt).timeIntervalSince1970, 1_792_000_000, accuracy: 0.001)

        let weekly = try XCTUnwrap(progress(mapped.lines, "Weekly"))
        XCTAssertEqual(weekly.used, 20, accuracy: 0.001)
        XCTAssertEqual(weekly.periodDurationMs, CommandCodeUsageMapper.weeklyPeriodMs)

        XCTAssertEqual(metricValues(mapped.lines, "Requests"), [MetricValue(number: 412, kind: .count, label: "requests")])
        XCTAssertEqual(metricValues(mapped.lines, "Spend This Period"), [MetricValue(number: 30.25, kind: .dollars)])

        // The org-wide limit, not the per-model one listed first.
        let org = try XCTUnwrap(progress(mapped.lines, "Org Spend Limit"))
        XCTAssertEqual(org.used, 12.5, accuracy: 0.001)
        XCTAssertEqual(org.limit, 200, accuracy: 0.001)
    }

    func testInactivePlanPoolIsSpendPlusRemaining() throws {
        let canceled = #"{"data":{"planId":"individual-pro-v1","status":"canceled"}}"#
        let mapped = try CommandCodeUsageMapper.map(
            whoami: nil, credits: data(creditsJSON), subscription: data(canceled), summary: data(summaryJSON)
        )
        let credits = try XCTUnwrap(progress(mapped.lines, "Credits"))
        XCTAssertEqual(credits.used, 30.25, accuracy: 0.001)
        XCTAssertEqual(credits.limit, 85.25, accuracy: 0.001)
        XCTAssertNil(credits.resetsAt)
    }

    func testPlanMatchingUsesLongestPrefix() {
        XCTAssertEqual(CommandCodeUsageMapper.planInfo(planID: "individual-goat")?.name, "GOAT")
        XCTAssertEqual(CommandCodeUsageMapper.planInfo(planID: "INDIVIDUAL_GO_V1")?.name, "Go")
        XCTAssertEqual(CommandCodeUsageMapper.planInfo(planID: "individual-pro-v1-annual")?.monthlyCredits, 80)
        XCTAssertEqual(CommandCodeUsageMapper.planInfo(planID: "individual-pro")?.monthlyCredits, 30)
        XCTAssertNil(CommandCodeUsageMapper.planInfo(planID: "enterprise"))
    }

    func testWindowsWithoutCapAreSkipped() throws {
        let body = #"{"credits":{"monthlyCredits":10},"windowLimits":{"limited":false,"fiveHour":{"used":0,"cap":0}}}"#
        let mapped = try CommandCodeUsageMapper.map(whoami: nil, credits: data(body), subscription: nil, summary: nil)
        XCTAssertNil(progress(mapped.lines, "5-Hour"))
        XCTAssertNotNil(progress(mapped.lines, "Credits"))
    }

    func testDateAcceptsISOAndEpochSecondsOrMilliseconds() {
        let expected = Date(timeIntervalSince1970: 1_792_000_000)
        XCTAssertEqual(CommandCodeUsageMapper.date(1_792_000_000_000), expected)
        XCTAssertEqual(CommandCodeUsageMapper.date(1_792_000_000), expected)
        XCTAssertNotNil(CommandCodeUsageMapper.date("2026-10-31T00:00:00.000Z"))
        XCTAssertNil(CommandCodeUsageMapper.date(nil))
    }

    func testNonObjectBodyIsInvalidResponse() {
        XCTAssertThrowsError(try CommandCodeUsageMapper.map(
            whoami: nil, credits: data("[]"), subscription: nil, summary: nil
        )) { error in
            XCTAssertEqual(error as? CommandCodeUsageError, .invalidResponse)
        }
    }

    func testEmptyBillingIsNoUsageData() throws {
        let mapped = try CommandCodeUsageMapper.map(whoami: nil, credits: data("{}"), subscription: data("{}"), summary: nil)
        XCTAssertEqual(mapped.lines, [.noUsageData])
    }
}

// MARK: - CommandCodeProviderTests

@MainActor
final class CommandCodeProviderTests: XCTestCase {
    func testRefreshCallsEndpointsLikeTheCLI() async throws {
        let http = RoutingHTTPClient { request in
            XCTAssertEqual(request.headers["Authorization"], "Bearer user_test")
            switch request.url.path {
            case CommandCodeUsageClient.whoamiPath:
                XCTAssertEqual(request.url.query, "limits=1")
                return jsonResponse(whoamiJSON)
            case CommandCodeUsageClient.creditsPath:
                XCTAssertEqual(request.url.query, "orgId=org_123")
                return jsonResponse(creditsJSON)
            case CommandCodeUsageClient.subscriptionPath:
                return jsonResponse(subscriptionJSON)
            case CommandCodeUsageClient.summaryPath:
                XCTAssertEqual(request.url.query, "orgId=org_123&since=2026-10-01T00:00:00Z")
                return jsonResponse(summaryJSON)
            default:
                XCTFail("unexpected request \(request.url)")
                return jsonResponse("{}", status: 404)
            }
        }
        let provider = CommandCodeProvider(authStore: makeAuthStore(key: "user_test"),
                                           usageClient: CommandCodeUsageClient(http: http))

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertNotNil(snapshot.line(label: "Credits"))
        XCTAssertNotNil(snapshot.line(label: "5-Hour"))
        XCTAssertNotNil(snapshot.line(label: "Requests"))
    }

    func testPersonalAccountOmitsOrgID() {
        XCTAssertEqual(
            CommandCodeUsageClient.url(path: CommandCodeUsageClient.creditsPath, query: ["orgId": nil]).absoluteString,
            "https://api.commandcode.ai/alpha/billing/credits"
        )
        XCTAssertNil(CommandCodeUsageMapper.orgID(fromWhoami: data(personalWhoamiJSON)))
    }

    func testSummaryFailureKeepsBillingMeters() async {
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case CommandCodeUsageClient.creditsPath: return jsonResponse(creditsJSON)
            case CommandCodeUsageClient.subscriptionPath: return jsonResponse(subscriptionJSON)
            case CommandCodeUsageClient.summaryPath: return jsonResponse("{}", status: 500)
            default: return jsonResponse(personalWhoamiJSON)
            }
        }
        let provider = CommandCodeProvider(authStore: makeAuthStore(key: "user_test"),
                                           usageClient: CommandCodeUsageClient(http: http))

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.line(label: "Credits"))
        XCTAssertNil(snapshot.line(label: "Requests"))
    }

    func testRefreshWithoutKeyReportsNotLoggedIn() async {
        let provider = CommandCodeProvider(
            authStore: CommandCodeAuthStore(files: FakeFiles(), environment: FakeEnvironment()),
            usageClient: CommandCodeUsageClient(http: RoutingHTTPClient { _ in
                XCTFail("should not hit the network without a key")
                return jsonResponse("{}")
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        let hasKey = await provider.hasLocalCredentials()
        XCTAssertFalse(hasKey)
    }

    func testRejectedKeyReportsAuthInvalid() async {
        let provider = CommandCodeProvider(authStore: makeAuthStore(key: "user_bad"),
                                           usageClient: CommandCodeUsageClient(http: RoutingHTTPClient { _ in
                                               jsonResponse(#"{"error":"unauthorized"}"#, status: 401)
                                           }))

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
    }

    func testBillingFailureSurfacesError() async {
        let cases: [(status: Int, expected: ErrorCategory)] = [(500, .http5xx), (429, .rateLimited)]
        for entry in cases {
            let http = RoutingHTTPClient { request in
                request.url.path == CommandCodeUsageClient.whoamiPath
                    ? jsonResponse(personalWhoamiJSON)
                    : jsonResponse("{}", status: entry.status)
            }
            let provider = CommandCodeProvider(authStore: makeAuthStore(key: "user_test"),
                                               usageClient: CommandCodeUsageClient(http: http))

            let snapshot = await provider.refresh()

            XCTAssertEqual(snapshot.errorCategory, entry.expected)
        }
    }

    func testTransportErrorReportsNetwork() async {
        let provider = CommandCodeProvider(authStore: makeAuthStore(key: "user_test"),
                                           usageClient: CommandCodeUsageClient(http: RoutingHTTPClient { _ in
                                               throw CommandCodeUsageError.connectionFailed
                                           }))

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .network)
    }

    func testAPIKeySourceHintNamesTheCLI() throws {
        let files = FakeFiles([CommandCodeAuthStore.cliAuthPath: #"{"apiKey":"user_cli"}"#])
        let provider = CommandCodeProvider(authStore: CommandCodeAuthStore(files: files, environment: FakeEnvironment()))

        XCTAssertEqual(provider.apiKeyStatus, .fromEnvironment)
        XCTAssertEqual(provider.externalKeySourceHint, "From Command Code CLI")

        try provider.saveAPIKey("user_saved")
        XCTAssertEqual(provider.apiKeyStatus, .overrideActive)
        XCTAssertEqual(provider.currentAPIKey(), "user_saved")

        try provider.deleteAPIKey()
        XCTAssertEqual(provider.currentAPIKey(), "user_cli")
    }

    func testEnvironmentKeyKeepsTheDefaultHint() {
        let provider = CommandCodeProvider(authStore: makeAuthStore(key: "user_env"))
        XCTAssertEqual(provider.externalKeySourceHint, "From Your Environment")
    }

    private func makeAuthStore(key: String) -> CommandCodeAuthStore {
        CommandCodeAuthStore(files: FakeFiles(), environment: FakeEnvironment(["COMMAND_CODE_API_KEY": key]))
    }
}
