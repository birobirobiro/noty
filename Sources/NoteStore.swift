import Foundation
import Combine
import AppKit
import CryptoKit

/// Observable in-memory model. SQLite is written through on every mutation;
/// the array is the single source of truth for every window and deck.
final class NoteStore: ObservableObject {
    static let shared = NoteStore()

    @Published private(set) var notes: [Note] = []
    /// Set when a note is deleted, cleared after the 10 s undo window elapses.
    @Published var pendingUndo: PendingDelete?

    private let store = Store()
    private var undoTimer: Timer?
    /// Keys for notes opened with a password during this run. Never written
    /// anywhere; quitting the app shuts every locked note again.
    private var sessionKeys: [String: SymmetricKey] = [:]

    struct PendingDelete: Equatable {
        let note: Note
        let deadline: Date
    }

    private init() {
        notes = store.load()
        if notes.isEmpty { seedWelcomeNote() }
    }

    // MARK: Derived collections

    var active: [Note] { notes.filter { !$0.archived }.sorted { $0.order < $1.order } }
    var archived: [Note] { notes.filter { $0.archived }.sorted { $0.modified > $1.modified } }

    func note(id: String) -> Note? { notes.first { $0.id == id } }

    // MARK: Mutations

    @discardableResult
    func create(body: String = "", color: Int? = nil) -> Note {
        var n = Note()
        n.order = (active.map(\.order).min() ?? 0) - 1   // newest sits at the top of the deck
        n.color = color ?? (notes.count % NoteColor.all.count)
        n.body = body
        n.title = Note.derivedTitle(from: body)
        notes.append(n)
        store.upsert(n)
        return n
    }

    func updateBody(id: String, body: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        guard notes[i].body != body else { return }
        if notes[i].locked {
            // Without the session key there is nothing to seal with, and
            // writing the text unsealed would defeat the whole feature.
            guard let key = sessionKeys[id], let inner = NoteLock.seal(body, with: key) else { return }
            notes[i].sealed = inner
            notes[i].body = body
            // The title is derived from the first line, so keeping it current
            // would print the note's opening words on a tab that is meant to
            // give nothing away.
        } else {
            notes[i].body = body
            notes[i].title = Note.derivedTitle(from: body)
        }
        notes[i].modified = Date()
        store.upsert(notes[i])
    }

    // MARK: Locking

    /// True while this run holds the key to a locked note.
    func isRevealed(_ id: String) -> Bool { sessionKeys[id] != nil }

    /// Puts a password on a note: the text is sealed with a key derived from
    /// it, and the derived title is dropped so the deck stops showing the
    /// first line of something that is supposed to be shut.
    @discardableResult
    func lock(id: String, password: String) -> Bool {
        guard let i = notes.firstIndex(where: { $0.id == id }), !notes[i].locked else { return false }
        let salt = NoteLock.newSalt()
        guard let key = NoteLock.derive(password: password, salt: salt),
              let inner = NoteLock.seal(notes[i].body, with: key) else { return false }
        notes[i].lockSalt = salt
        notes[i].sealed = inner
        notes[i].title = ""
        notes[i].modified = Date()
        sessionKeys[id] = key          // whoever just typed it keeps reading
        store.upsert(notes[i])
        return true
    }

    /// Opens a locked note for this run. False means the password was wrong —
    /// there is nothing else it can mean, since GCM's tag is what decides.
    @discardableResult
    func unlock(id: String, password: String) -> Bool {
        guard let i = notes.firstIndex(where: { $0.id == id }),
              let salt = notes[i].lockSalt, let blob = notes[i].sealed,
              let key = NoteLock.derive(password: password, salt: salt),
              let text = NoteLock.open(blob, with: key) else { return false }
        notes[i].body = text
        sessionKeys[id] = key
        return true
    }

    /// Takes the password off, leaving the note stored the ordinary way.
    @discardableResult
    func removeLock(id: String, password: String) -> Bool {
        guard let i = notes.firstIndex(where: { $0.id == id }),
              let salt = notes[i].lockSalt, let blob = notes[i].sealed,
              let key = NoteLock.derive(password: password, salt: salt),
              let text = NoteLock.open(blob, with: key) else { return false }
        notes[i].body = text
        notes[i].title = Note.derivedTitle(from: text)
        notes[i].lockSalt = nil
        notes[i].sealed = nil
        notes[i].modified = Date()
        sessionKeys[id] = nil
        store.upsert(notes[i])
        return true
    }

    /// Shuts a revealed note again, dropping the text from memory.
    func conceal(id: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }), notes[i].locked else { return }
        sessionKeys[id] = nil
        notes[i].body = ""
    }

    func cycleColor(id: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].color = (notes[i].color + 1) % NoteColor.all.count
        notes[i].modified = Date()
        store.upsert(notes[i])
    }

    func setColor(id: String, color: Int) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].color = color
        notes[i].modified = Date()
        store.upsert(notes[i])
    }

    func setArchived(id: String, _ archived: Bool) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].archived = archived
        notes[i].modified = Date()
        if !archived { notes[i].order = (active.map(\.order).min() ?? 0) - 1 }
        store.upsert(notes[i])
    }

    /// Removes the note but keeps it recoverable for ten seconds.
    func delete(id: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        let doomed = notes[i]
        notes.remove(at: i)
        store.delete(id: id)
        pendingUndo = PendingDelete(note: doomed, deadline: Date().addingTimeInterval(10))
        undoTimer?.invalidate()
        undoTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.pendingUndo = nil }
        }
    }

    func undoDelete() {
        guard let p = pendingUndo else { return }
        undoTimer?.invalidate()
        notes.append(p.note)
        store.upsert(p.note)
        pendingUndo = nil
    }

    func move(id: String, before otherID: String?) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        let list = active
        let newOrder: Double
        if let otherID, let target = list.firstIndex(where: { $0.id == otherID }) {
            let upper = list[target].order
            let lower = target > 0 ? list[target - 1].order : upper - 2
            newOrder = (upper + lower) / 2
        } else {
            newOrder = (list.map(\.order).max() ?? 0) + 1
        }
        notes[i].order = newOrder
        store.upsert(notes[i])
    }

    /// Bulk insert used by import — returns how many notes landed.
    @discardableResult
    func ingest(_ incoming: [Note]) -> Int {
        var added = 0
        var base = (notes.map(\.order).min() ?? 0) - 1
        for var n in incoming {
            if notes.contains(where: { $0.id == n.id }) { n.id = UUID().uuidString }
            n.order = base
            base -= 1
            notes.append(n)
            store.upsert(n)
            added += 1
        }
        return added
    }

    private func seedWelcomeNote() {
        create(body: """
        Welcome to Noty

        Your notes live at the edge of the screen. Slide the pointer to the \
        right edge and the deck fans out.

        ⌥⌘N  new note
        ⌥⌘A  all notes
        ⌥⌘L  archive

        Inside a note: Esc closes, ⌘F finds, ⌘. cycles the colour, \
        ⌘⌫ deletes with ten seconds to undo.
        """, color: 0)
    }
}
