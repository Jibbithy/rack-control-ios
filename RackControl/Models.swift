import Foundation

/// One service tile from GET /api/apps.
///
/// The response is keyed by node: {"atlas": [tile, ...], "calypso": [...]}.
struct AppTile: Codable, Identifiable, Sendable {
    let k: String  // key
    let n: String  // display name
    let m: String  // a metric string, e.g. "100.0% · 24h"
    let i: String  // icon key
    let s: String  // status
    let v: String  // where the status came from

    var id: String { k }

    /// `s` IS AN EMPTY STRING WHEN THE SERVICE IS UP, and "down" when it is not.
    /// The empty string is the good case; reading it as "unknown" paints every
    /// healthy tile grey and is the easiest mistake to make against this API.
    var isDown: Bool { s == "down" }

    /// THE THIRD STATE, and the reason this is not a Bool. The hub sends "idle"
    /// for a service it could not get an answer about - a container that is not
    /// deployed, a node whose Docker is unreachable, a systemd unit that is not
    /// installed. Folding it into `!isDown` painted those tiles solid green,
    /// which is the app telling you something is healthy at the exact moment it
    /// has no idea. The web tile has had three states all along; this side had
    /// two, and the gap only became visible when calypso and hermes started
    /// reporting more than two services each.
    var isUnknown: Bool { !s.isEmpty && s != "down" }

    /// What VoiceOver and the row both say about the state, in one place so
    /// they cannot drift apart.
    var stateWord: String { isDown ? "Down" : isUnknown ? "Unknown" : "Up" }
}

struct FileListing: Codable, Sendable {
    let path: String
    let entries: [FileEntry]
}

struct FileEntry: Codable, Identifiable, Sendable {
    let name: String
    let dir: Bool
    let size: Int?  // null for a directory
    let mtime: Double  // epoch MILLISECONDS - not seconds
    /// OPTIONAL because a hub older than the preview feature does not send it.
    /// Decoding would fail outright for the whole listing otherwise, so the app
    /// would show an empty folder rather than a folder it cannot preview.
    let kind: String?

    var id: String { name }
    var modified: Date { Date(timeIntervalSince1970: mtime / 1000) }
    var isMarkdown: Bool { name.hasSuffix(".md") }
    /// GET /api/vault/note takes the name WITHOUT the .md suffix.
    var noteName: String { isMarkdown ? String(name.dropLast(3)) : name }

    var preview: PreviewKind { PreviewKind(rawValue: kind ?? "") ?? .binary }
}

/// The hub's `kind` string. THE HUB OWNS THIS VOCABULARY - see KINDS in
/// hub/files.js. Adding an extension there needs no change here.
enum PreviewKind: String, Sendable {
    case image, video, audio, pdf, text, stl, gcode, binary

    var icon: String {
        switch self {
        case .image: "photo"
        case .video: "film"
        case .audio: "music.note"
        case .pdf: "doc.richtext"
        case .text: "doc.text"
        case .stl, .gcode: "cube"
        case .binary: "doc"
        }
    }
}

/// GET /api/files/ticket.
struct FileTicket: Codable, Sendable {
    let url: String
    let expires: Double
}

/// What a capped read of one file came back with.
struct FileBytes: Sendable {
    let data: Data
    /// True only when the hub HAS MORE than we asked for - not merely that it
    /// answered 206. It answers 206 for any satisfiable range, including one
    /// that covers the whole file, so status alone reports every small file as
    /// truncated.
    let truncated: Bool
}

struct Note: Codable, Sendable {
    let name: String
    let path: String
    let text: String
    let truncated: Bool
}

// --- Glances. These responses carry dozens of fields; only these are decoded,
// and Codable ignores the rest. ---

struct Quicklook: Codable, Sendable {
    let cpu: Double
    let cpu_name: String?
}

struct Mem: Codable, Sendable {
    let total: Int
    let used: Int
    let percent: Double
}

/// GET /api/glances/<node>/fs returns an ARRAY of mounts, not an object. atlas
/// has both "/" and "/srv/data" and the pool is the one worth showing.
struct FsMount: Codable, Identifiable, Sendable {
    let mnt_point: String
    let size: Int
    let used: Int
    let percent: Double
    var id: String { mnt_point }
}

/// What one node's card shows. Assembled from three separate Glances calls so
/// that one failing does not blank the other two.
struct NodeHealth: Sendable {
    var cpu: Double?
    var mem: Mem?
    var pool: FsMount?
    var error: String?
}
