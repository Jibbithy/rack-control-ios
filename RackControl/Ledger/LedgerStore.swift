import SwiftUI

/// Owns the ONE `GET /api/summary` response every tab renders from.
///
/// Three tabs each fetching independently would mean three round trips for
/// one screenful of data, and - worse, on a screen that shows money - the
/// fetches could land at different times and disagree with each other mid-
/// refresh, so Overview and Spending could show two different balances for a
/// few hundred milliseconds. A single store, injected into all three tabs via
/// the environment, makes that structurally impossible: there is exactly one
/// `Summary` in memory, and every tab reads the same one.
@Observable
@MainActor
final class LedgerStore {
    var summary: Summary?
    var fatal: LedgerError?
    var loading = false

    /// Set by RootView. Called on a 401 so the app can drop back to
    /// LoginView - LedgerClient.summary() has ALREADY cleared the stored cookie
    /// by the time this fires, so there's nothing left for the caller to
    /// clean up except its own navigation state.
    var onUnauthorized: () -> Void = {}

    func refresh() async {
        loading = true
        defer { loading = false }
        do {
            summary = try await LedgerClient.shared.summary()
            fatal = nil
        } catch let e as LedgerError {
            fatal = e
            if case .unauthorized = e { onUnauthorized() }
        } catch {
            fatal = .http(0, error.localizedDescription)
        }
    }

    // --- Subscriptions writes ---
    //
    // Each of these performs the write and then re-fetches `summary` -
    // never patches it in place. A local patch would mean guessing what the
    // hub just computed (e.g. `monthly_cents` for a newly-confirmed row),
    // and that guess could disagree with the real answer for as long as the
    // guess sits there; refreshing means it's wrong for zero milliseconds.
    // Throws rather than swallowing, so the caller (a detail sheet) can show
    // its own error instead of the write silently failing.

    func confirmSubscription(merchant: String, amountCents: Int, cadenceDays: Int?) async throws {
        try await LedgerClient.shared.confirmSubscription(merchant: merchant, amountCents: amountCents, cadenceDays: cadenceDays)
        await refresh()
    }

    func dismissSubscription(merchant: String) async throws {
        try await LedgerClient.shared.dismissSubscription(merchant: merchant)
        await refresh()
    }

    func removeSubscription(merchant: String) async throws {
        try await LedgerClient.shared.removeSubscription(merchant: merchant)
        await refresh()
    }

    // --- Settings ---

    /// The STORED pay schedule, not the resolved one on `summary`. Not cached
    /// here: the sheet is the only reader, it is short-lived, and a cached
    /// copy would be one more thing that can be stale on open.
    func loadSettings() async throws -> SettingsPayload {
        try await LedgerClient.shared.settings()
    }

    /// Double optional, deliberately: the hub merges, so "leave this key
    /// alone" (nil) and "clear this key" (.some(nil)) are different requests
    /// and collapsing them would either wipe a schedule or refuse to.
    func saveSettings(pay: PaySetting??) async throws {
        try await LedgerClient.shared.saveSettings(pay: pay)
        await refresh()
    }

    // --- Goals ---
    //
    // Same reasoning as the subscription writes above, but more load-bearing
    // here: add/remove/reorder change every OTHER goal's `allocated_cents`
    // too (the shared pool spills down in position order - see hub/goals.js),
    // so refreshing after the write isn't just this app's usual caution, it
    // is the only way GoalsView's other rows stop showing numbers the hub no
    // longer agrees with.

    func addGoal(name: String, targetCents: Int, targetDate: String?) async throws {
        try await LedgerClient.shared.addGoal(name: name, targetCents: targetCents, targetDate: targetDate)
        await refresh()
    }

    func updateGoal(id: Int, name: String, targetCents: Int, targetDate: String?) async throws {
        try await LedgerClient.shared.updateGoal(id: id, name: name, targetCents: targetCents, targetDate: targetDate)
        await refresh()
    }

    func removeGoal(id: Int) async throws {
        try await LedgerClient.shared.removeGoal(id: id)
        await refresh()
    }

    func reorderGoals(ids: [Int]) async throws {
        try await LedgerClient.shared.reorderGoals(ids: ids)
        await refresh()
    }
}
