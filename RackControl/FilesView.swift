import SwiftUI

/// The file browser. Two roots behind one toggle: the whole storage pool, or
/// just the Obsidian vault - which is the pool's most-visited subfolder and
/// worth one tap rather than three.
struct FilesView: View {
    enum Root: String, CaseIterable, Identifiable {
        case files = "Files"
        case vault = "Vault"
        var id: String { rawValue }
        var path: String { self == .files ? Config.filesRoot : Config.vaultRoot }
    }

    @State private var root: Root = .files
    #if DEBUG
        @State private var demoPush = DemoMode.filesPush
    #endif

    var body: some View {
        NavigationStack {
            // KEYED ON THE ROOT, so switching pops any folder you had drilled
            // into. Without the id, SwiftUI reuses the view and you would be
            // left looking at a path that is not under the root you picked.
            DirectoryView(path: root.path, title: root.rawValue)
                .id(root)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        // DeckSegmented, not a segmented Picker: the system
                        // control is a rounded pill that cannot be squared off.
                        DeckSegmented(
                            selection: $root,
                            options: Root.allCases.map { ($0, $0.rawValue) }
                        )
                        .frame(width: 200)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Root")
                    }
                }
                #if DEBUG
                    .navigationDestination(isPresented: $demoPush) { DemoMode.filesDestination() }
                #endif
        }
    }
}

/// One directory listing. Pushes another of itself for a subdirectory, a
/// NoteView for a .md file INSIDE THE VAULT, and a FilePreviewView for
/// everything else. Read-only throughout.
struct DirectoryView: View {
    let path: String
    let title: String

    @State private var entries: [FileEntry] = []
    @State private var error: HubError?
    @State private var loaded = false

    var body: some View {
        // A ScrollView of Deck rows rather than a List: nothing here swipes,
        // and a List's inset rows, grey chevrons and hairline separators are
        // system-owned. NavigationLink(value:) pushes the same from either.
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(sorted.enumerated()), id: \.element.id) { i, e in
                    Group {
                        // ORDER IS LOAD-BEARING. `dir` is tested before anything looks
                        // at the name or the kind, so a folder called "renders.stl"
                        // drills in rather than being handed to the model viewer - the
                        // hub sends no kind for a directory, but a listing that ever
                        // did would still lose to this branch.
                        if e.dir {
                            NavigationLink(value: Route.dir(childPath(e.name), e.name)) {
                                FileRow(separator: i > 0) { Label(e.name, systemImage: "folder") }
                            }
                        } else if e.isMarkdown && inVault {
                            // Ahead of the preview on purpose. The hub classifies .md
                            // as `text`, so without this a note would open as raw
                            // monospaced source; NoteView renders it from the vault,
                            // which is the reason to have opened it.
                            //
                            // AND ONLY INSIDE THE VAULT - see `inVault`. A .md anywhere
                            // else falls through to the preview below and opens as text,
                            // which is what the dashboard does with it too.
                            NavigationLink(value: Route.note(e.noteName)) {
                                FileRow(separator: i > 0) { Label(e.name, systemImage: "doc.text") }
                            }
                        } else {
                            NavigationLink(
                                value: Route.preview(
                                    childPath(e.name), e.name,
                                    e.preview.rawValue, e.size)
                            ) {
                                FileRow(separator: i > 0) {
                                    Label {
                                        HStack {
                                            Text(e.name)
                                            Spacer()
                                            if let s = e.size {
                                                Text(ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file))
                                                    .font(Theme.rowMeta)
                                                    .foregroundStyle(Deck.muted)
                                            }
                                        }
                                    } icon: {
                                        Image(systemName: e.preview.icon)
                                    }
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            // No top rule: the bar's 3px edge is the table's top. The
            // bottom rule closes it.
            .overlay(alignment: .bottom) { if !sorted.isEmpty { DeckRule() } }
            .padding(.bottom, Theme.sp4)
        }
        .background(Deck.ground)
        .navigationTitle(title)
        .navigationDestination(for: Route.self) { r in
            switch r {
            case .dir(let p, let n): DirectoryView(path: p, title: n)
            case .note(let n): NoteView(name: n)
            case .preview(let p, let n, let k, let s):
                FilePreviewView(
                    path: p, name: n,
                    kind: PreviewKind(rawValue: k) ?? .binary, size: s)
            }
        }
        .overlay(alignment: .top) {
            if let error, entries.isEmpty {
                DeckAlert(.crit, title: "Can't list this folder", message: error.localizedDescription)
                    .padding(Theme.sp4)
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            do { entries = try await HubClient.shared.files(at: path).entries } catch let e as HubError { error = e } catch {}
        }
    }

    /// Is this listing inside the Obsidian vault?
    ///
    /// GET /api/vault/note takes a BARE NAME and resolves it against an index
    /// the hub builds by walking VAULT_ROOT, so it can only answer for notes
    /// that live under it. Routing every .md to NoteView regardless of root
    /// meant a README.md anywhere else in the pool 404'd as "Can't open this
    /// note" - while the hub types it `text` and the dashboard previews it
    /// happily, so the one kind barred from the new text renderer was the kind
    /// most worth reading.
    ///
    /// GATED ON THE PATH rather than falling back to the preview on a 404,
    /// because this way the decision is a pure function of where the listing
    /// already is: it is settled before any request goes out, the row's icon and
    /// its destination cannot disagree, and there is no failed round trip and no
    /// flash of an error to recover from. A 404 fallback would also have to
    /// guess whether a 404 meant "not a vault note" or "the hub is mid-reindex".
    ///
    /// The trailing "/" is not decoration: a bare hasPrefix would also claim a
    /// sibling folder named "vault-archive".
    private var inVault: Bool {
        path == Config.vaultRoot || path.hasPrefix(Config.vaultRoot + "/")
    }

    /// The hub path for one entry in this listing.
    ///
    /// ONE PLACE RATHER THAN THREE. Plain concatenation is correct here and it
    /// is worth stating why once instead of letting each call site imply it:
    /// both roots in Config are spelled without a trailing slash, every deeper
    /// path is produced by this function and so inherits that, and the hub's
    /// listing returns single components straight out of readdir - so no name
    /// contains a "/" and no path ends in one. Characters that would matter in
    /// a URL - spaces, "&", "#", "?" - are not a hazard either: the path
    /// travels as a URLQueryItem value, which percent-encodes them.
    ///
    /// The hasSuffix guard covers the one thing above that is a convention
    /// rather than a guarantee. A root respelled "/srv/data/" someday would
    /// otherwise yield "/srv/data//x" - which the filesystem resolves, but
    /// which is a second spelling of one file, and Route is compared by value.
    private func childPath(_ name: String) -> String {
        path.hasSuffix("/") ? path + name : path + "/" + name
    }

    /// Directories first, then files, each alphabetically and case-insensitively
    /// - the hub returns them in whatever order the filesystem gave.
    private var sorted: [FileEntry] {
        entries.sorted {
            $0.dir == $1.dir
                ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                : $0.dir
        }
    }
}

/// One listing row's content: the entry's Label in Deck type, and the chevron
/// every pushing row carries. Keeps the `Label`, so VoiceOver reads the name
/// and not the glyph.
private struct FileRow<Content: View>: View {
    var separator: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: Theme.sp3) {
            content
                .labelStyle(FileLabelStyle())
            Spacer(minLength: 0)
            DeckChevron()
        }
        // Inside the link label, so the whole padded row is the tap target.
        .deckRow(separator: separator)
        .contentShape(Rectangle())
    }
}

private struct FileLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Theme.sp3) {
            configuration.icon
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Deck.ink)
                .frame(width: 24)
            configuration.title
                .font(Theme.rowTitle)
                .foregroundStyle(Deck.ink)
                .lineLimit(2)
        }
    }
}

enum Route: Hashable {
    case dir(String, String)
    case note(String)
    /// Path, display name, the hub's kind string, and the size in bytes.
    ///
    /// THE KIND TRAVELS AS A STRING rather than as a PreviewKind. Hashable is
    /// not the reason - an enum with no associated values synthesises that for
    /// free - and the call site passes `e.preview.rawValue`, which has already
    /// resolved an unrecognised kind to .binary. So the string here is always a
    /// known rawValue and the `?? .binary` at the destination is the compiler's
    /// due rather than a live fallback; what the String buys is that Route
    /// stays a plain tuple of stdlib types that nothing else has to import.
    ///
    /// The size stays OPTIONAL all the way through. FilePreviewView's ceiling
    /// check PROCEEDS on a nil rather than refusing, so flattening a missing
    /// size to 0 here would turn "the hub could not stat this" into "empty
    /// file" and silently change which files it is willing to pull down.
    case preview(String, String, String, Int?)
}
