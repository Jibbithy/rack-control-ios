import SwiftUI

/// A vault note, rendered as Markdown, with [[wikilinks]] made tappable.
struct NoteView: View {
    let name: String

    @State private var note: Note?
    @State private var error: HubError?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sp3) {
                if let note {
                    if note.truncated {
                        DeckStatusLine(.warn, "This note was truncated by the hub.")
                    }
                    ForEach(Array(Self.blocks(of: note.text).enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .text(let s):
                            Text(Self.markdown(s))
                                .font(Deck.body)
                                .foregroundStyle(Deck.ink)
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        case .link(let target):
                            NavigationLink(value: Route.note(target)) {
                                Label(target, systemImage: "link")
                                    .labelStyle(DeckRowLabelStyle())
                                    .padding(.horizontal, Theme.sp3)
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .deckTile()
                        }
                    }
                } else if let error {
                    DeckAlert(.crit, title: "Can't open this note", message: error.localizedDescription)
                } else {
                    DeckLoading().frame(minHeight: 200)
                }
            }
            .padding(Theme.sp4)
        }
        .background(Deck.ground)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { note = try await HubClient.shared.note(name) } catch let e as HubError { error = e } catch {}
        }
    }

    enum Block {
        case text(String)
        case link(String)
    }

    /// Split a note on [[wikilinks]]. THIS IS THE GRAPH, in the form a phone can
    /// use - the desktop's force-directed canvas is deliberately not ported,
    /// because panning a node graph on a 6-inch screen is a novelty rather than
    /// navigation.
    static func blocks(of text: String) -> [Block] {
        var out: [Block] = []
        var rest = Substring(text)
        while let open = rest.range(of: "[["), let close = rest.range(of: "]]", range: open.upperBound..<rest.endIndex) {
            let before = rest[rest.startIndex..<open.lowerBound]
            if !before.isEmpty { out.append(.text(String(before))) }
            var target = String(rest[open.upperBound..<close.lowerBound])
            // Obsidian allows [[note|alias]] and [[note#heading]]; the hub keys
            // notes on the bare name.
            if let bar = target.firstIndex(of: "|") { target = String(target[target.startIndex..<bar]) }
            if let hash = target.firstIndex(of: "#") { target = String(target[target.startIndex..<hash]) }
            out.append(.link(target.trimmingCharacters(in: .whitespaces)))
            rest = rest[close.upperBound...]
        }
        if !rest.isEmpty { out.append(.text(String(rest))) }
        return out
    }

    /// Falls back to the raw string rather than showing nothing when a note
    /// contains Markdown this initialiser rejects.
    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
