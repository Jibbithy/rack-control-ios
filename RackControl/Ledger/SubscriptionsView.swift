import SwiftUI

/// Confirmed recurring charges, and the hub's unconfirmed guesses about new
/// ones - see hub/recurring.js for how each list is built. This tab is the
/// only place in the app that writes anything besides logging in: confirming
/// or dismissing a candidate, or removing a confirmed subscription, all go
/// through LedgerStore (which re-fetches the shared summary afterward), so a
/// guess never sits in local state disagreeing with what the hub decided.
struct SubscriptionsView: View {
    @Environment(LedgerStore.self) private var store
    @State private var detail: SubscriptionDetail?
    @State private var actionError: LedgerError?

    var body: some View {
        Group {
            if let s = store.summary {
                // STILL A List: the candidate rows' swipe actions come from it.
                // Only its chrome is Deck (see deckList / deckListRow).
                List {
                    Section {
                        ConfirmedSection(items: s.subscriptions.confirmed) { detail = .confirmed($0) }
                    } header: {
                        DeckListHeader("Confirmed")
                    }
                    Section {
                        CandidatesSection(
                            items: s.subscriptions.candidates,
                            onTap: { detail = .candidate($0) },
                            onConfirm: { confirm($0) },
                            onDismiss: { dismiss($0) }
                        )
                    } header: {
                        DeckListHeader("Might be subscriptions")
                    }
                }
                .deckList()
            } else if store.loading {
                DeckLoading()
            } else if let e = store.fatal {
                LedgerFailure(error: e)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Deck.ground)
        .navigationTitle("Subscriptions")
        .refreshable { await store.refresh() }
        .sheet(item: $detail) { d in
            SubscriptionDetailSheet(detail: d, onError: { actionError = $0 })
                .deckSheet()
        }
        #if DEBUG
            .task {
                // `simctl` cannot tap a row, so the detail sheet would otherwise
                // be unreachable in the simulator.
                guard DemoMode.screen == .subDetail else { return }
                try? await Task.sleep(for: .milliseconds(900))
                if let c = store.summary?.subscriptions.candidates.first { detail = .candidate(c) }
            }
        #endif
        // One alert for every write path in this tab - the sheet's own
        // actions AND the candidate row's swipe actions - rather than a
        // separate alert per surface, since "the write failed" reads the
        // same regardless of which button triggered it.
        .alert(
            "Couldn't save that",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError?.localizedDescription ?? "")
        }
    }

    private func confirm(_ c: CandidateSubscription) {
        Task {
            do {
                try await store.confirmSubscription(merchant: c.merchant, amountCents: c.amount_cents, cadenceDays: defaultCadence(for: c.cadence_days))
            } catch let e as LedgerError { actionError = e } catch { actionError = .http(0, error.localizedDescription) }
        }
    }

    private func dismiss(_ c: CandidateSubscription) {
        Task {
            do { try await store.dismissSubscription(merchant: c.merchant) } catch let e as LedgerError { actionError = e } catch {
                actionError = .http(0, error.localizedDescription)
            }
        }
    }
}

/// Which detail sheet is open, and for what - a confirmed row or a
/// candidate. Kept as one enum rather than two separate `@State` optionals
/// so at most one sheet can ever be presented at a time.
private enum SubscriptionDetail: Identifiable {
    case confirmed(ConfirmedSubscription)
    case candidate(CandidateSubscription)

    var id: String {
        switch self {
        case .confirmed(let c): "confirmed-\(c.merchant)"
        case .candidate(let c): "candidate-\(c.merchant)"
        }
    }
}

/// The cadences a person can assert when confirming. Mirrors cadencePicker()
/// in web/app.js so the phone and the browser offer the same choices. `nil`
/// is "Not sure", which stores no cadence and therefore shows no monthly cost.
///
/// This exists because detection cannot supply one: every mcc-basis candidate
/// has been seen exactly once, so its cadence_days is always null. Without a
/// way to say "monthly", confirming such a candidate could never produce a
/// monthly figure. The rule was always that WE must not invent a cadence --
/// one the user states is not invented.
let cadenceChoices: [(label: String, days: Int?)] = [
    ("Weekly", 7), ("Every 2 weeks", 14), ("Monthly", 30),
    ("Quarterly", 91), ("Yearly", 365), ("Not sure", nil),
]

/// What the picker starts on: the detected cadence when there is one, and
/// monthly otherwise, because monthly is what almost every subscription is.
func defaultCadence(for detected: Int?) -> Int? { detected ?? 30 }

// --- Confirmed ---

private struct ConfirmedSection: View {
    let items: [ConfirmedSubscription]
    let onTap: (ConfirmedSubscription) -> Void

    var body: some View {
        if items.isEmpty {
            Text("Nothing confirmed yet — confirm a candidate below.")
                .font(Deck.body)
                .foregroundStyle(Deck.muted)
                .deckListRow(separator: false, last: true)
        } else {
            ConfirmedTotalRow(items: items)
                .deckListRow(separator: false)
            ForEach(items) { item in
                Button {
                    onTap(item)
                } label: {
                    ConfirmedRow(item: item)
                }
                .buttonStyle(.plain)
                .deckListRow(last: item.id == items.last?.id)
            }
        }
    }
}

/// The "$X/mo" total called for at the top of the Confirmed section. Split
/// into a real total (summed from `monthly_cents`) and an "assumed" total
/// (the raw charge amount for anything whose cadence isn't known) rather
/// than blending them into one number - adding an assumed figure into the
/// real total would print a monthly cost the hub never actually computed.
private struct ConfirmedTotalRow: View {
    let items: [ConfirmedSubscription]

    private var real: Int { items.compactMap(\.monthly_cents).reduce(0, +) }
    private var assumed: Int { items.filter { $0.monthly_cents == nil }.reduce(0) { $0 + $1.amount_cents } }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(formatCents(real))/mo")
                .font(Theme.subhead)
                .foregroundStyle(Deck.ink)
            if assumed > 0 {
                Text("+ \(formatCents(assumed)) assumed monthly")
                    .font(Deck.small)
                    .foregroundStyle(Deck.muted)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ConfirmedRow: View {
    let item: ConfirmedSubscription

    var body: some View {
        HStack {
            Text(item.display)
                .font(Theme.rowTitle)
                .foregroundStyle(Deck.ink)
            Spacer()
            if let m = item.monthly_cents {
                Text("\(formatCents(m))/mo")
                    .font(Deck.mono(14, .semibold))
                    .foregroundStyle(Deck.ink)
            } else {
                // See ConfirmedSubscription's doc comment - null cadence
                // means the hub refused to compute a monthly figure, so this
                // shows the one known charge amount instead, visibly softer
                // so it never reads as a real monthly cost.
                AssumedAmount(text: "\(formatCents(item.amount_cents)) (assumed monthly)")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// --- Candidates ---

private struct CandidatesSection: View {
    let items: [CandidateSubscription]
    let onTap: (CandidateSubscription) -> Void
    let onConfirm: (CandidateSubscription) -> Void
    let onDismiss: (CandidateSubscription) -> Void

    var body: some View {
        if items.isEmpty {
            Text("Nothing waiting — detection watches new transactions for repeating charges and subscription-flavored merchant categories.")
                .font(Deck.body)
                .foregroundStyle(Deck.muted)
                .deckListRow(separator: false, last: true)
        } else {
            ForEach(items) { item in
                Button {
                    onTap(item)
                } label: {
                    CandidateRow(item: item)
                }
                .buttonStyle(.plain)
                .deckListRow(
                    separator: item.id != items.first?.id,
                    last: item.id == items.last?.id
                )
                .swipeActions(edge: .trailing) {
                    Button("Dismiss", role: .destructive) { onDismiss(item) }
                    // Named for what it does: the swipe has nowhere to
                    // put a picker, so it commits the default rather than
                    // quietly storing "no cadence". Tap the row instead to
                    // choose a different one.
                    Button(item.cadence_days == nil ? "Confirm monthly" : "Confirm") { onConfirm(item) }.tint(Deck.ok)
                }
            }
        }
    }
}

private struct CandidateRow: View {
    let item: CandidateSubscription

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.display)
                    .font(Theme.rowTitle)
                    .foregroundStyle(Deck.ink)
                Spacer()
                if item.cadence_days == nil {
                    AssumedAmount(text: "\(formatCents(item.amount_cents)) (assumed monthly)")
                } else {
                    Text(formatCents(item.amount_cents))
                        .font(Deck.mono(14, .semibold))
                        .foregroundStyle(Deck.ink)
                }
            }
            Text(basisSummary(item))
                .font(Theme.rowMeta)
                .foregroundStyle(Deck.muted)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// "seen 3 times, every ~30 days" for a pattern candidate, or "looks like a
/// subscription by merchant category" for an mcc one - the user is being
/// asked to confirm a guess, so this says what the guess is BASED ON, per
/// spec, rather than just repeating the amount already shown next to it.
private func basisSummary(_ c: CandidateSubscription) -> String {
    switch c.basis {
    case "pattern":
        let times = "\(c.occurrences) time\(c.occurrences == 1 ? "" : "s")"
        if let days = c.cadence_days { return "seen \(times), every ~\(days) days" }
        return "seen \(times)"
    case "mcc":
        return "looks like a subscription by merchant category"
    default:
        return c.basis
    }
}

/// An amount the hub did NOT compute as monthly - shown softer and in italics
/// so it never reads as a real monthly cost.
private struct AssumedAmount: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Deck.mono(13, .regular))
            .italic()
            .foregroundStyle(Deck.muted)
            .multilineTextAlignment(.trailing)
    }
}

// --- Detail sheet ---

/// One detail view for either a confirmed row or a candidate - the fields
/// spec calls out (cadence, amount, first/last seen, count, every charge)
/// are identical between the two; only the action buttons at the bottom
/// differ (Confirm/Dismiss vs. Remove).
private struct SubscriptionDetailSheet: View {
    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismissSheet
    let detail: SubscriptionDetail
    let onError: (LedgerError) -> Void
    @State private var working = false
    /// Seeded in .onAppear from the candidate, so the sheet opens on the
    /// detected cadence when there is one and on monthly when there is not.
    @State private var pickedCadence: Int? = 30

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.sp5) {
                    DeckTileGroup {
                        LabeledContent("Cadence", value: cadenceText)
                        LabeledContent("Charge amount", value: formatCents(amountCents))
                        if let m = monthlyCents {
                            LabeledContent("Monthly", value: "\(formatCents(m))/mo")
                        } else {
                            LabeledContent("Monthly") {
                                Text("\(formatCents(amountCents))/mo assumed")
                                    .italic()
                            }
                        }
                        LabeledContent("First seen", value: firstOn.map(formatShortDate) ?? "—")
                        LabeledContent("Last seen", value: lastOn.map(formatShortDate) ?? "—")
                        LabeledContent("Charges", value: "\(count)")
                        if case .candidate(let c) = detail {
                            LabeledContent("Detected by", value: basisSummary(c))
                        }
                    }
                    .labeledContentStyle(DeckLabeledContentStyle())

                    DeckFormSection(title: "Every charge") {
                        ForEach(Array(charges.enumerated()), id: \.offset) { _, ch in
                            LabeledContent(formatShortDate(ch.posted_on), value: formatCents(ch.amount_cents))
                        }
                    }
                    .labeledContentStyle(DeckLabeledContentStyle())

                    switch detail {
                    case .candidate(let c):
                        VStack(alignment: .leading, spacing: Theme.sp3) {
                            DeckTileGroup {
                                PickerRow(title: "How often") {
                                    Picker("How often", selection: $pickedCadence) {
                                        ForEach(cadenceChoices, id: \.label) { choice in
                                            Text(choice.label).tag(choice.days)
                                        }
                                    }
                                }
                            }
                            HStack(spacing: Theme.sp3) {
                                Button("Confirm") {
                                    run { try await store.confirmSubscription(merchant: c.merchant, amountCents: c.amount_cents, cadenceDays: pickedCadence) }
                                }
                                .buttonStyle(.deckPrimary)
                                Button("Dismiss", role: .destructive) {
                                    run { try await store.dismissSubscription(merchant: c.merchant) }
                                }
                                .buttonStyle(.deckDanger)
                            }
                        }
                        .disabled(working)
                    case .confirmed(let c):
                        Button("Remove", role: .destructive) {
                            run { try await store.removeSubscription(merchant: c.merchant) }
                        }
                        .buttonStyle(.deckDanger)
                        .disabled(working)
                    }
                }
                .padding(Theme.sp4)
            }
            .background(Deck.ground)
            .navigationTitle(displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismissSheet() }
                        .buttonStyle(DeckButtonStyle(.ghost, small: true))
                }
            }
            .overlay { if working { DeckLoading() } }
            .onAppear { pickedCadence = defaultCadence(for: cadenceDaysValue) }
        }
    }

    /// Runs a write, closing the sheet on success and handing any failure
    /// back up to the tab's own alert rather than showing a second one here.
    private func run(_ body: @escaping () async throws -> Void) {
        working = true
        Task {
            do {
                try await body()
                working = false
                dismissSheet()
            } catch let e as LedgerError {
                working = false
                onError(e)
            } catch {
                working = false
                onError(.http(0, error.localizedDescription))
            }
        }
    }

    private var displayName: String {
        switch detail {
        case .confirmed(let c): c.display
        case .candidate(let c): c.display
        }
    }
    private var amountCents: Int {
        switch detail {
        case .confirmed(let c): c.amount_cents
        case .candidate(let c): c.amount_cents
        }
    }
    /// Only a confirmed row ever carries `monthly_cents` - see
    /// CandidateSubscription's doc comment for why the server never sends
    /// one for a candidate.
    private var monthlyCents: Int? {
        switch detail {
        case .confirmed(let c): c.monthly_cents
        case .candidate: nil
        }
    }
    private var cadenceDaysValue: Int? {
        switch detail {
        case .confirmed(let c): c.cadence_days
        case .candidate(let c): c.cadence_days
        }
    }
    private var firstOn: String? {
        switch detail {
        case .confirmed(let c): c.first_on
        case .candidate(let c): c.first_on
        }
    }
    private var lastOn: String? {
        switch detail {
        case .confirmed(let c): c.last_on
        case .candidate(let c): c.last_on
        }
    }
    private var count: Int {
        switch detail {
        case .confirmed(let c): c.count
        case .candidate(let c): c.count
        }
    }
    private var charges: [Charge] {
        switch detail {
        case .confirmed(let c): c.charges
        case .candidate(let c): c.charges
        }
    }
    private var cadenceText: String {
        guard let d = cadenceDaysValue else { return "unknown — a single charge doesn't establish one" }
        return "every \(d) day\(d == 1 ? "" : "s")"
    }
}
