import AVKit
import Combine
import QuickLook
import SwiftUI
import WebKit

/// One file, rendered the way its kind deserves.
///
/// The hub classifies every file it lists (see KINDS in hub/files.js) and this
/// switches on that answer rather than re-deriving it from the extension. Two
/// places guessing at "is this a video" is two places to disagree, and the hub
/// is the one that can also see the bytes.
///
/// EVERY PATH HERE IS READ-ONLY. Nothing in this view writes to the pool; the
/// only file it creates is a throwaway copy in the app's temp directory, and it
/// deletes that on the way out.
struct FilePreviewView: View {
    /// The absolute path on the hub, e.g. "/srv/data/models/bracket.stl".
    let path: String
    /// The bare filename. Used as the title, as the viewer's label, and - the
    /// load-bearing one - as the NAME OF THE TEMP COPY.
    let name: String
    let kind: PreviewKind
    /// The file's size in bytes, straight from the listing. OPTIONAL because
    /// the hub sends null for anything it could not stat, and because a caller
    /// that has not got one must still be able to open a file - see the note on
    /// `refusedCeiling`, which proceeds rather than refuses when this is nil.
    var size: Int?

    /// The biggest text file this view will pull into memory to show.
    ///
    /// 256KB is roughly 4,000 lines of source, which is past the point where
    /// reading it on a phone is the thing you actually wanted to do. The cap is
    /// enforced by the hub via a Range header rather than by truncating after
    /// the fact, so a 2GB log costs 256KB of transfer and not 2GB - which is the
    /// whole reason `data(at:limit:)` takes a limit at all.
    private static let textLimit = 256 * 1024

    /// The biggest PDF this view will download to preview: 100MB.
    ///
    /// RAM is NOT the constraint here, which is what makes this number
    /// different in kind from the text cap above - the download streams to disk
    /// and QuickLook maps the file lazily, so a large PDF is not going to be
    /// what kills the app. The two things that do go wrong are storage and
    /// patience: the bytes land in the app's container whether or not the
    /// reader waits for them, and the download reports no byte progress, so an
    /// oversized file is an indeterminate spinner followed by a write that
    /// fails opaquely on a full phone. 100MB is deliberately the same number
    /// viewer.html uses for STL, so "too big to pull over Tailscale" is one
    /// figure across the app rather than three that each need justifying.
    private static let pdfLimit = 100 * 1024 * 1024

    /// The biggest image this view will hand to AsyncImage: 40MB.
    ///
    /// THIS ONE IS A PROXY AND ONLY A PROXY, and it is worth being honest about
    /// that rather than presenting it as a memory bound. AsyncImage decodes the
    /// whole image, and a decoded bitmap costs width x height x 4 bytes with no
    /// relation to the compressed size on disk - so a highly compressible PNG
    /// of enormous dimensions is small on the pool and enormous in memory, and
    /// this check cannot see it coming. What the number does cover is the
    /// ordinary case: camera originals run 2-15MB and a 4K PNG screenshot about
    /// 20MB, so 40MB passes everything anyone actually browses while refusing
    /// the scanned-poster TIFFs that sit in a pool for years. The pathological
    /// PNG stays a known risk rather than a silenced one - the same trade
    /// viewer.html makes when its STL ceiling tracks the binary bound and lets
    /// the ASCII peak stand as a named risk.
    private static let imageLimit = 40 * 1024 * 1024

    /// The prefix on every temp directory this view creates.
    ///
    /// Shared with the launch sweep in RackControlApp so the two cannot drift
    /// apart: a rename here that the sweep did not follow would not fail, it
    /// would just quietly stop collecting the garbage.
    static let tempPrefix = "preview-"

    @State private var ticket: URL?
    @State private var text: String?
    @State private var textTruncated = false
    @State private var player: AVPlayer?
    /// Set when the player item admits it cannot decode the file.
    ///
    /// SEPARATE FROM `error` on purpose, and for the same reason
    /// `refusedCeiling` is: it carries no Retry, because a codec this phone
    /// does not have will not turn up on a second attempt.
    @State private var undecodable = false
    @State private var local: LocalCopy?
    @State private var downloading = false
    /// The failure that replaced the preview entirely.
    @State private var error: HubError?
    /// A failure that must NOT replace the preview - the share download falling
    /// over while a perfectly good text file is on screen. Blanking the file the
    /// reader is looking at to report that a different, optional thing failed is
    /// the wrong trade, so this surfaces as an alert instead.
    @State private var shareError: String?

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Deck.ground)
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { shareControl } }
            .alert(
                "Couldn't download this file",
                isPresented: .init(
                    get: { shareError != nil },
                    set: { if !$0 { shareError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(shareError ?? "")
            }
            .task { await load() }
            .onDisappear(perform: teardown)
    }

    // MARK: - the preview itself

    @ViewBuilder
    private var content: some View {
        if let ceiling = refusedCeiling, let size {
            // BEFORE the error branch and deliberately NOT one of its cases:
            // this is not a failure and it carries no Retry, because retrying
            // will not make the file smaller. The share button stays live above
            // it, so an oversized PDF is still reachable - the refusal is about
            // what this view will pull down on its own, not about locking the
            // file away.
            PreviewState {
                DeckAlert(
                    .warn, title: "Too big to preview",
                    message:
                        "This file is \(Self.mb(size)); the \(kind.rawValue) preview stops at \(Self.mb(ceiling)). Use the share button to open it in another app."
                )
            }
        } else if let error {
            PreviewState {
                DeckAlert(.crit, title: "Can't open this file", message: error.localizedDescription) {
                    // `.task` fires once per appearance, so without this a
                    // momentary blip - the tailnet reconnecting, one refused mint -
                    // left the only way forward being to pop the view and push it
                    // again. The user knows the file is fine; the app should not
                    // make them prove it by navigating.
                    Button("Retry") { Task { await retry() } }
                        .buttonStyle(.deck)
                        .padding(.top, Theme.sp2)
                }
            }
        } else {
            switch kind {
            case .image:
                if let ticket {
                    // AsyncImage rather than a hand-rolled fetch because the
                    // ticketed URL needs no header - which is the entire reason
                    // tickets exist - so there is nothing left for a custom
                    // loader to add.
                    AsyncImage(url: ticket) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFit()
                        case .failure(let e):
                            // NOT NECESSARILY THE TRANSFER, which is what this
                            // branch used to assert outright. An expired ticket
                            // is still ruled out - those last six hours now (hub
                            // commit ef8081d) - but AsyncImage is UIImage-backed
                            // and UIImage does not decode SVG, while the hub
                            // types .svg as `image` deliberately and the
                            // dashboard renders it fine. So a download that
                            // worked perfectly lands here too, and the old
                            // wording reported it as a network failure.
                            PreviewState {
                                DeckAlert(
                                    .crit, title: "Can't show this image",
                                    message: Self.imageFailure(name: name, error: e))
                            }
                        default:
                            DeckLoading()
                        }
                    }
                } else {
                    minting
                }

            case .video, .audio:
                if undecodable {
                    // The toolbar's share button is untouched by this branch and
                    // is the actual way out - the same trade the oversize
                    // refusal above makes.
                    PreviewState {
                        DeckAlert(
                            .crit, title: "Can't play this file",
                            message: "This format can't be decoded \u{2014} .mkv, .avi and .ogg all land here. Use the share button to open it in another app.")
                    }
                } else if let player {
                    // The player is built ONCE, when the ticket lands, and held
                    // in state. Constructing it inside body would hand VideoPlayer
                    // a brand new AVPlayer on every state change - restarting
                    // playback from zero each time the share button changed shape.
                    VideoPlayer(player: player)
                } else {
                    minting
                }

            case .pdf:
                if let local {
                    QuickLookPreview(url: local.file)
                } else {
                    // QuickLook reads from disk and has no hook for supplying
                    // bytes, so the download is not optional here the way it is
                    // for the other kinds - it IS the preview.
                    DeckLoading("Downloading…")
                }

            case .text:
                if let text {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.sp3) {
                            if textTruncated {
                                DeckStatusLine(.warn, "Only the first \(Self.textLimit / 1024)KB is shown.")
                            }
                            Text(text)
                                .font(Deck.mono(13, .regular, relativeTo: .footnote))
                                .foregroundStyle(Deck.ink)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(Theme.sp3)
                                .deckTile()
                        }
                        .padding(Theme.sp4)
                    }
                } else {
                    DeckLoading()
                }

            case .stl, .gcode:
                if let ticket, let viewer = Self.viewerURL(for: ticket, kind: kind, name: name) {
                    WebViewer(url: viewer)
                        .ignoresSafeArea(edges: .bottom)
                } else if ticket != nil {
                    // viewerURL returns nil only if percent-encoding fails, which
                    // it cannot for a URL Foundation just produced - but a silent
                    // blank screen would be the worst possible way to be wrong.
                    PreviewState {
                        DeckAlert(
                            .crit, title: "Can't build a viewer link",
                            message: "The hub returned a ticket this app couldn't encode.")
                    }
                } else {
                    minting
                }

            case .binary:
                PreviewState {
                    DeckEmpty(
                        label: kind.rawValue, title: "No preview for this file",
                        message: "Use the share button to open it in another app or save it to Files.")
                }
            }
        }
    }

    /// The gap between "the view appeared" and "the ticket came back". It is a
    /// round trip to the hub over Tailscale, so it is short but not free, and a
    /// bare spinner on a black screen reads as a hang.
    private var minting: some View {
        DeckLoading("Getting a link…")
    }

    /// This kind's ceiling, or nil for a kind that has none.
    ///
    /// Only the two kinds that pull a whole file down unprompted are capped.
    /// Text is already bounded by the hub's Range header, stl and gcode are
    /// bounded by viewer.html's own MAX_BYTES, video and audio stream rather
    /// than buffer, and binary fetches nothing at all.
    private static func ceiling(for kind: PreviewKind) -> Int? {
        switch kind {
        case .pdf: pdfLimit
        case .image: imageLimit
        default: nil
        }
    }

    /// The ceiling this file breaks, or nil if it is fine to load.
    ///
    /// A MISSING SIZE PROCEEDS RATHER THAN REFUSING, which is the same call
    /// viewer.html's checkSize makes when Content-Length is absent: the guard
    /// exists to catch the file that is obviously too big, not to make an
    /// unknown size unopenable. The hub sends a size for every regular file, so
    /// nil here means a caller that did not pass one along.
    private var refusedCeiling: Int? {
        guard let size, let ceiling = Self.ceiling(for: kind), size > ceiling else { return nil }
        return ceiling
    }

    /// Why an image did not appear, in the one case the filename settles it.
    ///
    /// The hub maps .svg to `image` on purpose and the dashboard draws it, so
    /// on iOS this is the one kind where the bytes arrive intact and the
    /// renderer is what gives up. Claiming "the transfer failed" there sends
    /// the reader to check Tailscale over a file that downloaded perfectly.
    ///
    /// This still ATTEMPTS the SVG rather than refusing it up front: if UIImage
    /// ever learns to decode one, this app renders it with no change here, and
    /// until then the reader is told the real reason. For every other name the
    /// message names BOTH possibilities rather than picking one, because from
    /// inside this branch the two are genuinely indistinguishable.
    static func imageFailure(name: String, error: any Error) -> String {
        name.lowercased().hasSuffix(".svg")
            ? "iOS can't render SVG. The file itself downloaded fine - use the share button to open it in another app."
            : "The transfer failed, or this phone can't decode the file. \(error.localizedDescription)"
    }

    /// "214.0 MB" - the same 1024-based, one-decimal spelling as viewer.html's
    /// mb(), so a refusal reads identically whichever of the two produced it.
    private static func mb(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    // MARK: - loading

    private func retry() async {
        // Clearing the error first so the spinner comes back rather than the
        // failure sitting there through the whole second attempt.
        error = nil
        undecodable = false
        await load()
    }

    private func load() async {
        // The ceiling is checked before anything is fetched, so an oversized
        // file costs no transfer at all - the same reason viewer.html resolves
        // its limit before the fetch rather than after.
        guard refusedCeiling == nil else { return }
        do {
            switch kind {
            case .text:
                let bytes = try await HubClient.shared.data(at: path, limit: Self.textLimit)
                // String(decoding:as:) rather than String(data:encoding:), which
                // returns nil for the WHOLE buffer on one bad byte. A capped read
                // lands wherever 256KB lands, which for any non-ASCII file is
                // eventually mid-way through a multi-byte character - so the
                // strict initialiser would show "can't open this file" for a
                // perfectly readable UTF-8 log purely because of where the cut
                // fell. This one substitutes U+FFFD and always succeeds.
                text = String(decoding: bytes.data, as: UTF8.self)
                textTruncated = bytes.truncated

            case .pdf:
                local = try await fetchLocalCopy()  // nil only if one is already running

            case .image, .video, .audio, .stl, .gcode:
                let url = try await HubClient.shared.ticketURL(for: path)
                ticket = url
                if kind == .video || kind == .audio {
                    // AVPlayerItem built explicitly rather than AVPlayer(url:),
                    // because the ITEM is what carries the status - the player
                    // never reports a codec failure of its own.
                    let item = AVPlayerItem(url: url)
                    player = AVPlayer(playerItem: item)
                    // Runs until the view goes away, which is fine: nothing
                    // follows it here, and `.task` cancels it on disappear.
                    await watchDecode(item)
                }

            case .binary:
                break  // nothing to fetch; the share button is the whole feature
            }
        } catch let e as HubError {
            error = e
        } catch let e {
            // `let e` rather than the implicit `error`, which would shadow the
            // @State of the same name and read as assigning it to itself.
            error = .http(0, e.localizedDescription)
        }
    }

    /// Waits for the player item to admit it cannot decode the file.
    ///
    /// THE ITEM'S STATUS IS THE ONLY SIGNAL - exactly as the `error` event is
    /// the only one on the web side, where fpMedia in web/index.html carries the
    /// same note. An unsupported codec throws nothing, rejects no promise and
    /// returns no error from any call this view makes. Left unobserved,
    /// VideoPlayer shows a black frame and a dead scrubber, which reads as a
    /// broken hub rather than a missing codec - and the pool is full of the
    /// formats this hits: the hub types .mkv, .avi, .ogg and .opus as
    /// video/audio, and AVPlayer decodes none of them.
    ///
    /// The stream never completes on its own; the enclosing `.task` cancels it.
    private func watchDecode(_ item: AVPlayerItem) async {
        for await status in item.publisher(for: \.status).values where status == .failed {
            undecodable = true
            return
        }
    }

    // MARK: - the temp copy

    /// A downloaded file, and the directory built to hold it.
    ///
    /// The DIRECTORY is what gets deleted, not the file, because the file has to
    /// keep its real name and two files in the pool can share one - so each copy
    /// gets a directory of its own rather than a mangled unique filename.
    private struct LocalCopy {
        let dir: URL
        let file: URL
    }

    /// Downloads the file to a temp copy named exactly as it is on the hub.
    ///
    /// THE NAME IS NOT COSMETIC. QuickLook and the share sheet both dispatch on
    /// the path extension - there is no MIME type in play once the bytes are on
    /// disk - so a copy saved as a UUID previews as nothing and shares as
    /// "unknown data". The transfer itself is HubClient's, which streams it to
    /// disk and maps its own failures; the only thing decided here is where the
    /// file lands and what it is called.
    ///
    /// Returns nil when a download is already running - see the guard.
    private func fetchLocalCopy() async throws -> LocalCopy? {
        if let local { return local }
        // A GUARD RATHER THAN A DISABLED BUTTON. `downloading` is set inside
        // this function, which runs a scheduling hop after the button's Task is
        // created, so two taps in quick succession both enqueue a Task before
        // either flips the flag and before the button has had a chance to
        // change shape. The second download would overwrite `local` and strand
        // the first directory forever, since `local` is the only thing that
        // remembers a directory exists.
        guard !downloading else { return nil }
        downloading = true
        defer { downloading = false }

        let dir = FileManager.default.temporaryDirectory
            .appending(path: "\(Self.tempPrefix)\(UUID().uuidString)", directoryHint: .isDirectory)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { throw HubError.local(error.localizedDescription) }

        let dest = dir.appending(path: Self.safeFilename(name), directoryHint: .notDirectory)
        do {
            try await HubClient.shared.download(path, to: dest)
        } catch {
            // The empty directory goes back if the transfer failed, otherwise a
            // refused download leaves litter that only the launch sweep will
            // ever collect - and it would be collecting nothing.
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return LocalCopy(dir: dir, file: dest)
    }

    /// A filename that cannot escape the directory built for it.
    ///
    /// The hub's listing returns single path components out of readdir, so in
    /// practice none of this fires. It is here because the consequence of being
    /// wrong is writing outside the temp directory, and because the three
    /// dangerous spellings are each dangerous for a different reason:
    ///
    /// - A NUL byte terminates the C string the filesystem call is eventually
    ///   built from, so "safe\0/../../x" can validate as one string and act as
    ///   a shorter one. Removed first, before anything else inspects it.
    /// - A "/" makes the name a PATH, and appending it would silently place the
    ///   file somewhere else entirely. lastPathComponent reduces it to the leaf.
    /// - ".." and "." are legal path components that mean "the parent" and
    ///   "here"; lastPathComponent keeps them intact, so they need naming.
    ///
    /// The fallback deliberately keeps no extension: a name this function could
    /// not trust should preview as nothing rather than as whatever type a
    /// salvaged suffix claimed.
    static func safeFilename(_ raw: String) -> String {
        let stripped = raw.replacingOccurrences(of: "\0", with: "")
        let leaf = (stripped as NSString).lastPathComponent
        // NSString.lastPathComponent returns "/" for "/" and "" for "", and
        // leaves "." and ".." alone - so all four still have to be caught here.
        if leaf.isEmpty || leaf == "." || leaf == ".." || leaf.contains("/") { return "file" }
        return leaf
    }

    @ViewBuilder
    private var shareControl: some View {
        if let local {
            ShareLink(item: local.file)
                .labelStyle(.iconOnly)
                .buttonStyle(DeckIconButtonStyle(side: 34))
        } else if downloading {
            ProgressView().tint(Deck.ink).frame(width: 36, height: 36)
        } else {
            // TWO TAPS, ON PURPOSE. ShareLink needs its item up front, so an
            // always-present one would mean downloading every file the moment it
            // is opened - a 2GB video pulled over Tailscale because someone
            // glanced at it. The button downloads; the ShareLink replaces it.
            Button {
                Task {
                    do { if let copy = try await fetchLocalCopy() { local = copy } } catch let e { shareError = e.localizedDescription }
                }
            } label: {
                // A bare arrow: the Deck button is already the box a circled
                // glyph would draw.
                Image(systemName: "arrow.down")
            }
            .buttonStyle(DeckIconButtonStyle(side: 34))
            .accessibilityLabel("Download")
        }
    }

    private func teardown() {
        // An AVPlayer is not stopped by its view going away: a backgrounded
        // audio file keeps playing over whatever screen comes next, and the item
        // holds its buffered bytes until the player is released. Pausing alone
        // leaves the item loaded, hence both lines.
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        // The whole directory, so nothing is left behind if anything else ever
        // lands beside the file. Safe to do while a share sheet is up, because a
        // sheet presented over this view does not disappear it - only popping
        // the navigation stack or locking the app does, and both mean the sheet
        // is already gone.
        //
        // This is the ordinary path and not the only one: a download still in
        // flight when the view goes away finishes into a directory this has
        // already decided is empty. RackControlApp.sweepPreviewTemp is the
        // backstop for exactly that.
        if let local { try? FileManager.default.removeItem(at: local.dir) }
    }

    // MARK: - the hub's own STL/GCODE viewer

    /// Unreserved characters only (RFC 3986 §2.3). Everything else is escaped.
    private static let unreserved = CharacterSet(
        charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// The URL of web/viewer.html, pointed at a ticketed content URL.
    ///
    /// THE `src` PARAMETER IS A WHOLE URL INSIDE A QUERY VALUE, and getting it
    /// there intact is the entire difficulty. viewer.html reads it with
    /// `URLSearchParams.get("src")`, then resolves it and REFUSES anything whose
    /// pathname is not exactly "/api/files/content" - so a mangled src does not
    /// fail loudly at the fetch, it renders the page's own error text where the
    /// model should be.
    ///
    /// Two ways to get it wrong, both verified against the real page rather than
    /// assumed:
    ///
    /// 1. Interpolating the ticket URL raw. It carries "&exp=" and "&sig=", so
    ///    the browser splits it into three parameters of viewer.html and `src`
    ///    arrives as the bare content URL with its signature gone. The pathname
    ///    check still passes, the fetch goes out unsigned, and the hub answers
    ///    401 - because a WKWebView carries no session cookie, which is the
    ///    whole reason this page is in PUBLIC_STATIC.
    ///
    /// 2. Letting URLComponents.queryItems do the encoding. It escapes "&" and
    ///    "=" (measured), so case 1 does not happen - but it leaves "+" alone,
    ///    and URLSearchParams decodes "+" as a SPACE because it parses
    ///    x-www-form-urlencoded. Any "+" in the ticket would silently become a
    ///    space. Today's tickets cannot contain one - the signature is hex and
    ///    encodeURIComponent escapes "+" in the path - so this would be a bug
    ///    that appears years later, from the hub's side, in a file nobody
    ///    changed here.
    ///
    /// Escaping down to the unreserved set closes both: "%2B" is read as "+" by
    /// URLSearchParams and by Foundation alike, and there is no character left
    /// on which the two disagree.
    static func viewerURL(for content: URL, kind: PreviewKind, name: String) -> URL? {
        guard let src = content.absoluteString.addingPercentEncoding(withAllowedCharacters: unreserved),
            let label = name.addingPercentEncoding(withAllowedCharacters: unreserved)
        else { return nil }
        var comps = URLComponents(
            url: Config.baseURL.appending(path: "/viewer.html"),
            resolvingAgainstBaseURL: false)
        // percentEncodedQuery, not queryItems: the string above is already
        // encoded exactly as intended and queryItems would encode it a second
        // time by its own rules.
        comps?.percentEncodedQuery = "src=\(src)&kind=\(kind.rawValue)&name=\(label)"
        return comps?.url
    }
}

/// A state message (a refusal, a failure, "nothing to show") placed where the
/// preview would have been: at the top, padded, on the ground.
private struct PreviewState<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack { content }
            .padding(Theme.sp4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// web/viewer.html in a WKWebView.
///
/// The WebGL STL renderer and the GCODE toolpath viewer already exist on the
/// hub and are already exercised by the dashboard. A second implementation in
/// SceneKit would be a second thing to fix every time an STL parses oddly.
struct WebViewer: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Non-persistent: this page is served with no credential and stores
        // nothing, so there is no cookie or cache worth keeping across files -
        // and a stale cached response for a ticketed URL would be a cached
        // credential.
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        // The near-black Deck fill: viewer.html draws its models for a dark
        // backdrop, and this is what shows before the page has painted.
        view.backgroundColor = DeckChrome.ui(Deck.onFill)
        // The page sets touch-action:none on its canvas and handles its own
        // drags; leaving UIKit's scrolling on means a rotate gesture fights the
        // scroll view for the same finger.
        view.scrollView.isScrollEnabled = false
        view.scrollView.bounces = false
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        // ONLY on a real change. updateUIView runs for any state change in an
        // ancestor - the share button turning into a ShareLink is enough - and
        // an unconditional load() would re-download and re-parse the model each
        // time, throwing away the camera position the user had set.
        guard context.coordinator.loaded != url else { return }
        context.coordinator.loaded = url
        view.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator { var loaded: URL? }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        // Navigating to about:blank rather than just dropping the reference.
        // viewer.html disposes its WebGL context on "pagehide", and a browser
        // grants roughly 16 of them before it starts killing the oldest - so an
        // app used to flip through a folder of STLs needs each one to actually
        // hand its context back. Deallocation alone does not fire pagehide,
        // and WKWebView teardown is asynchronous.
        view.stopLoading()
        view.load(URLRequest(url: URL(string: "about:blank")!))
    }
}

/// QuickLook over a local file. Used for PDFs, where the system renderer
/// handles pagination, text selection, search and thumbnails - none of which
/// are worth rebuilding, and all of which readers expect from a PDF.
struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        controller.reloadData()
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        // NSURL, not URL: QLPreviewItem is an Objective-C protocol that NSURL
        // conforms to and the Swift value type does not.
        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> any QLPreviewItem {
            url as NSURL
        }
    }
}
