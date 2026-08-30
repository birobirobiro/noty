import AppKit
import SwiftUI
import Combine

enum LibraryMode: String, CaseIterable, Identifiable {
    case all = "All"
    case active = "Active"
    case archived = "Archived"
    var id: String { rawValue }

    /// What the window calls itself when opened straight into this filter.
    var windowTitle: String { self == .archived ? "Archive" : "All Notes" }
}

final class LibraryModel: ObservableObject {
    @Published var mode: LibraryMode = .all
    @Published var query = ""
    @Published var selection: String?
    let bridge = EditorBridge()
}

/// "⌥⌘A opens every note in one window" — plus the archive, on ⌥⌘L.
final class LibraryWindow: NSObject, NSWindowDelegate {
    static let shared = LibraryWindow()
    private var window: NSWindow?
    private let model = LibraryModel()

    /// So closing the settings window does not drop the Dock icon out from
    /// under this one while it is still on screen.
    var isOpen: Bool { window?.isVisible == true }

    func show(mode: LibraryMode) {
        model.mode = mode
        if model.selection == nil { model.selection = currentList().first?.id }

        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 580),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Noty"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 720, height: 420)
            w.delegate = self
            w.contentView = NSHostingView(rootView: LibraryView(model: model))
            w.center()
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func currentList() -> [Note] { NoteStore.shared.list(model.mode) }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu-bar-less agent so the dock icon disappears again --
        // unless settings is still up and needs it.
        DispatchQueue.main.async {
            if !SettingsWindow.shared.isOpen { NSApp.setActivationPolicy(.accessory) }
        }
    }
}

// MARK: - The sheet it all sits on

private extension Color {
    /// A window full of coloured paper was being framed in system grey, which
    /// made it read as a file browser rather than as the notes it holds.
    static let sheet = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.145, alpha: 1)
            : NSColor(calibratedRed: 0.953, green: 0.945, blue: 0.929, alpha: 1)
    })
    static let sunken = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(calibratedWhite: 1, alpha: 0.08)
            : NSColor(calibratedWhite: 0, alpha: 0.055)
    })
}

// MARK: - View

struct LibraryView: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject var store = NoteStore.shared

    /// Ticked rows. Export acts on these when there are any, on the whole
    /// filtered list when there are not.
    @State private var picked: Set<String> = []

    private var source: [Note] { store.list(model.mode) }

    private var filtered: [Note] {
        let q = model.query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return source }
        return source.filter {
            $0.displayTitle.lowercased().contains(q) || $0.body.lowercased().contains(q)
        }
    }

    private var selected: Note? {
        guard let id = model.selection else { return nil }
        return store.note(id: id)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 380)
            Divider().opacity(0.5)
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 460)
        .background(Color.sheet)
        .onChange(of: model.mode) { _, _ in model.selection = filtered.first?.id }
        .onAppear {
            if model.selection == nil || store.note(id: model.selection!) == nil {
                model.selection = filtered.first?.id
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(model.mode.windowTitle)
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                Button { NoteStore.shared.create() } label: {
                    Label("New", systemImage: "plus")
                }
                .controlSize(.small)
                .help("New Note  ⌥⌘N")
                Button { Transfer.importFiles() } label: {
                    Label("Import…", systemImage: "square.and.arrow.down")
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 18)
            .padding(.top, 34)
            .padding(.bottom, 12)

            search
            chips

            if filtered.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filtered) { note in
                            row(note)
                                .contentShape(Rectangle())
                                // A whole-row Button would nest the checkbox
                                // button inside it, which macOS handles badly;
                                // the trait is what VoiceOver needs either way.
                                .onTapGesture { model.selection = note.id }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityLabel(note.displayTitle)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private var search: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("Search all notes", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
            if model.query.isEmpty {
                Text("\(filtered.count) note\(filtered.count == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            } else {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.sunken))
        .padding(.horizontal, 18)
    }

    private var chips: some View {
        HStack(spacing: 6) {
            ForEach(LibraryMode.allCases) { m in
                let on = model.mode == m
                Button { model.mode = m } label: {
                    Text(m.rawValue)
                        .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.primary : .secondary)
                        .padding(.horizontal, 11)
                        .frame(height: 24)
                        .background(Capsule().fill(on ? Color.sunken : .clear))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if !picked.isEmpty {
                Menu {
                    exportItems(for: filtered.filter { picked.contains($0.id) })
                } label: {
                    Label("Export \(picked.count)", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var empty: some View {
        VStack(spacing: 7) {
            Image(systemName: model.mode == .archived ? "archivebox" : "note.text")
                .font(.system(size: 24)).foregroundStyle(.quaternary)
            Text(model.query.isEmpty
                 ? (model.mode == .archived ? "Nothing archived" : "No notes yet")
                 : "No matches")
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ note: Note) -> some View {
        let on = model.selection == note.id
        return HStack(alignment: .top, spacing: 10) {
            Button {
                if picked.contains(note.id) { picked.remove(note.id) } else { picked.insert(note.id) }
            } label: {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.28), lineWidth: 1.2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(picked.contains(note.id) ? Color.accentColor : .clear)
                    )
                    .frame(width: 15, height: 15)
                    .overlay {
                        if picked.contains(note.id) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
            }
            .buttonStyle(.plain)
            .padding(.top, 1)
            .accessibilityLabel(picked.contains(note.id) ? "Deselect note" : "Select note")

            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(note.palette.dash)
                .frame(width: 3.5)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(note.displayTitle)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(note.archived ? "ARCHIVED" : "ACTIVE")
                        .font(.system(size: 8.5, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.sunken))
                    Text(Fmt.ago(note.modified))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                // The preview is set in the note's own hand: these are sticky
                // notes, and the list should look like it holds some.
                if !note.preview.isEmpty {
                    Text(note.preview)
                        .font(Font(Ink.body(11.5)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(on ? Color.sunken : .clear))
        .contextMenu {
            Button(note.archived ? "Restore" : "Archive") {
                NoteStore.shared.setArchived(id: note.id, !note.archived)
            }
            Divider()
            Button("Delete", role: .destructive) { NoteStore.shared.delete(id: note.id) }
        }
    }

    @ViewBuilder
    private func exportItems(for notes: [Note]) -> some View {
        Button("Markdown (one file per note)…") { Transfer.export(.markdown, notes: notes) }
        Button("Plain text (one file per note)…") { Transfer.export(.plainText, notes: notes) }
        Button("Single document…") { Transfer.export(.singleFile, notes: notes) }
        Button("Sticky archive (.stickies)…") { Transfer.export(.stickies, notes: notes) }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let note = selected {
            LibraryDetail(note: note, bridge: model.bridge)
                .id(note.id)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "sidebar.right").font(.system(size: 26)).foregroundStyle(.quaternary)
                Text("Select a note").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Detail pane

/// The note as a note. This pane used to be a full-bleed text field on the
/// system's text background, which is the one place in the app where a sticky
/// note stopped looking like one.
struct LibraryDetail: View {
    let note: Note
    let bridge: EditorBridge

    @State private var text = ""
    @State private var saveWork: DispatchWorkItem?
    @State private var confirmingDelete = false

    private var pal: NoteColor { note.palette }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(pal.dash).frame(width: 9, height: 9)
                Text(note.archived ? "ARCHIVED" : "ACTIVE · IN THE DECK")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 10)
                Button {
                    NoteStore.shared.setArchived(id: note.id, !note.archived)
                } label: {
                    Label(note.archived ? "Restore" : "Archive",
                          systemImage: note.archived ? "tray.and.arrow.up" : "archivebox")
                }

                // A borderless menu draws no chrome at all, so this read as a
                // stray word sitting between two buttons.
                Menu {
                    Button("Markdown…") { Transfer.export(.markdown, notes: [note]) }
                    Button("Plain text…") { Transfer.export(.plainText, notes: [note]) }
                    Button("Single document…") { Transfer.export(.singleFile, notes: [note]) }
                    Button("Sticky archive…") { Transfer.export(.stickies, notes: [note]) }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.button)
                .fixedSize()

                Button {
                    confirmingDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(Color(nsColor: .systemRed))
                .confirmationDialog("Delete this note?", isPresented: $confirmingDelete) {
                    Button("Delete", role: .destructive) { NoteStore.shared.delete(id: note.id) }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("You will have ten seconds to undo it.")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 22)
            .padding(.top, 34)
            .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(note.displayTitle)
                        .font(.system(size: 15, weight: .bold))
                        .lineLimit(1)
                    Spacer(minLength: 10)
                    Text("edited \(Fmt.ago(note.modified))")
                        .font(.system(size: 10.5))
                        .opacity(0.55)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 8)

                NoteTextView(text: $text, ink: NSColor(pal.ink), bridge: bridge,
                             autofocus: false, fontSize: Settings.noteFontSize)
                    .padding(.horizontal, 14)
                    .frame(maxHeight: .infinity)

                Divider().opacity(0.28).padding(.horizontal, 20)
                Text("Created \(Fmt.stamp.string(from: note.created)) · Updated \(Fmt.ago(note.modified))")
                    .font(.system(size: 10))
                    .opacity(0.5)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 11)
            }
            .foregroundStyle(pal.ink)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(pal.paper))
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
        }
        .onAppear { text = note.body }
        .onChange(of: text) { _, v in
            saveWork?.cancel()
            let w = DispatchWorkItem { NoteStore.shared.updateBody(id: note.id, body: v) }
            saveWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
        }
        .onDisappear {
            saveWork?.cancel()
            NoteStore.shared.updateBody(id: note.id, body: text)
        }
    }
}
