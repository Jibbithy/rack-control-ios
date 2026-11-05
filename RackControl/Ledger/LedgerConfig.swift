import Foundation

enum LedgerConfig {
    /// A `tailscale serve` endpoint: it resolves in DNS for anyone, but routes
    /// for nobody off the tailnet. A failed request is therefore "Tailscale is
    /// off", not "the server is down" - which is why LedgerError separates
    /// .unreachable from .unauthorized, same as rack-control's client.
    static let baseURL = URL(string: "https://your-server.example")!

    /// The hub's CSRF check (hub/auth.js originOk) allows a request with NO
    /// Origin header through, since that's the non-browser case - but the
    /// server's allowlist (LEDGER_ORIGINS) is configured to exactly this one
    /// string, and a foreign Origin is a 403. Sending it always, rather than
    /// only when convenient, means this client is never one server-side config
    /// change away from a login that silently stops working.
    static let origin = "https://your-server.example"
}
