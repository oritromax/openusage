import Foundation

/// Builds metric lines from the four payloads behind the Command Code CLI's `/usage` screen, porting
/// the CLI's own projection (`projectUsageView`) so the numbers match what `cmd` shows:
///
/// - **Credits** — `/alpha/billing/credits` reports what's *left* in each bucket (monthly, purchased,
///   free, all USD). The pool is the plan's monthly allowance (when the subscription is `active`) plus
///   purchased and free credits; otherwise spend this period plus what's left. Used = pool − remaining.
/// - **5-Hour / Weekly** — `windowLimits.fiveHour|weekly.{used, cap, resetAt}`, shown as a percentage of
///   the cap (the ratio is unit-agnostic; `resetAt` is epoch ms in the CLI's comparisons).
/// - **Requests / Spend This Period** — `/alpha/usage/summary` since the billing period start.
/// - **Org Spend Limit** — the org-wide entry of `whoami.orgLimits` (per-model limits are skipped).
///
/// Pure (no I/O) so it tests against sample payloads.
enum CommandCodeUsageMapper {
    static let fiveHourPeriodMs = 5 * 60 * 60 * 1000
    static let weeklyPeriodMs = 7 * 24 * 60 * 60 * 1000

    struct PlanInfo: Equatable, Sendable {
        var name: String
        /// The plan's monthly credit allowance in USD.
        var monthlyCredits: Double
    }

    /// The CLI's hardcoded plan table, keyed by plan-id prefix.
    static let plans: [String: PlanInfo] = [
        "individual-go": PlanInfo(name: "Go", monthlyCredits: 10),
        "individual-go-v1": PlanInfo(name: "Go", monthlyCredits: 10),
        "individual-goat": PlanInfo(name: "GOAT", monthlyCredits: 70),
        "individual-pro": PlanInfo(name: "Pro", monthlyCredits: 30),
        "individual-pro-v1": PlanInfo(name: "Pro", monthlyCredits: 80),
        "individual-provider": PlanInfo(name: "Provider", monthlyCredits: 15),
        "individual-max": PlanInfo(name: "Max", monthlyCredits: 150),
        "individual-ultra": PlanInfo(name: "Ultra", monthlyCredits: 300),
        "teams-pro": PlanInfo(name: "Teams Pro", monthlyCredits: 40)
    ]

    /// Matches like the CLI: lowercase, `_` → `-`, then the longest known prefix wins (so `individual-goat`
    /// isn't read as `individual-go`). Unknown ids return nil.
    static func planInfo(planID: String) -> PlanInfo? {
        let normalized = planID.lowercased().replacingOccurrences(of: "_", with: "-")
        guard !normalized.isEmpty,
              let key = plans.keys.sorted(by: { $0.count > $1.count }).first(where: { normalized.hasPrefix($0) })
        else { return nil }
        return plans[key]
    }

    /// `org.id` from `/alpha/whoami`, scoping the billing calls to the key's org. Nil for personal accounts.
    static func orgID(fromWhoami body: Data?) -> String? {
        guard let body, let org = ProviderParse.jsonObject(body)?["org"] as? [String: Any] else { return nil }
        return stringValue(org["id"])
    }

    /// `data.currentPeriodStart` from `/alpha/billing/subscriptions` — the summary's `since`.
    static func periodStart(fromSubscription body: Data?) -> String? {
        guard let body, let data = ProviderParse.jsonObject(body)?["data"] as? [String: Any] else { return nil }
        return stringValue(data["currentPeriodStart"])
    }

    /// `(plan, lines)` from whichever payloads came back (`nil` = that call failed). A 2xx body that isn't
    /// a JSON object is an invalid response, not "no data".
    static func map(whoami: Data?, credits: Data?, subscription: Data?, summary: Data?) throws
        -> (plan: String?, lines: [MetricLine]) {
        let whoamiRoot = try object(whoami)
        let creditsRoot = try object(credits)
        let subscriptionRoot = try object(subscription)
        let summaryRoot = try object(summary)

        let sub = subscriptionRoot?["data"] as? [String: Any]
        let creditBuckets = creditsRoot?["credits"] as? [String: Any]
        let planID = stringValue(sub?["planId"]) ?? stringValue(creditBuckets?["planId"])
        let plan = planID.flatMap(planInfo(planID:))

        var lines: [MetricLine] = []
        if let creditBuckets,
           let line = creditsLine(buckets: creditBuckets, subscription: sub, plan: plan, summary: summaryRoot) {
            lines.append(line)
        }
        if let windows = creditsRoot?["windowLimits"] as? [String: Any] {
            if let line = windowLine(windows["fiveHour"], label: "5-Hour", periodMs: fiveHourPeriodMs) {
                lines.append(line)
            }
            if let line = windowLine(windows["weekly"], label: "Weekly", periodMs: weeklyPeriodMs) {
                lines.append(line)
            }
        }
        if let summaryRoot {
            if let count = ProviderParse.number(summaryRoot["totalCount"]) {
                lines.append(.values(label: "Requests",
                                     values: [MetricValue(number: max(0, count), kind: .count, label: "requests")]))
            }
            if let cost = ProviderParse.number(summaryRoot["totalCost"]) {
                lines.append(.values(label: "Spend This Period",
                                     values: [MetricValue(number: max(0, cost), kind: .dollars)]))
            }
        }
        if let line = orgLimitLine(whoamiRoot?["orgLimits"]) {
            lines.append(line)
        }

        return (plan?.name, lines.isEmpty ? [.noUsageData] : lines)
    }

    // MARK: - Lines

    private static func creditsLine(
        buckets: [String: Any],
        subscription: [String: Any]?,
        plan: PlanInfo?,
        summary: [String: Any]?
    ) -> MetricLine? {
        let monthly = max(0, ProviderParse.number(buckets["monthlyCredits"]) ?? 0)
        let purchased = max(0, ProviderParse.number(buckets["purchasedCredits"]) ?? 0)
        let free = max(0, ProviderParse.number(buckets["freeCredits"]) ?? 0)
        let remaining = monthly + purchased + free
        let spent = max(0, ProviderParse.number(summary?["totalCost"]) ?? 0)

        let isActive = stringValue(subscription?["status"]) == "active"
        let pool: Double
        if isActive, let allowance = plan?.monthlyCredits {
            pool = max(allowance, monthly) + purchased + free
        } else {
            pool = spent + remaining
        }
        guard pool > 0 else { return nil }

        let periodStart = date(subscription?["currentPeriodStart"])
        let periodEnd = date(subscription?["currentPeriodEnd"])
        let periodMs = both(periodStart, periodEnd).flatMap { start, end -> Int? in
            let ms = end.timeIntervalSince(start) * 1000
            return ms >= 1 ? Int(ms) : nil
        }
        return .progress(
            label: "Credits",
            used: min(pool, max(0, pool - remaining)),
            limit: pool,
            format: .dollars,
            resetsAt: periodEnd,
            periodDurationMs: periodMs
        )
    }

    private static func windowLine(_ value: Any?, label: String, periodMs: Int) -> MetricLine? {
        guard let window = value as? [String: Any],
              let used = ProviderParse.number(window["used"]),
              let cap = ProviderParse.number(window["cap"]),
              cap > 0 else { return nil }
        return .progress(
            label: label,
            used: ProviderParse.clampPercent(max(0, used) / cap * 100),
            limit: 100,
            format: .percent,
            resetsAt: date(window["resetAt"]),
            periodDurationMs: periodMs
        )
    }

    /// The org-wide spend limit (`scope` other than `"model"`). Per-model limits stay out of the card.
    private static func orgLimitLine(_ value: Any?) -> MetricLine? {
        guard let limits = value as? [[String: Any]],
              let orgWide = limits.first(where: { stringValue($0["scope"]) != "model" }),
              let limit = ProviderParse.number(orgWide["limit"]),
              limit > 0 else { return nil }
        let spent = max(0, ProviderParse.number(orgWide["spent"]) ?? 0)
        return .progress(
            label: "Org Spend Limit",
            used: spent,
            limit: limit,
            format: .dollars,
            resetsAt: date(orgWide["resetAt"])
        )
    }

    // MARK: - Parsing

    private static func object(_ body: Data?) throws -> [String: Any]? {
        guard let body else { return nil }
        guard let root = ProviderParse.jsonObject(body) else { throw CommandCodeUsageError.invalidResponse }
        return root
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string.nilIfEmpty }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    /// An ISO-8601 string, or an epoch number (milliseconds when it's that large, else seconds).
    static func date(_ value: Any?) -> Date? {
        if let string = value as? String, let parsed = OpenUsageISO8601.date(from: string) {
            return parsed
        }
        guard let number = ProviderParse.number(value), number > 0 else { return nil }
        return Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1000 : number)
    }
}

private func both<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
