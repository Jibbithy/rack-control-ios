import Foundation

enum LedgerError: LocalizedError, Sendable {
    /// The hub answered, and said no. Either the session cookie is gone/
    /// expired, or (in `login`) the credentials were wrong - never distinguish
    /// those two in the message shown for login, since which one it is is
    /// exactly what the hub refuses to reveal about a login attempt.
    case unauthorized
    /// Nothing answered. Almost always Tailscale being off -
    /// your-server.example resolves for everyone and routes for nobody
    /// outside the tailnet.
    case unreachable
    case http(Int, String)
    case decoding(String)
    /// A call this app built wrong, caught before it reached the network.
    /// Never the hub's fault, so it must not borrow one of the cases above -
    /// .http(0,) would blame the hub for a bug on this side of the wire.
    case badRequest(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Signed out. Please sign in again."
        case .unreachable: "Can't reach the hub. Is Tailscale connected?"
        case .http(let c, let b): "The hub answered \(c): \(b)"
        case .decoding(let d): "Couldn't read the hub's answer: \(d)"
        case .badRequest(let d): "That request was malformed: \(d)"
        }
    }
}

private struct ErrorBody: Decodable { let error: String? }

actor LedgerClient {
    static let shared = LedgerClient()

    private let session: URLSession

    init() {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.waitsForConnectivity = false  // fail fast so "not on the tailnet" appears promptly
        // This app reads and replays the session cookie itself, through
        // SessionStore - never through URLSession's own jar. Letting the jar
        // ALSO track it would mean two places that think they own "am I
        // signed in", and they can disagree (e.g. after logout clears the
        // Keychain but the ephemeral jar, scoped to this process, still holds
        // a cookie from earlier in the same launch).
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        session = URLSession(configuration: c)
    }

    /// URLError -> LedgerError. THIS MAPPING IS THE WHOLE UX of the failure path:
    /// "not on the tailnet" and "signed out" send the user to completely
    /// different fixes, and the only thing that tells them apart is this.
    private func mapped(_ error: Error) -> LedgerError {
        if let e = error as? LedgerError { return e }
        guard let u = error as? URLError else { return .http(0, error.localizedDescription) }
        switch u.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost,
            .notConnectedToInternet, .networkConnectionLost, .dnsLookupFailed:
            return .unreachable
        default:
            return .http(0, u.localizedDescription)
        }
    }

    /// Pulls just the `ledger_sid=<value>` pair out of a raw Set-Cookie
    /// header, discarding the attributes (Max-Age, HttpOnly, SameSite, Path,
    /// Secure) that follow the first `;`. Those attributes are instructions to
    /// a BROWSER's cookie jar; this app has no jar (see the httpShouldSetCookies
    /// comment above) and re-sends the raw value by hand on every request, so
    /// there is nothing here that needs them.
    private static func sessionCookie(from resp: HTTPURLResponse?) -> String? {
        guard let raw = resp?.value(forHTTPHeaderField: "Set-Cookie"),
            let firstPart = raw.split(separator: ";").first,
            let eq = firstPart.firstIndex(of: "=")
        else { return nil }
        let value = firstPart[firstPart.index(after: eq)...]
        return value.isEmpty ? nil : String(value)
    }

    /// POST /api/login. Throws with the hub's OWN message on failure - see
    /// hub/auth.js: a wrong password and a nonexistent username get the exact
    /// same status and body on purpose, so this must show that string
    /// verbatim rather than write a friendlier one that could reintroduce the
    /// distinction the hub worked to erase.
    func login(username: String, password: String) async throws {
        var r = URLRequest(url: LedgerConfig.baseURL.appending(path: "/api/login"))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Required: hub/server.js's originOk 403s any request whose Origin is
        // present but not in LEDGER_ORIGINS, and that env var is set on atlas
        // to exactly this one string. Omitting the header entirely also
        // passes the hub's check (a non-browser caller has none), but sending
        // it is what keeps this client honest about being the one app the
        // hub's allowlist was written for.
        r.setValue(LedgerConfig.origin, forHTTPHeaderField: "Origin")
        do {
            r.httpBody = try JSONEncoder().encode(["username": username, "password": password])
        } catch {
            throw LedgerError.badRequest("couldn't encode the login body")
        }

        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await session.data(for: r) } catch { throw mapped(error) }

        let http = resp as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        guard code == 200 else {
            let msg = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            throw LedgerError.http(code, msg ?? (String(data: data, encoding: .utf8) ?? ""))
        }
        guard let cookie = Self.sessionCookie(from: http) else {
            throw LedgerError.decoding("login succeeded but the hub set no session cookie")
        }
        SessionStore.save(cookie)
    }

    /// POST /api/logout. Best-effort against the network - the cookie is
    /// cleared locally either way, same as web/app.js's "cookie may already be
    /// gone" comment: a hub that can't be reached still has to let this device
    /// forget the session, or Sign Out would do nothing while offline.
    func logout() async {
        defer { SessionStore.clear() }
        guard let cookie = SessionStore.load() else { return }
        var r = URLRequest(url: LedgerConfig.baseURL.appending(path: "/api/logout"))
        r.httpMethod = "POST"
        r.setValue(LedgerConfig.origin, forHTTPHeaderField: "Origin")
        r.setValue("ledger_sid=\(cookie)", forHTTPHeaderField: "Cookie")
        _ = try? await session.data(for: r)
    }

    /// GET /api/summary. A 401 here means THIS cookie specifically was
    /// refused - expired past the 30-day idle window, revoked, or simply
    /// never valid - so it is cleared right here, in the one place that reads
    /// it back out, rather than leaving every call site responsible for
    /// remembering to do that themselves.
    func summary() async throws -> Summary {
        #if DEBUG
            if DemoMode.isActive { return DemoMode.summary }  // see DemoMode
        #endif
        guard let cookie = SessionStore.load() else { throw LedgerError.unauthorized }

        var r = URLRequest(url: LedgerConfig.baseURL.appending(path: "/api/summary"))
        r.setValue("ledger_sid=\(cookie)", forHTTPHeaderField: "Cookie")

        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await session.data(for: r) } catch { throw mapped(error) }

        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 {
            SessionStore.clear()
            throw LedgerError.unauthorized
        }
        guard (200..<300).contains(code) else {
            throw LedgerError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        do { return try JSONDecoder().decode(Summary.self, from: data) } catch { throw LedgerError.decoding("\(error)") }
    }

    // --- Subscriptions writes ---
    //
    // The app's first writes besides login. Each hits an endpoint that is
    // BOTH session-gated (checked by the router before these run) and
    // origin-checked exactly like handleLogin - see hub/server.js's comment
    // on the three handlers - so the Origin header below is not optional the
    // way it might look; omitting it is a 403, same as a foreign origin.
    // None of these touch `summary` locally: the caller (LedgerStore) always
    // re-fetches after a successful write, so the UI only ever shows what
    // the hub actually recorded, never a local guess of what it will say.

    /// Shared shape for the three calls below - same cookie, same Origin,
    /// same 401 handling as summary(). `body`'s nil values are dropped
    /// rather than encoded as JSON null: the hub's parseSubscriptionBody
    /// treats a missing key and an explicit null identically, so there is no
    /// behavioral difference, and dropping keeps a dismiss/remove body
    /// (`{"merchant": ...}` only) from growing stray nulls.
    private func postSubscriptionAction(_ path: String, body: [String: Any?]) async throws {
        guard let cookie = SessionStore.load() else { throw LedgerError.unauthorized }

        var r = URLRequest(url: LedgerConfig.baseURL.appending(path: path))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(LedgerConfig.origin, forHTTPHeaderField: "Origin")
        r.setValue("ledger_sid=\(cookie)", forHTTPHeaderField: "Cookie")
        do {
            r.httpBody = try JSONSerialization.data(withJSONObject: body.compactMapValues { $0 })
        } catch {
            throw LedgerError.badRequest("couldn't encode the request body")
        }

        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await session.data(for: r) } catch { throw mapped(error) }

        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 {
            SessionStore.clear()
            throw LedgerError.unauthorized
        }
        guard (200..<300).contains(code) else {
            let msg = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            throw LedgerError.http(code, msg ?? (String(data: data, encoding: .utf8) ?? ""))
        }
    }

    /// POST /api/subscriptions. Promotes a candidate to confirmed, or
    /// re-confirms an existing one with corrected numbers - hub/db.js's
    /// confirmSubscription is an upsert (ON CONFLICT), not an insert-only.
    /// `kind` is never sent: the hub defaults it to "subscription" and this
    /// app has no UI yet for anything else.
    func confirmSubscription(merchant: String, amountCents: Int, cadenceDays: Int?) async throws {
        try await postSubscriptionAction(
            "/api/subscriptions",
            body: [
                "merchant": merchant, "amount_cents": amountCents, "cadence_days": cadenceDays,
            ])
    }

    /// POST /api/subscriptions/dismiss. The candidate stops reappearing
    /// (hub/recurring.js's detectCandidates filters out decided merchants)
    /// but nothing is deleted from `recurring` - see removeSubscription for
    /// undoing a confirm.
    func dismissSubscription(merchant: String) async throws {
        try await postSubscriptionAction("/api/subscriptions/dismiss", body: ["merchant": merchant])
    }

    /// POST /api/subscriptions/remove. Deletes the `recurring` row outright,
    /// so a confirmed subscription goes back to being whatever the detector
    /// makes of it on the next refresh - a candidate again, or nothing.
    func removeSubscription(merchant: String) async throws {
        try await postSubscriptionAction("/api/subscriptions/remove", body: ["merchant": merchant])
    }

    // --- Settings: the pay schedule ---
    //
    // The one fact left in Ledger the bank never sends - see SettingsPayload's
    // doc comment for why the savings goal moved out to its own `/api/goals/*`
    // routes below rather than staying a key in this merge.

    /// GET /api/settings. Returns the STORED schedule (not the one already
    /// resolved against today that `summary` carries) plus the cadences the hub
    /// can actually compute, which is what the picker is built from.
    func settings() async throws -> SettingsPayload {
        #if DEBUG
            if DemoMode.isActive { return DemoMode.settings }  // see DemoMode
        #endif
        guard let cookie = SessionStore.load() else { throw LedgerError.unauthorized }

        var r = URLRequest(url: LedgerConfig.baseURL.appending(path: "/api/settings"))
        r.setValue("ledger_sid=\(cookie)", forHTTPHeaderField: "Cookie")

        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await session.data(for: r) } catch { throw mapped(error) }

        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 {
            SessionStore.clear()
            throw LedgerError.unauthorized
        }
        guard (200..<300).contains(code) else {
            throw LedgerError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        do { return try JSONDecoder().decode(SettingsPayload.self, from: data) } catch { throw LedgerError.decoding("\(error)") }
    }

    /// POST /api/settings.
    ///
    /// The hub MERGES: a key absent from the body is left alone, and a key sent
    /// as an explicit null is cleared. That distinction is why `pay` is a
    /// double optional rather than a plain one - `pay: nil` on its own cannot
    /// say whether the caller means "don't touch it" or "delete it", and
    /// guessing wrong either wipes a schedule or silently refuses to. There is
    /// no `goal` parameter any more: the hub now rejects any body containing a
    /// `goal` key outright rather than merging it, so sending one - even nil -
    /// would turn a pay-only save into a 400.
    func saveSettings(pay: PaySetting??) async throws {
        guard let cookie = SessionStore.load() else { throw LedgerError.unauthorized }

        var body: [String: Any] = [:]
        if let pay { body["pay"] = pay.map(Self.dictionary(from:)) ?? NSNull() }
        guard !body.isEmpty else { throw LedgerError.badRequest("nothing to change") }

        var r = URLRequest(url: LedgerConfig.baseURL.appending(path: "/api/settings"))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(LedgerConfig.origin, forHTTPHeaderField: "Origin")
        r.setValue("ledger_sid=\(cookie)", forHTTPHeaderField: "Cookie")
        do { r.httpBody = try JSONSerialization.data(withJSONObject: body) } catch { throw LedgerError.badRequest("couldn't encode the settings body") }

        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await session.data(for: r) } catch { throw mapped(error) }

        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 {
            SessionStore.clear()
            throw LedgerError.unauthorized
        }
        guard (200..<300).contains(code) else {
            // The hub's own message names WHAT was rejected, which is the only
            // thing that makes a 400 here fixable.
            let msg = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            throw LedgerError.http(code, msg ?? (String(data: data, encoding: .utf8) ?? ""))
        }
    }

    private static func dictionary(from pay: PaySetting) -> [String: Any] {
        [
            "amount_cents": pay.amount_cents,
            "cadence_days": pay.cadence_days,
            "anchor_date": pay.anchor_date,
        ]
    }

    // --- Goals: the ranked list - see hub/goals.js ---
    //
    // Same shape as postSubscriptionAction above (cookie, Origin, 401
    // handling, the hub's own error message surfaced on a 400) because these
    // are session-gated and origin-checked exactly the same way - see
    // hub/server.js's comment on the four goal handlers. None of these touch
    // `summary` locally either: LedgerStore always re-fetches after a write,
    // which matters MORE here than for subscriptions - adding, removing or
    // reordering one goal changes every OTHER goal's `allocated_cents` too
    // (the pool spills down in position order), so a local patch would have
    // to correctly re-run the hub's own allocation to stay honest, and the
    // one place that logic should live is the hub.

    /// POST /api/goals/add. Appended after every existing goal - the hub
    /// decides where a brand new goal lands in the funding order (last), not
    /// this call.
    func addGoal(name: String, targetCents: Int, targetDate: String?) async throws {
        try await postSubscriptionAction(
            "/api/goals/add",
            body: [
                "name": name, "target_cents": targetCents, "target_date": targetDate,
            ])
    }

    /// POST /api/goals/update. Edits name/target/deadline in place - `id`
    /// says which goal, so this never touches `position`.
    func updateGoal(id: Int, name: String, targetCents: Int, targetDate: String?) async throws {
        try await postSubscriptionAction(
            "/api/goals/update",
            body: [
                "id": id, "name": name, "target_cents": targetCents, "target_date": targetDate,
            ])
    }

    /// POST /api/goals/remove. Idempotent on the hub side - removing an id
    /// that is already gone is not an error, so this never needs to check
    /// first.
    func removeGoal(id: Int) async throws {
        try await postSubscriptionAction("/api/goals/remove", body: ["id": id])
    }

    /// POST /api/goals/reorder. `ids` must be exactly the current set of goal
    /// ids, once each, in the new funding order - the hub rejects anything
    /// missing an id, carrying an extra one, or repeating one (400, "ids must
    /// be exactly the current set of goal ids, once each"), rather than
    /// silently dropping whatever it doesn't recognise to the bottom.
    func reorderGoals(ids: [Int]) async throws {
        try await postSubscriptionAction("/api/goals/reorder", body: ["ids": ids])
    }
}
