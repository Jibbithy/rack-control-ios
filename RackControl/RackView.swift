import SwiftUI

@Observable
@MainActor
final class RackModel {
    var health: [String: NodeHealth] = [:]
    var tiles: [String: [AppTile]] = [:]
    var fatal: HubError?
    var loading = false

    /// PER NODE, DELIBERATELY. One `async let` group that rethrows would blank
    /// the whole screen because a single machine is asleep; here a dead node
    /// degrades its own card and the others render normally.
    func refresh() async {
        loading = true
        defer { loading = false }

        do {
            tiles = try await HubClient.shared.apps()
            fatal = nil
        } catch let e as HubError {
            // Only a credential problem is worth taking the whole screen for.
            if case .unauthorized = e { fatal = e } else { fatal = e }
        } catch {}

        await withTaskGroup(of: (String, NodeHealth).self) { group in
            for node in Config.nodes {
                group.addTask { (node, await Self.health(of: node)) }
            }
            for await (node, h) in group { health[node] = h }
        }
    }

    /// One line that answers the only question this screen gets asked from a
    /// pocket: is anything broken. Everything else on the tab requires scrolling
    /// past five machines and their services to work out, which is the wrong
    /// amount of effort for a yes/no.
    var faults: (services: Int, nodes: Int) {
        let down = tiles.values.flatMap { $0 }.filter(\.isDown).count
        // A node with no reading at all is unreachable, not healthy - counting
        // only `error` would call a machine that answered nothing "fine".
        let bad = Config.nodes.filter { health[$0]?.error != nil }.count
        return (down, bad)
    }

    private static func health(of node: String) async -> NodeHealth {
        var out = NodeHealth()
        let want = Config.poolMount(for: node)
        // Each call is independent: a node can answer /mem and not /fs.
        async let ql = try? await HubClient.shared.quicklook(node)
        async let mem = try? await HubClient.shared.mem(node)
        async let fs = try? await HubClient.shared.filesystems(node)

        out.cpu = await ql?.cpu
        out.mem = await mem
        let mounts = await fs
        out.pool = mounts?.first { $0.mnt_point == want } ?? mounts?.first { $0.mnt_point == "/" }
        if out.cpu == nil && out.mem == nil && out.pool == nil { out.error = "unreachable" }
        return out
    }
}

/// The rack, as the website draws it: Deck cards on the cream ground.
///
/// NOT A `List`. A grouped List paints `.systemGroupedBackground` and its own
/// inset rows, and neither is themeable past a point - the row fill, the
/// separator inset and the section header case are all system-owned. A
/// ScrollView of `.rackCard()`s is the same information with the web's own
/// surface treatment, and it is the ONLY way the two ever match.
struct RackView: View {
    @State private var model = RackModel()
    /// "Change token", from the theme menu. A SHEET that forgets nothing until
    /// a new token is proved - a 401 already goes back to the token screen by
    /// itself (see HubToken); this is the deliberate way, for a token rotated
    /// before the phone has noticed.
    @State private var changingToken = false
    @Environment(\.scenePhase) private var phase

    var body: some View {
        NavigationStack {
            content
                .background(Deck.ground)
                .navigationTitle("Rack")
                // The web keeps its theme button in the dashboard header, and
                // this app has no settings screen - so it lives here, on the
                // tab the app opens on.
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        DeckThemeMenu(onChangeToken: { changingToken = true })
                    }
                }
        }
        .sheet(isPresented: $changingToken) {
            TokenEntryView(onClose: { changingToken = false })
        }
        .task { await model.refresh() }
        .task(id: phase) {
            // Poll ONLY while foregrounded. A background timer drains the
            // battery and Tailscale may not even be up to answer it.
            guard phase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if Task.isCancelled { return }
                await model.refresh()
            }
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(spacing: Theme.sp5) {
                // IN THE STACK, NOT AN OVERLAY. As a floating
                // ContentUnavailableView this printed its headline straight
                // across the middle of the node cards, which still render
                // (each one showing its own "unreachable") - two truths
                // stacked on top of each other, neither readable. A card at
                // the top says the same thing once, in the place the eye
                // already starts.
                if let e = model.fatal {
                    DeckAlert(.crit, message: e.localizedDescription)
                } else {
                    RollupCard(faults: model.faults, loaded: !model.health.isEmpty)
                }

                ForEach(Config.nodeDefs) { def in
                    NodeCard(
                        def: def,
                        health: model.health[def.id],
                        tiles: model.tiles[def.id] ?? [])
                }
            }
            .padding(Theme.sp4)
        }
        .scrollContentBackground(.hidden)
        .refreshable { await model.refresh() }
    }
}

/// One machine and everything it runs, in a single card.
///
/// The services USED TO BE A SEPARATE SECTION further down the screen, keyed by
/// node name, so reading "is hermes healthy" meant holding a hostname in your
/// head and scrolling to find it again. The web has never split them: a node's
/// tile and its services are one object there, and they are one card here.
struct NodeCard: View {
    let def: Config.NodeDef
    let health: NodeHealth?
    let tiles: [AppTile]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sp3) {
            header

            if let h = health, h.error == nil {
                HStack(alignment: .top, spacing: Theme.sp4) {
                    stat("CPU", h.cpu.map { ($0, pct($0)) })
                    stat("RAM", h.mem.map { ($0.percent, pct($0.percent)) })
                    stat("Disk", h.pool.map { ($0.percent, pct($0.percent)) })
                }
                if let m = h.mem {
                    Text("\(bytes(m.used)) of \(bytes(m.total))")
                        .font(Theme.rowMeta)
                        .foregroundStyle(Deck.muted)
                }
            } else if health == nil {
                ProgressView().controlSize(.small).tint(Deck.ink)
            }

            if !tiles.isEmpty {
                // The card's own edge, not a system Divider: a 2px ink rule
                // between the machine and what it runs.
                DeckRule()
                VStack(spacing: 0) {
                    ForEach(Array(tiles.enumerated()), id: \.element.id) { i, tile in
                        if i > 0 { Rectangle().fill(Deck.hair).frame(height: Deck.borderWidth) }
                        ServiceRow(tile: tile)
                    }
                }
            } else if !def.docker && health?.error == nil {
                // Says what the web's panel says rather than leaving a blank:
                // "no containers here" and "I could not read Docker" look
                // identical as an empty list, and only one of them is fine.
                Text("No containers on this node")
                    .font(Deck.small)
                    .foregroundStyle(Deck.muted)
            }
        }
        .rackCard()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(def.id).font(Deck.heading).foregroundStyle(Deck.ink)
                Text(def.role).font(Deck.small).foregroundStyle(Deck.muted)
            }
            Spacer()
            if let e = health?.error {
                StatusPill(state: .down, text: e)
            } else {
                Text(def.ru).eyebrow()
            }
        }
    }

    /// Label, number, meter. The number is the largest of the three - it used
    /// to be body-size under a caption, which gave a reading the same weight as
    /// the word describing it.
    private func stat(_ label: String, _ value: (Double, String)?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).eyebrow()
            Text(value?.1 ?? "—")
                .font(Theme.figure)
                .foregroundStyle(value == nil ? Deck.muted : Deck.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Meter(percent: value?.0 ?? 0)
                .opacity(value == nil ? 0.35 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value?.1 ?? "no reading")
    }

    private func pct(_ v: Double) -> String { String(format: "%.0f%%", v) }

    private func bytes(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .memory)
    }
}

struct ServiceRow: View {
    let tile: AppTile

    private var state: RackState {
        tile.isDown ? .down : tile.isUnknown ? .unknown : .up
    }

    var body: some View {
        HStack(spacing: Theme.sp3) {
            StatusDot(state: state, size: 9)
            Text(tile.n)
                .font(Theme.rowTitle)
                .foregroundStyle(Deck.ink)
            Spacer(minLength: Theme.sp2)
            Text(tile.m)
                .font(Theme.rowMeta)
                .foregroundStyle(state == .down ? Deck.critInk : Deck.muted)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, Theme.sp3)
        .frame(minHeight: 44)
        /* One element, not three. Without this VoiceOver reads the name and the
           meta as separate stops and never says the state at all - the dot is
           an unlabelled shape, so it is simply skipped. */
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tile.n)
        .accessibilityValue("\(tile.stateWord). \(tile.m)")
    }
}

/// The Rack tab's summary line. Quiet and green when there is nothing to say,
/// loud and specific when there is - the count only appears when the count is
/// the bad news, which is the same rule the web rollup follows.
///
/// A DeckAlert: the verdict is carried by the dot's SHAPE (● ■ ○) and the
/// edge colour together, never by colour alone.
struct RollupCard: View {
    let faults: (services: Int, nodes: Int)
    let loaded: Bool

    private var bad: Bool { faults.services > 0 || faults.nodes > 0 }
    private var state: RackState { !loaded ? .unknown : bad ? .down : .up }

    private var message: String {
        if !loaded { return "Checking the rack…" }
        if !bad { return "All good" }
        var parts: [String] = []
        if faults.nodes > 0 {
            parts.append("\(faults.nodes) machine\(faults.nodes == 1 ? "" : "s") unreachable")
        }
        if faults.services > 0 {
            parts.append("\(faults.services) service\(faults.services == 1 ? "" : "s") down")
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        DeckAlert(state.deck, message: message)
            // One element: VoiceOver should read the verdict, not the dot and
            // the sentence as two separate stops.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Rack status")
            .accessibilityValue(message)
    }
}
