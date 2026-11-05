import SwiftUI

/// The full transaction list, newest first - the hub's own order, kept as-is
/// rather than re-sorted here so this tab can never disagree with what the
/// hub considers "recent".
struct ActivityView: View {
    @Environment(LedgerStore.self) private var store

    var body: some View {
        Group {
            if let s = store.summary {
                List {
                    Section {
                        TransactionsCard(transactions: s.transactions)
                    } header: {
                        DeckListHeader("Transactions")
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
        .navigationTitle("Activity")
        .refreshable { await store.refresh() }
    }
}

private struct TransactionsCard: View {
    let transactions: [Transaction]
    var body: some View {
        if transactions.isEmpty {
            Text("No transactions yet.")
                .font(Deck.body)
                .foregroundStyle(Deck.muted)
                .deckListRow(separator: false, last: true)
        } else {
            ForEach(Array(transactions.enumerated()), id: \.element.id) { i, t in
                let credit = t.direction == "credit"
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.label)
                            .font(Theme.rowTitle)
                            .foregroundStyle(Deck.ink)
                        Text("\(formatShortDate(t.posted_on)) · \(t.category)")
                            .font(Theme.rowMeta)
                            .foregroundStyle(Deck.muted)
                    }
                    Spacer()
                    // The sign is the signal (+ in, − out); the green only
                    // repeats it.
                    Text("\(credit ? "+" : "\u{2212}")\(formatCents(t.amount_cents))")
                        .font(Deck.mono(15, .semibold))
                        .foregroundStyle(credit ? Deck.okInk : Deck.ink)
                }
                .deckListRow(separator: i > 0, last: i == transactions.count - 1)
            }
        }
    }
}
