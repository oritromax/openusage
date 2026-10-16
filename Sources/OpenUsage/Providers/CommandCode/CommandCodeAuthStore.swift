import Foundation

struct CommandCodeAuth: Hashable, Sendable {
    var apiKey: String
}

enum CommandCodeAuthError: Error, LocalizedError, Equatable {
    case missingKey
    case invalidKey
    case saveFailed
    case deleteFailed

    init(_ failure: UserAPIKeyStore.Failure) {
        switch failure {
        case .missingKey: self = .missingKey
        case .saveFailed: self = .saveFailed
        case .deleteFailed: self = .deleteFailed
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "No Command Code API key. Run `cmd login`, or add a key in Settings → API Keys."
        case .invalidKey:
            return "Command Code API key invalid or expired. Run `cmd login` again, or replace the key in Settings."
        case .saveFailed:
            return "Couldn't save the Command Code API key."
        case .deleteFailed:
            return "Couldn't remove the saved Command Code API key."
        }
    }
}

/// Reads a [Command Code](https://commandcode.ai) API key from three places, in this order:
///
/// 1. a key saved from OpenUsage's Settings → API Keys (`~/.config/openusage/commandcode.json`),
/// 2. the `COMMAND_CODE_API_KEY` environment variable,
/// 3. the key the Command Code CLI stored at login (`~/.commandcode/auth.json`, field `apiKey`).
///
/// 2 and 3 follow the CLI's own precedence (env over the auth file), so OpenUsage meters the same
/// account the CLI is using. API-only users — no CLI installed — add their key in Settings instead.
///
/// The CLI's `auth.json` is read-only to OpenUsage: it's the CLI's login, so clearing the key in
/// Settings only removes OpenUsage's own saved file and falls back to the CLI/environment key.
struct CommandCodeAuthStore: Sendable {
    /// Written by Settings → API Keys. JSON `{"apiKey":"…"}` (or a plain-text file holding only the key).
    static let savedKeyPath = "~/.config/openusage/commandcode.json"
    /// The Command Code CLI's production login file. Holds `apiKey` plus account metadata (and possibly
    /// bring-your-own-key provider keys under other names, which are ignored).
    static let cliAuthPath = "~/.commandcode/auth.json"
    static let environmentName = "COMMAND_CODE_API_KEY"

    /// Where the effective key came from — drives the Settings source hint.
    enum Source: Equatable, Sendable {
        case saved
        case environment
        case cli
    }

    private let files: TextFileAccessing
    private let environment: EnvironmentReading
    /// Owns the saved-key file (read/save/delete). No env names: the environment is checked separately
    /// so the CLI file can sit between the saved key and nothing, without ever being deleted.
    private let savedStore: UserAPIKeyStore

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader()
    ) {
        self.files = files
        self.environment = environment
        savedStore = UserAPIKeyStore(
            configPaths: [Self.savedKeyPath],
            environmentNames: [],
            files: files,
            environment: environment,
            makeError: { CommandCodeAuthError($0) }
        )
    }

    func loadAPIKey() -> CommandCodeAuth? {
        resolve().map { CommandCodeAuth(apiKey: $0.key) }
    }

    func currentAPIKey() -> String? { resolve()?.key }

    /// The source of the key `loadAPIKey()` would return, or `nil` when there is none.
    func keySource() -> Source? { resolve()?.source }

    /// A saved key over a CLI/env key is an override; a CLI or env key alone is "external" (read-only
    /// in Settings, overridable, never deleted by OpenUsage).
    func keyStatus() -> APIKeyStatus {
        let hasSaved = savedStore.loadKey() != nil
        let hasExternal = environmentKey() != nil || cliKey() != nil
        switch (hasSaved, hasExternal) {
        case (true, true): return .overrideActive
        case (true, false): return .saved
        case (false, true): return .fromEnvironment
        default: return .notSet
        }
    }

    func saveAPIKey(_ key: String) throws { try savedStore.saveKey(key) }
    func deleteAPIKey() throws { try savedStore.deleteKey() }

    // MARK: - Private

    private func resolve() -> (key: String, source: Source)? {
        if let key = savedStore.loadKey() { return (key, .saved) }
        if let key = environmentKey() { return (key, .environment) }
        if let key = cliKey() { return (key, .cli) }
        return nil
    }

    private func environmentKey() -> String? {
        environment.value(for: Self.environmentName)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// `apiKey` from the CLI's `auth.json`. Only that field counts — the CLI treats a file without it as
    /// signed out, and other top-level entries are third-party provider keys, not a Command Code login.
    private func cliKey() -> String? {
        let text: String?
        do {
            text = try files.readTextIfPresent(Self.cliAuthPath)
        } catch {
            AppLog.error(.auth, "read \(Self.cliAuthPath) failed: \(error.localizedDescription)")
            return nil
        }
        guard let text, let object = ProviderParse.jsonObject(Data(text.utf8)) else { return nil }
        return (object["apiKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}
