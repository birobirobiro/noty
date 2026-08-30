# Vendored code

## MarkdownEngine

From [nodes-app/swift-markdown-engine](https://github.com/nodes-app/swift-markdown-engine),
revision `08ff3c0`, licensed Apache-2.0 (`MarkdownEngine/LICENSE`). Unmodified.

It is copied in rather than fetched because this project builds with plain
`swiftc` and has no package manager; the engine's core target has no
dependencies of its own, so it compiles as part of the same module. To update
it, replace the directory with a newer checkout of that target and rebuild.
