import AppKit
import SwiftUI

/// The note's text, rendered as Markdown while you write it.
///
/// Wraps the vendored MarkdownEngine and configures it to look like a sticky
/// note rather than a document: the note's own ink, the hand chosen in
/// settings, and the markers shrunk to 0.1pt so nobody has to look at a pair
/// of asterisks. The markers stay in the text storage, which is what keeps
/// selection, find, copy and undo honest — displayed range and stored range
/// are the same range.
enum NoteFormat: String, CaseIterable {
    case bold, italic, strikethrough, code, heading, quote, bullet, task

    /// One notification per action. The engine subscribes to whatever names it
    /// is given, so the toolbar only has to post; none of the wrapping logic
    /// lives in this app.
    var request: Notification.Name { Notification.Name("noty.format.\(rawValue)") }

    var symbol: String {
        switch self {
        case .bold:          return "bold"
        case .italic:        return "italic"
        case .strikethrough: return "strikethrough"
        case .code:          return "chevron.left.forwardslash.chevron.right"
        case .heading:       return "textformat.size"
        case .quote:         return "text.quote"
        case .bullet:        return "list.bullet"
        case .task:          return "checklist"
        }
    }

    var help: LocalizedStringKey {
        switch self {
        case .bold:          return "Bold"
        case .italic:        return "Italic"
        case .strikethrough: return "Strikethrough"
        case .code:          return "Code"
        case .heading:       return "Heading"
        case .quote:         return "Quote"
        case .bullet:        return "List"
        case .task:          return "Checklist"
        }
    }

    func post() {
        var info: [AnyHashable: Any] = [:]
        if self == .heading { info["level"] = 1 }
        NotificationCenter.default.post(name: request, object: nil, userInfo: info)
    }
}

/// Selection state the engine publishes back, so a button can look pressed.
extension Notification.Name {
    static let notySelectionBold = Notification.Name("noty.selection.bold")
    static let notySelectionItalic = Notification.Name("noty.selection.italic")
    /// ⌘F. The engine searches its OWN displayed text, which is the only place
    /// the answer is right: a match's position on screen is not its position in
    /// the source once markers are shrunk and links are drawn short.
    static let notyFindQuery = Notification.Name("noty.find.query")
    static let notyFindResults = Notification.Name("noty.find.results")
    static let notyFindClear = Notification.Name("noty.find.clear")
}

/// ⌘F, asked of the engine rather than computed here.
enum NoteFind {
    static func run(_ query: String, index: Int = 0) {
        NotificationCenter.default.post(name: .notyFindQuery, object: nil,
                                        userInfo: ["query": query, "currentIndex": index])
    }
    static func clear() {
        NotificationCenter.default.post(name: .notyFindClear, object: nil)
    }
}

struct NoteMarkdownEditor: View {
    @Binding var text: String
    let note: Note
    var isEditable: Bool = true
    /// Distinguishes two editors showing the same note. The engine keys undo
    /// on this, so the note window and the library must not share one stack.
    var surface: String = "note"

    @State private var wikiActive = false
    @State private var pendingReplacement: InlineReplacementRequest?

    private var pal: NoteColor { note.palette }

    private var configuration: MarkdownEditorConfiguration {
        var theme = MarkdownEditorTheme.default
        theme.bodyText = NSColor(pal.ink)
        theme.mutedText = NSColor(pal.ink).withAlphaComponent(0.55)
        theme.headingMarker = NSColor(pal.ink).withAlphaComponent(0.4)
        theme.link = NSColor(pal.dash)
        theme.strikethroughColor = NSColor(pal.ink).withAlphaComponent(0.6)

        var config = MarkdownEditorConfiguration()
        config.theme = theme
        // Nobody writing a shopping list should meet an asterisk. The cost is
        // that the syntax cannot be edited by hand — the bar does it instead.
        config.markers = MarkerStyle(revealUnderCaret: false)
        // Room to breathe, and somewhere for the caret to sit at the start of
        // a line without touching the edge of the paper.
        config.textInsets = TextInsets(horizontal: 16, vertical: 12)
        // 27.5pt a level is document-sized. A note is 460pt wide and mostly
        // short lines, so a bullet that far from its text reads as detached.
        config.lists = ListStyle(indentPerLevel: 15)
        // ~~text~~ is opt-in; a note that marks things done wants it.
        config.extensions = [StrikethroughExtension()]
        config.services.bus = MarkdownEditorBus(
            applyBoldRequest: NoteFormat.bold.request,
            applyItalicRequest: NoteFormat.italic.request,
            applyHeadingRequest: NoteFormat.heading.request,
            applyStrikethroughRequest: NoteFormat.strikethrough.request,
            applyInlineCodeRequest: NoteFormat.code.request,
            applyBlockquoteRequest: NoteFormat.quote.request,
            applyUnorderedListRequest: NoteFormat.bullet.request,
            applyTaskListRequest: NoteFormat.task.request,
            selectionBoldDidChange: .notySelectionBold,
            selectionItalicDidChange: .notySelectionItalic,
            findClearHighlights: .notyFindClear,
            findQuery: .notyFindQuery,
            findResults: .notyFindResults
        )
        return config
    }

    var body: some View {
        NativeTextViewWrapper(
            text: $text,
            isWikiLinkActive: $wikiActive,
            pendingInlineReplacement: $pendingReplacement,
            configuration: configuration,
            // "" is his sentinel for the system font; the engine wants a real
            // PostScript name either way.
            fontName: Ink.face.body.isEmpty ? NSFont.systemFont(ofSize: 13).fontName : Ink.face.body,
            fontSize: Settings.noteFontSize,
            // Per-note undo stacks: switching notes and back must not let one
            // note's undo reach into another's text.
            documentId: "\(surface):\(note.id)",
            isEditable: isEditable
        )
    }
}

/// The formatting bar. Each button posts; the engine does the work.
struct NoteFormatBar: View {
    let ink: Color
    @State private var isBold = false
    @State private var isItalic = false

    private func lit(_ f: NoteFormat) -> Bool {
        switch f {
        case .bold: return isBold
        case .italic: return isItalic
        default: return false
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(NoteFormat.allCases, id: \.self) { f in
                Button { f.post() } label: {
                    Image(systemName: f.symbol)
                        .font(.system(size: 10.5, weight: .semibold))
                        .frame(width: 22, height: 20)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(lit(f) ? ink.opacity(0.14) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(ink.opacity(lit(f) ? 0.95 : 0.5))
                .tip(f.help)
                .accessibilityLabel(f.help)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        // The engine says what the caret is standing in, so the bar can show it.
        .onReceive(NotificationCenter.default.publisher(for: .notySelectionBold)) {
            isBold = ($0.userInfo?["isBold"] as? Bool) ?? false
        }
        .onReceive(NotificationCenter.default.publisher(for: .notySelectionItalic)) {
            isItalic = ($0.userInfo?["isItalic"] as? Bool) ?? false
        }
    }
}

// MARK: - Tooltips

/// Reports hover regardless of whether this app is frontmost.
///
/// SwiftUI's `.onHover` installs a tracking area whose activation is scoped to
/// the active application, and the deck is used *while another app is
/// frontmost* — so it never fired here at all. `.activeAlways` is the option
/// that says otherwise, and it has to be asked for by hand.
struct HoverArea: NSViewRepresentable {
    var delay: TimeInterval = 0
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> NSView { Tracker(delay: delay, changed: changed) }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Tracker: NSView {
        private let delay: TimeInterval
        private let changed: (Bool) -> Void

        init(delay: TimeInterval, changed: @escaping (Bool) -> Void) {
            self.delay = delay
            self.changed = changed
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func updateTrackingAreas() {
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self))
            super.updateTrackingAreas()
        }

        /// The delay lives here rather than in a dispatched block because this
        /// one can be *cancelled*. Entering and leaving inside the delay used
        /// to leave the pending block to fire after the exit had already been
        /// handled — raising a label that no further exit would take down.
        override func mouseEntered(with event: NSEvent) {
            NSObject.cancelPreviousPerformRequests(withTarget: self)
            perform(#selector(show), with: nil, afterDelay: delay)
        }

        override func mouseExited(with event: NSEvent) {
            NSObject.cancelPreviousPerformRequests(withTarget: self)
            changed(false)
        }

        /// A window going away takes its exit event with it.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                NSObject.cancelPreviousPerformRequests(withTarget: self)
                changed(false)
            }
        }

        @objc private func show() {
            guard NSEvent.pressedMouseButtons == 0 else { return }
            changed(true)
        }
    }
}

/// Our own, because the system's never appear here.
///
/// `.help()` is drawn by AppKit for the key window, and the deck's note is a
/// non-activating panel that usually is not one — so every tooltip in this app
/// was silently doing nothing. This draws inside the note instead.
struct Tip: ViewModifier {
    let text: LocalizedStringKey
    var below = true
    @State private var showing = false

    func body(content: Content) -> some View {
        content
            // A beat of delay, so passing over a row of buttons does not
            // strobe a label under each one.
            .background(HoverArea(delay: 0.35) { showing = $0 })
            .overlay(alignment: below ? .bottom : .top) {
                if showing {
                    Text(text)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.black.opacity(0.84)))
                        .fixedSize()
                        .offset(y: below ? 21 : -21)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .zIndex(20)
                }
            }
            .animation(.easeOut(duration: 0.12), value: showing)
    }
}

extension View {
    func tip(_ text: LocalizedStringKey, below: Bool = true) -> some View {
        modifier(Tip(text: text, below: below))
    }
}
