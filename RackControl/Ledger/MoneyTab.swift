import SwiftUI

/// The Money tab's root: the ledger session gate, and the store behind it.
///
/// THE LEDGER LOGIN LIVES HERE, INSIDE THE TAB, and not at the app's root where
/// the rack token is asked for. The two credentials are unrelated - a header
/// token for example.com, a session cookie for the ledger hub on atlas - and
/// making the second one a condition of opening the app would turn the finance
/// half into a tax on the rack half. Someone opening this app to restart a
/// container must never be asked for a banking password. A missing ledger
/// session degrades this tab and nothing else, which is the same rule RackView
/// already follows when one node is asleep.
struct MoneyTab: View {
    @State private var session: String? = SessionStore.load()
    @State private var store = LedgerStore()

    var body: some View {
        if session == nil {
            LoginView { session = SessionStore.load() }
        } else {
            OverviewView(onSignOut: { session = nil })
                .environment(store)
                .task {
                    // On the tab root rather than on any one screen, so it
                    // fires once per session however the user navigates -
                    // four screens each kicking off their own fetch is the
                    // "N round trips, maybe disagreeing" problem the shared
                    // store exists to avoid.
                    //
                    // Routes back to the LOGIN, not out of the app. An expired
                    // ledger cookie says nothing about the rack token.
                    store.onUnauthorized = { session = nil }
                    await store.refresh()
                }
        }
    }
}
