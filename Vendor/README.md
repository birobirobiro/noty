# Vendored code

## MarkdownEngine

From [nodes-app/swift-markdown-engine](https://github.com/nodes-app/swift-markdown-engine),
revision `08ff3c0`, licensed Apache-2.0 (`MarkdownEngine/LICENSE`).

**Modified**, and every change is marked `NOTY MODIFICATION` so a future
update can find them:

- `Styling/MarkdownASTStyler.swift` — a hidden inline marker was only shrunk
  to 0.1pt, which still draws a speck next to the word. It is drawn in
  `NSColor.clear` too, matching what the engine already does for links and
  code. Only applies while the caret is outside the token, so caret reveal is
  unchanged.
- `Services/MarkdownEditorServices.swift`, `TextView/ContextMenu.swift`,
  `TextView/Coordinator/NativeTextViewCoordinator*.swift` — added a task-list
  action (`applyTaskListRequest`), which is their own generic `applyList` with
  a `- [ ] ` prefix.
- `TextView/ContextMenu.swift` — `applyList` and `applyHeading` only ever
  added their marker. Each stripped an existing one and put it straight back,
  which stops "- - item" but means a second click does nothing. Both toggle
  now, matching `didMarkdownBlockquote` in the same file, which already did.
- `TextView/ContextMenu.swift` — `applyList` prefixed the whole selected block
  once instead of each line, so asking for a bullet across two lines produced
  `- one\ntwo`. It now applies their per-line logic to each line in turn.

It is copied in rather than fetched because this project builds with plain
`swiftc` and has no package manager; the engine's core target has no
dependencies of its own, so it compiles as part of the same module. To update
it, replace the directory with a newer checkout of that target and rebuild.
