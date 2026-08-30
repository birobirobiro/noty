import SwiftUI

// MARK: - Root

struct DeckRootView: View {
    @ObservedObject var deck: DeckModel
    unowned let controller: DeckController
    @ObservedObject var store = NoteStore.shared

    private var onRight: Bool { !deck.onLeftEdge }
    private var edge: Edge { onRight ? .trailing : .leading }

    private var visible: [Note] {
        deck.showAll ? store.active : Array(store.active.prefix(Settings.fanLimit))
    }
    private var hiddenCount: Int { max(0, store.active.count - Settings.fanLimit) }
    private var showsMoreTab: Bool { !deck.showAll && hiddenCount > 0 }
    /// An empty deck still draws one tab, so the stack is never zero-height.
    private var itemCount: Int { max(1, visible.count) }

    /// Widest label currently on the deck — drives how tall each tab's strip is.
    private var longestLabel: CGFloat {
        visible.map { DeckGeom.labelWidth($0.displayTitle) }.max() ?? 0
    }

    private func layout(_ panelHeight: CGFloat) -> DeckLayout {
        DeckGeom.layout(panelHeight: panelHeight, count: itemCount,
                        hasMore: showsMoreTab, style: deck.style,
                        longestLabel: longestLabel)
    }

    var body: some View {
        let h = max(1, deck.panelHeight)
        let lay = layout(h)

        return ZStack(alignment: onRight ? .topTrailing : .topLeading) {

                if deck.fanVisible {
                    FanColumn(deck: deck, controller: controller,
                              notes: visible, hiddenCount: showsMoreTab ? hiddenCount : 0,
                              layout: lay, onRight: onRight)
                        .padding(.top, lay.top)
                } else {
                    PillView(notes: store.active)
                        .padding(.top, max(0, (h - DeckGeom.pillHeight(noteCount: max(1, store.active.count))) / 2))
                        .padding(onRight ? .trailing : .leading, 1)
                        .transition(.opacity)
                }

            }
        // A ZStack is only as wide as its widest child, so it has to be told to fill
        // the panel — otherwise the deck sits at the panel's left edge with a dead
        // gap against the screen. Filling from the parent's proposal (rather than a
        // measured width) keeps it pinned to the edge through a resize.
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: onRight ? .topTrailing : .topLeading)
        .animation(.spring(response: 0.30, dampingFraction: 0.9), value: deck.fanVisible)
        .animation(.easeInOut(duration: 0.22), value: deck.style)
    }

}

// MARK: - Pill (at rest)

struct PillView: View {
    let notes: [Note]

    private var shown: [Note] { Array(notes.prefix(DeckGeom.maxDashes)) }
    private var overflow: Int { max(0, notes.count - DeckGeom.maxDashes) }

    var body: some View {
        VStack(spacing: DeckGeom.dashGap) {
            if notes.isEmpty { dash(Color.secondary.opacity(0.4)) }
            ForEach(shown) { dash($0.palette.dash) }
            if overflow > 0 { dash(Color.secondary.opacity(0.5)) }
        }
        .padding(.vertical, DeckGeom.pillPad)
        .frame(width: DeckGeom.pillWidth)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.55))
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.ultraThinMaterial)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.22), radius: 6, x: -2, y: 1)
        )
    }

    private func dash(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(color)
            .frame(width: DeckGeom.dashWidth, height: DeckGeom.dashHeight)
    }
}

// MARK: - Fan

struct FanColumn: View {
    @State private var dragging: String?
    @ObservedObject var deck: DeckModel
    unowned let controller: DeckController
    let notes: [Note]
    let hiddenCount: Int
    let layout: DeckLayout
    let onRight: Bool

    @State private var revealed = false

    var body: some View {
        ZStack(alignment: onRight ? .trailing : .leading) {
            Group {
                if deck.showAll && layout.overflows {
                    ScrollView(.vertical, showsIndicators: false) {
                        stack.padding(.vertical, 4)
                    }
                    .frame(height: layout.cap)
                    .scrollClipDisabled()
                } else {
                    stack
                }
            }
            .overlay(alignment: onRight ? .trailing : .leading) { spine }
        }
        .onAppear { revealed = true }
        .onChange(of: deck.revealTick) { _, _ in
            revealed = false
            DispatchQueue.main.async { revealed = true }
        }
    }

    /// The lap comes from negative stack spacing — real layout, so hit areas follow
    /// the tabs. (`.offset` would draw them in the right place but leave their taps
    /// behind at the top of the stack.) Paint order is left to declaration order: a
    /// stack draws later children on top, which is exactly the lap we want. An
    /// explicit `zIndex` per tab is *not* equivalent — it reorders neighbours and
    /// breaks the shingle.
    private var stack: some View {
        VStack(spacing: layout.spacing) {
            if notes.isEmpty {
                EmptyTab(height: layout.itemHeight, strip: layout.pitch, onRight: onRight) {
                    (NSApp.delegate as? AppDelegate)?.newNote()
                }
                .staged(index: 0, revealed: revealed, onRight: onRight)
            }
            ForEach(Array(notes.enumerated()), id: \.element.id) { idx, note in
                Group {
                    if deck.style == .compact {
                        ChipTab(note: note,
                                isOpen: deck.state.expandedID == note.id,
                                onRight: onRight) { open(note) }
                    } else {
                        VerticalTab(note: note,
                                    isOpen: deck.state.expandedID == note.id,
                                    height: layout.itemHeight,
                                    strip: layout.pitch,
                                    onRight: onRight,
                                    action: { open(note) })
                    }
                }
                .staged(index: idx, revealed: revealed, onRight: onRight)
                // Reordering. NoteStore.move has been here since the start
                // with nothing calling it; this is what calls it.
                .onDrag {
                    dragging = note.id
                    return NSItemProvider(object: note.id as NSString)
                }
                .onDrop(of: [.text], isTargeted: nil) { _ in
                    guard let moved = dragging, moved != note.id else { return false }
                    NoteStore.shared.move(id: moved, before: note.id)
                    dragging = nil
                    return true
                }
            }
            if hiddenCount > 0 {
                MoreTab(count: hiddenCount, height: layout.moreHeight, onRight: onRight) {
                    deck.showAll = true
                }
                .padding(.top, layout.moreGap - layout.spacing)   // undo the lap
                .staged(index: notes.count, revealed: revealed, onRight: onRight)
            }
            DeckButton(icon: "plus", help: "New Note  ⌥⌘N") {
                (NSApp.delegate as? AppDelegate)?.newNote()
            }
            .padding(.top, DeckGeom.plusGap - layout.spacing)
            .staged(index: notes.count + 1, revealed: revealed, onRight: onRight)

            DeckButton(icon: "list.bullet", help: "All Notes  ⌥⌘A") {
                (NSApp.delegate as? AppDelegate)?.openAllNotes()
            }
            .padding(.top, DeckGeom.buttonGap - layout.spacing)   // undo the lap
            .staged(index: notes.count + 2, revealed: revealed, onRight: onRight)
        }
        .frame(width: DeckGeom.tabWidth)
    }

    private func open(_ note: Note) {
        if deck.state.expandedID == note.id { controller.collapse() }
        else { controller.expand(note.id) }
    }

    /// The dashed rule the deck hangs from, right at the screen edge.
    private var spine: some View {
        EdgeLine()
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            .foregroundStyle(Color.white.opacity(0.35))
            .frame(width: 1, height: min(layout.stackHeight + 26, layout.cap))
            .padding(onRight ? .trailing : .leading, 3)
            .allowsHitTesting(false)
    }
}

/// The note emerging from its tab: a short slide off the edge, a touch of scale
/// anchored there, and a fade. A full-width slide reads as a window flying in.
struct EdgeLine: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        return p
    }
}

/// Rounded on the outward-facing side only, so the tab reads as docked to the edge.
func edgeTabShape(onRight: Bool, radius r: CGFloat = 11) -> UnevenRoundedRectangle {
    UnevenRoundedRectangle(
        topLeadingRadius: onRight ? r : 0,
        bottomLeadingRadius: onRight ? r : 0,
        bottomTrailingRadius: onRight ? 0 : r,
        topTrailingRadius: onRight ? 0 : r,
        style: .continuous)
}

// MARK: - Tabs

/// A tab keeps its colour and carries its label turned on its side.
///
/// Tabs overlap, so the label is pinned to the top of the tab — the part that
/// stays uncovered. Hovering lifts the whole tab clear to reveal the rest of it.
struct VerticalTab: View {
    let note: Note
    let isOpen: Bool
    let height: CGFloat
    let strip: CGFloat          // the part of this tab the next one does not cover
    let onRight: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .top) {
                edgeTabShape(onRight: onRight)
                    .fill(note.palette.paper)
                    .shadow(color: .black.opacity(isOpen || hovering ? 0.32 : 0.22),
                            radius: isOpen || hovering ? 9 : 6,
                            x: onRight ? -3 : 3, y: 2)
                Text(note.displayTitle.uppercased())
                    .font(Ink.tabFont)
                    .tracking(Ink.tabTracking)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(note.palette.ink.opacity(0.85))
                    .frame(width: max(20, strip - DeckGeom.labelInset),
                           height: DeckGeom.tabWidth)
                    .rotationEffect(.degrees(onRight ? 90 : -90))
                    .frame(width: DeckGeom.tabWidth, height: strip)
                    .offset(x: onRight ? -DeckGeom.bleed / 2 : DeckGeom.bleed / 2)
            }
            .frame(width: DeckGeom.tabWidth + DeckGeom.bleed, height: height, alignment: .top)
            .rotationEffect(.degrees(DeckGeom.lean(onRight: onRight)), anchor: onRight ? .trailing : .leading)
            .offset(x: onRight ? DeckGeom.bleed : -DeckGeom.bleed)
            .frame(width: DeckGeom.tabWidth)
            .contentShape(Rectangle())
        }
        .overlay(alignment: onRight ? .topTrailing : .topLeading) {
            if note.pinned {
                Circle()
                    .fill(note.palette.dash)
                    .frame(width: 5, height: 5)
                    .padding(.top, 7)
                    .padding(onRight ? .trailing : .leading, 9)
            }
        }
        .buttonStyle(TabPressStyle())
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isOpen)
        .animation(.easeOut(duration: 0.14), value: hovering)
        .noteContextMenu(note)
        .help(note.displayTitle)
    }
}

/// Compact style — colour only, so the deck barely touches the screen.
struct ChipTab: View {
    let note: Note
    let isOpen: Bool
    let onRight: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            edgeTabShape(onRight: onRight, radius: 7)
                .fill(note.palette.dash)
                .frame(width: DeckGeom.chipWidth, height: DeckGeom.chipHeight)
                .shadow(color: .black.opacity(isOpen ? 0.34 : 0.22), radius: isOpen ? 8 : 5,
                        x: onRight ? -2 : 2, y: 1)
                .rotationEffect(.degrees(DeckGeom.lean(onRight: onRight) * 0.6), anchor: onRight ? .trailing : .leading)
                .offset(x: onRight ? DeckGeom.bleed / 2 : -DeckGeom.bleed / 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(TabPressStyle())
        .animation(.spring(response: 0.26, dampingFraction: 0.8), value: isOpen)
        .noteContextMenu(note)
        .help(note.displayTitle)
    }
}

struct MoreTab: View {
    let count: Int
    let height: CGFloat
    let onRight: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                edgeTabShape(onRight: onRight, radius: 9)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.18), radius: 5, x: onRight ? -2 : 2, y: 1)
                Text("+\(count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: DeckGeom.tabWidth, height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(TabPressStyle())
        .help(String.localizedStringWithFormat(NSLocalizedString("%d more notes", comment: ""), count))
    }
}

struct EmptyTab: View {
    let height: CGFloat
    let strip: CGFloat
    let onRight: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .top) {
                edgeTabShape(onRight: onRight).fill(.ultraThinMaterial)
                Text("NEW NOTE")
                    .font(Ink.tabFont)
                    .tracking(Ink.tabTracking)
                    .foregroundStyle(.secondary)
                    .frame(width: max(20, strip - DeckGeom.labelInset),
                           height: DeckGeom.tabWidth)
                    .rotationEffect(.degrees(onRight ? 90 : -90))
                    .frame(width: DeckGeom.tabWidth, height: strip)
            }
            .frame(width: DeckGeom.tabWidth, height: height, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(TabPressStyle())
    }
}

/// The round buttons that sit under the fan. Two of them now: writing a note
/// and finding one are the two things you come to the deck for, and the second
/// used to be reachable only from a right-click or a shortcut you had to know.
struct DeckButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.75))
                .frame(width: DeckGeom.plusSize, height: DeckGeom.plusSize)
                .background(Circle().fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.22), radius: 5, y: 1))
                .scaleEffect(hovering ? 1.08 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(help)
        // The label is an SF Symbol, so without this VoiceOver reads nothing
        // at all. `help` already carries the words; give them to the label too.
        .accessibilityLabel(help)
    }
}

// MARK: - Shared bits

extension View {
    func noteContextMenu(_ note: Note) -> some View {
        contextMenu {
            Button(note.pinned ? "Unpin" : "Pin") { NoteStore.shared.togglePin(id: note.id) }
            Button("Archive") { NoteStore.shared.setArchived(id: note.id, true) }
            Button("Cycle colour  ⌘.") { NoteStore.shared.cycleColor(id: note.id) }
            Divider()
            Button("Delete") { NoteStore.shared.delete(id: note.id) }
        }
    }
}

// MARK: - Staging (the 45 ms shingle)

private struct Staged: ViewModifier {
    let index: Int
    let revealed: Bool
    let onRight: Bool

    func body(content: Content) -> some View {
        content
            .offset(x: revealed ? 0 : (onRight ? DeckGeom.tabWidth + 24 : -(DeckGeom.tabWidth + 24)))
            .opacity(revealed ? 1 : 0)
            .animation(.spring(response: 0.36, dampingFraction: 0.82)
                        .delay(Double(index) * 0.045), value: revealed)
    }
}

private extension View {
    func staged(index: Int, revealed: Bool, onRight: Bool) -> some View {
        modifier(Staged(index: index, revealed: revealed, onRight: onRight))
    }
}

struct TabPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
