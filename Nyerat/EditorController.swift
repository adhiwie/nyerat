import AppKit
import SwiftUI
import Combine

/// Bridges the SwiftUI format bar to the active `NSTextView`. The editor registers its text view
/// here; the toolbar buttons call these methods to wrap the selection or toggle line prefixes.
enum CountMode: String { case words, characters }

@MainActor
final class EditorController: ObservableObject {
    weak var textView: NSTextView?
    /// Counts of the rendered text (markdown syntax stripped). Updated by the editor coordinator.
    @Published var wordCount: Int = 0
    @Published var characterCount: Int = 0
    /// Whether the footer shows words or characters (persisted across launches).
    @Published var countMode: CountMode = CountMode(rawValue: UserDefaults.standard.string(forKey: "countMode") ?? "") ?? .words {
        didSet { UserDefaults.standard.set(countMode.rawValue, forKey: "countMode") }
    }

    // MARK: - Inline wrapping (bold / italic / …) — toggles the marker on/off

    /// All inline markers are a repeat of a single character (`**`, `*`, `~~`, `==`, `` ` ``).
    /// Toggles: strips the marker if the selection is already wrapped in it, otherwise wraps it.
    private func toggleWrap(_ marker: String) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let ns = tv.string as NSString
        let range = tv.selectedRange()
        let markerNS = marker as NSString
        let mLen = markerNS.length
        let markerChar = marker.first!
        let start = range.location
        let end = NSMaxRange(range)
        let selected = ns.substring(with: range)

        func char(at i: Int) -> Character? {
            guard i >= 0, i < ns.length else { return nil }
            return ns.substring(with: NSRange(location: i, length: 1)).first
        }

        // Case A: markers sit just outside the selection — `**[word]**`. Strip them. The run guard
        // ensures we don't treat the inner `*` of `**` (bold) as an italic `*`.
        if start - mLen >= 0, end + mLen <= ns.length,
           ns.substring(with: NSRange(location: start - mLen, length: mLen)) == marker,
           ns.substring(with: NSRange(location: end, length: mLen)) == marker,
           char(at: start - mLen - 1) != markerChar, char(at: end + mLen) != markerChar {
            let outer = NSRange(location: start - mLen, length: range.length + 2 * mLen)
            replace(outer, with: selected, tv, storage)
            tv.setSelectedRange(NSRange(location: start - mLen, length: (selected as NSString).length))
            return
        }

        // Case B: the selection itself includes the markers — `[**word**]`. Strip them.
        if (selected as NSString).length >= 2 * mLen,
           selected.hasPrefix(marker), selected.hasSuffix(marker) {
            let inner = (selected as NSString).substring(
                with: NSRange(location: mLen, length: (selected as NSString).length - 2 * mLen))
            replace(range, with: inner, tv, storage)
            tv.setSelectedRange(NSRange(location: start, length: (inner as NSString).length))
            return
        }

        // Case C: not styled yet — wrap it.
        replace(range, with: marker + selected + marker, tv, storage)
        if selected.isEmpty {
            tv.setSelectedRange(NSRange(location: start + mLen, length: 0))
        } else {
            tv.setSelectedRange(NSRange(location: start + mLen, length: (selected as NSString).length))
        }
    }

    private func replace(_ range: NSRange, with string: String, _ tv: NSTextView, _ storage: NSTextStorage) {
        guard tv.shouldChangeText(in: range, replacementString: string) else { return }
        storage.replaceCharacters(in: range, with: string)
        tv.didChangeText()
        tv.window?.makeFirstResponder(tv)
    }

    func bold()   { toggleWrap("**") }
    func italic() { toggleWrap("*") }
    func strike() { toggleWrap("~~") }
    func mark()   { toggleWrap("==") }
    func code()   { toggleWrap("`") }

    // MARK: - Line prefixes (lists / quote / checkbox)

    /// Add `prefix` at the start of the current line, or remove it if already present.
    private func toggleLinePrefix(_ prefix: String) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let sel = tv.selectedRange()
        let ns = tv.string as NSString
        let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let line = ns.substring(with: lineRange)
        let prefixLen = (prefix as NSString).length

        if line.hasPrefix(prefix) {
            let removeRange = NSRange(location: lineRange.location, length: prefixLen)
            guard tv.shouldChangeText(in: removeRange, replacementString: "") else { return }
            storage.replaceCharacters(in: removeRange, with: "")
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: max(sel.location - prefixLen, lineRange.location), length: 0))
        } else {
            let insertRange = NSRange(location: lineRange.location, length: 0)
            guard tv.shouldChangeText(in: insertRange, replacementString: prefix) else { return }
            storage.replaceCharacters(in: insertRange, with: prefix)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: sel.location + prefixLen, length: 0))
        }
        tv.window?.makeFirstResponder(tv)
    }

    func bulletList()   { toggleLinePrefix("- ") }
    func numberedList() { toggleLinePrefix("1. ") }
    func quote()        { toggleLinePrefix("> ") }
    func checkbox()     { toggleLinePrefix("- [ ] ") }

    /// Set the current line's heading level (1–6), replacing any existing heading prefix.
    /// Picking the level the line already has clears the heading.
    func setHeading(_ newLevel: Int) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let sel = tv.selectedRange()
        let ns = tv.string as NSString
        let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let line = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)

        var hashes = 0
        for ch in line { if ch == "#" { hashes += 1 } else { break } }
        let hasSpace = line.count > hashes && Array(line)[hashes] == " "
        let level = (hasSpace && (1...6).contains(hashes)) ? hashes : 0
        let existingLen = level > 0 ? level + 1 : 0            // hashes + the space
        let newPrefix = newLevel == level ? "" : String(repeating: "#", count: newLevel) + " "

        let replaceRange = NSRange(location: lineRange.location, length: existingLen)
        guard tv.shouldChangeText(in: replaceRange, replacementString: newPrefix) else { return }
        storage.replaceCharacters(in: replaceRange, with: newPrefix)
        tv.didChangeText()
        let delta = (newPrefix as NSString).length - existingLen
        tv.setSelectedRange(NSRange(location: max(sel.location + delta, lineRange.location), length: 0))
        tv.window?.makeFirstResponder(tv)
    }

    // MARK: - Link

    func insertLink() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        let selected = (tv.string as NSString).substring(with: range)
        let text = selected.isEmpty ? "text" : selected
        let replacement = "[\(text)](url)"
        guard tv.shouldChangeText(in: range, replacementString: replacement) else { return }
        storage.replaceCharacters(in: range, with: replacement)
        tv.didChangeText()
        // Select the placeholder "url" so it can be typed over.
        let urlLoc = range.location + ("[\(text)](" as NSString).length
        tv.setSelectedRange(NSRange(location: urlLoc, length: 3))
        tv.window?.makeFirstResponder(tv)
    }
}

/// Approximate word and character counts of the *rendered* text: strip markdown syntax, then count
/// whitespace-separated tokens (words) and characters (with single spaces). Formatting markers, code
/// fences, table pipes, image/math/link URLs etc. are removed (link text is kept); math and images
/// render as graphics so they contribute nothing.
func renderedCounts(_ markdown: String) -> (words: Int, characters: Int) {
    var s = markdown
    func strip(_ pattern: String, _ template: String = " ") {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return }
        s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    strip(#"(?m)^[ \t]*(```|~~~).*$"#)              // code fence lines (keep the code content)
    strip(#"\$\$[\s\S]*?\$\$"#)                     // display math
    strip(#"(?m)\$[^$\n]+\$"#)                      // inline math
    strip(#"!\[[^\]]*\]\([^)]*\)"#)                 // inline images
    strip(#"!\[[^\]]*\]\[[^\]]*\]"#)                // reference images
    strip(#"(?m)^[ \t]*\[[^\]]+\]:.*$"#)            // reference definitions
    strip(#"\[([^\]]+)\]\([^)]*\)"#, "$1")          // links → keep text
    strip(#"\[([^\]]+)\]\[[^\]]*\]"#, "$1")         // reference links → keep text
    strip(#"(?m)^[ \t]*#{1,6}[ \t]+"#)              // heading markers
    strip(#"(?m)^[ \t]*>+[ \t]?"#)                  // blockquote markers
    strip(#"\[[ xX]\]"#)                            // checkboxes
    strip(#"(?m)^[ \t]*([-*+]|\d+\.)[ \t]+"#)       // list markers
    strip(#"(?m)^[ \t]*\|?[ \t:|-]+\|?[ \t]*$"#)    // table delimiter / HR-ish rows
    strip(#"\|"#)                                    // table pipes
    strip(#"[*_~=`]"#)                              // emphasis / code markers

    let words = s.split(whereSeparator: { $0.isWhitespace })
    let characters = words.joined(separator: " ").count
    return (words.count, characters)
}

/// Formatting controls pinned at the trailing edge of the window toolbar. Collapsed, only an "Aa"
/// format button remains (like Notes); expanding slides the buttons out leftward from that anchor.
struct FormatToolbar: ToolbarContent {
    @ObservedObject var controller: EditorController
    @Binding var expanded: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 4) {
                if expanded {
                    control("bold", "Bold", "b") { controller.bold() }
                    control("italic", "Italic", "i") { controller.italic() }
                    control("strikethrough", "Strikethrough", nil) { controller.strike() }
                    control("highlighter", "Highlight", nil) { controller.mark() }
                    control("chevron.left.forwardslash.chevron.right", "Inline code", nil) { controller.code() }
                    HeadingMenuButton(controller: controller)
                    control("list.bullet", "Bulleted list", nil) { controller.bulletList() }
                    control("list.number", "Numbered list", nil) { controller.numberedList() }
                    control("checklist", "Checkbox", nil) { controller.checkbox() }
                    control("text.quote", "Quote", nil) { controller.quote() }
                    control("link", "Link", "k") { controller.insertLink() }
                }

                FormatButton(icon: expanded ? "chevron.right" : "bold.italic.underline",
                             help: expanded ? "Collapse toolbar" : "Formatting",
                             shortcut: nil) {
                    withAnimation(.smooth(duration: 0.3)) { expanded.toggle() }
                }
            }
            // Fill the item's slot and pin content to its trailing edge: the toolbar resizes the
            // slot instantly while the HStack width animates, and centered content would drag the
            // (persistent) toggle from the slot's middle to its edge.
            .frame(maxWidth: .infinity, alignment: .trailing)
            .animation(.smooth(duration: 0.3), value: expanded)
        }
    }

    private func control(_ icon: String, _ help: String, _ shortcut: Character?,
                         _ action: @escaping () -> Void) -> some View {
        FormatButton(icon: icon, help: help, shortcut: shortcut, action: action)
    }
}

/// The heading picker: visually identical to `FormatButton`, but opens a menu of heading levels.
private struct HeadingMenuButton: View {
    let controller: EditorController

    var body: some View {
        Menu {
            ForEach(1...6, id: \.self) { level in
                Button("Heading \(level)") { controller.setHeading(level) }
            }
        } label: {
            Image(systemName: "textformat.size")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Headings")
        .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .trailing)))
    }
}

/// A standard toolbar icon button. Uses the system (borderless) toolbar button style so hover
/// highlights fill the button's Liquid Glass well, exactly like the sidebar-toggle button.
private struct FormatButton: View {
    let icon: String
    let help: String
    let shortcut: Character?
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            Image(systemName: icon)
                .contentTransition(.symbolEffect(.replace))
        }
        .help(shortcut != nil ? "\(help) (⌘\(shortcut!.uppercased()))" : help)
        .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .trailing)))

        if let shortcut {
            button.keyboardShortcut(KeyEquivalent(shortcut), modifiers: .command)
        } else {
            button
        }
    }
}
