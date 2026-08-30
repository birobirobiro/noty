import SwiftUI
import AppKit

// MARK: - Bridge to the underlying NSTextView (used for ⌘F)

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
    @State private var title = ""
    @State private var titleWork: DispatchWorkItem?
    @State private var findCount = 0
    @State private var findAt = 0

    enum GateField { case first, second }
    @FocusState private var gateFocus: GateField?

    /// The live row's palette, not the snapshot's: picking a colour writes
    /// to the store, and a snapshot would keep the old paper until reopened.
    private var pal: NoteColor { live.palette }

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
                .fill(LinearGradient(colors: [pal.paper, pal.paperShade],
                                     startPoint: .top, endPoint: .bottom))
        )
        .clipShape(noteShape)
        .overlay(noteShape.strokeBorder(Color.black.opacity(0.07), lineWidth: 0.5))
        .onAppear {
            title = note.title
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
            TextField("", text: $title)
                .overlay(alignment: .leading) {
                    if title.isEmpty {
                        Text(note.displayTitle)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(pal.ink.opacity(0.45))
                            .allowsHitTesting(false)
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(pal.ink.opacity(0.92))
                .tint(pal.ink)
                .lineLimit(1)
                .onSubmit { NoteStore.shared.setTitle(id: note.id, title: title) }
                .onChange(of: title) { _, v in
                    titleWork?.cancel()
                    let w = DispatchWorkItem { NoteStore.shared.setTitle(id: note.id, title: v) }
                    titleWork = w
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
                }
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
            .tip(note.pinned ? "Unpin — ⌘P" : "Pin so it stays open  ⌘P")

            Button { deck.findQuery = deck.findQuery == nil ? "" : nil } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10.5, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(pal.ink.opacity(0.5))
            .tip("Find  ⌘F")
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
            .tip(live.locked ? "Remove the password" : "Lock this note")
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
                .tip(LocalizedStringKey(c.name), below: false)
            }
            Spacer(minLength: 8)
            footerButton("Archive", "archivebox") {
                NoteStore.shared.setArchived(id: note.id, true)
                controller.collapse()
            }
            footerButton("Delete", "trash", danger: true) { confirmingDelete = true }
            footerButton("Close", "xmark") { controller.collapse() }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    private func footerButton(_ title: LocalizedStringKey, _ symbol: String,
                              danger: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(danger
                    ? Color(nsColor: .systemRed).opacity(0.85)
                    : pal.ink.opacity(0.72))
                .frame(width: 26, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(pal.ink.opacity(0.08))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tip(title, below: false)
        .accessibilityLabel(title)
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
