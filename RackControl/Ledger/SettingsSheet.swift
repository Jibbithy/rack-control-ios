import SwiftUI

/// The edit sheet for the one fact left that the bank never sends: the pay
/// schedule. The savings goal used to live here too, as a single row; it is
/// now a ranked LIST with its own screen (GoalsView) and its own
/// `/api/goals/*` routes, so it no longer belongs in a form whose whole
/// contract is "one merge, one save" - see LedgerModels.swift's
/// SettingsPayload doc comment.
///
/// It reads GET /api/settings rather than pulling the value out of the summary
/// already on screen. The summary carries pay ALREADY resolved against today
/// (next_on, days_until) - editing a derived view of a value instead of the
/// value itself is how a form starts writing back its own output.
struct SettingsSheet: View {
    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var loaded: SettingsPayload?
    @State private var loadError: String?
    @State private var saving = false
    @State private var saveError: String?

    @State private var payAmount = ""
    @State private var payCadence = 7
    @State private var payAnchor = Date()
    @State private var payAnchorSet = false

    var body: some View {
        NavigationStack {
            Group {
                if let loaded {
                    form(loaded)
                } else if let loadError {
                    DeckAlert(.crit, title: "Can't open settings", message: loadError)
                        .padding(Theme.sp4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    DeckLoading()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Deck.ground)
            .navigationTitle("Paycheck")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                        .buttonStyle(DeckButtonStyle(.ghost, small: true))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving || loaded == nil)
                        .buttonStyle(DeckButtonStyle(.primary, small: true))
                }
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private func form(_ payload: SettingsPayload) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sp3) {
                DeckFormSection(title: "Paycheck") {
                    LabeledContent("Amount") {
                        TextField(
                            "0.00", text: $payAmount,
                            prompt: Text(verbatim: "0.00").foregroundStyle(Deck.muted)
                        )
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(DeckFieldStyle(mono: true))
                        .frame(maxWidth: 170)
                    }
                    .labeledContentStyle(DeckLabeledContentStyle(combine: false))
                    // Built from the SERVER's list, never a hardcoded one: an
                    // option the hub would then refuse is a form that can only fail.
                    PickerRow(title: "How often") {
                        Picker("How often", selection: $payCadence) {
                            ForEach(payload.cadences) { c in Text(c.label).tag(c.days) }
                        }
                    }
                    Toggle("Set a payday", isOn: $payAnchorSet)
                        .toggleStyle(DeckToggleStyle())
                        .padding(.horizontal, 14).padding(.vertical, 4)
                    if payAnchorSet {
                        DeckDateField(title: "A day you were paid", selection: $payAnchor)
                            // The bound Date is UTC midnight (dateFromISO), so the
                            // picker must read it in UTC too - in local time west of
                            // Greenwich it showed the day BEFORE the saved payday.
                            .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                    }
                }
                DeckHint("Every future payday is counted from that one. Leave the amount and payday empty to remove the schedule.")
                    .padding(.horizontal, 2)

                if let saveError {
                    DeckErrorText(saveError)
                }
            }
            .padding(Theme.sp4)
        }
        .scrollDismissesKeyboard(.interactively)
        .disabled(saving)
    }

    private func load() async {
        do {
            let payload = try await store.loadSettings()
            payAmount = centsToInput(payload.pay?.amount_cents)
            // Falls back to the first cadence the SERVER offers rather than a
            // literal 7 - the two lists must not be able to drift apart.
            payCadence = payload.pay?.cadence_days ?? payload.cadences.first?.days ?? 7
            if let anchor = dateFromISO(payload.pay?.anchor_date) {
                payAnchor = anchor
                payAnchorSet = true
            }
            loaded = payload
        } catch {
            loadError = (error as? LedgerError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// All-or-nothing. A paycheck with an amount but no payday is not a
    /// half-saved paycheck, it is a mistake - saving it would put a payday on
    /// screen counted from nothing. Leaving everything blank is how the
    /// schedule gets deleted.
    private func save() async {
        saveError = nil

        var pay: PaySetting??
        if payAmount.trimmingCharacters(in: .whitespaces).isEmpty && !payAnchorSet {
            pay = .some(nil)  // an explicit clear
        } else {
            guard let cents = centsFromInput(payAmount), cents > 0 else {
                saveError = "Enter the paycheck amount, like 420.00."
                return
            }
            guard payAnchorSet else {
                saveError = "Pick a day you were actually paid."
                return
            }
            pay = .some(
                PaySetting(
                    amount_cents: cents, cadence_days: payCadence,
                    anchor_date: isoFromDate(payAnchor)))
        }

        saving = true
        defer { saving = false }
        do {
            try await store.saveSettings(pay: pay)
            dismiss()
        } catch {
            saveError = (error as? LedgerError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// A menu Picker as a Deck form row. The visible title is decoration for
/// VoiceOver, which reads the Picker's own label ("How often, Weekly") - the
/// same one stop the Form row was.
struct PickerRow<P: View>: View {
    let title: String
    @ViewBuilder let picker: P

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(Deck.sans(15, .medium))
                .foregroundStyle(Deck.ink)
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            picker
                .labelsHidden()
                .font(Deck.mono(14, .semibold, relativeTo: .subheadline))
                .tint(Deck.accentInk)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(minHeight: 44)
    }
}
