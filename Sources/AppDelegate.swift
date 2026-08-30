import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var deckManager: DeckManager!
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMainMenu()

        deckManager = DeckManager()
        buildStatusItem()
        UndoToast.shared.start()

        HotKeys.shared.register(
            newNote: { [weak self] in self?.newNote() },
            allNotes: { [weak self] in self?.openAllNotes() },
            archive:  { [weak self] in self?.openArchive() }
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeys.shared.unregisterAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }


    // MARK: The menu

    /// Everything the app can do, in one place. The deck's right-click and the
    /// status item both show this, so they cannot drift apart.
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        populate(menu)
        return menu
    }

    /// Rebuilt every time it opens, so the ticks and the enabled states are
    /// telling the truth rather than whatever they said last time.
    func menuNeedsUpdate(_ menu: NSMenu) { populate(menu) }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        // Doing, not configuring: everything that was a checkmark or a submenu
        // of preferences now lives in the settings window, where a choice can
        // show what it looks like instead of being a tick in a list.
        menu.addItem(withTitle: NSLocalizedString("New Note", comment: ""), action: #selector(AppDelegate.newNote), keyEquivalent: "")
        menu.addItem(withTitle: NSLocalizedString("All Notes", comment: ""), action: #selector(AppDelegate.openAllNotes), keyEquivalent: "")
        menu.addItem(withTitle: NSLocalizedString("Archive", comment: ""), action: #selector(AppDelegate.openArchive), keyEquivalent: "")
        menu.addItem(.separator())

        let exportItem = NSMenuItem(title: NSLocalizedString("Export", comment: ""), action: nil, keyEquivalent: "")
        let exportMenu = NSMenu()
        exportMenu.addItem(withTitle: NSLocalizedString("Markdown (one file per note)…", comment: ""),
                           action: #selector(AppDelegate.exportMarkdown), keyEquivalent: "")
        exportMenu.addItem(withTitle: NSLocalizedString("Plain text (one file per note)…", comment: ""),
                           action: #selector(AppDelegate.exportPlainText), keyEquivalent: "")
        exportMenu.addItem(withTitle: NSLocalizedString("Single document…", comment: ""),
                           action: #selector(AppDelegate.exportSingleFile), keyEquivalent: "")
        exportMenu.addItem(withTitle: NSLocalizedString("Sticky archive (.stickies)…", comment: ""),
                           action: #selector(AppDelegate.exportStickies), keyEquivalent: "")
        exportItem.submenu = exportMenu
        menu.addItem(exportItem)
        menu.addItem(withTitle: NSLocalizedString("Import…", comment: ""), action: #selector(AppDelegate.importStickies), keyEquivalent: "")
        menu.addItem(.separator())

        menu.addItem(withTitle: NSLocalizedString("Settings…", comment: ""), action: #selector(AppDelegate.openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: NSLocalizedString("About Noty", comment: ""), action: #selector(AppDelegate.showAbout), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: NSLocalizedString("Quit Noty", comment: ""), action: #selector(AppDelegate.quit), keyEquivalent: "")

        for item in menu.items where item.action != nil {
            item.target = NSApp.delegate
        }
    }

    @objc func openSettings() { SettingsWindow.shared.show() }

    /// Settings reach the decks through here.
    func refreshDecks() { deckManager.refreshAll() }

    /// An app with no Dock icon needs somewhere to be found. Without this the
    /// only way to reach settings or the note list was a right-click on the
    /// deck, which you have to already know about.
    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "note.text",
                                     accessibilityDescription: "Noty")
        item.button?.image?.isTemplate = true   // follows the menu bar, light or dark
        item.button?.toolTip = "Noty"
        item.menu = makeMenu()
        statusItem = item
    }

    // MARK: Actions

    @objc func newNote() {
        let note = NoteStore.shared.create()
        deckManager.focused?.expand(note.id)
    }

    @objc func openAllNotes() { LibraryWindow.shared.show(mode: .all) }
    @objc func openArchive() { LibraryWindow.shared.show(mode: .archived) }

    @objc func toggleOverFullScreen() {
        Settings.showOverFullScreen.toggle()
        deckManager.refreshAll()
    }

    @objc func setDeckStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = DeckStyle(rawValue: raw) else { return }
        Settings.deckStyle = style
        deckManager.refreshAll()
    }

    @objc func setFontSize(_ sender: NSMenuItem) {
        guard let size = sender.representedObject as? Double else { return }
        Settings.noteFontSize = size
        deckManager.refreshAll()
    }

    /// ⌃+ / ⌃- while a note is open.
    func stepFontSize(by delta: Double) {
        Settings.noteFontSize += delta
        deckManager.refreshAll()
    }

    @objc func biggerText()  { stepFontSize(by: 1.5) }
    @objc func smallerText() { stepFontSize(by: -1.5) }

    @objc func setNoteFace(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Settings.noteFace = id
        deckManager.refreshAll()
    }

    @objc func toggleDeckEdge() {
        Settings.deckOnLeftEdge.toggle()
        deckManager.refreshAll()
    }

    @objc func toggleLaunchAtLogin() {
        Settings.launchAtLogin.toggle()
    }

    @objc func exportMarkdown()  { Transfer.export(.markdown,  notes: NoteStore.shared.notes) }
    @objc func exportPlainText() { Transfer.export(.plainText, notes: NoteStore.shared.notes) }
    @objc func exportSingleFile(){ Transfer.export(.singleFile, notes: NoteStore.shared.notes) }
    @objc func exportStickies()  { Transfer.export(.stickies,  notes: NoteStore.shared.notes) }
    @objc func importStickies()  { Transfer.importFiles() }

    @objc func checkForUpdates() { Updater.shared.checkForUpdates() }

    @objc func toggleAutoUpdates() {
        Updater.shared.automaticallyChecks.toggle()
    }

    @objc func quit() { NSApp.terminate(nil) }

    @objc func showAbout() {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = "Noty"
        a.informativeText = """
        Sticky notes docked to the edge of your screen.

        ⌥⌘N  new note      ⌥⌘A  all notes      ⌥⌘L  archive
        In a note — Esc closes, ⌘F finds, ⌘. cycles the colour.

        Notes are stored locally in an SQLite database; bodies are encrypted \
        with AES-GCM. Your notes never leave this Mac — the only network request \
        the app makes is the update check, which you can switch off.
        """
        a.runModal()
    }

    // MARK: Main menu
    //
    // An accessory app draws no menu bar, but NSApp.mainMenu is still what
    // dispatches ⌘C/⌘V/⌘Z inside the note editor — without it, text editing
    // loses every standard shortcut.

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: NSLocalizedString("About Noty", comment: ""), action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(withTitle: NSLocalizedString("Settings…", comment: ""), action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(withTitle: NSLocalizedString("Check for Updates…", comment: ""), action: #selector(checkForUpdates), keyEquivalent: "")
        appMenu.addItem(.separator())
        // Held onto rather than found again by title further down: once these
        // titles are translated, item(withTitle:) stops matching, the ⌥ mask
        // below is never applied, and ⌘N / ⌘A / ⌘L quietly go back to
        // shadowing typing in text fields — the exact thing it prevents.
        let newItem = appMenu.addItem(withTitle: NSLocalizedString("New Note", comment: "menu"),
                                      action: #selector(newNote), keyEquivalent: "n")
        let allItem = appMenu.addItem(withTitle: NSLocalizedString("All Notes", comment: "menu"),
                                      action: #selector(openAllNotes), keyEquivalent: "a")
        let archiveItem = appMenu.addItem(withTitle: NSLocalizedString("Archive", comment: "menu"),
                                          action: #selector(openArchive), keyEquivalent: "l")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: NSLocalizedString("Import…", comment: ""), action: #selector(importStickies), keyEquivalent: "i")
        appMenu.addItem(.separator())
        let bigger = appMenu.addItem(withTitle: NSLocalizedString("Bigger Text", comment: ""), action: #selector(biggerText), keyEquivalent: "+")
        bigger.keyEquivalentModifierMask = [.control]
        let smaller = appMenu.addItem(withTitle: NSLocalizedString("Smaller Text", comment: ""), action: #selector(smallerText), keyEquivalent: "-")
        smaller.keyEquivalentModifierMask = [.control]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: NSLocalizedString("Hide Noty", comment: ""), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: NSLocalizedString("Quit Noty", comment: ""), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        // The three global shortcuts already carry ⌥; mirror that here so the menu
        // items do not shadow ⌘N / ⌘A / ⌘L inside text fields.
        for item in [newItem, allItem, archiveItem] {
            item.keyEquivalentModifierMask = [.command, .option]
        }
        for item in appMenu.items where item.action != nil
            && item.action != #selector(NSApplication.hide(_:))
            && item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: NSLocalizedString("Undo", comment: ""), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: NSLocalizedString("Redo", comment: ""), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: NSLocalizedString("Cut", comment: ""), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: NSLocalizedString("Copy", comment: ""), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: NSLocalizedString("Paste", comment: ""), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: NSLocalizedString("Select All", comment: ""), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }
}
