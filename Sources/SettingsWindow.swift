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
    @State private var face = Settings.noteFace
    @State private var size = Settings.noteFontSize
    @State private var atLogin = Settings.launchAtLogin
    @State private var autoUpdate = Updater.shared.automaticallyChecks

    private func refresh() { (NSApp.delegate as? AppDelegate)?.refreshDecks() }

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
                    ForEach(Ink.faces) { f in
                        Text(f.name)
                            .font(f.regular.flatMap { NSFont(name: $0, size: 13) }.map(Font.init)
                                  ?? .system(size: 13))
                            .tag(f.id)
                    }
                }
                .onChange(of: face) { _, v in Settings.noteFace = v; refresh() }

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
