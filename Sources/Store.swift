import Foundation
import SQLite3
import Combine

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite-backed note storage. Titles and bodies are both AES-GCM sealed.
///
/// Leaving titles in the clear made the lists cheaper to draw, but a note's
/// title is usually the part that gives it away — "Senha do banco", a client's
/// name — so the database still told anyone reading it what every note was
/// about. Unsealing a title is a few microseconds; the whole list costs less
/// than a frame.
final class Store {
    private var db: OpaquePointer?

    init() {
        if sqlite3_open_v2(Paths.db.path, &db,
                           SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                           nil) != SQLITE_OK {
            NSLog("Noty: cannot open db at \(Paths.db.path)")
        }
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
        exec("""
        CREATE TABLE IF NOT EXISTS notes (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL DEFAULT '',
          body BLOB NOT NULL,
          color INTEGER NOT NULL DEFAULT 0,
          created REAL NOT NULL,
          modified REAL NOT NULL,
          archived INTEGER NOT NULL DEFAULT 0,
          sort_order REAL NOT NULL DEFAULT 0
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_notes_archived ON notes(archived, sort_order);")
        migrateTitles()
        if !hasColumn("lock_salt") { exec("ALTER TABLE notes ADD COLUMN lock_salt BLOB;") }
        migrateTaskGlyphs()
    }

    /// Rewrites ☐/☑ task lines as Markdown, once.
    ///
    /// Runs behind `PRAGMA user_version` rather than a defaults flag, because
    /// it is a property of this database: copy the file to another Mac and the
    /// migration state travels with it.
    ///
    /// A note that will not decrypt is skipped, never rewritten — the same
    /// rule as `upsert`. Better to leave one note in the old shape than to
    /// seal an empty body over ciphertext that is still good.
    private func migrateTaskGlyphs() {
        guard userVersion() < 1 else { return }

        var converted = 0, skipped = 0
        for note in load() {
            if note.unreadable || note.locked { skipped += 1; continue }
            let fresh = Tasks.glyphsToMarkdown(note.body)
            guard fresh != note.body else { continue }
            var n = note
            n.body = fresh
            upsert(n)
            converted += 1
        }
        setUserVersion(1)
        if converted > 0 || skipped > 0 {
            NSLog("Noty: task syntax migrated in \(converted) note(s); \(skipped) skipped")
        }
    }

    /// A locked note's body is not in memory to convert, and its glyphs sit
    /// inside the password layer where this cannot reach. Those are rewritten
    /// the next time they are unlocked and saved.
    private func userVersion() -> Int {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &st, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int(st, 0)) : 0
    }

    private func setUserVersion(_ v: Int) { exec("PRAGMA user_version = \(v);") }

    /// Adds the sealed-title column and seals whatever the old plaintext one
    /// still holds. Runs once; afterwards `title` is left empty on every row.
    private func migrateTitles() {
        guard !hasColumn("title_enc") else { return }
        exec("ALTER TABLE notes ADD COLUMN title_enc BLOB;")
        var rows: [(String, String)] = []
        var st: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id,title FROM notes WHERE title <> '';", -1, &st, nil) == SQLITE_OK {
            while sqlite3_step(st) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(st, 0))
                let title = sqlite3_column_text(st, 1).map { String(cString: $0) } ?? ""
                rows.append((id, title))
            }
        }
        sqlite3_finalize(st)
        for (id, title) in rows {
            guard let sealed = try? Crypto.seal(title, id: id, field: "title") else { continue }
            var up: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE notes SET title_enc=?, title='' WHERE id=?;", -1, &up, nil) == SQLITE_OK else { continue }
            _ = sealed.withUnsafeBytes { raw in
                sqlite3_bind_blob(up, 1, raw.baseAddress, Int32(sealed.count), SQLITE_TRANSIENT)
            }
            sqlite3_bind_text(up, 2, id, -1, SQLITE_TRANSIENT)
            sqlite3_step(up)
            sqlite3_finalize(up)
        }
        if !rows.isEmpty { NSLog("Noty: sealed \(rows.count) title(s) that were stored in the clear") }
    }

    private func hasColumn(_ name: String) -> Bool {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(notes);", -1, &st, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(st) }
        while sqlite3_step(st) == SQLITE_ROW {
            if let c = sqlite3_column_text(st, 1), String(cString: c) == name { return true }
        }
        return false
    }

    deinit { if let db { sqlite3_close_v2(db) } }

    private func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK, let err {
            NSLog("Noty sql: \(String(cString: err))")
            sqlite3_free(err)
        }
    }

    // MARK: Reads

    func load() -> [Note] {
        var out: [Note] = []
        var st: OpaquePointer?
        let sql = "SELECT id,title,body,color,created,modified,archived,sort_order,title_enc,lock_salt FROM notes ORDER BY sort_order ASC;"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return out }
        defer { sqlite3_finalize(st) }
        while sqlite3_step(st) == SQLITE_ROW {
            var n = Note()
            n.id = String(cString: sqlite3_column_text(st, 0))
            if let blob = sqlite3_column_blob(st, 8) {
                let len = Int(sqlite3_column_bytes(st, 8))
                do { n.title = try Crypto.openText(Data(bytes: blob, count: len), id: n.id, field: "title") }
                catch { n.unreadable = true }
            } else {
                // Not migrated yet (or written by an older build).
                n.title = sqlite3_column_text(st, 1).map { String(cString: $0) } ?? ""
            }
            if let salt = sqlite3_column_blob(st, 9) {
                n.lockSalt = Data(bytes: salt, count: Int(sqlite3_column_bytes(st, 9)))
            }
            if let blob = sqlite3_column_blob(st, 2) {
                let len = Int(sqlite3_column_bytes(st, 2))
                do {
                    let payload = try Crypto.open(Data(bytes: blob, count: len), id: n.id, field: "body")
                    // A locked note's payload is the inner ciphertext. It is
                    // carried as bytes and stays shut until a password opens it.
                    if n.locked { n.sealed = payload } else { n.body = String(decoding: payload, as: UTF8.self) }
                } catch { n.unreadable = true }
            }
            if n.unreadable { n.body = ""; n.sealed = nil }
            n.color = Int(sqlite3_column_int(st, 3))
            n.created = Date(timeIntervalSince1970: sqlite3_column_double(st, 4))
            n.modified = Date(timeIntervalSince1970: sqlite3_column_double(st, 5))
            n.archived = sqlite3_column_int(st, 6) != 0
            n.order = sqlite3_column_double(st, 7)
            out.append(n)
        }
        return out
    }

    // MARK: Writes

    func upsert(_ n: Note) {
        // A note we could not decrypt is on screen as a warning, not as text.
        // Writing it back would seal that emptiness over ciphertext that is
        // still intact — the one mistake here that cannot be undone.
        guard !n.unreadable else {
            NSLog("Noty: refusing to overwrite unreadable note \(n.id)")
            return
        }
        // Locked: the inner ciphertext goes to disk, and the plain text never
        // does. Unlocked: the text itself, sealed once.
        let payload = n.locked ? (n.sealed ?? Data()) : Data(n.body.utf8)
        guard let sealedBody = try? Crypto.seal(payload, id: n.id, field: "body"),
              let sealedTitle = try? Crypto.seal(n.title, id: n.id, field: "title") else {
            NSLog("Noty: no key — note \(n.id) not saved")
            return
        }
        let sql = """
        INSERT INTO notes (id,title,body,color,created,modified,archived,sort_order,title_enc,lock_salt)
        VALUES (?,'',?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          title='', title_enc=excluded.title_enc,
          body=excluded.body, color=excluded.color,
          modified=excluded.modified, archived=excluded.archived,
          sort_order=excluded.sort_order, lock_salt=excluded.lock_salt;
        """
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        let sealed = sealedBody
        sqlite3_bind_text(st, 1, n.id, -1, SQLITE_TRANSIENT)
        _ = sealed.withUnsafeBytes { raw in
            sqlite3_bind_blob(st, 2, raw.baseAddress, Int32(sealed.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_int(st, 3, Int32(n.color))
        sqlite3_bind_double(st, 4, n.created.timeIntervalSince1970)
        sqlite3_bind_double(st, 5, n.modified.timeIntervalSince1970)
        sqlite3_bind_int(st, 6, n.archived ? 1 : 0)
        sqlite3_bind_double(st, 7, n.order)
        _ = sealedTitle.withUnsafeBytes { raw in
            sqlite3_bind_blob(st, 8, raw.baseAddress, Int32(sealedTitle.count), SQLITE_TRANSIENT)
        }
        if let salt = n.lockSalt {
            _ = salt.withUnsafeBytes { raw in
                sqlite3_bind_blob(st, 9, raw.baseAddress, Int32(salt.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(st, 9)
        }
        if sqlite3_step(st) != SQLITE_DONE {
            NSLog("Noty: upsert failed — \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    func delete(id: String) {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM notes WHERE id=?;", -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, id, -1, SQLITE_TRANSIENT)
        sqlite3_step(st)
    }
}
