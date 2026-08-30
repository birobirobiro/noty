import AppKit
import SwiftUI

/// An open note is its own window.
///
/// It used to be a subview of the deck's panel, which meant it could only ever
/// live inside that panel's rectangle: it could not be dragged to a second
/// display, could not go above the visible frame, and did not exist to Mission
/// Control or Stage Manager. Moving it "worked" only because the panel had been
/// stretched across the whole screen to fake a middle for it to sit in.
///
/// As its own panel it gets all of that from AppKit for free, and the deck's
/// panel goes back to being the width of the deck.
final class NotePanel: NSPanel {
    // Without this an expanded note silently refuses keystrokes.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0,
                                       width: DeckGeom.editorWidth, height: DeckGeom.editorHeight),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        // AppKit derives the shadow from the rendered alpha, so the rounded
        // card casts a correct one. A SwiftUI shadow would be clipped at the
        // window's edge instead.
        hasShadow = true
        // The whole card is the handle. Controls and the text view take their
        // own clicks first, so this never fights typing or a button.
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        applyLevel()
    }

    func applyLevel() {
        level = Settings.showOverFullScreen ? .statusBar : .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }
}

/// Hosts the note and says, with the cursor, that the card can be moved.
///
/// `isMovableByWindowBackground` runs its drag loop inside `mouseDown`, so the
/// closed hand set before `super` stays up for the whole drag and the open hand
/// comes back when it returns. This view only ever sees `mouseDown` when no
/// control and not the text view wanted it — which is exactly when a drag is
/// about to happen, so the cursor never lies.
final class NoteHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) { super.init(rootView: rootView) }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Same reason as DeckHostingView: the note is used while another app is
    /// frontmost, so a click must act rather than be spent activating us.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        NSCursor.closedHand.set()
        super.mouseDown(with: event)
        NSCursor.openHand.set()
    }

    override func mouseEntered(with event: NSEvent) { NSCursor.openHand.set() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
}

final class NoteWindow {
    static let shared = NoteWindow()
    private var panel: NotePanel?
    private(set) var showing: String?

    /// Opens `note` centred on `screen`, or brings the open one to that note.
    func show(_ note: Note, deck: DeckModel, controller: DeckController, on screen: NSScreen?) {
        let p = panel ?? {
            let fresh = NotePanel()
            panel = fresh
            return fresh
        }()
        p.applyLevel()
        // DeckHostingView, not NSHostingView: it acts on the first click into
        // an inactive panel, which is the normal case here — the note is used
        // while another app is frontmost.
        p.contentView = NoteHostingView(
            rootView: NoteEditorView(note: note, deck: deck, controller: controller))

        // Centre when there is no sensible place to reuse. Moving the note is
        // a deliberate act and undoing it on every open would be worse than
        // the alternative — but a frame left on a display that is now
        // unplugged, or dragged almost entirely off-screen, is not a place to
        // put it back, so those recentre.
        if showing == nil || !isUsable(p.frame), let screen {
            let v = screen.visibleFrame
            p.setFrame(NSRect(x: v.midX - DeckGeom.editorWidth / 2,
                              y: v.midY - DeckGeom.editorHeight / 2,
                              width: DeckGeom.editorWidth, height: DeckGeom.editorHeight),
                       display: false)
        }
        showing = note.id

        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup {
            $0.duration = 0.16
            p.animator().alphaValue = 1
        }
    }

    /// Enough of the card visible on some current screen to grab hold of.
    private func isUsable(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { screen in
            let shown = screen.visibleFrame.intersection(frame)
            return shown.width > 120 && shown.height > 80
        }
    }

    func close() {
        guard let panel, showing != nil else { return }
        showing = nil
        panel.orderOut(nil)
    }
}
