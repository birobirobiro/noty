import Foundation
import ServiceManagement

/// Thin UserDefaults wrapper for the handful of togglable preferences.
enum Settings {
    private static let d = UserDefaults.standard

    static var showOverFullScreen: Bool {
        get { d.object(forKey: "showOverFullScreen") as? Bool ?? false }
        set { d.set(newValue, forKey: "showOverFullScreen") }
    }

    static var deckOnLeftEdge: Bool {
        get { d.bool(forKey: "deckOnLeftEdge") }
        set { d.set(newValue, forKey: "deckOnLeftEdge") }
    }

    /// Max tabs the fan shows before collapsing the remainder into "+N".
    /// Five keeps every tab at full size instead of squeezing the deck.
    static let fanLimit = 5

    /// Body text size inside a note.
    static let fontSizes: [(name: String, size: Double)] = [
        ("Small", 12), ("Medium", 13.5), ("Large", 15.5), ("Extra Large", 18)
    ]

    static let fontRange: ClosedRange<Double> = 10...30

    static var noteFontSize: Double {
        get {
            let v = d.double(forKey: "noteFontSize")
            return fontRange.contains(v) ? v : 13.5
        }
        set { d.set(min(max(newValue, fontRange.lowerBound), fontRange.upperBound),
                    forKey: "noteFontSize") }
    }

    /// PostScript name of the face note bodies are set in; empty means the
    /// system font. Defaults to a hand, the way a sticky note actually looks.
    static var noteFontName: String {
        get {
            if let v = d.string(forKey: "noteFontName") { return v }
            // migrate the old boolean
            let hand = d.object(forKey: "handwrittenBody") as? Bool ?? true
            return hand ? "Noteworthy-Light" : ""
        }
        set { d.set(newValue, forKey: "noteFontName") }
    }

    /// How long the deck may sit untouched before it tidies itself away.
    static let fanIdleTimeout: TimeInterval = 4
    static let noteIdleTimeout: TimeInterval = 60

    /// Labelled tabs, or bare colour chips that barely touch the screen.
    static var deckStyle: DeckStyle {
        get { DeckStyle(rawValue: d.string(forKey: "deckStyle") ?? "") ?? .tabs }
        set { d.set(newValue.rawValue, forKey: "deckStyle") }
    }

    /// The language the app is read in. Empty means "whatever the Mac is set
    /// to", which is what almost everyone wants and what macOS does by default.
    ///
    /// This writes AppleLanguages, the per-app override macOS itself uses (the
    /// same thing System Settings ▸ General ▸ Language & Region ▸ Applications
    /// writes). The bundle picks its .lproj at launch, so a change only shows
    /// after a relaunch — the settings window says so and offers to do it.
    static var language: String {
        get { d.string(forKey: "notyLanguage") ?? "" }
        set {
            d.set(newValue, forKey: "notyLanguage")
            if newValue.isEmpty {
                d.removeObject(forKey: "AppleLanguages")
            } else {
                d.set([newValue], forKey: "AppleLanguages")
            }
        }
    }

    /// The languages the app actually ships, named in themselves — an endonym
    /// is what someone looking for their own language will recognise, and it is
    /// never translated.
    static let languages: [(id: String, name: String)] = [
        ("",      "System"),
        ("en",    "English"),
        ("pt-BR", "Português (Brasil)"),
        ("es",    "Español"),
    ]

    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Noty: launch-at-login toggle failed — \(error.localizedDescription)")
            }
        }
    }
}
