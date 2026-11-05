import SwiftUI

/// The ledger login, as a first-run step at the app's root rather than a
/// surprise inside the Money tab.
///
/// WHY IT IS SKIPPABLE, and why that is not a cop-out: the ledger session is a
/// 30-day-idle, 90-day-absolute cookie, so it WILL expire while the rack token
/// - which has no expiry at all - is still perfectly good. A root gate that
/// demanded both without a way past would mean an expired finance cookie
/// locking you out of restarting a container, which is the wrong failure by a
/// wide margin. "Not now" drops you into the tabs, and the Money tab still
/// carries its own inline login for exactly that case.
///
/// `LoginView` roots itself in its own `NavigationStack`, so the skip cannot be
/// a toolbar item added from out here - a toolbar attaches to the nearest
/// enclosing navigation container, and that one is inside. `safeAreaInset` sits
/// outside the whole thing and needs no cooperation from it. (LoginView used
/// to be byte-identical to the copy in a sibling app; the Deck restyle changed
/// both, separately.)
struct LedgerSetup: View {
    var onSignedIn: () -> Void
    var onSkip: () -> Void

    var body: some View {
        LoginView(onSignedIn: onSignedIn)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    Button("Not now") { onSkip() }
                        .buttonStyle(.deck)
                    Text("You can sign in later from the Money tab.")
                        .font(Deck.small)
                        .foregroundStyle(Deck.muted)
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .deckBar(.bottom)
            }
    }
}
