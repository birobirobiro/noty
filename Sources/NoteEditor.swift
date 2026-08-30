import SwiftUI
import AppKit

// MARK: - Bridge to the underlying NSTextView (used for ⌘F)

final class EditorBridge: ObservableObject {
    weak var textView: NSTextView?
    @Published var matchCount = 0

    func recount(_ q: String) {
        guard let tv = textView, !q.isEmpty else { matchCount = 0; return }
        let ns = tv.string as NSString
        var count = 0, loc = 0
        while loc < ns.length {
            let r = ns.range(of: q, options: [.caseInsensitive],
                             range: NSRange(location: loc, length: ns.length - loc))
            if r.location == NSNotFound { break }
            count += 1
            loc = r.location + max(1, r.length)
        }
        matchCount = count
    }

    func findNext(_ q: String, forward: Bool = true) {
        guard let tv = textView, !q.isEmpty else { return }
        let ns = tv.string as NSString
        let sel = tv.selectedRange()
        var found: NSRange

        if forward {
            let start = min(ns.length, NSMaxRange(sel))
            found = ns.range(of: q, options: [.caseInsensitive],
                             range: NSRange(location: start, length: ns.length - start))
            if found.location == NSNotFound {
                found = ns.range(of: q, options: [.caseInsensitive])   // wrap
            }
        } else {
            found = ns.range(of: q, options: [.caseInsensitive, .backwards],
                             range: NSRange(location: 0, length: sel.location))
            if found.location == NSNotFound {
                found = ns.range(of: q, options: [.caseInsensitive, .backwards])
            }
        }
        guard found.location != NSNotFound else { return }
        tv.setSelectedRange(found)
        tv.scrollRangeToVisible(found)
        tv.showFindIndicator(for: found)
    }

    /// Turn the caret's line into a task, or strip the checkbox back off it.
    func toggleTaskLine() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let ns = tv.string as NSString
        let caret = min(tv.selectedRange().location, ns.length)
        let line = ns.lineRange(for: NSRange(location: caret, length: 0))
        let text = ns.substring(with: line)

        if Tasks.isTask(text) {
            var length = 1
            if line.length > 1, ns.character(at: line.location + 1) == 32 { length = 2 }
            let range = NSRange(location: line.location, length: length)
            guard tv.shouldChangeText(in: range, replacementString: "") else { return }
            storage.replaceCharacters(in: range, with: "")
        } else {
            let range = NSRange(location: line.location, length: 0)
            guard tv.shouldChangeText(in: range, replacementString: Tasks.openPrefix) else { return }
            storage.replaceCharacters(in: range, with: Tasks.openPrefix)
        }
        tv.didChangeText()
    }

    func focusText() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
    }
}

// MARK: - NSTextView wrapper

/// Text view that treats a leading ☐ / ☑ as a real checkbox: clicking the box
/// toggles it, Return carries the list on, and finished lines get struck through.
final class TaskTextView: NSTextView {

    /// Asked for the keyboard before it had a window to ask.
    var wantsInitialFocus = false

    /// The one moment when taking focus can actually work. `makeNSView` runs
    /// while the view is still detached, so the old `tv.window?.makeFirstResponder`
    /// there resolved `window` to nil and did nothing at all — quietly, because
    /// of the `?`. A window arrives here, and a panel that is not key yet still
    /// remembers the responder it was given.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard wantsInitialFocus, let window else { return }
        wantsInitialFocus = false
        DeckLog.line("note text entered a window — claiming focus")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            window.makeFirstResponder(self)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if toggleBox(at: point) { return }
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let lm = layoutManager, let tc = textContainer else { return }
        let ns = string as NSString
        let origin = textContainerOrigin
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: .byLines) { sub, range, _, _ in
            guard let sub, Tasks.isTask(sub) else { return }
            let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: range.location, length: 1),
                                       actualCharacterRange: nil)
            var r = lm.boundingRect(forGlyphRange: glyphs, in: tc)
            r.origin.x += origin.x
            r.origin.y += origin.y
            self.addCursorRect(r.insetBy(dx: -3, dy: -2), cursor: .pointingHand)
        }
    }

    /// Returns true when the click landed on a checkbox and was consumed.
    private func toggleBox(at point: NSPoint) -> Bool {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage else { return false }
        let ns = string as NSString
        guard ns.length > 0 else { return false }

        let index = min(characterIndexForInsertion(at: point), max(0, ns.length - 1))
        let line = ns.lineRange(for: NSRange(location: index, length: 0))
        guard line.length > 0 else { return false }
        let first = ns.character(at: line.location)
        guard first == Tasks.open.unicodeScalars.first!.value ||
              first == Tasks.done.unicodeScalars.first!.value else { return false }

        let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: line.location, length: 1),
                                   actualCharacterRange: nil)
        var box = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        box.origin.x += textContainerOrigin.x
        box.origin.y += textContainerOrigin.y
        guard box.insetBy(dx: -4, dy: -3).contains(point) else { return false }

        let target = NSRange(location: line.location, length: 1)
        let flipped = String(first == Tasks.open.unicodeScalars.first!.value ? Tasks.done : Tasks.open)
        guard shouldChangeText(in: target, replacementString: flipped) else { return true }
        storage.replaceCharacters(in: target, with: flipped)
        didChangeText()
        return true
    }
}

struct NoteTextView: NSViewRepresentable {
    @Binding var text: String
    let ink: NSColor
    let bridge: EditorBridge
    var autofocus: Bool
    var fontSize: CGFloat = 13.5

    static func bodyFont(_ size: CGFloat) -> NSFont { Ink.body(size) }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let tv = TaskTextView()
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = Self.bodyFont(fontSize)
        tv.textColor = ink
        tv.insertionPointColor = ink
        tv.textContainerInset = NSSize(width: 15, height: 6)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isContinuousSpellCheckingEnabled = true
        tv.string = text

        scroll.documentView = tv
        bridge.textView = tv
        Self.styleTasks(tv, ink: ink, size: fontSize)
        if autofocus { tv.wantsInitialFocus = true }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text {
            tv.string = text
            Self.styleTasks(tv, ink: ink, size: fontSize)
        }
        let want = Self.bodyFont(fontSize)
        if tv.textColor != ink || tv.font != want {
            tv.textColor = ink
            tv.insertionPointColor = ink
            tv.font = want
            Self.styleTasks(tv, ink: ink, size: fontSize)
        }
        if bridge.textView !== tv { bridge.textView = tv }
    }

    /// Dim and strike through anything already ticked off.
    /// Restyling touches the whole document, which happens on every keystroke.
    /// Two things make that safe: the caret has to be put back afterwards, and
    /// `typingAttributes` has to be refreshed — otherwise the next character is
    /// inserted in the *previous* font and immediately rewritten, which reads as
    /// the text jumping under the cursor after a font or size change.
    static func styleTasks(_ tv: NSTextView, ink: NSColor, size: CGFloat = 13.5) {
        let font = bodyFont(size)
        tv.typingAttributes = [.font: font, .foregroundColor: ink]

        guard let storage = tv.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0 else { return }
        let caret = tv.selectedRange()
        storage.beginEditing()
        storage.removeAttribute(.strikethroughStyle, range: full)
        storage.addAttribute(.foregroundColor, value: ink, range: full)
        storage.addAttribute(.font, value: font, range: full)
        let ns = storage.string as NSString
        ns.enumerateSubstrings(in: full, options: .byLines) { sub, range, _, _ in
            guard let sub, Tasks.marker(of: sub) == Tasks.done else { return }
            storage.addAttribute(.strikethroughStyle,
                                 value: NSUnderlineStyle.single.rawValue, range: range)
            storage.addAttribute(.foregroundColor,
                                 value: ink.withAlphaComponent(0.45), range: range)
        }
        storage.endEditing()
        let end = (storage.string as NSString).length
        tv.setSelectedRange(NSRange(location: min(caret.location, end),
                                    length: min(caret.length, end - min(caret.location, end))))
        tv.window?.invalidateCursorRects(for: tv)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: NoteTextView
        init(_ p: NoteTextView) { parent = p }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            NoteTextView.styleTasks(tv, ink: parent.ink, size: parent.fontSize)
            parent.text = tv.string
        }

        /// Return on a task line starts the next task; on an empty one, ends the list.
        func textView(_ tv: NSTextView, shouldChangeTextIn range: NSRange,
                      replacementString replacement: String?) -> Bool {
            guard replacement == "\n" else { return true }
            let ns = tv.string as NSString
            guard range.location <= ns.length else { return true }
            let line = ns.lineRange(for: NSRange(location: range.location, length: 0))
            let text = ns.substring(with: line)
            guard Tasks.isTask(text) else { return true }

            if Tasks.stripped(text.trimmingCharacters(in: .newlines)).isEmpty {
                let clear = NSRange(location: line.location,
                                    length: min(line.length, ns.length - line.location))
                if tv.shouldChangeText(in: clear, replacementString: "") {
                    tv.textStorage?.replaceCharacters(in: clear, with: "")
                    tv.didChangeText()
                }
                return false
            }
            tv.insertText("\n" + Tasks.openPrefix, replacementRange: range)
            return false
        }
    }
}

// MARK: - Editor

struct NoteEditorView: View {
    let note: Note
    @ObservedObject var deck: DeckModel
    unowned let controller: DeckController

    @State private var text = ""
    @State private var saveWork: DispatchWorkItem?
    @State private var savedAt: Date?
    @FocusState private var findFocused: Bool

    /// The note passed in is a snapshot. Locking changes the store, and the
    /// gate has to notice, so read the live row for anything lock-related.
    @ObservedObject private var store = NoteStore.shared

    enum GateMode { case unlock, set, remove }
    @State private var gateMode: GateMode?
    @State private var pass1 = ""
    @State private var pass2 = ""
    @State private var gateError = ""
    @State private var confirmingDelete = false
    @State private var findCount = 0
    @State private var findAt = 0

    enum GateField { case first, second }
    @FocusState private var gateFocus: GateField?

    private var pal: NoteColor { note.palette }

    private func step(_ delta: Int) {
        guard findCount > 0 else { return }
        findAt = (findAt + delta + findCount) % findCount
        NoteFind.run(deck.findQuery ?? "", index: findAt)
    }

    private var live: Note { store.note(id: note.id) ?? note }
    /// Locked and not opened during this run: the text is not in memory at all.
    private var sealed: Bool { live.locked && !store.isRevealed(note.id) }

    var body: some View {
        sheet
        .background(
            noteShape
                .fill(LinearGradient(colors: [pal.paper, pal.paper.opacity(0.88)],
                                     startPoint: .top, endPoint: .bottom))
        )
        .clipShape(noteShape)
        .overlay(noteShape.strokeBorder(Color.black.opacity(0.07), lineWidth: 0.5))
        .onAppear {
            text = sealed ? "" : live.body
            savedAt = note.modified
        }
        .onChange(of: text) { _, v in
            controller.noteActivity()
            scheduleSave(v)
        }
        .onChange(of: deck.findQuery) { _, q in
            if q != nil { findFocused = true } else { NoteFind.clear(); NoteWindow.focusText(in: NoteWindow.shared.contentView) }
        }
        .onDisappear {
            confirmingDelete = false   // never reopen mid-question
            flush()
            // Shut a locked note behind us: the key and the text both leave
            // memory, so reopening asks for the password again.
            if live.locked { store.conceal(id: note.id); text = "" }
        }
    }

    /// Rounded all the way round: nothing is against the screen edge any more.
    /// `edgeTabShape` stays as it is — the tabs still meet the bezel and must
    /// keep their square side.
    private var noteShape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }

    // MARK: The note itself

    private var sheet: some View {
        VStack(spacing: 0) {
            header
            if deck.findQuery != nil && !sealed && gateMode == nil { findBar }
            if sealed || gateMode != nil {
                gate
            } else {
                NoteFormatBar(ink: pal.ink)
                NoteMarkdownEditor(text: $text, note: note)
            }
            footer
        }
        .overlay {
            if confirmingDelete { deleteConfirm }
        }
    }

    private var deleteConfirm: some View {
        VStack(spacing: 8) {
            Image(systemName: "trash")
                .font(.system(size: 20))
                .foregroundStyle(pal.ink.opacity(0.55))
            Text("Delete this note?")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(pal.ink.opacity(0.9))
            Text("You will have ten seconds to undo it.")
                .font(.system(size: 10.5))
                .foregroundStyle(pal.ink.opacity(0.55))
            HStack(spacing: 8) {
                Button("Cancel") { confirmingDelete = false }
                    .buttonStyle(.plain)
                    .foregroundStyle(pal.ink.opacity(0.6))
                Button("Delete") {
                    confirmingDelete = false
                    NoteStore.shared.delete(id: note.id)
                    controller.collapse()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(nsColor: .systemRed))
            }
            .font(.system(size: 11.5))
            .padding(.top, 2)
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(pal.paper)
            .shadow(color: .black.opacity(0.28), radius: 18, y: 8))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(pal.ink.opacity(0.12), lineWidth: 1))
        .padding(.horizontal, 26)
    }

    // MARK: The lock

    private var gate: some View {
        let mode = gateMode ?? .unlock
        return VStack(spacing: 9) {
            Image(systemName: mode == .unlock ? "lock.fill" : "lock.open.fill")
                .font(.system(size: 22))
                .foregroundStyle(pal.ink.opacity(0.55))
            Text(gateTitle(mode))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(pal.ink.opacity(0.9))
            Text(gateHint(mode))
                .font(.system(size: 10.5))
                .foregroundStyle(pal.ink.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
            // The system field style paints its own white (or near-black)
            // box, which lands on a pastel sheet looking like a hole cut in
            // the paper. Dress it in the note's own ink instead.
            gateField("Password", text: $pass1).focused($gateFocus, equals: .first)
            if mode == .set {
                gateField("Repeat", text: $pass2).focused($gateFocus, equals: .second)
            }
            if !gateError.isEmpty {
                Text(gateError)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color(nsColor: .systemRed))
            }
            HStack(spacing: 8) {
                if mode != .unlock {
                    Button("Cancel") { closeGate() }.buttonStyle(.plain)
                        .foregroundStyle(pal.ink.opacity(0.6))
                }
                Button(mode == .unlock ? "Open" : (mode == .set ? "Lock" : "Remove")) { submitGate() }
                    .buttonStyle(.borderedProminent)
                    .tint(pal.ink.opacity(0.75))
            }
            .font(.system(size: 11.5))
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A non-activating panel is not key at the instant the gate appears,
        // and focus asked for before the window can take the keyboard is
        // simply dropped. One turn of the loop later, it sticks.
        .onAppear {
            DispatchQueue.main.async { gateFocus = .first }
        }
        // SwiftUI's key-view loop does not carry Tab between these fields
        // inside a borderless panel, so move it by hand.
        .onKeyPress(.tab) {
            guard mode == .set else { return .ignored }
            gateFocus = (gateFocus == .first) ? .second : .first
            return .handled
        }
    }

    private func gateField(_ prompt: String, text: Binding<String>) -> some View {
        SecureField("", text: text, prompt: Text(prompt).foregroundColor(pal.ink.opacity(0.4)))
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(pal.ink)
            .padding(.horizontal, 10)
            .frame(width: 200, height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(pal.ink.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(pal.ink.opacity(0.2), lineWidth: 1))
            .onSubmit(submitGate)
    }

    private func gateTitle(_ m: GateMode) -> LocalizedStringKey {
        switch m {
        case .unlock: return "This note is locked"
        case .set:    return "Put a password on this note"
        case .remove: return "Remove the password"
        }
    }

    private func gateHint(_ m: GateMode) -> LocalizedStringKey {
        switch m {
        case .unlock: return "The text is sealed with your password and cannot be recovered without it."
        case .set:    return "There is no way to reset this. Forget it and the note is gone for good."
        case .remove: return "The note goes back to being stored the ordinary way."
        }
    }

    private func submitGate() {
        let mode = gateMode ?? .unlock
        switch mode {
        case .unlock:
            guard store.unlock(id: note.id, password: pass1) else {
                gateError = "Wrong password."; pass1 = ""; return
            }
            text = store.note(id: note.id)?.body ?? ""
            closeGate()
        case .set:
            guard pass1.count >= 4 else { gateError = "At least four characters."; return }
            guard pass1 == pass2 else { gateError = "The two do not match."; pass2 = ""; return }
            flush()   // the text on screen is what gets sealed
            guard store.lock(id: note.id, password: pass1) else {
                gateError = "Could not lock this note."; return
            }
            closeGate()
        case .remove:
            guard store.removeLock(id: note.id, password: pass1) else {
                gateError = "Wrong password."; pass1 = ""; return
            }
            text = store.note(id: note.id)?.body ?? ""
            closeGate()
        }
    }

    private func closeGate() {
        gateMode = nil; pass1 = ""; pass2 = ""; gateError = ""
        NoteWindow.focusText(in: NoteWindow.shared.contentView)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(note.displayTitle)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(pal.ink.opacity(0.92))
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(savedAt.map { "Saved · \(Fmt.ago($0))" } ?? "Not saved")
                .font(.system(size: 10))
                .foregroundStyle(pal.ink.opacity(0.42))
            Button { NoteStore.shared.togglePin(id: note.id) } label: {
                Image(systemName: note.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(note.pinned ? 0 : 32))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(pal.ink.opacity(note.pinned ? 0.85 : 0.4))
            .help(note.pinned ? "Unpin — ⌘P" : "Pin so it stays open  ⌘P")

            Button { deck.findQuery = deck.findQuery == nil ? "" : nil } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10.5, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(pal.ink.opacity(0.5))
            .help("Find  ⌘F")
            Button {
                gateMode = live.locked ? .remove : .set
                pass1 = ""; pass2 = ""; gateError = ""
            } label: {
                Image(systemName: live.locked ? "lock.fill" : "lock")
                    .font(.system(size: 10.5, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(pal.ink.opacity(live.locked ? 0.85 : 0.5))
            .help(live.locked ? "Remove the password" : "Lock this note")
            .accessibilityLabel(live.locked ? "Remove the password" : "Lock this note")
            .disabled(sealed)
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
    }

    private var findBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10)).foregroundStyle(pal.ink.opacity(0.45))
            TextField("Find in note", text: Binding(
                get: { deck.findQuery ?? "" },
                set: { deck.findQuery = $0; findAt = 0; NoteFind.run($0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(pal.ink)
                .focused($findFocused)
                .onSubmit { step(1) }
            Text(findCount == 0 ? "—" : "\(findAt + 1)/\(findCount)")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(pal.ink.opacity(0.45))
            Button { step(-1) } label: {
                Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold))
            }.buttonStyle(.plain).foregroundStyle(pal.ink.opacity(0.55))
            .accessibilityLabel("Previous match")
            Button { step(1) } label: {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }.buttonStyle(.plain).foregroundStyle(pal.ink.opacity(0.55))
            .accessibilityLabel("Next match")
        }
        // The engine answers every query with how many it found.
        .onReceive(NotificationCenter.default.publisher(for: .notyFindResults)) {
            findCount = ($0.userInfo?["count"] as? Int) ?? 0
            if findAt >= findCount { findAt = 0 }
        }
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(pal.dash.opacity(0.12))
    }

    private var footer: some View {
        HStack(spacing: 7) {
            ForEach(Array(NoteColor.all.enumerated()), id: \.offset) { idx, c in
                Button { NoteStore.shared.setColor(id: note.id, color: idx) } label: {
                    Circle()
                        .fill(c.dash)
                        .frame(width: 11, height: 11)
                        .overlay(
                            Circle().strokeBorder(pal.ink.opacity(0.55),
                                                  lineWidth: idx == note.color ? 1.5 : 0)
                                .padding(-2.5)
                        )
                        .padding(2)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(c.name)
            }
            Spacer(minLength: 8)
            footerButton("Archive") {
                NoteStore.shared.setArchived(id: note.id, true)
                controller.collapse()
            }
            footerButton("Delete") { confirmingDelete = true }
            footerButton("Close") { controller.collapse() }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    private func footerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(pal.ink.opacity(0.72))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(pal.ink.opacity(0.08))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Autosave — 250 ms after typing stops

    private func scheduleSave(_ value: String) {
        saveWork?.cancel()
        let work = DispatchWorkItem {
            NoteStore.shared.updateBody(id: note.id, body: value)
            savedAt = Date()
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func flush() {
        saveWork?.cancel()
        NoteStore.shared.updateBody(id: note.id, body: text)
    }
}
