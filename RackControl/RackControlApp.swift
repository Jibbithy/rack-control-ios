import SwiftUI

@main
struct RackControlApp: App {
    // The one part of remote notifications SwiftUI has no answer for - see
    // AppDelegate in PushRegistrar.swift.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // The Deck faces are registered at runtime from the bundled .ttf files,
        // before the first view or bar asks for one - a font requested before
        // this runs falls back to the system face without a word. The bar
        // appearance is built FROM those faces, so it has to come second.
        Deck.registerFonts()
        DeckChrome.install()
        // Before anything reads the token - HubToken.shared's first Keychain
        // read, which RootView's first body evaluation triggers.
        TokenStore.migrateToSharedGroup()
        Self.sweepPreviewTemp()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // ONE tint for the whole app. Accent-INK, not the accent fill:
                // the tint is what system controls draw TEXT and glyphs in, and
                // #ff5c39 as text fails 4.5:1 on the cream ground. Without any
                // tint every control rendered in system blue, a colour that
                // appears nowhere in Rack OS.
                .tint(Deck.accentInk)
                // The default face for any Text that does not choose one, so
                // nothing falls back to SF.
                .font(Deck.body)
                // Auto / Cream / Dark from the Rack tab's menu, stamped on the
                // WINDOW so the UIKit bars DeckChrome styles flip with the
                // content - see DeckTheme in DeckCream.swift.
                .deckTheme()
        }
    }

    /// Deletes the temp directories a previous run left behind.
    ///
    /// THIS HAS TO LIVE AT APP LEVEL, because the view whose files these are is
    /// precisely the thing that is gone when the leak happens. FilePreviewView
    /// deletes its own directory in onDisappear, and that covers the ordinary
    /// path - but the share download is started by a button whose Task is not
    /// tied to the view's lifetime, so navigating back mid-download runs
    /// onDisappear while there is still nothing to clean up, and the download
    /// then finishes and writes a directory that nothing owns. A force-quit or
    /// a crash between the download completing and the view disappearing does
    /// the same. Each of those strands a whole file - gigabytes, for the videos
    /// this path exists to carry - somewhere iOS only reclaims under storage
    /// pressure, and the app has no other reason to ever look there again.
    ///
    /// Safe to run unconditionally at start: nothing from a previous launch can
    /// still be open, and no preview in THIS launch has been created yet.
    /// Failures are ignored on purpose - a directory that will not delete is
    /// wasted space, not a reason to refuse to start.
    static func sweepPreviewTemp() {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: fm.temporaryDirectory, includingPropertiesForKeys: nil)
        else { return }
        // Matched on FilePreviewView's own constant rather than a literal, so a
        // rename cannot leave this silently collecting nothing.
        for entry in entries where entry.lastPathComponent.hasPrefix(FilePreviewView.tempPrefix) {
            try? fm.removeItem(at: entry)
        }
    }
}

/// Decides between the token prompt and the app itself. Task 6 inserts the
/// Face ID gate here.
///
/// THE TOKEN IS OBSERVED, NOT COPIED. `HubToken.shared.needsToken` turns true
/// the moment the hub answers 401 (a rotated token), and this view drops back
/// to the token screen on its own; a locked Keychain never turns it true. A
/// `@State` seeded once at launch is what used to leave a rejected app stuck
/// on "That token was rejected." with no field to paste the new one into.
struct RootView: View {
    private let hub = HubToken.shared
    /// The ledger cookie, collected at the root so both credentials are asked
    /// for in one place on first run rather than one of them ambushing you
    /// three taps into the Money tab.
    @State private var ledgerSession: String? = SessionStore.load()
    /// Set by "Not now". Lives only as long as this launch - the setup step
    /// offers itself again next time, which is right for something you skipped
    /// rather than declined.
    @State private var skippedLedger = false
    @State private var lock = Lock()
    @State private var tab: MainTab = DemoMode.tab ?? .rack
    @Environment(\.scenePhase) private var phase

    var body: some View {
        content
            .onChange(of: phase) { _, now in
                // Re-lock on the way OUT, not on the way back in. Locking on
                // .active would fire a biometric prompt over the app switcher
                // preview; locking on .background means the app is already
                // covered by the system snapshot when the state flips.
                if now == .background { lock.unlocked = false }
                // AGAIN ON EVERY ACTIVATION, not only at launch: a launch that
                // found the Keychain locked could do neither, and a resumed
                // app never launches again. See TokenStore.migrateToSharedGroup
                // and HubToken.refresh; both are cheap when nothing changed.
                if now == .active {
                    TokenStore.migrateToSharedGroup()
                    hub.refresh()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if !lock.unlocked {
            LockView(lock: lock)
        } else if hub.needsToken {
            TokenEntryView()
        } else if ledgerSession == nil && !skippedLedger {
            // Both credentials, one setup flow. They are genuinely two secrets
            // for two different hosts - a header token for example.com, a
            // username and password for the ledger hub on atlas - so this is
            // two screens in sequence, not one combined form pretending
            // otherwise. Neither is ever asked for twice: both persist in the
            // Keychain.
            LedgerSetup(
                onSignedIn: { ledgerSession = SessionStore.load() },
                onSkip: { skippedLedger = true })
        } else {
            // Opens on Rack. Files keeps its place at the left of the bar -
            // the order is about where your thumb expects a tab to be, the
            // selection is about what the app is for when you open it.
            //
            // Chat used to be the third tab and is now its own app, Agents -
            // a separate project. Nothing here should grow a link to it: two apps
            // that launch each other are one app with extra steps.
            //
            // Money is the whole of what used to be the Ledger app. It is ONE
            // tab holding four screens rather than four tabs, because six
            // top-level tabs is one more than iOS shows before it hides the
            // rest behind "More".
            TabView(selection: $tab) {
                Tab("Files", systemImage: "folder", value: .files) { FilesView() }
                Tab("Rack", systemImage: "server.rack", value: .rack) { RackView() }
                Tab("Money", systemImage: "dollarsign.circle", value: .money) { MoneyTab() }
            }
            // HERE, NOT IN init(), and the placement is the whole decision.
            // This branch is reached only once the app is unlocked AND the hub
            // token exists, so the notification prompt lands on someone who
            // has seen what the app is and has a hub to be notified BY. At
            // launch it would be the first thing a new install ever showed,
            // and iOS asks exactly once - a reflexive "no" there is a trip to
            // Settings to undo.
            //
            // `.task` re-runs on every appearance of this branch, which is
            // wanted: it is also the device-token refresh. See registerPush.
            .task { await PushRegistrar.shared.enable() }
        }
    }
}

enum MainTab: Hashable { case files, rack, money }
