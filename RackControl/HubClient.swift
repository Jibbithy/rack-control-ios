import Foundation

enum HubError: LocalizedError, Sendable {
    /// The hub answered, and said no. The token is wrong or gone.
    case unauthorized
    /// Nothing answered. Almost always Tailscale being off - example.com
    /// resolves for everyone and routes for nobody outside the tailnet.
    case unreachable
    case http(Int, String)
    case decoding(String)
    /// A call this app built wrong, caught before it reached the network. Never
    /// the hub's fault, so it must not borrow one of the cases above - .http(0,)
    /// would blame the hub for a bug on this side of the wire.
    case badRequest(String)
    /// The transfer worked and the PHONE could not keep it - a full disk, a
    /// container the app cannot write. Distinct from .badRequest for the same
    /// reason .badRequest is distinct from .http: "that request was malformed"
    /// sends someone hunting a bug in the app when the actual fix is to free up
    /// space, and neither of those is the hub being unreachable.
    case local(String)
    /// The Keychain would not hand the token over because the phone is locked
    /// (see TokenStore.Read). The token is fine; this request just cannot
    /// carry it. Never .unauthorized, which would send the user to re-paste it.
    case locked

    var errorDescription: String? {
        switch self {
        case .unauthorized: "That token was rejected."
        case .unreachable: "Can't reach the rack. Is Tailscale connected?"
        case .http(let c, let b): "The hub answered \(c): \(b)"
        case .decoding(let d): "Couldn't read the hub's answer: \(d)"
        case .badRequest(let d): "That request was malformed: \(d)"
        case .local(let d): "Couldn't save that file: \(d)"
        case .locked: "The phone is locked. Unlock it, then try again."
        }
    }
}

actor HubClient {
    static let shared = HubClient()

    private let session: URLSession

    init() {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.waitsForConnectivity = false  // fail fast so "not on the tailnet" appears promptly
        session = URLSession(configuration: c)
    }

    /// THE WAY BACK TO THE TOKEN SCREEN. Every 401 on the token header goes
    /// through here, so a rotated token forgets itself and RootView asks for
    /// the new one, instead of every screen saying "That token was rejected."
    /// with nowhere to paste a fix. `sent` is the token that request actually
    /// carried, nil when there was none - see HubToken.rejected for why that
    /// matters. NOT used by `download`: a 401 on a ticket is not the token's.
    private func unauthorized(_ sent: String?) async -> HubError {
        await HubToken.shared.rejected(sent)
        return .unauthorized
    }

    /// Every request carries the token. A request built without it is a bug,
    /// so there is exactly one place that builds requests.
    ///
    /// No token throws .unauthorized, which every caller routes to
    /// `unauthorized(nil)` and the token screen. A LOCKED Keychain throws
    /// .locked instead, which no caller catches that way - see TokenStore.Read.
    private func request(_ path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        let token: String
        switch TokenStore.read() {
        case .token(let t): token = t
        case .missing: throw HubError.unauthorized
        case .locked: throw HubError.locked
        }
        var comps = URLComponents(
            url: Config.baseURL.appending(path: path),
            resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var r = URLRequest(url: comps.url!)
        r.setValue(token, forHTTPHeaderField: "x-rack-token")
        return r
    }

    /// URLError -> HubError. THIS MAPPING IS THE WHOLE UX of the failure path:
    /// "not on the tailnet" and "signed out" send the user to completely
    /// different fixes, and the only thing that tells them apart is this.
    private func mapped(_ error: Error) -> HubError {
        if let e = error as? HubError { return e }
        guard let u = error as? URLError else { return .http(0, error.localizedDescription) }
        switch u.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost,
            .notConnectedToInternet, .networkConnectionLost, .dnsLookupFailed:
            return .unreachable
        default:
            return .http(0, u.localizedDescription)
        }
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as: T.Type = T.self) async throws -> T {
        #if DEBUG
            if DemoMode.isActive { return try DemoMode.hub(path, query: query) }  // see DemoMode
        #endif
        let req: URLRequest
        do { req = try request(path, query: query) } catch HubError.unauthorized { throw await unauthorized(nil) } catch { throw mapped(error) }

        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch { throw mapped(error) }

        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw await unauthorized(req.value(forHTTPHeaderField: "x-rack-token")) }
        guard (200..<300).contains(code) else {
            throw HubError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw HubError.decoding("\(error)") }
    }

    /// A POST with a JSON body, for the few routes that change something.
    ///
    /// NO `x-rack-csrf` HEADER AND NO Origin, deliberately. The hub holds a
    /// TOKEN caller to `originOk`, which allows a request with no Origin at
    /// all - which is what URLSession sends. The stricter session rule exists
    /// for browsers, which cannot set `x-rack-token` cross-origin in the first
    /// place. Adding a CSRF header here would look like belt and braces and
    /// actually just be noise.
    @discardableResult
    func post(_ path: String, body: [String: Any]) async throws -> Data {
        var req: URLRequest
        do { req = try request(path) } catch HubError.unauthorized { throw await unauthorized(nil) } catch { throw mapped(error) }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        do { req.httpBody = try JSONSerialization.data(withJSONObject: body) } catch { throw HubError.badRequest("\(error)") }

        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch { throw mapped(error) }

        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw await unauthorized(req.value(forHTTPHeaderField: "x-rack-token")) }
        guard (200..<300).contains(code) else {
            throw HubError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    // --- the endpoints, named so a caller never spells a path ---

    func apps() async throws -> [String: [AppTile]] { try await get("/api/apps") }

    /// Tell the hub where to send notifications for this phone.
    ///
    /// CALLED ON EVERY LAUNCH, not once. A device token is not stable: a
    /// restore from backup, a reinstall, and occasionally an OS update all
    /// issue a new one, and the ONLY way to learn that is to ask APNs every
    /// time and re-send whatever comes back. The hub upserts, so a repeat is
    /// free - see registerDevice in hub/push.js.
    ///
    /// A 503 here means the hub has no apns.json, which is a perfectly normal
    /// state and not worth telling anyone about.
    func registerPush(token: String, env: String) async throws {
        try await post(
            "/api/push/register",
            body: [
                "token": token,
                "env": env,
                // NAMED EXPLICITLY, because the hub serves three apps off one
                // device registry and falls back to its OWN configured bundle
                // when a registration does not say. That fallback is right only
                // for as long as the hub happens to be configured as this app -
                // the day it is not, these tokens quietly register as some other
                // app and every push Apple is asked to deliver comes back
                // DeviceTokenNotForTopic. Read rather than hardcoded so a rename
                // cannot leave this registering under a name the hub's allowlist
                // does not know; the literal is only a floor for a build with no
                // id at all.
                "bundle": Bundle.main.bundleIdentifier ?? "com.example.rackcontrol",
            ])
    }

    func quicklook(_ node: String) async throws -> Quicklook { try await get("/api/glances/\(node)/quicklook") }
    func mem(_ node: String) async throws -> Mem { try await get("/api/glances/\(node)/mem") }
    func filesystems(_ node: String) async throws -> [FsMount] { try await get("/api/glances/\(node)/fs") }

    func files(at path: String) async throws -> FileListing {
        try await get("/api/files", query: [.init(name: "path", value: path)])
    }

    /// `name` carries no .md suffix, and vault note names contain spaces and
    /// ampersands - hence URLQueryItem rather than string interpolation.
    func note(_ name: String) async throws -> Note {
        try await get("/api/vault/note", query: [.init(name: "name", value: name)])
    }

    /// A short-lived signed URL for one file.
    ///
    /// AVPlayer issues its own byte-range requests and cannot be made to send
    /// `x-rack-token`, so a media URL has to carry its own proof.
    ///
    /// THE TICKET LIVES SIX HOURS, and it used to live five. AVPlayer re-issues
    /// range requests for the whole playback session rather than only at the
    /// start, so a five-minute ticket played a film for five minutes and then
    /// stalled at the buffer edge; a backwards-then-forwards seek did the same.
    /// The hub widened the window rather than have this app re-mint per request
    /// through an AVAssetResourceLoaderDelegate - see hub/ticket.js, which
    /// carries the full trade. What matters on this side is that a ticket now
    /// comfortably outlives any playback session, so no caller here needs to
    /// think about renewal. It is still bound to this one path, and that path
    /// binding is now the load-bearing half of the scheme.
    func ticketURL(for path: String) async throws -> URL {
        let t: FileTicket = try await get(
            "/api/files/ticket",
            query: [.init(name: "path", value: path)])
        // The hub mints a ROOT-RELATIVE url, which is why resolving against
        // Config.baseURL is right - and also why a path component on baseURL
        // would be dropped rather than kept, harmless only for as long as that
        // stays true on the hub side.
        guard let u = URL(string: t.url, relativeTo: Config.baseURL)?.absoluteURL else {
            throw HubError.decoding("the hub returned an unusable ticket url")
        }
        // URL(string:relativeTo:) IS A RESOLVER, NOT A FILTER. The base is
        // ignored the instant the string is absolute or protocol-relative, so
        // `https://evil.example.com/x`, `//evil.example.com/x` and
        // `javascript:...` all resolve successfully and to themselves -
        // resolution succeeding says nothing about where the URL points. What
        // is being protected is a bearer credential: the signature rides in the
        // query string with no replay protection, and this URL goes straight to
        // AVPlayer, which will fetch whatever host it names.
        guard u.scheme == Config.baseURL.scheme, u.host == Config.baseURL.host else {
            throw HubError.decoding("the hub returned an off-host ticket url")
        }
        return u
    }

    /// Raw bytes, capped. For the kinds the app renders itself rather than
    /// handing to a player - text, and images small enough to hold in memory.
    func data(at path: String, limit: Int) async throws -> FileBytes {
        // A non-positive limit builds `bytes=0--1`, which does not match the
        // hub's `^bytes=(\d*)-(\d*)$` - so it parses no range at all and
        // answers 200 WITH THE WHOLE FILE. The cap would silently vanish on the
        // one call that asked for the least. Throw rather than clamp: a caller
        // passing 0 has a bug, and quietly reading one byte would hide it.
        guard limit > 0 else { throw HubError.badRequest("a byte limit must be positive") }
        #if DEBUG
            if DemoMode.isActive { return DemoMode.textFile }  // see DemoMode
        #endif

        var req: URLRequest
        do { req = try request("/api/files/content", query: [.init(name: "path", value: path)]) } catch HubError.unauthorized {
            throw await unauthorized(nil)
        } catch { throw mapped(error) }
        req.setValue("bytes=0-\(limit - 1)", forHTTPHeaderField: "Range")

        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch { throw mapped(error) }

        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw await unauthorized(req.value(forHTTPHeaderField: "x-rack-token")) }
        guard code == 200 || code == 206 else {
            throw HubError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        // NOT `code == 206`. The hub answers 206 for any satisfiable range,
        // including one that covers the whole file, so a 400-byte note read
        // with a megabyte limit comes back 206 and would fly a "truncated"
        // banner over the complete text. The total after the slash in
        // `Content-Range: bytes 0-399/400` is the only honest source.
        let total = (resp as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Range")?
            .split(separator: "/").last
            .flatMap { Int($0) }
        // No header at all - an intermediary that dropped the Range and sent a
        // plain 200, or a total spelled `*`. "We got everything we asked for"
        // is the most that can be said without it.
        return FileBytes(data: data, truncated: total.map { $0 > data.count } ?? (data.count >= limit))
    }

    /// Streams one file to `destination`, which must not already exist.
    ///
    /// THE COUNTERPART TO `data(at:limit:)`, AND THE REASON BOTH LIVE HERE: that
    /// one caps a read at a few hundred KB and holds it in memory, this one
    /// takes a whole file of any size and never holds more than a buffer of it,
    /// because a download task writes straight to disk. A 2GB video costs 2GB of
    /// storage and a few MB of RAM.
    ///
    /// It is in HubClient rather than in the view that wants it so that its
    /// URLError lands in `mapped` like every other call in this file. Written in
    /// the view it would have had no access to `mapped` and would have reported
    /// "the hub answered 0: A server with the specified hostname could not be
    /// found" where every other call says "Can't reach the rack. Is Tailscale
    /// connected?" - and that mapping is the whole UX of the failure path.
    ///
    /// The MOVE happens here too, not at the call site. URLSession hands back a
    /// file in a location it owns and reclaims, so the window between the
    /// download finishing and the file being put somewhere durable has to be
    /// closed by whoever is holding it - which is this function.
    func download(_ path: String, to destination: URL) async throws {
        // The ticket rather than the token header, which a download task would
        // carry perfectly well: it keeps every byte of one file on the same
        // credential, and ticketURL already refuses an off-host URL.
        let url = try await ticketURL(for: path)

        let temp: URL
        let resp: URLResponse
        do { (temp, resp) = try await downloads.download(from: url) } catch { throw mapped(error) }

        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        // A 401 on a ticketed URL is NOT a rejected token, so it must not
        // surface as .unauthorized - that would send the reader to the token
        // screen to fix a signature problem. It means the ticket expired or was
        // refused, and with a six-hour window that is close to impossible.
        guard (200..<300).contains(code) else {
            throw HubError.http(code, "the hub refused the download")
        }

        do { try FileManager.default.moveItem(at: temp, to: destination) } catch { throw HubError.local(error.localizedDescription) }
    }

    /// EPHEMERAL so a downloaded file is not also written into the shared URL
    /// cache on disk. For the large files this path exists to carry that would
    /// mean two copies in the app's container, one of them invisible and never
    /// deleted by the code that asked for the download.
    private let downloads = URLSession(configuration: .ephemeral)

    /// Proves a token before TokenEntryView commits it. A typo stored would
    /// 401 on the first call and bounce straight back to that screen, and over
    /// "Change token" it would already have replaced a token that worked.
    nonisolated func validate(_ token: String) async -> Bool {
        var r = URLRequest(url: Config.baseURL.appending(path: "/api/apps"))
        r.setValue(token, forHTTPHeaderField: "x-rack-token")
        r.timeoutInterval = 15
        guard let (_, resp) = try? await URLSession.shared.data(for: r) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
}
