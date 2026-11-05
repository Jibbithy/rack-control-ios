import SwiftUI

/// A fake, offline rack so the UI can be looked at in the simulator.
///
/// The simulator is not on the tailnet, has no hub token and no ledger
/// session, so without this every screen past the token prompt is
/// unreachable and the design cannot be reviewed at all.
///
/// Activated ONLY by a launch argument, and only in a debug build: `screen` is
/// a plain `nil` in release, so every branch guarded by it is dead code the
/// optimiser removes. Nothing here touches the network or the Keychain.
///
///     xcrun simctl launch <udid> com.example.rackcontrol -RackDemo -RackScreen spending
///
/// `-RackScreen` picks the screen (see DemoScreen); without it the app opens
/// on the Rack tab as usual.
enum DemoScreen: String, CaseIterable {
    case lock, token, setup
    case rack
    case rackFaults = "rack-faults"
    case rackOffline = "rack-offline"
    case files, note, text, binary
    case tooBig = "too-big"
    case money, spending, subscriptions, activity, goals
    case paycheck
    case goalEdit = "goal-edit"
    case subDetail = "sub-detail"
}

enum DemoMode {

    /// The screen to open on, or nil when the demo is off - always nil in a
    /// release build.
    static var screen: DemoScreen? {
        #if DEBUG
            guard ProcessInfo.processInfo.arguments.contains("-RackDemo") else { return nil }
            return UserDefaults.standard.string(forKey: "RackScreen").flatMap(DemoScreen.init) ?? .rack
        #else
            return nil
        #endif
    }

    static var isActive: Bool { screen != nil }

    /// What TokenStore.load() answers in the demo: a token, except on the
    /// screen whose whole point is not having one.
    static var hubToken: String? { screen == .token ? nil : "demo" }

    /// Likewise for the ledger session and the first-run setup step.
    static var ledgerSession: String? { screen == .setup ? nil : "demo" }

    /// The tab RootView opens on; nil = its own default.
    static var tab: MainTab? {
        switch screen {
        case .files, .note, .text, .binary, .tooBig: .files
        case .money, .spending, .subscriptions, .activity, .goals,
            .paycheck, .goalEdit, .subDetail:
            .money
        default: nil
        }
    }

    /// Whether FilesView should push a screen on appear (`simctl` cannot tap).
    static var filesPush: Bool {
        switch screen {
        case .note, .text, .binary, .tooBig: true
        default: false
        }
    }

    /// Whether OverviewView should push one of its four screens on appear.
    static var moneyPush: Bool {
        switch screen {
        case .spending, .subscriptions, .activity, .goals, .goalEdit, .subDetail: true
        default: false
        }
    }
}

#if DEBUG
    extension DemoMode {

        // MARK: - pushed screens

        @MainActor @ViewBuilder
        static func filesDestination() -> some View {
            switch screen {
            case .note:
                NoteView(name: "Rack Control")
            case .text:
                FilePreviewView(
                    path: "/srv/data/docker-compose.yml", name: "docker-compose.yml",
                    kind: .text, size: 1874)
            case .tooBig:
                FilePreviewView(
                    path: "/srv/data/manual.pdf", name: "manual.pdf",
                    kind: .pdf, size: 224_395_264)
            default:
                FilePreviewView(
                    path: "/srv/data/archive.tar.zst", name: "archive.tar.zst",
                    kind: .binary, size: 3_650_722_201)
            }
        }

        @MainActor @ViewBuilder
        static func moneyDestination() -> some View {
            switch screen {
            case .spending: SpendingView()
            case .subscriptions, .subDetail: SubscriptionsView()
            case .activity: ActivityView()
            default: GoalsView()
            }
        }

        // MARK: - the hub

        /// Stands in for HubClient.get. Throws exactly what the real client would
        /// for a machine that is not answering.
        static func hub<T: Decodable>(_ path: String, query: [URLQueryItem]) throws -> T {
            if screen == .rackOffline { throw HubError.unreachable }
            let value: Any
            switch path {
            case "/api/apps":
                value = screen == .rackFaults ? appsWithFaults : apps
            case "/api/files":
                let at = query.first { $0.name == "path" }?.value ?? Config.filesRoot
                value = at == Config.vaultRoot ? vaultListing : filesListing
            case "/api/vault/note":
                value = note
            default:
                let parts = path.split(separator: "/").map(String.init)  // api glances <node> <kind>
                guard parts.count == 4, parts[1] == "glances", let g = glances[parts[2]] else {
                    throw HubError.http(404, "the demo has nothing at \(path)")
                }
                if screen == .rackFaults && parts[2] == "talos" { throw HubError.unreachable }
                switch parts[3] {
                case "quicklook": value = Quicklook(cpu: g.cpu, cpu_name: nil)
                case "mem": value = g.mem
                default: value = g.fs
                }
            }
            guard let typed = value as? T else {
                throw HubError.decoding("the demo's \(path) is not a \(T.self)")
            }
            return typed
        }

        static let textFile = FileBytes(
            data: Data(
                """
                services:
                  rack-hub:
                    image: node:22-alpine
                    working_dir: /srv/rack-control/hub
                    command: node server.js
                    restart: unless-stopped
                    environment:
                      - VAULT_ROOT=/srv/data/vault
                    volumes:
                      - /srv/rack-control:/srv/rack-control:ro
                      - /srv/data:/srv/data:ro

                  glances:
                    image: nicolargo/glances:latest-full
                    restart: unless-stopped
                    pid: host
                    network_mode: host
                    environment:
                      - GLANCES_OPT=-w --disable-webui

                """.utf8), truncated: true)

        private static func tile(_ k: String, _ n: String, _ m: String, _ s: String = "") -> AppTile {
            AppTile(k: k, n: n, m: m, i: k, s: s, v: "kuma")
        }

        private static let apps: [String: [AppTile]] = [
            "atlas": [
                tile("caddy", "Caddy", "100.0% · 24h"),
                tile("rack-hub", "Rack hub", "100.0% · 24h"),
                tile("ledger", "Ledger", "99.9% · 24h"),
                tile("media-server", "Media server", "100.0% · 24h"),
                tile("photo-index", "Photo Index", "99.7% · 24h"),
            ],
            "calypso": [
                tile("sim-runner", "Sim Runner", "100.0% · 24h"),
                tile("feed-tool", "Feed Tool", "98.2% · 24h"),
            ],
            "hermes": [
                tile("agent-host", "Agent host", "100.0% · 24h"),
                tile("assistant", "Assistant", "99.5% · 24h"),
                tile("scheduler", "Scheduler", "not deployed", "idle"),
            ],
            "iris": [
                tile("build-runner", "Build Runner", "launchd · up 6d")
            ],
        ]

        private static var appsWithFaults: [String: [AppTile]] {
            var a = apps
            a["calypso"] = [
                tile("sim-runner", "Sim Runner", "100.0% · 24h"),
                tile("feed-tool", "Feed Tool", "exited (1) 12m ago", "down"),
            ]
            return a
        }

        private struct Glance {
            let cpu: Double
            let mem: Mem
            let fs: [FsMount]
        }

        private static let gib = 1_073_741_824
        private static let tb = 1_000_000_000_000

        private static let glances: [String: Glance] = [
            "atlas": Glance(
                cpu: 12.4,
                mem: Mem(total: 32 * gib, used: 13 * gib, percent: 40.6),
                fs: [
                    FsMount(mnt_point: "/", size: 1 * tb, used: tb * 31 / 100, percent: 31.0),
                    FsMount(mnt_point: "/srv/data", size: 16 * tb, used: tb * 1256 / 100, percent: 78.5),
                ]),
            "calypso": Glance(
                cpu: 8.1,
                mem: Mem(total: 16 * gib, used: 10 * gib, percent: 62.3),
                fs: [FsMount(mnt_point: "/", size: tb / 2, used: tb * 22 / 100, percent: 44.0)]),
            "hermes": Glance(
                cpu: 23.7,
                mem: Mem(total: 16 * gib, used: 11 * gib, percent: 71.2),
                fs: [FsMount(mnt_point: "/", size: tb / 2, used: tb * 29 / 100, percent: 58.0)]),
            "talos": Glance(
                cpu: 4.2,
                mem: Mem(total: 8 * gib, used: 3 * gib, percent: 38.4),
                fs: [FsMount(mnt_point: "/", size: tb / 4, used: tb * 55 / 1000, percent: 22.0)]),
            "iris": Glance(
                cpu: 17.9,
                mem: Mem(total: 16 * gib, used: 13 * gib, percent: 83.1),
                fs: [FsMount(mnt_point: "/", size: tb / 4, used: tb * 227 / 1000, percent: 91.0)]),
        ]

        private static let mtime = 1_789_900_000_000.0

        private static func entry(_ name: String, dir: Bool = false, _ size: Int? = nil, _ kind: String? = nil) -> FileEntry {
            FileEntry(name: name, dir: dir, size: size, mtime: mtime, kind: kind)
        }

        private static let filesListing = FileListing(
            path: Config.filesRoot,
            entries: [
                entry("vault", dir: true), entry("media", dir: true), entry("models", dir: true),
                entry("backups", dir: true),
                entry("README.md", 2_143, "text"),
                entry("docker-compose.yml", 1_874, "text"),
                entry("rack-photo.jpg", 4_404_019, "image"),
                entry("bracket.stl", 1_873_004, "stl"),
                entry("manual.pdf", 224_395_264, "pdf"),
                entry("archive.tar.zst", 3_650_722_201, "binary"),
            ])

        private static let vaultListing = FileListing(
            path: Config.vaultRoot,
            entries: [
                entry("Daily", dir: true), entry("Projects", dir: true),
                entry("Rack Control.md", 1_204, "text"),
                entry("Network Overview.md", 6_310, "text"),
            ])

        private static let note = Note(
            name: "Rack Control", path: "/srv/data/vault/Projects/Rack Control.md",
            text: """
                Rack Control is the phone and web front end for the rack. The **hub** runs on atlas behind Caddy, and every node reports through Glances.

                See the network in [[Network Overview]], and the build node in [[Build Node Plan|the build plan]].

                - atlas: NAS, hub, Caddy
                - calypso, hermes: thin clients
                - talos: the Pi

                Deploys go through `deploy.sh`.
                """, truncated: true)

        // MARK: - the ledger

        static let settings = SettingsPayload(
            pay: PaySetting(amount_cents: 200_000, cadence_days: 14, anchor_date: "2026-09-05"),
            cadences: [
                Cadence(days: 7, label: "Weekly"), Cadence(days: 14, label: "Every 2 weeks"),
                Cadence(days: 28, label: "Every 4 weeks"),
            ])

        private static func tx(
            _ id: Int, _ on: String, _ cents: Int, _ label: String, _ category: String,
            credit: Bool = false
        ) -> Transaction {
            Transaction(
                id: id, posted_on: on, amount_cents: cents, direction: credit ? "credit" : "debit",
                merchant: label.lowercased(), display: label, merchant_raw: label.uppercased(),
                mcc: nil, state: "posted", balance_after_cents: nil, mask: "0001", category: category)
        }

        private static func charges(_ cents: Int, _ dates: [String]) -> [Charge] {
            dates.map { Charge(posted_on: $0, amount_cents: cents) }
        }

        static let summary = Summary(
            accounts: [
                Account(
                    id: 1, name: "Checking", mask: "0001", kind: "checking", balance_cents: 250_000,
                    balance_on: "2026-09-20", available_cents: 240_000, balance_source: "summary"),
                Account(
                    id: 2, name: "Savings", mask: "0002", kind: "savings", balance_cents: 1_200_000,
                    balance_on: "2026-09-14", available_cents: nil, balance_source: "transaction"),
                Account(
                    id: 3, name: "Credit card", mask: "0003", kind: "credit", balance_cents: nil,
                    balance_on: nil, available_cents: nil, balance_source: nil),
            ],
            transactions: [
                tx(10, "2026-09-20", 4_312, "Grocery Store", "Groceries"),
                tx(9, "2026-09-19", 5_820, "Gas Station", "Fuel"),
                tx(8, "2026-09-19", 200_000, "Paycheck", "Income", credit: true),
                tx(7, "2026-09-18", 9_214, "Warehouse Club", "Groceries"),
                tx(6, "2026-09-17", 1_199, "Music Stream", "Subscriptions"),
                tx(5, "2026-09-16", 3_998, "Online Store", "Shopping"),
                tx(4, "2026-09-15", 1_455, "Taco Stand", "Dining"),
                tx(3, "2026-09-14", 50_000, "Transfer to savings", "Transfer"),
                tx(2, "2026-09-12", 2_500, "Refund", "Transfer", credit: true),
                tx(1, "2026-09-11", 6_743, "Hardware Store", "Shopping"),
            ],
            spend: [
                CategorySpend(category: "Groceries", total_cents: 48_210, count: 12),
                CategorySpend(category: "Dining", total_cents: 31_540, count: 9),
                CategorySpend(category: "Fuel", total_cents: 22_875, count: 6),
                CategorySpend(category: "Shopping", total_cents: 19_990, count: 4),
                CategorySpend(category: "Utilities", total_cents: 16_400, count: 2),
                CategorySpend(category: "Subscriptions", total_cents: 12_297, count: 5),
                CategorySpend(category: "Transport", total_cents: 7_420, count: 4),
                CategorySpend(category: "Travel", total_cents: 5_100, count: 1),
                CategorySpend(category: "Entertainment", total_cents: 3_401, count: 2),
            ],
            merchants: [
                Merchant(merchant: "warehouse club", display: "Warehouse Club", total_cents: 21_840, count: 3, last_on: "2026-09-18"),
                Merchant(merchant: "grocery store", display: "Grocery Store", total_cents: 14_230, count: 4, last_on: "2026-09-19"),
                Merchant(merchant: "gas station", display: "Gas Station", total_cents: 12_005, count: 5, last_on: "2026-09-20"),
                Merchant(merchant: "online store", display: "Online Store", total_cents: 11_990, count: 3, last_on: "2026-09-16"),
                Merchant(merchant: "airline", display: "Regional Air", total_cents: 9_800, count: 1, last_on: "2026-09-02"),
            ],
            unparsed: 2,
            hasIncome: false,
            subscriptions: Subscriptions(
                confirmed: [
                    ConfirmedSubscription(
                        merchant: "music stream", display: "Music Stream", amount_cents: 1_199,
                        cadence_days: 30, kind: "pattern", monthly_cents: 1_199,
                        charges: charges(1_199, ["2026-07-17", "2026-08-17", "2026-09-17"]),
                        first_on: "2026-07-17", last_on: "2026-09-17", count: 3),
                    ConfirmedSubscription(
                        merchant: "cloud storage", display: "Cloud Storage", amount_cents: 299,
                        cadence_days: 30, kind: "pattern", monthly_cents: 299,
                        charges: charges(299, ["2026-08-03", "2026-09-03"]),
                        first_on: "2026-08-03", last_on: "2026-09-03", count: 2),
                    ConfirmedSubscription(
                        merchant: "backup service", display: "Backup Service", amount_cents: 900,
                        cadence_days: nil, kind: "mcc", monthly_cents: nil,
                        charges: charges(900, ["2026-09-08"]),
                        first_on: "2026-09-08", last_on: "2026-09-08", count: 1),
                ],
                candidates: [
                    CandidateSubscription(
                        merchant: "video stream", display: "Video Stream", amount_cents: 1_549,
                        cadence_days: 30, occurrences: 3, confidence: 0.9, basis: "pattern",
                        charges: charges(1_549, ["2026-07-09", "2026-08-09", "2026-09-09"]),
                        first_on: "2026-07-09", last_on: "2026-09-09", count: 3),
                    CandidateSubscription(
                        merchant: "app store", display: "App Store", amount_cents: 499,
                        cadence_days: nil, occurrences: 1, confidence: 0.6, basis: "mcc",
                        charges: charges(499, ["2026-09-13"]),
                        first_on: "2026-09-13", last_on: "2026-09-13", count: 1),
                ],
                monthly_total_cents: 1_498, monthly_known: 2, monthly_unknown: 1),
            poll: Poll(
                enabled: true, running: false, lastRunAt: 1_789_992_000_000 - 4 * 60_000,
                lastError: nil, lastStored: 3),
            since: "2026-08-22",
            now: 1_789_992_000_000,
            totals: Totals(
                balance_cents: 1_450_000, available_cents: nil, accounts_known: 2,
                accounts_total: 3, as_of: "2026-09-14"),
            spendTotal: SpendTotal(total_cents: 184_233, count: 47),
            pay: PayForecast(
                amount_cents: 200_000, cadence_days: 14, anchor_date: "2026-09-05",
                next_on: "2026-10-03", days_until: 12, previous_on: "2026-09-19",
                cadence_label: "Every 2 weeks"),
            goal_funds: GoalFunds(saved_cents: 1_200_000, source: "savings", accounts: ["Savings ••0002"]),
            goals: [
                Goal(
                    id: 1, name: "Emergency fund", target_cents: 1_000_000, target_date: nil, position: 0,
                    allocated_cents: 1_000_000, remaining_cents: 0, progress: 1.0, reached: true, days_left: nil),
                Goal(
                    id: 2, name: "Vehicle service", target_cents: 300_000, target_date: "2026-11-01", position: 1,
                    allocated_cents: 200_000, remaining_cents: 100_000, progress: 0.667, reached: false, days_left: 41),
                Goal(
                    id: 3, name: "New rack node", target_cents: 250_000, target_date: nil, position: 2,
                    allocated_cents: 0, remaining_cents: 250_000, progress: 0, reached: false, days_left: nil),
            ],
            today: "2026-09-21")
    }
#endif
