import SwiftUI

/// Rack Control's own spacing and type roles, on top of Deck Cream.
///
/// EVERY COLOUR IS A `Deck.*` TOKEN, used directly at the call site. This file
/// used to hold the app's own palette - a port of the old web dashboard's
/// near-neutral ramp and blue accent - and both apps have since moved to the
/// shared Rack OS system (rack-os-design), so a second palette here would only
/// be something to drift from it. What stays is what only this app decides:
/// the spacing steps, which Deck face a reading is set in, and the three
/// states a rack tile can be in.
enum Theme {

    // MARK: - spacing
    //
    // Named rather than inlined so a gap and a padding that are meant to match
    // cannot drift by a point.

    static let sp1: CGFloat = 4
    static let sp2: CGFloat = 8
    static let sp3: CGFloat = 12
    static let sp4: CGFloat = 16
    static let sp5: CGFloat = 20
    static let sp6: CGFloat = 24

    // MARK: - type
    //
    // Deck faces only, each relative to a text style so Dynamic Type scales
    // it. Space Grotesk says what a thing IS; IBM Plex Mono is the reading.

    /// A row's name - a service, a file, a merchant.
    static let rowTitle = Deck.sans(15, .medium, relativeTo: .body)
    /// The data under or beside it - a size, a date, an uptime.
    static let rowMeta = Deck.mono(12, .regular, relativeTo: .footnote)
    /// A money figure or reading that is the point of its row.
    static let figure = Deck.mono(20, .semibold, relativeTo: .title3)
    /// The one number a screen exists to show (the balance).
    static let headline = Deck.mono(34, .semibold, relativeTo: .largeTitle)
    /// The second tier: a pay amount, a pool, a monthly cost.
    static let subhead = Deck.mono(26, .semibold, relativeTo: .title)
}

extension View {
    /// The Deck card with the padding every rack card uses - what
    /// `.glassCard()` was before the restyle.
    func rackCard(padding: CGFloat = Theme.sp4) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .deckCard()
    }

    /// The section eyebrow: Deck's mono uppercase label.
    func eyebrow() -> some View { deckLabel() }
}

// MARK: - status

/// The three states a tile can be in, and the ONE place that decides what each
/// one looks like.
///
/// THREE, NOT TWO. "idle" - not deployed, Docker unreachable, unit not
/// installed - used to fall through to the healthy fill, so the app claimed a
/// service was fine precisely when the hub had told it nothing was known.
enum RackState {
    case up, down, unknown

    /// Shape as well as hue - ● up, ■ down, ○ unknown. Red/green is the one
    /// pairing most colour-blind readers cannot separate, and it was carrying
    /// the whole up/down signal on its own.
    var deck: DeckStatus {
        switch self {
        case .up: .ok
        case .down: .crit
        case .unknown: .idle
        }
    }

    /// The same state as TEXT colour - the `-ink` twins, which clear 4.5:1.
    var text: Color {
        switch self {
        case .up: Deck.okInk
        case .down: Deck.critInk
        case .unknown: Deck.muted
        }
    }
}

/// `.pill` - a dot and a word, as a Deck chip.
struct StatusPill: View {
    let state: RackState
    let text: String

    var body: some View {
        DeckChip(text, kind: kind, status: state.deck)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
    }

    private var kind: DeckChip.Kind {
        switch state {
        case .up: .ok
        case .down: .crit
        case .unknown: .plain
        }
    }
}

struct StatusDot: View {
    let state: RackState
    var size: CGFloat = 8

    var body: some View { DeckDot(state.deck, size: size) }
}

/// The meter under a CPU/RAM/disk reading. A number alone makes "68%" and "8%"
/// look alike at a glance; the bar is what makes a full disk visible without
/// reading.
struct Meter: View {
    /// 0-100, as the hub reports it.
    let percent: Double

    /// Warn amber from 75, crit red from 90 - the fill changes AND the bar is
    /// visibly longer, so the colour is never the only signal.
    private var fill: Color {
        percent >= 90 ? Deck.crit : percent >= 75 ? Deck.warn : Deck.accent
    }

    var body: some View {
        DeckMeter(fraction: min(max(percent, 0), 100) / 100, fill: fill, height: 10)
            .accessibilityHidden(true)  // the number beside it already says this
    }
}
