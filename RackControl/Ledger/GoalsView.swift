import SwiftUI

/// The full ranked list of savings goals - pushed from Overview's compact
/// card, the same way Spending/Subscriptions/Activity are. NO NavigationStack
/// of its own: this view is always reached via a push from OverviewView's
/// stack, and a nested stack here would break that push chain and stack two
/// title bars on screen at once (see SpendingView for the same rule).
///
/// There is ONE pool of money (`goal_funds`) behind every row here, spilled
/// down them in position order by the hub (hub/goals.js's `allocate`).
/// That is why
/// every mutation below - add, edit, remove, reorder - calls `store.refresh()`
/// rather than patching a row in place: changing ANY goal's target or rank
/// changes what every OTHER goal's `allocated_cents` and `progress` legitimately
/// are, and a local patch would have to reimplement the hub's own allocation
/// to stay honest. The one place that logic should live is the hub.
struct GoalsView: View {
    @Environment(LedgerStore.self) private var store
    @State private var sheetTarget: GoalSheetTarget?
    @State private var actionError: LedgerError?

    var body: some View {
        Group {
            if let s = store.summary {
                content(s)
            } else if store.loading {
                DeckLoading()
            } else if let e = store.fatal {
                LedgerFailure(error: e)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Deck.ground)
        .navigationTitle("Goals")
        .refreshable { await store.refresh() }
        .toolbar {
            // EditButton is what puts the List into edit mode, which is what
            // makes the ForEach's `.onMove` handles (and its delete circles)
            // appear - there is no reordering UI without it.
            ToolbarItem(placement: .topBarLeading) {
                EditButton().buttonStyle(DeckButtonStyle(small: true))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add", systemImage: "plus") { sheetTarget = .add }
                    .labelStyle(.iconOnly)
                    .buttonStyle(DeckIconButtonStyle(.primary, side: 34))
            }
        }
        .sheet(item: $sheetTarget) { target in
            GoalFormSheet(target: target).environment(store).deckSheet()
        }
        #if DEBUG
            .task {
                // `simctl` cannot tap a row, so the edit sheet would otherwise be
                // unreachable in the simulator. The goal with a deadline, so the
                // date picker shows too.
                guard DemoMode.screen == .goalEdit else { return }
                try? await Task.sleep(for: .milliseconds(900))
                if let goal = store.summary?.goals.first(where: { $0.target_date != nil }) {
                    sheetTarget = .edit(goal)
                }
            }
        #endif
        // One alert for every write path that happens OUTSIDE a sheet -
        // delete and reorder - same reasoning as SubscriptionsView's single
        // alert for its swipe actions. A failed add/edit shows its error
        // inline in GoalFormSheet instead, since that sheet is still open to
        // show it in.
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

    @ViewBuilder
    private func content(_ s: Summary) -> some View {
        // STILL A List, unlike the other Money screens: swipe-to-delete, the
        // EditButton's delete circles and drag-to-reorder all come from it.
        // Only its chrome is Deck (see deckList / deckListRow).
        List {
            if let funds = s.goal_funds {
                Section {
                    PoolCard(funds: funds, goals: s.goals)
                        .deckListRow(separator: false, last: true)
                } header: {
                    DeckListHeader("Pool")
                }
            }
            Section {
                if s.goals.isEmpty {
                    Text("No goals yet. Add one to start tracking it against your savings.")
                        .font(Deck.body)
                        .foregroundStyle(Deck.muted)
                        .deckListRow(separator: false, last: true)
                } else {
                    ForEach(s.goals) { goal in
                        Button {
                            sheetTarget = .edit(goal)
                        } label: {
                            GoalRow(goal: goal)
                        }
                        .buttonStyle(.plain)
                        .deckListRow(
                            separator: goal.id != s.goals.first?.id,
                            last: goal.id == s.goals.last?.id
                        )
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) { delete(goal) }
                        }
                    }
                    .onDelete { offsets in delete(s.goals, at: offsets) }
                    .onMove { source, destination in move(s.goals, from: source, to: destination) }
                }
            } header: {
                DeckListHeader("Goals")
            }
        }
        .deckList()
    }

    private func delete(_ goal: Goal) {
        Task {
            do { try await store.removeGoal(id: goal.id) } catch let e as LedgerError { actionError = e } catch {
                actionError = .http(0, error.localizedDescription)
            }
        }
    }

    private func delete(_ goals: [Goal], at offsets: IndexSet) {
        for goal in offsets.map({ goals[$0] }) { delete(goal) }
    }

    /// Builds the FULL new id order and sends that whole ordering, as
    /// `reorderGoals` requires - a partial or move-instruction API would let
    /// this and the hub disagree about which goals exist. If the hub rejects
    /// it (its own set of ids has moved on since this list was fetched - a
    /// goal added or removed from elsewhere in the meantime), the write
    /// throws, this shows the same alert as a failed delete, and the refresh
    /// below restores whatever order the hub actually has - the dragged
    /// order was never real without the hub's agreement.
    private func move(_ goals: [Goal], from source: IndexSet, to destination: Int) {
        var ids = goals.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        Task {
            do { try await store.reorderGoals(ids: ids) } catch let e as LedgerError {
                actionError = e
                await store.refresh()
            } catch {
                actionError = .http(0, error.localizedDescription)
                await store.refresh()
            }
        }
    }
}

// --- The pool ---
//
// Every bar below draws on this one number - that is the entire reason goals
// are ranked instead of each getting an independent bar. Shown here rather
// than only implied by the bars, so opening this screen answers "how much do
// I actually have" before "how far did it get split up".

private struct PoolCard: View {
    let funds: GoalFunds
    let goals: [Goal]

    private var allocated: Int { goals.reduce(0) { $0 + $1.allocated_cents } }
    private var unallocated: Int { max(0, funds.saved_cents - allocated) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(formatCents(funds.saved_cents))
                .font(Theme.subhead)
                .foregroundStyle(Deck.ink)
            Text(sourceCaption)
                .font(Deck.small).foregroundStyle(Deck.muted)
            if !goals.isEmpty {
                Text("\(formatCents(unallocated)) unallocated")
                    .font(Deck.small).foregroundStyle(Deck.muted)
            }
        }
        .padding(.vertical, 4)
    }

    private var sourceCaption: String {
        funds.source == "savings"
            ? "counting \(funds.accounts.joined(separator: ", "))"
            : "counting every account — no savings account has reported yet"
    }
}

// --- One goal ---

/// One goal's row. NOT private: OverviewView lists every goal with this same
/// row, so the glance and the full screen cannot drift into describing the same
/// goal two different ways.
struct GoalRow: View {
    let goal: Goal

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(goal.name)
                    .font(Deck.sans(16, .bold, relativeTo: .headline))
                    .foregroundStyle(Deck.ink)
                Spacer()
                Text("\(formatCents(goal.allocated_cents)) of \(formatCents(goal.target_cents))")
                    .font(Deck.mono(13, .medium, relativeTo: .subheadline))
                    .foregroundStyle(Deck.muted)
                    .multilineTextAlignment(.trailing)
            }
            // A meter in place of ProgressView, whose track is a rounded
            // capsule. Reached is the bar filling edge to edge, in ok green.
            DeckMeter(fraction: goal.progress, fill: goal.reached ? Deck.ok : Deck.accent, height: 12)
                .accessibilityElement()
                .accessibilityLabel("Progress")
                .accessibilityValue("\(Int((goal.progress * 100).rounded())) percent")
            // The deadline, when there is one, otherwise what is still short -
            // never both, there is only room in one caption line and the
            // deadline is the more useful fact once it exists.
            if let caption = deadlineCaption {
                Text(caption).font(Theme.rowMeta).foregroundStyle(Deck.muted)
            } else if !goal.reached {
                Text("\(formatCents(goal.remaining_cents)) to go")
                    .font(Theme.rowMeta).foregroundStyle(Deck.muted)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var deadlineCaption: String? {
        guard let on = goal.target_date, let left = goal.days_left else { return nil }
        return left >= 0
            ? "\(left) day\(left == 1 ? "" : "s") until \(formatShortDate(on))"
            : "target date \(formatShortDate(on)) has passed"
    }
}

// --- Add / edit sheet ---

/// Which sheet is open, and for what - a brand new goal or an existing one.
/// One enum rather than two optionals, same reasoning as SubscriptionsView's
/// SubscriptionDetail: at most one sheet can ever be presented at a time.
private enum GoalSheetTarget: Identifiable {
    case add
    case edit(Goal)

    var id: String {
        switch self {
        case .add: "add"
        case .edit(let g): "edit-\(g.id)"
        }
    }
}

/// One form for both add and edit - the fields are identical, and only which
/// LedgerStore call fires on Save differs. Mirrors SettingsSheet's goal
/// section (now removed from there) field-for-field, so a goal edited here
/// looks and behaves the way it always has.
private struct GoalFormSheet: View {
    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let target: GoalSheetTarget

    @State private var name = ""
    @State private var targetAmount = ""
    @State private var dateSet = false
    @State private var date = Date()
    @State private var saving = false
    @State private var formError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.sp3) {
                    DeckTileGroup {
                        TextField(
                            "What for", text: $name,
                            prompt: Text("What for").foregroundStyle(Deck.muted)
                        )
                        .textFieldStyle(DeckFieldStyle())
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        LabeledContent("Target") {
                            TextField(
                                "0.00", text: $targetAmount,
                                prompt: Text(verbatim: "0.00").foregroundStyle(Deck.muted)
                            )
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(DeckFieldStyle(mono: true))
                            .frame(maxWidth: 170)
                        }
                        .labeledContentStyle(DeckLabeledContentStyle(combine: false))
                        Toggle("Set a deadline", isOn: $dateSet)
                            .toggleStyle(DeckToggleStyle())
                            .padding(.horizontal, 14).padding(.vertical, 4)
                        if dateSet {
                            DeckDateField(title: "By when", selection: $date)
                                // UTC, to match dateFromISO - see SettingsSheet.
                                .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                        }
                    }
                    DeckHint("Progress is measured against your real savings balance, so it never needs updating by hand.")
                        .padding(.horizontal, 2)

                    if let formError {
                        DeckErrorText(formError)
                    }
                }
                .padding(Theme.sp4)
            }
            .background(Deck.ground)
            .navigationTitle(isEditing ? "Edit goal" : "New goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                        .buttonStyle(DeckButtonStyle(.ghost, small: true))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(saving)
                        .buttonStyle(DeckButtonStyle(.primary, small: true))
                }
            }
            .disabled(saving)
        }
        .onAppear(perform: seed)
    }

    private var isEditing: Bool {
        if case .edit = target { return true }
        return false
    }

    /// Pre-fills from the existing goal on edit; does nothing on add, leaving
    /// the fields at their empty defaults above.
    private func seed() {
        guard case .edit(let g) = target else { return }
        name = g.name
        targetAmount = centsToInput(g.target_cents)
        if let d = dateFromISO(g.target_date) {
            date = d
            dateSet = true
        }
    }

    /// Unlike SettingsSheet's pay/goal form, there is no "leave everything
    /// blank to delete" here - delete is its own explicit action on the list
    /// (swipe or edit-mode), never an accidental empty save.
    private func save() async {
        formError = nil
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            formError = "Give the goal a name."
            return
        }
        guard let cents = centsFromInput(targetAmount), cents > 0 else {
            formError = "Enter what you are saving toward, like 5000.00."
            return
        }
        let targetDate = dateSet ? isoFromDate(date) : nil

        saving = true
        defer { saving = false }
        do {
            switch target {
            case .add:
                try await store.addGoal(name: trimmed, targetCents: cents, targetDate: targetDate)
            case .edit(let g):
                try await store.updateGoal(id: g.id, name: trimmed, targetCents: cents, targetDate: targetDate)
            }
            dismiss()
        } catch let e as LedgerError {
            formError = e.errorDescription
        } catch {
            formError = error.localizedDescription
        }
    }
}
