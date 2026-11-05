import SwiftUI
import UIKit

// Rack Control's own Deck Cream pieces - everything this app needed that
// DeckCream.swift / DeckExtras.swift do not have yet.
//
// DeckCream.swift and DeckExtras.swift are COPIES of rack-os-design/ios and
// are never edited here (`node check.mjs --apps` fails on a hand-edited copy).
// Anything generally useful goes in THIS file instead, written against the
// Deck tokens only, and is a candidate to move up into rack-os-design.

// MARK: - System chrome (UINavigationBar, UITabBar)

/// The navigation and tab bars, in Deck terms: a rail strip with the 3px ink
/// edge facing the page, Space Grotesk titles, and an inverted ink block for
/// the selected tab - the same "selected = inverted" rule as DeckSegmented.
///
/// UIKIT APPEARANCE, NOT SwiftUI MODIFIERS, because the modifiers stop at
/// the background colour: `.toolbarBackground` cannot set a title font, the
/// edge under the bar, or anything about a tab item. Installed once, before
/// the first bar exists.
///
/// This only reads as Deck because the app opts out of Liquid Glass
/// (UIDesignRequiresCompatibility in project.yml). Under glass the tab bar is
/// a floating rounded capsule and every toolbar button sits in a glass pill,
/// and none of that is reachable from here.
enum DeckChrome {

    @MainActor
    static func install() {
        let ink = ui(Deck.ink)

        // --- navigation bar
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = ui(Deck.rail)
        // A template image is tinted with shadowColor, which is how the edge
        // gets to be 3pt thick AND follow the appearance: shadowColor on its
        // own is a one-pixel hairline.
        nav.shadowColor = ui(Deck.line)
        nav.shadowImage = edge(Deck.borderWidthLarge)
        nav.titleTextAttributes = [
            .font: font(Deck.SansWeight.bold.rawValue, 17, .headline),
            .foregroundColor: ink,
        ]
        nav.largeTitleTextAttributes = [
            .font: font(Deck.SansWeight.bold.rawValue, 32, .largeTitle),
            .foregroundColor: ink,
        ]
        let plain = UIBarButtonItemAppearance(style: .plain)
        plain.normal.titleTextAttributes = [.font: font(Deck.SansWeight.bold.rawValue, 15, .body)]
        nav.buttonAppearance = plain
        nav.backButtonAppearance = plain
        let done = UIBarButtonItemAppearance(style: .done)
        done.normal.titleTextAttributes = [.font: font(Deck.SansWeight.bold.rawValue, 15, .body)]
        nav.doneButtonAppearance = done

        let bar = UINavigationBar.appearance()
        bar.standardAppearance = nav
        bar.compactAppearance = nav
        bar.scrollEdgeAppearance = nav
        bar.compactScrollEdgeAppearance = nav
        // Any bar item left in its system style. In practice the SwiftUI
        // `.tint(Deck.accentInk)` at the root wins for the back button, which
        // is right: it reads as a link, in the accent that passes as text.
        bar.tintColor = ink

        // --- tab bar
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = ui(Deck.rail)
        tab.shadowColor = ui(Deck.line)
        tab.shadowImage = edge(Deck.borderWidthLarge)
        // A TEMPLATE block tinted by selectionIndicatorTintColor: the tint is a
        // dynamic colour, so the inverted fill flips with the appearance. (A
        // light/dark UIImageAsset here draws nothing at all.)

        // Fixed size: a tab bar does not grow with Dynamic Type (iOS shows the
        // large-content viewer on a long press instead), so a scaled font here
        // would only clip.
        let label = font(Deck.MonoWeight.semibold.rawValue, 10, nil)
        let item = UITabBarItemAppearance(style: .stacked)
        item.normal.iconColor = ui(Deck.muted)
        item.normal.titleTextAttributes = [.font: label, .foregroundColor: ui(Deck.muted)]
        item.selected.iconColor = ink
        item.selected.titleTextAttributes = [
            .font: label, .foregroundColor: ui(Deck.inkInverse),
            .backgroundColor: ink,
        ]
        tab.stackedLayoutAppearance = item
        tab.inlineLayoutAppearance = item
        tab.compactInlineLayoutAppearance = item

        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }

    // MARK: helpers

    /// A Deck token as a DYNAMIC UIColor, re-resolved per trait collection so
    /// a bar built once at launch still flips with the appearance.
    static func ui(_ color: Color) -> UIColor {
        UIColor { traits in
            var env = EnvironmentValues()
            env.colorScheme = traits.userInterfaceStyle == .dark ? .dark : .light
            return UIColor(cgColor: color.resolve(in: env).cgColor)
        }
    }

    /// A registered Deck face for UIKit, scaled by Dynamic Type relative to
    /// `style` (nil = fixed size).
    static func font(_ name: String, _ size: CGFloat, _ style: UIFont.TextStyle?) -> UIFont {
        let base = UIFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: .semibold)
        guard let style else { return base }
        return UIFontMetrics(forTextStyle: style).scaledFont(for: base)
    }

    /// A 1pt-wide strip `height` tall, as a template: the bar tints it.
    private static func edge(_ height: CGFloat) -> UIImage {
        let size = CGSize(width: 1, height: height)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            ui(Deck.line).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        .withRenderingMode(.alwaysTemplate)
    }

    /// A stretchable solid block, as a template - the tab bar tints it.
    private static func block() -> UIImage {
        let size = CGSize(width: 4, height: 4)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            ui(Deck.ink).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        .resizableImage(withCapInsets: .zero, resizingMode: .stretch)
        .withRenderingMode(.alwaysTemplate)
    }
}

// MARK: - Theme menu (DeckThemePicker for a toolbar)

/// Auto / Cream / Dark as a toolbar icon that opens a menu - DeckThemePicker
/// (DeckCream.swift) is a full-width strip and needs a settings screen, which
/// this app does not have. The icon shows the CURRENT choice; the menu rows
/// are the system's, with its checkmark on the selected one.
///
/// `onChangeToken` adds a "Change token" row under the themes. It rides in
/// this menu because it is the app's only settings-like control - there is no
/// settings screen to put it on.
struct DeckThemeMenu: View {
    var onChangeToken: (() -> Void)? = nil
    @AppStorage(DeckTheme.storageKey) private var theme: DeckTheme = .auto

    var body: some View {
        Menu {
            Picker(
                "Theme",
                selection: Binding(
                    get: { theme },
                    set: {
                        theme = $0
                        $0.apply()
                    })
            ) {
                ForEach(DeckTheme.allCases) { t in
                    Label(t.label, systemImage: t.systemImage).tag(t)
                }
            }
            if let onChangeToken {
                Section {
                    Button {
                        onChangeToken()
                    } label: {
                        Label("Change token", systemImage: "key")
                    }
                }
            }
        } label: {
            Image(systemName: theme.systemImage)
        }
        .menuStyle(.button)
        .buttonStyle(DeckIconButtonStyle(side: 34))
        .accessibilityLabel(onChangeToken == nil ? "Theme" : "Theme and hub token")
        .accessibilityValue(theme.label)
    }
}

// MARK: - Toggle (dk-check as a switch)

/// A Toggle drawn as a DeckCheck: the system switch is a rounded capsule that
/// cannot be squared off.
///
/// VoiceOver is given a REAL Toggle to read (accessibilityRepresentation), so
/// it still announces "switch button, on/off" exactly as the system one did -
/// the square is only the picture.
struct DeckToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 12) {
                configuration.label
                    .font(Deck.sans(15, .medium))
                    .foregroundStyle(isEnabled ? Deck.ink : Deck.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                DeckCheck(state: !isEnabled ? .unavailable : configuration.isOn ? .on : .off)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

// MARK: - Date field (the compact DatePicker without its grey pill)

/// A date as a Deck field - bordered, square, mono - over a REAL compact
/// DatePicker that still takes the tap, opens the system calendar and is what
/// VoiceOver reads ("By when, Oct 31, 2026"). The system control's rounded
/// grey pill is the only part replaced, and it is not reachable any other way.
///
/// The picker stays at 0.02 opacity rather than 0: UIKit drops views under
/// 0.01 from hit-testing and from the accessibility tree.
struct DeckDateField: View {
    let title: String
    @Binding var selection: Date
    /// The label is drawn by hand, so it must read the date in the SAME zone
    /// the picker does - the environment's, which a caller binding a UTC-midnight
    /// Date sets to UTC. `formatted()` alone uses the device zone and, west of
    /// Greenwich, printed the day BEFORE the one the picker held.
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(Deck.sans(15, .medium))
                .foregroundStyle(Deck.ink)
                .accessibilityHidden(true)  // the picker carries the label
            Spacer(minLength: 8)
            DatePicker(title, selection: $selection, displayedComponents: .date)
                .labelsHidden()
                .opacity(0.02)
                .overlay {
                    Text(selection.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: timeZone)))
                        .font(Deck.mono(14, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(Deck.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Deck.surface)
                        .overlay(Rectangle().strokeBorder(Deck.line, lineWidth: Deck.borderWidth))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
    }
}

// MARK: - Loading (a spinner and a mono caption)

/// The indeterminate wait. The spinner is the system one (it is a glyph, not a
/// surface, so it has no corner to square); the caption is a Deck label.
struct DeckLoading: View {
    var label: String?
    init(_ label: String? = nil) { self.label = label }

    var body: some View {
        VStack(spacing: 10) {
            ProgressView().tint(Deck.ink)
            if let label { Text(label).deckLabel() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Status line (DeckErrorText for every status)

/// One line of status text behind its shape: ■ crit, ◆ warn, ● ok, ○ idle.
/// DeckErrorText is the crit case of this; the others are needed for "this
/// note was truncated" (warn) and the like.
struct DeckStatusLine: View {
    let status: DeckStatus
    let text: String
    init(_ status: DeckStatus, _ text: String) {
        self.status = status
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            DeckDot(status, size: 7)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
            Text(text)
                .font(Deck.sans(12.5, .bold, relativeTo: .footnote))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var color: Color {
        switch status {
        case .ok: Deck.okInk
        case .warn: Deck.warnInk
        case .crit: Deck.critInk
        case .idle: Deck.muted
        }
    }
}

// MARK: - Tile group (DeckFormSection without the label)

/// A bordered tile with a hair between each child - DeckFormSection for a
/// group that had no heading, where inventing one would add words the screen
/// never had.
struct DeckTileGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(rows) { row in
                    if row.id != rows.first?.id {
                        Rectangle().fill(Deck.hair).frame(height: Deck.borderWidth)
                    }
                    row
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .deckTile()
    }
}

// MARK: - Label / value rows

/// `LabeledContent` as a Deck form row: the label in Space Grotesk, the value
/// in mono, 44pt tall, padded for a DeckFormSection.
///
/// `combine` makes the pair ONE VoiceOver stop, which is what the grouped
/// `Form` did for free - "Cadence, every 30 days". Turn it off for a row whose
/// content is a text field, which has to stay its own focusable element.
struct DeckLabeledContentStyle: LabeledContentStyle {
    var combine = true

    func makeBody(configuration: Configuration) -> some View {
        let row = HStack(alignment: .firstTextBaseline, spacing: 12) {
            configuration.label
                .font(Deck.sans(15, .medium))
                .foregroundStyle(Deck.ink)
            Spacer(minLength: 8)
            configuration.content
                .font(Deck.mono(14, .medium, relativeTo: .subheadline))
                .foregroundStyle(Deck.muted)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 44)

        if combine {
            row.accessibilityElement(children: .combine)
        } else {
            row
        }
    }
}

/// An icon + title Label for a navigation row: accent-ink glyph, bold title.
/// Keeps `Label`, so VoiceOver still reads only the title.
struct DeckRowLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.icon
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Deck.accentInk)
                .frame(width: 22)
            configuration.title
                .font(Deck.sans(15, .bold))
                .foregroundStyle(Deck.ink)
        }
    }
}

/// The trailing chevron on a row that pushes. Decorative: the link itself
/// already says it is a button.
struct DeckChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Deck.muted)
            .accessibilityHidden(true)
    }
}

// MARK: - List chrome

extension View {
    /// A row inside a `List` kept for its swipe actions / edit mode: no system
    /// insets or separator, the Deck row fill and 2px hair instead.
    func deckListRow(separator: Bool = true, last: Bool = false) -> some View {
        self
            .deckRow(separator: separator)
            .overlay(alignment: .bottom) { if last { DeckRule() } }
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Deck.surface)
    }

    /// A `List` on the Deck ground: plain style (the inset-grouped card has
    /// rounded corners), no system background.
    func deckList() -> some View {
        self
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Deck.ground)
            .environment(\.defaultMinListHeaderHeight, 0)
    }
}

/// A `List` section header as a Deck table head, flush to both edges.
struct DeckListHeader: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        DeckTableHead(text)
            .listRowInsets(EdgeInsets())
    }
}

// MARK: - Hatch ("not one thing")

/// Diagonal muted stripes on the rail - the fill for a slice that stands for
/// several categories ("Other"), which must not look like one more category.
/// Mirrors ledger's --pie-other (web/index.html) so the phone and the browser
/// paint Other the same way.
enum DeckHatch {
    @MainActor private static var cache: [ColorScheme: Image] = [:]

    @MainActor
    static func paint(_ scheme: ColorScheme) -> ImagePaint {
        ImagePaint(image: tile(scheme), scale: 1 / 3)
    }

    @MainActor
    private static func tile(_ scheme: ColorScheme) -> Image {
        if let hit = cache[scheme] { return hit }
        var env = EnvironmentValues()
        env.colorScheme = scheme
        let rail = UIColor(cgColor: Deck.rail.resolve(in: env).cgColor)
        let stripe = UIColor(cgColor: Deck.muted.resolve(in: env).cgColor)
        // 15px at scale 3 = a 5pt repeat, 2pt stripe - the web pattern's size.
        let side: CGFloat = 15
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { ctx in
            rail.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let path = UIBezierPath()
            // Three segments so the stripe continues across tile seams.
            for offset in [-side, 0, side] {
                path.move(to: CGPoint(x: offset, y: side))
                path.addLine(to: CGPoint(x: offset + side, y: 0))
            }
            stripe.setStroke()
            path.lineWidth = 5
            path.stroke()
        }
        let result = Image(uiImage: image)
        cache[scheme] = result
        return result
    }
}
