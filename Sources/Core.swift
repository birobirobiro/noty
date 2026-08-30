import Foundation
import SwiftUI
import AppKit
import CryptoKit
import Security

// MARK: - Paths

enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Noty", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
    static var db: URL { support.appendingPathComponent("notes.db") }
    static var key: URL { support.appendingPathComponent("note.key") }
}

// MARK: - Crypto (AES-GCM, master key in the Keychain)

/// Three things matter here, and the old version got each of them wrong in a
/// way that is quiet until it costs you something:
///
///  * the key lived in `note.key` beside `notes.db`, so anything that could
///    read the notes could read the key sitting next to them — encryption that
///    protects against nothing. It belongs in the Keychain.
///  * every ciphertext was sealed with no associated data, so a blob could be
///    moved between rows or between columns and would still decrypt happily.
///  * a body that failed to decrypt came back as "", which shows an intact
///    note as empty and lets the next autosave write that emptiness over
///    ciphertext that was still perfectly good.
enum Crypto {
    enum Failure: Error { case noKey, unreadable }

    private static let service = "app.noty.notes"
    private static let account = "master-key"

    /// nil means the Keychain refused us on a fresh install: the app then
    /// stores nothing rather than quietly falling back to something weaker.
    static let key: SymmetricKey? = {
        if let found = keychainRead(), found.count == 32 { return SymmetricKey(data: found) }

        // A key written by an older build. Move it in, then take it off disk.
        if let old = try? Data(contentsOf: Paths.key), old.count == 32 {
            if keychainWrite(old) {
                try? FileManager.default.removeItem(at: Paths.key)
                NSLog("Noty: moved the note key into the Keychain")
            } else {
                // Refusing here would lock someone out of notes they can
                // already read, for no gain — the key is on disk either way.
                NSLog("Noty: Keychain unavailable, still using the key file")
            }
            return SymmetricKey(data: old)
        }

        let fresh = SymmetricKey(size: .bits256)
        let raw = fresh.withUnsafeBytes { Data($0) }
        guard keychainWrite(raw) else {
            NSLog("Noty: Keychain unavailable — refusing to store notes")
            return nil
        }
        return fresh
    }()

    /// Binds a ciphertext to the row and the column it belongs to, so it
    /// cannot be lifted from one note's body into another's title.
    private static func aad(_ id: String, _ field: String) -> Data {
        Data("noty/v1|\(id)|\(field)".utf8)
    }

    /// Bytes in, bytes out. A locked note's payload is itself ciphertext, so
    /// decoding it as text on the way past would corrupt it.
    static func seal(_ data: Data, id: String, field: String) throws -> Data {
        guard let key else { throw Failure.noKey }
        let box = try AES.GCM.seal(data, using: key, authenticating: aad(id, field))
        guard let combined = box.combined else { throw Failure.unreadable }
        return combined
    }

    static func open(_ data: Data, id: String, field: String) throws -> Data {
        guard let key else { throw Failure.noKey }
        if data.isEmpty { return Data() }
        guard let box = try? AES.GCM.SealedBox(combined: data) else { throw Failure.unreadable }
        if let plain = try? AES.GCM.open(box, using: key, authenticating: aad(id, field)) {
            return plain
        }
        // Rows written before the field binding existed carry no associated
        // data; they are re-sealed with it the next time the note is saved.
        if let plain = try? AES.GCM.open(box, using: key) { return plain }
        throw Failure.unreadable
    }

    static func seal(_ text: String, id: String, field: String) throws -> Data {
        try seal(Data(text.utf8), id: id, field: field)
    }

    static func openText(_ data: Data, id: String, field: String) throws -> String {
        String(decoding: try open(data, id: id, field: field), as: UTF8.self)
    }

    // MARK: Keychain

    private static func keychainQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func keychainRead() -> Data? {
        var q = keychainQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func keychainWrite(_ data: Data) -> Bool {
        var q = keychainQuery()
        q[kSecValueData as String] = data
        // The key is only ever needed while someone is using this Mac, and it
        // must not ride along to another device in a Keychain sync.
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemDelete(keychainQuery() as CFDictionary)
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
}

// MARK: - Palette

struct NoteColor {
    let name: String
    let paper: Color      // note body background
    let dash: Color       // saturated edge dash / colour bar
    let ink: Color        // text colour on paper

    /// Slightly deeper than a highlighter pastel, so a note reads as paper with
    /// colour in it rather than a tinted white rectangle.
    static let all: [NoteColor] = [
        NoteColor(name: "Lemon",  paper: hex(0xFCE795), dash: hex(0xE0AD08), ink: hex(0x3A3008)),
        NoteColor(name: "Peach",  paper: hex(0xFBCFA6), dash: hex(0xE2762A), ink: hex(0x422413)),
        NoteColor(name: "Rose",   paper: hex(0xFAC4D1), dash: hex(0xDC4570), ink: hex(0x40161F)),
        NoteColor(name: "Lilac",  paper: hex(0xD9C7FA), dash: hex(0x7C4DEE), ink: hex(0x2A1B44)),
        NoteColor(name: "Sky",    paper: hex(0xBEDDFA), dash: hex(0x2280D6), ink: hex(0x13293A)),
        NoteColor(name: "Mint",   paper: hex(0xB4E8D0), dash: hex(0x0E9B6E), ink: hex(0x0F2E23)),
        NoteColor(name: "Sand",   paper: hex(0xE3D3B4), dash: hex(0xA37B3C), ink: hex(0x372C18)),
        NoteColor(name: "Slate",  paper: hex(0xCBD6E2), dash: hex(0x4E6579), ink: hex(0x1A242E)),
    ]

    /// A touch darker at the foot of the sheet, the way paper catches light.
    var paperShade: Color { paper.opacity(1) }

    static func at(_ i: Int) -> NoteColor { all[((i % all.count) + all.count) % all.count] }

    private static func hex(_ v: UInt32) -> Color {
        Color(.sRGB,
              red:   Double((v >> 16) & 0xFF) / 255,
              green: Double((v >> 8) & 0xFF) / 255,
              blue:  Double(v & 0xFF) / 255,
              opacity: 1)
    }
}

// MARK: - Type

/// One entry per face offered for note bodies.
struct NoteFace {
    let name: String          // shown in the menu
    let body: String          // PostScript name, "" for the system font
    let tab: String           // heavier cut used on the tab labels
    let bump: CGFloat         // size nudge so faces look the same size as each other
}

enum Ink {
    /// Faces that suit a note. Filtered to what is actually installed, so the
    /// menu never offers something that would silently fall back.
    static let allFaces: [NoteFace] = [
        NoteFace(name: "System",       body: "",                     tab: "",                     bump: 0),
        NoteFace(name: "Noteworthy",   body: "Noteworthy-Light",     tab: "Noteworthy-Bold",      bump: 1.5),
        NoteFace(name: "Bradley Hand", body: "BradleyHandITCTT-Bold", tab: "BradleyHandITCTT-Bold", bump: 1.5),
        NoteFace(name: "Marker Felt",  body: "MarkerFelt-Thin",      tab: "MarkerFelt-Wide",      bump: 1),
        NoteFace(name: "Chalkboard",   body: "ChalkboardSE-Light",   tab: "ChalkboardSE-Bold",    bump: 0),
        NoteFace(name: "Avenir Next",  body: "AvenirNext-Regular",   tab: "AvenirNext-DemiBold",  bump: 0),
        NoteFace(name: "New York",     body: "NewYork-Regular",      tab: "NewYork-Semibold",     bump: 0),
        NoteFace(name: "Georgia",      body: "Georgia",              tab: "Georgia-Bold",         bump: 0),
        NoteFace(name: "Menlo",        body: "Menlo-Regular",        tab: "Menlo-Bold",           bump: -1),
    ]

    static var faces: [NoteFace] {
        allFaces.filter { $0.body.isEmpty || NSFont(name: $0.body, size: 12) != nil }
    }

    static var face: NoteFace {
        let want = Settings.noteFontName
        return faces.first { $0.body == want } ?? faces[0]
    }

    /// The hand (or face) note bodies are set in.
    static func body(_ size: CGFloat) -> NSFont {
        let f = face
        guard !f.body.isEmpty, let font = NSFont(name: f.body, size: size + f.bump) else {
            return .systemFont(ofSize: size)
        }
        return font
    }

    // Tab labels use the same face a shade bolder, so they hold up turned on
    // their side at this size.
    static let tabSize: CGFloat = 9.5
    static let tabTracking: CGFloat = 0.1

    /// For measuring — layout sizes each tab's strip to the longest label.
    static var tabNSFont: NSFont {
        let f = face
        guard !f.tab.isEmpty, let font = NSFont(name: f.tab, size: tabSize + f.bump) else {
            return .systemFont(ofSize: 9, weight: .semibold)
        }
        return font
    }

    static var tabFont: Font {
        let f = face
        guard !f.tab.isEmpty, NSFont(name: f.tab, size: tabSize) != nil else {
            return .system(size: 9, weight: .semibold)
        }
        return .custom(f.tab, size: tabSize + f.bump)
    }
}

// MARK: - Model

struct Note: Identifiable, Hashable {
    var id: String = UUID().uuidString
    var title: String = ""
    var body: String = ""
    var color: Int = 0
    var created: Date = Date()
    var modified: Date = Date()
    var archived: Bool = false
    var pinned: Bool = false
    var order: Double = 0
    /// Set when the stored text would not decrypt. Such a note is shown as a
    /// warning and is never written back, so the ciphertext survives whatever
    /// went wrong (a restored database, a rotated key) long enough to fix it.
    var unreadable: Bool = false
    /// Per-note password salt. Non-nil means the note carries a second lock;
    /// the salt itself is never shown and never leaves the process.
    var lockSalt: Data? = nil
    /// While a locked note is closed this holds the inner ciphertext, and
    /// `body` stays empty. Opening it moves the text the other way.
    var sealed: Data? = nil

    var locked: Bool { lockSalt != nil }

    var palette: NoteColor { NoteColor.at(color) }

    /// Title shown in the fan / lists, derived from the first non-empty line.
    static func derivedTitle(from body: String) -> String {
        let line = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var clean = line.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "^#{1,6}\\s*", with: "", options: .regularExpression)
        clean = Tasks.stripped(clean)
        clean = Markdown.plain(clean)
        if clean.isEmpty { return "" }
        return clean.count > 60 ? String(clean.prefix(60)) + "…" : clean
    }

    var displayTitle: String {
        // A title someone typed is shown even on a locked note: they chose it,
        // unlike the first line, which locking clears precisely so it cannot
        // give the note away.
        if !title.isEmpty { return title }
        if locked { return "Locked note" }
        return title.isEmpty ? "New note" : title
    }

    /// Completed / total, or nil when the note holds no tasks.
    var taskProgress: (done: Int, total: Int)? {
        var done = 0, total = 0
        for line in body.split(whereSeparator: \.isNewline) {
            switch Tasks.marker(of: line) {
            case Tasks.done: done += 1; total += 1
            case Tasks.open: total += 1
            default: break
            }
        }
        return total > 0 ? (done, total) : nil
    }

    /// Second line onwards, collapsed — used as list subtitle.
    var preview: String {
        // A locked note gives nothing away in a list, even while it is open
        // somewhere else: unlocking it in the deck must not put its first line
        // on a card in another window.
        guard !locked else { return "" }
        let lines = body.split(whereSeparator: \.isNewline).map(String.init)
        let rest = lines.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return rest.count > 120 ? String(rest.prefix(120)) + "…" : rest
    }
}

// MARK: - Tasks

/// Checkbox tasks are stored inline in the note body as ☐ / ☑ line prefixes, so a
/// note is still plain text and exports cleanly to Markdown task syntax.
/// Markdown reduced to the words in it.
///
/// The title in a note's header, on its deck tab and on its library card is
/// the first line of the body — and the body is Markdown, so a line written as
/// `**groceries**` was being shown with its asterisks. The editor hides those;
/// everywhere else that quotes the text has to strip them.
enum Markdown {
    private static let rules: [(String, String)] = [
        // Links and images first: their labels survive, their targets do not.
        ("!?\\[([^\\]]*)\\]\\([^)]*\\)", "$1"),
        ("!?\\[\\[([^\\]|]*)(\\|[^\\]]*)?\\]\\]", "$1"),
        ("`([^`]*)`", "$1"),
        ("\\*\\*([^*]*)\\*\\*", "$1"),
        ("__([^_]*)__", "$1"),
        ("~~([^~]*)~~", "$1"),
        ("==([^=]*)==", "$1"),
        // Single delimiters last, so ** has already gone.
        ("\\*([^*]*)\\*", "$1"),
        ("(?<![\\p{L}\\p{N}])_([^_]*)_(?![\\p{L}\\p{N}])", "$1"),
        // Leading block markers on a line that is being quoted as a title.
        ("^\\s*>\\s*", ""),
        ("^\\s*[-*+]\\s+", ""),
        ("^\\s*\\d+[.)]\\s+", ""),
        // Anything the writer escaped is shown as the character itself.
        ("\\\\([\\\\`*_\\[\\]~#>+.-])", "$1"),
    ]

    static func plain(_ line: String) -> String {
        var out = line
        for (pattern, replacement) in rules {
            out = out.replacingOccurrences(of: pattern, with: replacement,
                                           options: [.regularExpression])
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}

enum Tasks {
    static let open: Character = "\u{2610}"    // ☐
    static let done: Character = "\u{2611}"    // ☑
    static let openPrefix = "\u{2610} "
    static let donePrefix = "\u{2611} "

    static func marker(of line: some StringProtocol) -> Character? {
        guard let f = line.first, f == open || f == done else { return nil }
        return f
    }

    static func isTask(_ line: some StringProtocol) -> Bool { marker(of: line) != nil }

    /// Strip the marker for display in lists and titles.
    static func stripped(_ line: some StringProtocol) -> String {
        guard isTask(line) else { return String(line) }
        return String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    /// Markdown task syntax in, ☐/☑ out.
    static func fromMarkdown(_ text: String) -> String {
        text.replacingOccurrences(of: "^(\\s*)[-*]\\s+\\[[ ]\\]\\s+",
                                  with: "$1" + openPrefix,
                                  options: [.regularExpression])
            .replacingOccurrences(of: "^(\\s*)[-*]\\s+\\[[xX]\\]\\s+",
                                  with: "$1" + donePrefix,
                                  options: [.regularExpression])
    }

    /// The stored format itself, once, from the ☐/☑ glyphs to real Markdown.
    ///
    /// Storing the glyphs meant every read and write crossed a translation
    /// layer, and that layer was wrong: `fromMarkdown` anchors `^` without
    /// `.anchorsMatchLines`, so importing a checklist converted only its first
    /// line and left the rest as literal "- [ ]" text. Storing what the file
    /// format actually says removes the layer and the bug together.
    ///
    /// Line-based on purpose: `toMarkdown` replaces the prefix anywhere it
    /// appears, which would rewrite a ☐ that happens to sit mid-sentence.
    static func glyphsToMarkdown(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            let rest = line.dropFirst(indent.count)
            guard let mark = rest.first, mark == open || mark == done else { return String(line) }
            let body = rest.dropFirst().drop { $0 == " " }
            return "\(indent)- [\(mark == done ? "x" : " ")] \(body)"
        }.joined(separator: "\n")
    }

    /// ☐/☑ out, Markdown task syntax in.
    static func toMarkdown(_ text: String) -> String {
        text.replacingOccurrences(of: openPrefix, with: "- [ ] ")
            .replacingOccurrences(of: donePrefix, with: "- [x] ")
    }
}

// MARK: - Formatting

enum Fmt {
    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()

    static func ago(_ d: Date) -> String {
        if Date().timeIntervalSince(d) < 60 { return NSLocalizedString("just now", comment: "recent timestamp") }
        return relative.localizedString(for: d, relativeTo: Date())
    }
}
