import UIKit
import UserNotifications

/// Remote notifications: asking for them, telling the hub where to send them,
/// and deciding what a banner does while the app is already open.
///
/// WHY THE APP NEEDS ANY OF THIS. Everything else here is pull - the app opens
/// a socket and the hub answers - and iOS suspends the process within seconds
/// of the screen locking. hub/turns.js already makes the ANSWER survive that;
/// nothing made the *knowing* survive it. A push is the only channel that
/// reaches a suspended app, so this file is the other half of that fix.
@MainActor
final class PushRegistrar: NSObject {
    static let shared = PushRegistrar()

    /// Set once the hub has accepted a token, so a re-launch does not re-POST
    /// the same registration on every cold start of the same session.
    private var registered = false

    /// Ask, then register. Safe to call repeatedly.
    ///
    /// CALLED AFTER THE HUB TOKEN EXISTS, not at launch. The permission sheet
    /// is the first thing a new install would otherwise show - before the app
    /// has explained what it is, and before there is any hub to register with.
    /// A "no" here is close to permanent (iOS only asks once; after that it is
    /// a trip to Settings), so the prompt is worth spending carefully.
    func enable() async {
        #if DEBUG
            // The permission alert would sit over every demo screenshot.
            if DemoMode.isActive { return }
        #endif
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let granted: Bool
        do {
            granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            // A throw here is the system declining to ask at all - a screen-time
            // restriction, or a profile. Not an error worth surfacing: the app
            // works exactly as it did before push existed.
            return
        }
        guard granted else { return }

        // MUST BE THE MAIN THREAD. registerForRemoteNotifications() off the
        // main actor is a runtime complaint at best and a silent no-op at
        // worst - the callback simply never fires and the phone looks like it
        // registered. The @MainActor on this type is what guarantees it.
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// APNs handed us a token. Hex-encode it and tell the hub.
    func received(deviceToken: Data) {
        // HEX, BY HAND. `deviceToken.description` used to print the bytes and
        // has printed "32 bytes" since iOS 13 - code that shipped the
        // description registered a device token of literally that string,
        // which the hub stores happily and Apple then rejects forever. There
        // is no warning anywhere on that path.
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task {
            do {
                try await HubClient.shared.registerPush(token: hex, env: Self.apsEnvironment)
                registered = true
            } catch {
                // Nothing to show and nothing to retry right now: the next
                // launch calls enable() again, and iOS re-issues the same
                // token without another prompt.
                registered = false
            }
        }
    }

    /// Which APNs environment this BUILD's device tokens live in.
    ///
    /// READ OFF THE EMBEDDED PROVISIONING PROFILE rather than from `#if DEBUG`,
    /// because the two are not the same question. A Release build installed
    /// with a development profile - which is how every build on this rack gets
    /// onto the phone - is still a SANDBOX token, and a `#if DEBUG` check calls
    /// it production. The hub would then push it at api.push.apple.com, get a
    /// 400 BadDeviceToken, and delete the registration as dead: a
    /// misconfiguration that erases its own evidence. See hub/push.js.
    static var apsEnvironment: String {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
            let raw = try? Data(contentsOf: url)
        else {
            // No profile at all: the Simulator, or an App Store build. Neither
            // can be wrong in a way that matters - the Simulator gets no real
            // token, and an App Store build is production by definition but
            // will never be produced by this repo.
            return "sandbox"
        }
        // The file is a CMS envelope with a plain-text plist inside it. Slicing
        // the plist out is what every tool that reads these does; parsing CMS
        // to get at a string Apple embeds in the clear is not worth a
        // dependency.
        guard let start = raw.range(of: Data("<plist".utf8)),
            let end = raw.range(of: Data("</plist>".utf8))
        else { return "sandbox" }
        let plist = raw[start.lowerBound..<end.upperBound]
        guard let parsed = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
            let entitlements = parsed["Entitlements"] as? [String: Any],
            let aps = entitlements["aps-environment"] as? String
        else { return "sandbox" }
        // Apple spells the development value "development"; the hub speaks in
        // Apple's HOST names, where the same thing is called sandbox.
        return aps == "production" ? "production" : "sandbox"
    }
}

extension PushRegistrar: UNUserNotificationCenterDelegate {
    /// A banner while the app is already open.
    ///
    /// SHOWN, NOT SUPPRESSED, and that is deliberate. The hub already refuses
    /// to send a notification for a turn somebody is watching - see
    /// notifyTurnFinished in hub/server.js - so anything that arrives here is
    /// about something the current screen is NOT showing: a node that just went
    /// down while you were reading a file, a text, a script on the rack. The
    /// two suppressions together would mean an outage went unannounced purely
    /// because the app happened to be open.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}

/// The three UIApplicationDelegate callbacks APNs needs, bridged into SwiftUI.
///
/// A DELEGATE IS UNAVOIDABLE. SwiftUI has no equivalent of
/// `didRegisterForRemoteNotificationsWithDeviceToken` - it is the one part of
/// remote notifications with no modern replacement, so `@UIApplicationDelegateAdaptor`
/// is the supported way in rather than a legacy hangover.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in PushRegistrar.shared.received(deviceToken: deviceToken) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Airplane mode, no APNs reachability, a profile without the
        // entitlement. None of them is actionable from inside the app, and all
        // of them resolve themselves on a later launch.
        print("[push] registration failed: \(error.localizedDescription)")
    }
}
