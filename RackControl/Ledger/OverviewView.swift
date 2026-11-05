import SwiftUI

/// The balance, forecast, and subscription-detection placeholders, plus the
/// unparsed-mail banner and Sign Out. Everything here answers one question -
/// "where does my money stand right now" - which is why it's the tab the app
/// opens on.
struct OverviewView: View {
    var onSignOut: () -> Void
    @Environment(LedgerStore.self) private var store
    @State private var editingPay = false
    #if DEBUG
        @State private var demoPush = DemoMode.moneyPush
    #endif

    var body: some View {
        NavigationStack {
            Group {
                if let s = store.summary {
                    // A ScrollView of Deck sections rather than a grouped List:
                    // nothing here swipes, and the inset-grouped card is a
                    // rounded system surface that cannot be squared off.
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.sp5) {
                            if s.unparsed > 0 {
                                DeckAlert(.warn, message: "\(s.unparsed) email\(s.unparsed == 1 ? "" : "s") could not be read")
                            }
                            DeckFormSection(title: "Balance") {
                                // The combined figure first, then the accounts
                                // behind it. "What do I have" is the question, and
                                // until the balance-summary parser existed it could
                                // not be answered - only checking had ever reported.
                                if let totals = s.totals, totals.accounts_known > 0 {
                                    TotalCard(totals: totals, nowMs: s.now)
                                }
                                BalanceCard(accounts: s.accounts, nowMs: s.now)
                                PollRow(poll: s.poll, nowMs: s.now)
                            }
                            DeckFormSection(title: "Next paycheck") { PayCard(pay: s.pay) }
                            DeckFormSection(title: "Goal") { GoalCard(goals: s.goals) }
                            DeckFormSection(title: "Subscriptions") {
                                SubscriptionsCard(subscriptions: s.subscriptions)
                            }
                            // The four screens that used to be tabs (Goals joins
                            // them here, same reasoning as the other three: "exist
                            // to be drilled into, never to be the first thing on
                            // screen" once six tabs stopped fitting).
                            DeckTileGroup {
                                NavigationLink {
                                    SpendingView()
                                } label: {
                                    LinkRow(title: "Spending", systemImage: "chart.bar")
                                }
                                NavigationLink {
                                    SubscriptionsView()
                                } label: {
                                    LinkRow(title: "Subscriptions", systemImage: "arrow.triangle.2.circlepath")
                                }
                                NavigationLink {
                                    ActivityView()
                                } label: {
                                    LinkRow(title: "Activity", systemImage: "list.bullet")
                                }
                                NavigationLink {
                                    GoalsView()
                                } label: {
                                    LinkRow(title: "Goals", systemImage: "target")
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(Theme.sp4)
                    }
                } else if store.loading {
                    DeckLoading()
                } else if let e = store.fatal {
                    LedgerFailure(error: e)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Deck.ground)
            .navigationTitle("Ledger")
            .refreshable { await store.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // Pay is the only thing left to edit from here - goal
                    // editing moved to GoalsView, pushed from the section
                    // above, so this button no longer needs to say which half
                    // it opens on.
                    Button("Edit", systemImage: "slider.horizontal.3") { editingPay = true }
                        .labelStyle(.iconOnly)
                        .buttonStyle(DeckIconButtonStyle(side: 34))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sign Out") {
                        Task {
                            await LedgerClient.shared.logout()
                            onSignOut()
                        }
                    }
                    .buttonStyle(DeckButtonStyle(small: true))
                }
            }
            .sheet(isPresented: $editingPay) {
                SettingsSheet().environment(store).deckSheet()
            }
            #if DEBUG
                .navigationDestination(isPresented: $demoPush) { DemoMode.moneyDestination() }
                .task {
                    guard DemoMode.screen == .paycheck else { return }
                    try? await Task.sleep(for: .milliseconds(600))
                    editingPay = true
                }
            #endif
        }
    }
}

/// One of the four pushed screens, as a Deck row: accent-ink glyph, bold
/// title, chevron. A `Label` inside, so VoiceOver reads only the title.
private struct LinkRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
                .labelStyle(DeckRowLabelStyle())
            Spacer()
            DeckChevron()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// "Can't load Ledger" - the one failure every Money screen shows the same
/// way, so it is written once.
struct LedgerFailure: View {
    let error: LedgerError

    var body: some View {
        DeckAlert(.crit, title: "Can't load Ledger", message: error.localizedDescription)
            .padding(Theme.sp4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The padding every row inside a DeckFormSection gets, so a card's content
/// sits the same distance from the tile's edge as a LabeledContent row does.
extension View {
    fileprivate func sectionRow() -> some View {
        self
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A money figure's STALE flag: a warn chip, so staleness is carried by a
/// word and a shape (◆) and never by the amber alone.
private struct StaleChip: View {
    var body: some View {
        DeckChip("Stale", kind: .warn, status: .warn)
    }
}

// --- Mailbox poll ---

/// Sits under the balance because that is the number it explains. A poller
/// that silently stopped is indistinguishable from a month with no charges,
/// so "checked 4 minutes ago" is what makes the balance trustworthy rather
/// than merely present. Renders nothing at all when the hub reports no
/// poller, so an older hub simply looks the way it always did.
private struct PollRow: View {
    let poll: Poll?
    let nowMs: Double

    var body: some View {
        if let p = poll {
            if !p.enabled {
                label("Automatic checking is off — ingest is manual.", bad: false)
            } else if let err = p.lastError {
                label("Last mailbox check failed: \(err)", bad: true)
            } else if let at = p.lastRunAt {
                label("Mailbox checked \(relativeMinutes(nowMs - at)).", bad: false)
            } else {
                label("Mailbox has not been checked yet.", bad: false)
            }
        }
    }

    @ViewBuilder
    private func label(_ text: String, bad: Bool) -> some View {
        Group {
            if bad { DeckErrorText(text) } else { DeckHint(text) }
        }
        .sectionRow()
    }
}

// --- Balance ---

/// The money across every account.
///
/// Dated by its STALEST part (see hub/queries.js's balanceTotals): a total is
/// only as current as the oldest balance inside it, and showing the newest date
/// would make a month-old savings figure look refreshed this morning. It also
/// says when some account has never reported at all - a sum over two of three
/// accounts looks exactly like a sum over three.
private struct TotalCard: View {
    let totals: Totals
    let nowMs: Double

    var body: some View {
        let days = totals.as_of.flatMap { daysBetween($0, nowMs: nowMs) }
        let stale = (days ?? 0) > staleDays
        VStack(alignment: .leading, spacing: 6) {
            Text(formatCents(totals.balance_cents))
                .font(Theme.headline)
                .foregroundStyle(stale ? Deck.warnInk : Deck.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption(days))
                .font(Deck.small)
                .foregroundStyle(stale ? Deck.warnInk : Deck.muted)
                .fixedSize(horizontal: false, vertical: true)
            if stale { StaleChip() }
        }
        .sectionRow()
    }

    private func caption(_ days: Int?) -> String {
        var parts = ["across \(totals.accounts_known) account\(totals.accounts_known == 1 ? "" : "s")"]
        if totals.accounts_known < totals.accounts_total {
            let missing = totals.accounts_total - totals.accounts_known
            parts.append("\(missing) more \(missing == 1 ? "has" : "have") never reported")
        }
        if let on = totals.as_of, let days {
            parts.append("as of \(formatShortDate(on)) · \(relativeDay(days))")
        }
        return parts.joined(separator: " · ")
    }
}

// --- Pay ---

/// The next paycheck - the ONLY figure on this screen the bank did not send.
/// Not one deposit alert has ever arrived, so it cannot be inferred; it is
/// stated by the owner and hub/pay.js does the calendar arithmetic. Labelled as
/// expected, never as received, so it can never be read as money that landed.
private struct PayCard: View {
    let pay: PayForecast?

    var body: some View {
        if let pay {
            VStack(alignment: .leading, spacing: 6) {
                Text(formatCents(pay.amount_cents))
                    .font(Theme.subhead)
                    .foregroundStyle(Deck.ink)
                HStack(spacing: 4) {
                    Text(formatDayName(pay.next_on)).font(Deck.sans(15, .bold))
                    Text("· \(when(pay.days_until))").font(Deck.sans(15, .medium))
                }
                .foregroundStyle(pay.days_until <= 1 ? Deck.okInk : Deck.muted)
                Text(
                    [pay.cadence_label, "expected, not yet received"]
                        .compactMap { $0 }.joined(separator: " · ")
                )
                .font(Deck.small).foregroundStyle(Deck.muted)
            }
            .sectionRow()
        } else {
            Text("No paycheck set up yet. No deposit alert has ever arrived, so this is something to tell Ledger rather than something it can work out.")
                .font(Deck.body)
                .foregroundStyle(Deck.muted)
                .sectionRow()
        }
    }

    private func when(_ days: Int) -> String {
        if days == 0 { return "today" }
        if days == 1 { return "tomorrow" }
        return "in \(days) days"
    }
}

// --- Goal ---

/// EVERY goal, in funding order - not a stand-in for one.
///
/// This started as a compact card naming only the first unreached goal, on the
/// reasoning that Overview is a glance. That was wrong for the way these are
/// actually read: the ranking IS the allocation, so seeing one goal tells you
/// nothing about whether the pool has reached the next one. The whole point of
/// the spill-down model is the relationship BETWEEN the goals, and a card
/// showing one of them hides exactly that.
///
/// It uses GoalsView's own `GoalRow`, so the two can never describe the same
/// goal differently. Adding, editing and reordering still live in GoalsView -
/// this is read-only, which is what keeps it a glance.
private struct GoalCard: View {
    let goals: [Goal]

    var body: some View {
        if goals.isEmpty {
            Text("No goals set. Add one and Ledger will track it against your savings.")
                .font(Deck.body)
                .foregroundStyle(Deck.muted)
                .sectionRow()
        } else {
            ForEach(goals) { GoalRow(goal: $0).sectionRow() }
        }
    }
}

private struct BalanceCard: View {
    let accounts: [Account]
    let nowMs: Double

    var body: some View {
        if accounts.isEmpty {
            Text("No accounts yet.")
                .font(Deck.body)
                .foregroundStyle(Deck.muted)
                .sectionRow()
        } else {
            ForEach(accounts) { acct in
                let label = acct.mask.map { "\(acct.name) ••\($0)" } ?? acct.name
                if let cents = acct.balance_cents, let on = acct.balance_on {
                    let days = daysBetween(on, nowMs: nowMs) ?? 0
                    let stale = days > staleDays
                    VStack(alignment: .leading, spacing: 4) {
                        Text(label).deckLabel()
                        Text(formatCents(cents))
                            // Smaller than the combined total above it: the
                            // total is the headline now, and two equally large
                            // numbers would compete for it.
                            .font(Theme.figure)
                            .foregroundStyle(stale ? Deck.warnInk : Deck.ink)
                        // Only a BALANCE SUMMARY carries this. Its absence is
                        // shown as absence, never as equality with the current
                        // balance - the gap is holds and pending charges.
                        if let available = acct.available_cents, available != cents {
                            Text("\(formatCents(available)) available")
                                .font(Deck.small).foregroundStyle(Deck.muted)
                        }
                        HStack(spacing: 8) {
                            Text("as of \(formatShortDate(on)) · \(relativeDay(days))")
                                .font(Deck.small)
                                .foregroundStyle(stale ? Deck.warnInk : Deck.muted)
                            // A stale balance shown as though it were current is
                            // the one way this screen can lie about money - see
                            // the spec. The badge exists so staleness can never
                            // be missed by scanning color alone.
                            if stale { StaleChip() }
                        }
                    }
                    .sectionRow()
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(label).deckLabel()
                        Text("Balance unknown")
                            .font(Deck.sans(17, .bold, relativeTo: .headline))
                            .foregroundStyle(Deck.ink)
                        Text("no balance has been reported yet")
                            .font(Deck.small).foregroundStyle(Deck.muted)
                    }
                    .sectionRow()
                }
            }
        }
    }
}

// --- Subscriptions ---
//
// A one-line pointer to the Subscriptions tab, not a second copy of what
// that tab already shows in full - this card's whole job is to make the
// balance screen say "there's something to look at over there" the same way
// the unparsed-mail banner does.

private struct SubscriptionsCard: View {
    let subscriptions: Subscriptions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Entries with no known cadence are EXCLUDED from the total and
            // counted separately: the hub refuses to invent a cadence for a
            // merchant seen once, and folding those in as zero would present
            // an under-count as a total.
            if let monthly = subscriptions.monthly_total_cents,
                let known = subscriptions.monthly_known, known > 0
            {
                Text("\(formatCents(monthly)) / mo")
                    .font(Theme.subhead)
                    .foregroundStyle(Deck.ink)
                Text(costCaption(known: known, unknown: subscriptions.monthly_unknown ?? 0))
                    .font(Deck.small).foregroundStyle(Deck.muted)
            }
            Text(text).font(Deck.body).foregroundStyle(Deck.muted)
        }
        .sectionRow()
    }

    private func costCaption(known: Int, unknown: Int) -> String {
        var parts = ["\(known) subscription\(known == 1 ? "" : "s")"]
        if unknown > 0 { parts.append("\(unknown) more with no known cadence, not counted") }
        return parts.joined(separator: " · ")
    }

    private var text: String {
        let confirmed = subscriptions.confirmed.count
        let candidates = subscriptions.candidates.count
        if confirmed == 0 && candidates == 0 {
            return "No subscriptions confirmed or detected yet."
        }
        var parts: [String] = []
        if confirmed > 0 { parts.append("\(confirmed) confirmed") }
        if candidates > 0 { parts.append("\(candidates) to review") }
        return "\(parts.joined(separator: ", ")) — see the Subscriptions tab."
    }
}
