import LocalAuthentication
import SwiftUI

/// Biometric gate.
///
/// This is not theatre: behind it sits `x-rack-token`, the hub's shared secret,
/// which authorises Docker start/stop/restart on atlas as well as reads. A
/// borrowed unlocked phone would otherwise be a shell-adjacent credential.
@Observable
@MainActor
final class Lock {
    var unlocked = false
    var failure: String?

    func authenticate() async {
        #if DEBUG
            // The simulator has no Face ID to pass; the lock screen itself is kept
            // (with a failure to show) only when it is the screen being looked at.
            if let screen = DemoMode.screen {
                unlocked = screen != .lock
                failure = screen == .lock ? "Face ID did not match." : nil
                return
            }
        #endif
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Use Passcode"

        var probe: NSError?
        // .deviceOwnerAuthentication, NOT ...WithBiometrics: the passcode has to
        // remain a way in. A phone with a wet thumb or a re-registered face
        // would otherwise be locked out of its own rack with no recourse.
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &probe) else {
            // No passcode set at all. Refusing entirely would brick the app on a
            // device that simply has no lock, so this opens - the Keychain item
            // is ThisDeviceOnly and is already as protected as the device
            // allows.
            unlocked = true
            return
        }

        do {
            unlocked = try await ctx.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock Rack Control")
            failure = nil
        } catch {
            unlocked = false
            failure = (error as? LAError)?.code == .userCancel ? nil : error.localizedDescription
        }
    }
}

struct LockView: View {
    let lock: Lock

    var body: some View {
        VStack(spacing: Theme.sp5) {
            Image(systemName: "lock.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Deck.ink)
                .frame(width: 76, height: 76)
                .deckTile()
                .accessibilityHidden(true)
            Text("Rack Control")
                .font(Deck.title)
                .textCase(.uppercase)
                .foregroundStyle(Deck.ink)
            if let f = lock.failure {
                DeckErrorText(f)
                    .multilineTextAlignment(.center)
            }
            Button("Unlock") { Task { await lock.authenticate() } }
                .buttonStyle(.deckPrimary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .deckGround()
        .task { await lock.authenticate() }
    }
}
