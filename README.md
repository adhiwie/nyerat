# Nyerat

**A Markdown notes editor for macOS — native, fast, and beautiful.**

Nyerat renders Markdown *as you type* — headings, tables, math, code, images, and
task lists appear inline, in a single clean writing column. No preview pane, no
split view, no round‑trip to a browser engine. Just text that looks the way it reads.

Free and open source.

---

## Why Nyerat

### It's native

Nyerat is built directly on AppKit's text system — a custom `NSTextStorage` and
layout manager doing the rendering. There is **no WebView, no Electron, no
JavaScript runtime**. LaTeX math is drawn with CoreText via SwiftMath. Tables,
code panels, checkboxes, and blockquote bars are drawn by the layout manager
itself.

That means it behaves like a Mac app: real text selection, the system Find panel,
proper undo, instant launch, and a memory footprint measured in megabytes.

### It's fast

- **Zero‑latency typing.** The editor only touches the buffer on a genuine file
  switch — typing, auto‑save, and list renumbering never reset the text or jump
  the cursor.
- **Debounced auto‑save** writes to disk 500 ms after you stop typing. You never
  press ⌘S.
- **Cached rendering.** Math images are cached per LaTeX + light/dark appearance,
  so repeated styling passes are essentially free.
- **Instant file switching** across a sidebar that can hold thousands of notes.

### It's beautiful

- Live Markdown styling with a centered, max‑width writing column
- macOS 26 Liquid Glass toolbar with a Notes‑style collapsible formatting bar
- Progressive‑blur scroll edge under the titlebar
- Nested blockquote bars with tiered rounded caps
- Rounded panels behind fenced code, with syntax highlighting for JS, TS, CSS, and HTML
- GitHub‑style tables rendered with real borders and wrapped cells
- Clickable task checkboxes drawn as crisp SF Symbols
- Fully light/dark aware — including re‑rendered math

---

## Features

| | |
|---|---|
| **Live rendering** | Headings, bold/italic/strikethrough/highlight/inline code, links |
| **Lists** | Bullets, ordered lists with auto‑renumbering, Enter‑to‑continue |
| **Task lists** | `- [ ]` / `- [x]`, toggled with a click |
| **Blockquotes** | Arbitrarily nested, with per‑level bars |
| **Code blocks** | Fenced blocks in rounded panels, syntax‑highlighted |
| **Tables** | GitHub‑style pipe tables, natively drawn |
| **Math** | Inline `$…$` and display `$$…$$` LaTeX via SwiftMath |
| **Images** | Local and remote, rendered inline |
| **Formatting bar** | Collapsible toolbar with keyboard shortcuts (⌘B, ⌘I, ⌘K, …) |
| **Word / character count** | Live count of the *rendered* text |
| **iCloud Drive sync** | Notes live in `iCloud Drive/Nyerat`, synced across your Macs |
| **Folders** | Nested folders in the sidebar, sorted newest‑first |

Files are plain `.md` on disk. Nothing is locked in a proprietary format.

---

## Requirements

- macOS 26.2 or later
- Xcode 26 or later to build

## Building

```sh
git clone https://github.com/adhiwie/nyerat
cd nyerat
open Nyerat.xcodeproj
```

Then build and run the `Nyerat` scheme (⌘R).

---

## License

Nyerat is released under the [MIT License](LICENSE).
