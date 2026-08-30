import AppKit
import SwiftUI

/// A window for the settings, because a menu is a poor place to keep them.
///
/// They had accumulated into the deck's right-click menu: two submenus, four
/// checkmarks and the update controls, all of it invisible until you knew to
/// right-click a strip of tabs. A menu is for doing things; this is for
/// changing them, and it can show what a choice actually looks like.
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    var isOpen: Bool { window?.isVisible == true }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = NSLocalizedString("Noty Settings", comment: "window title")
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to an agent, so the Dock icon goes away again.
        DispatchQueue.main.async {
            if !LibraryWindow.shared.isOpen { NSApp.setActivationPolicy(.accessory) }
        }
    }
}

// MARK: - View

struct SettingsView: View {
    @State private var style = Settings.deckStyle
    @State private var onLeft = Settings.deckOnLeftEdge
    @State private var overFullScreen = Settings.showOverFullScreen
    @State private var face = Settings.noteFontName
    @State private var size = Settings.noteFontSize
    @State private var atLogin = Settings.launchAtLogin
    @State private var language = Settings.language
    @State private var languageChanged = false
    @State private var autoUpdate = Updater.shared.automaticallyChecks

    private func refresh() { (NSApp.delegate as? AppDelegate)?.refreshDecks() }

    /// A bundle reads its .lproj once, at launch, so the only honest way to
    /// show a new language is to start again. Open a fresh instance first,
    /// then quit this one, so the deck is never gone from the screen.
    private func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    var body: some View {
        Form {
            Section("The deck") {
                Picker("Style", selection: $style) {
                    ForEach(DeckStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .onChange(of: style) { _, v in Settings.deckStyle = v; refresh() }

                Picker("Edge", selection: $onLeft) {
                    Text("Right").tag(false)
                    Text("Left").tag(true)
                }
                .pickerStyle(.segmented)
                .onChange(of: onLeft) { _, v in Settings.deckOnLeftEdge = v; refresh() }

                Toggle("Show over full-screen apps", isOn: $overFullScreen)
                    .onChange(of: overFullScreen) { _, v in Settings.showOverFullScreen = v; refresh() }
            }

            Section("Notes") {
                // Each name is set in its own face: the point of choosing a
                // hand is what it looks like, so the list shows it.
                Picker("Hand", selection: $face) {
                    ForEach(Ink.faces, id: \.body) { f in
                        Text(f.name)
                            .font(NSFont(name: f.body, size: 13).map(Font.init) ?? .system(size: 13))
                            .tag(f.body)
                    }
                }
                .onChange(of: face) { _, v in Settings.noteFontName = v; refresh() }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Text size")
                        Spacer()
                        Text("\(Int(size)) pt")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $size, in: Settings.fontRange, step: 0.5)
                        .onChange(of: size) { _, v in Settings.noteFontSize = v; refresh() }
                    Text("The quick brown fox")
                        .font(Font(Ink.body(size)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.top, 2)
                }
            }

            Section("General") {
                Picker("Language", selection: $language) {
                    // Each name in its own language: that is what someone
                    // scanning for theirs will recognise. "System" is first
                    // because following the Mac is the right default.
                    ForEach(Settings.languages, id: \.id) { lang in
                        Text(lang.id.isEmpty ? String(localized: "System") : lang.name)
                            .tag(lang.id)
                    }
                }
                .onChange(of: language) { _, v in
                    Settings.language = v
                    languageChanged = true
                }

                if languageChanged {
                    HStack {
                        Text("Takes effect after relaunching.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Relaunch") { relaunch() }
                            .controlSize(.small)
                    }
                }

                Toggle("Launch at login", isOn: $atLogin)
                    .onChange(of: atLogin) { _, v in Settings.launchAtLogin = v }

                LabeledContent("Shortcuts") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("⌥⌘N  new note")
                        Text("⌥⌘A  all notes")
                        Text("⌥⌘L  archive")
                    }
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }

            if Updater.available {
                Section("Updates") {
                    Toggle("Check automatically", isOn: $autoUpdate)
                        .onChange(of: autoUpdate) { _, v in Updater.shared.automaticallyChecks = v }
                    Button("Check for Updates…") { Updater.shared.checkForUpdates() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
    }
}
