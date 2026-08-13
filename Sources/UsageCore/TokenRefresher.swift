import Foundation

/// Refreshes an expired OAuth token the same way the Claude Code CLI does —
/// for **file-backed** profiles only — and writes the rotated pair back to
/// `.credentials.json` so the CLI stays logged in.
///
/// Refresh tokens are single-use and rotate: the response carries a new one
/// that supersedes ours server-side, so persisting it is not optional. That is
/// also why Keychain-backed credentials are deliberately left alone: the item
/// is owned by the CLI binary, a write from this process pops a consent prompt
/// and can fail *after* the rotation is already consumed — which logs the CLI
/// out. Those profiles keep the "open Claude Code to refresh" behavior.
public actor TokenRefresher {
    public static let endpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    /// Claude Code's public OAuth client id (present as a string in the CLI binary).
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// Longer than any poll interval on purpose: a dead refresh token must not
    /// be POSTed once per poll. Manual refresh (`force`) still bypasses it.
    static let cooldown: TimeInterval = 300

    private var inFlight: Task<Credentials?, Never>?
    private var lastFailAt: Date = .distantPast

    private let file: URL

    public init(credentialsFile: URL) {
        self.file = credentialsFile
    }

    /// Fresh credentials, or nil when refresh can't help — callers keep their
    /// original read, so every existing failure render stays as it was.
    ///
    /// `badToken` is a token the server just rejected: a file still holding it
    /// does not count as "already refreshed by the CLI", however valid its
    /// `expiresAt` claims to be.
    public func refresh(force: Bool = false, badToken: String? = nil) async -> Credentials? {
        // One in-flight refresh per profile: two concurrent consumers of a
        // single-use rotating token would invalidate each other.
        if let running = inFlight { return await running.value }
        if !force, Date().timeIntervalSince(lastFailAt) < Self.cooldown { return nil }

        let task = Task { await self.doRefresh(badToken: badToken) }
        inFlight = task
        let result = await task.value
        inFlight = nil
        lastFailAt = result == nil ? Date() : .distantPast
        return result
    }

    private func doRefresh(badToken: String?) async -> Credentials? {
        // Read fresh rather than trusting the caller: the CLI may have rotated
        // the token since, and a POST with a stale copy is a guaranteed
        // invalid_grant.
        guard let root = Self.readJSON(file),
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let refreshToken = oauth["refreshToken"] as? String
        else { return nil } // no file or no refresh token — e.g. Keychain-backed

        let nowMs = Date().timeIntervalSince1970 * 1000
        let expiresAtMs = (oauth["expiresAt"] as? NSNumber)?.doubleValue ?? 0
        if let access = oauth["accessToken"] as? String, access != badToken,
           !(expiresAtMs > 0 && nowMs > expiresAtMs) {
            // The CLI already refreshed while we were deciding to — use its token.
            return Credentials(token: access, expired: false)
        }
        let refreshExpiresMs = (oauth["refreshTokenExpiresAt"] as? NSNumber)?.doubleValue ?? 0
        if refreshExpiresMs > 0, nowMs > refreshExpiresMs { return nil }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Same UA insurance as the usage endpoint: generic clients get served
        // a far less friendly bucket.
        request.setValue(UsageAPI.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
        ])

        guard let (body, response) = try? await URLSession.shared.data(for: request),
              (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
              let parsed = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let rotated = Self.applyRotation(into: Self.readJSON(file) ?? root,
                                               response: parsed,
                                               previousRefreshToken: refreshToken)
        else {
            // invalid_grant here usually means a concurrent CLI session consumed
            // the token first and wrote fresh credentials — pick those up instead.
            if let again = CredentialStore.readFile(at: file),
               again.token != nil, !again.expired { return again }
            return nil
        }

        Self.writeBack(rotated.root, to: file)
        // The in-memory token is authoritative even if the write failed: the
        // rotation is spent server-side either way.
        return Credentials(token: rotated.accessToken, expired: false)
    }

    /// Pure merge of a token-endpoint response into the credentials JSON.
    ///
    /// Merging into a fresh read of the file — not rebuilding it — is what lets
    /// fields we don't know about (`scopes`, `subscriptionType`, top-level keys
    /// like `mcpOAuth`) and anything the CLI wrote meanwhile survive the rewrite.
    static func applyRotation(
        into root: [String: Any],
        response: [String: Any],
        previousRefreshToken: String,
        now: Date = Date()
    ) -> (root: [String: Any], accessToken: String)? {
        guard let accessToken = response["access_token"] as? String else { return nil }
        var merged = root
        var oauth = (merged["claudeAiOauth"] as? [String: Any]) ?? [:]
        oauth["accessToken"] = accessToken
        // Rotation: keep ours only if the response omitted a replacement.
        oauth["refreshToken"] = (response["refresh_token"] as? String) ?? previousRefreshToken
        let expiresIn = (response["expires_in"] as? NSNumber)?.doubleValue ?? 28800
        oauth["expiresAt"] = Int((now.timeIntervalSince1970 + expiresIn) * 1000)
        merged["claudeAiOauth"] = oauth
        return (merged, accessToken)
    }

    static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func writeBack(_ root: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: root) else { return }
        // `.atomic` is the tmp-file-plus-rename dance; a torn write here would
        // lose a rotation that is already consumed server-side.
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: url.path)
    }
}
