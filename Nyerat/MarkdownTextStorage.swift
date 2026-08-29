import AppKit

extension NSAttributedString.Key {
    /// Tags a `[]` / `[ ]` / `[x]` range so the layout manager can draw a checkbox icon over it.
    /// The value is a `Bool` — true when checked.
    static let checkboxState = NSAttributedString.Key("nyeratCheckboxState")
    /// Tags a horizontal-rule line so the layout manager can draw a full-width thin line.
    static let horizontalRule = NSAttributedString.Key("nyeratHorizontalRule")
    /// Tags the content of a fenced code block so the layout manager can draw a rounded panel
    /// behind it. Value is a `Bool` (true).
    static let codeBlockBackground = NSAttributedString.Key("nyeratCodeBlockBackground")
    /// Tags a hidden table source line with a `TableRowRef` so the layout manager can draw that
    /// row of the rendered table into the reserved vertical space.
    static let tableRow = NSAttributedString.Key("nyeratTableRow")
    /// Tags a hidden image source line with an `ImageRef` so the view can draw the image into the
    /// reserved vertical space.
    static let imageAttachment = NSAttributedString.Key("nyeratImageAttachment")
    /// Tags a hidden math source line with a `MathRef` so the view can draw the rendered LaTeX.
    static let mathImage = NSAttributedString.Key("nyeratMathImage")
    /// Tags a blockquote line so the layout manager can draw vertical bars on its left.
    /// The value is an `Int` nesting depth (1 = `>`, 2 = `>>`, …); the layout manager draws
    /// one bar per level.
    static let blockquoteBar = NSAttributedString.Key("nyeratBlockquoteBar")
}

/// Shared left edge for the text of blockquotes, bullets, ordered lists and checkboxes, so they
/// all line up regardless of their (variable-width) markers.
enum Layout {
    static let contentIndent: CGFloat = 28
}

/// Geometry for nested blockquote bars. Level 1 aligns its content with `Layout.contentIndent`
/// (so it lines up with lists/checkboxes); each deeper level shifts bar + content by `indentStep`.
enum BlockquoteMetrics {
    static let barGutter: CGFloat = 8      // x of the level-1 bar within the line fragment
    static let indentStep: CGFloat = 24    // horizontal shift added per nesting level
    static let barWidth: CGFloat = 4

    static func contentIndent(depth: Int) -> CGFloat {
        Layout.contentIndent + CGFloat(max(depth - 1, 0)) * indentStep
    }

    static func barX(level: Int) -> CGFloat {
        barGutter + CGFloat(level - 1) * indentStep
    }
}

/// Geometry for checkbox rendering.
enum CheckboxMetrics {
    static let iconSide: CGFloat = 17
    /// Task text starts at the shared content indent (icon sits in the gutter to its left).
    static let contentIndent: CGFloat = Layout.contentIndent
}

final class MarkdownTextStorage: NSTextStorage {

    private var backing = NSMutableAttributedString()

    /// `[id]: url "title"` reference definitions, collected each styling pass (they can be defined
    /// anywhere in the document) and used to resolve reference-style images `![alt][id]`.
    private var referenceDefinitions: [String: (url: String, title: String?)] = [:]

    var insertionPoint: Int = 0 {
        didSet {
            guard oldValue != insertionPoint else { return }
            // Re-style for active-line highlighting. applyStyles mutates `backing` directly
            // (no edited() call), then we ask the layout manager to re-render — this never
            // reports a storage edit, so it can't disturb the text view's selection.
            applyStyles()
            refreshLayout()
        }
    }

    // MARK: - NSTextStorage required

    override var string: String { backing.string }

    override func attributes(at location: Int, effectiveRange range: NSRangePointer?) -> [NSAttributedString.Key: Any] {
        guard location < backing.length else { return [:] }
        return backing.attributes(at: location, effectiveRange: range)
    }

    override func replaceCharacters(in range: NSRange, with str: String) {
        beginEditing()
        backing.replaceCharacters(in: range, with: str)
        edited(.editedCharacters, range: range, changeInLength: (str as NSString).length - range.length)
        endEditing()
    }

    override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
        guard range.location + range.length <= backing.length else { return }
        beginEditing()
        backing.setAttributes(attrs, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
        endEditing()
    }

    override func processEditing() {
        // Re-style the whole document into `backing` BEFORE super processes the edit, so the
        // characters around the edit are laid out with correct attributes immediately.
        applyStyles()
        super.processEditing()
        // applyStyles also changed attributes far outside the edited character range (active-line
        // toggling, bold/list markers on other lines). Those must be re-rendered, but we must NOT
        // do it via edited(): unioning a full-range edit with the character edit makes the text
        // view treat the whole document as character-edited and jump the cursor to the end.
        // Invalidating the layout manager re-renders the styling without touching selection.
        refreshLayout()
    }

    /// Force the layout manager(s) to re-lay-out and redraw the whole document using the current
    /// attributes in `backing`, without reporting a storage edit.
    private func refreshLayout() {
        guard backing.length > 0 else { return }
        let full = NSRange(location: 0, length: backing.length)
        for lm in layoutManagers {
            // Regenerate glyphs (not just layout): styling can change a run's font family, and
            // stale glyph indices from the old font render as garbage under the new one.
            lm.invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
            lm.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
            lm.invalidateDisplay(forCharacterRange: full)
        }
    }

    // MARK: - Core styling pass

    private func applyStyles() {
        guard backing.length > 0 else { return }
        let fullRange = NSRange(location: 0, length: backing.length)
        backing.setAttributes(Styles.body, range: fullRange)

        referenceDefinitions = collectReferenceDefinitions()

        let safeIP = min(max(insertionPoint, 0), backing.length)
        let activePara = (backing.string as NSString).lineRange(for: NSRange(location: safeIP, length: 0))

        let text = backing.string as NSString
        var pos = 0
        var inFence = false
        var fenceContentStart = 0
        var fenceLang = ""
        var inMathFence = false
        var mathOpenLine = NSRange(location: 0, length: 0)

        while pos < backing.length {
            let lineRange = text.lineRange(for: NSRange(location: pos, length: 0))
            guard lineRange.length > 0 else { break }

            let line = text.substring(with: lineRange).trimmingCharacters(in: .newlines)
            let isActive = lineRange.location < NSMaxRange(activePara) &&
                           NSMaxRange(lineRange) > activePara.location

            if inMathFence {
                // Inside a `$$ … $$` display block; a lone `$$` closes it.
                if line.trimmingCharacters(in: .whitespaces) == "$$" {
                    closeMathFence(open: mathOpenLine, close: lineRange)
                    inMathFence = false
                }
            } else if line.hasPrefix("```") || line.hasPrefix("~~~") {
                // The fence line itself is hidden (collapsed when inactive, revealed for editing).
                hideFenceLine(lineRange, isActive: isActive)
                if inFence {
                    let contentRange = NSRange(location: fenceContentStart,
                                               length: lineRange.location - fenceContentStart)
                    applyCodeBlock(contentRange: contentRange, language: fenceLang)
                    inFence = false
                } else {
                    inFence = true
                    fenceContentStart = NSMaxRange(lineRange)
                    fenceLang = fenceLanguage(line)
                }
            } else if !inFence {
                // A table (header + delimiter + body) is consumed as a block; when the cursor is
                // inside it, `tryStyleTable` returns nil so the raw source shows for editing.
                if line.trimmingCharacters(in: .whitespaces) == "$$" {
                    inMathFence = true
                    mathOpenLine = lineRange
                } else if let consumed = tryStyleTable(headerRange: lineRange) {
                    pos = NSMaxRange(consumed)
                    continue
                } else if let consumed = tryStyleMathLine(lineRange: lineRange) {
                    pos = NSMaxRange(consumed)
                    continue
                } else if tryHideReferenceDefinition(lineRange: lineRange, isActive: isActive) {
                    // Collapsed `[id]: url` definition — nothing more to style.
                } else if !tryStyleImage(lineRange: lineRange) {
                    styleLine(lineRange: lineRange, line: line, isActive: isActive)
                }
            }

            pos = lineRange.location + lineRange.length
        }

        // Unclosed fence block — style everything after the opening fence as code.
        if inFence {
            applyCodeBlock(contentRange: NSRange(location: fenceContentStart,
                                                 length: backing.length - fenceContentStart),
                           language: fenceLang)
        }
    }

    // MARK: - Tables

    /// If the line at `headerRange` begins a pipe table (header + `---|---` delimiter + body),
    /// renders it and returns the whole table's character range. Returns nil if it isn't a table,
    /// or if the cursor is inside it (so the raw markdown is shown for editing instead).
    private func tryStyleTable(headerRange: NSRange) -> NSRange? {
        let ns = backing.string as NSString
        let headerLine = ns.substring(with: headerRange).trimmingCharacters(in: .newlines)
        guard headerLine.contains("|") else { return nil }

        let delimStart = NSMaxRange(headerRange)
        guard delimStart < backing.length else { return nil }
        let delimRange = ns.lineRange(for: NSRange(location: delimStart, length: 0))
        let delimLine = ns.substring(with: delimRange).trimmingCharacters(in: .newlines)
        guard isTableDelimiter(delimLine) else { return nil }

        // Consume contiguous following lines that look like body rows (contain a pipe).
        var bodyRanges: [NSRange] = []
        var pos = NSMaxRange(delimRange)
        while pos < backing.length {
            let r = ns.lineRange(for: NSRange(location: pos, length: 0))
            let l = ns.substring(with: r).trimmingCharacters(in: .newlines)
            guard l.contains("|"), !l.trimmingCharacters(in: .whitespaces).isEmpty else { break }
            bodyRanges.append(r)
            pos = NSMaxRange(r)
        }

        let tableEnd = bodyRanges.last.map { NSMaxRange($0) } ?? NSMaxRange(delimRange)
        let tableRange = NSRange(location: headerRange.location, length: tableEnd - headerRange.location)

        // Editing: if the caret's line is within the table, bail so the raw source renders. Using
        // the caret's line (not the raw offset) avoids revealing when the caret is on the line
        // immediately after the table.
        let ip = min(max(insertionPoint, 0), backing.length)
        let caretLine = ns.lineRange(for: NSRange(location: ip, length: 0))
        if caretLine.location >= tableRange.location && caretLine.location < NSMaxRange(tableRange) {
            return nil
        }

        let alignments = parseAlignments(delimLine)
        let headerCells = splitRow(headerLine)
        let bodyCells = bodyRanges.map { splitRow(ns.substring(with: $0).trimmingCharacters(in: .newlines)) }
        guard let layout = TableLayout(
            headerCells: headerCells, bodyRows: bodyCells, alignments: alignments,
            availableWidth: tableAvailableWidth(),
            bodyFont: Styles.bodyFont,
            headerFont: NSFont.systemFont(ofSize: 15, weight: .semibold)) else { return nil }

        reserveTableRow(headerRange, layout: layout, index: 0)
        collapseLine(delimRange)
        for (i, r) in bodyRanges.enumerated() {
            reserveTableRow(r, layout: layout, index: i + 1)
        }
        return tableRange
    }

    /// Hide a table source line and force its fragment to the rendered row's height, tagging it so
    /// the layout manager draws that row into the reserved space.
    private func reserveTableRow(_ range: NSRange, layout: TableLayout, index: Int) {
        guard index < layout.rowHeights.count,
              range.location != NSNotFound, NSMaxRange(range) <= backing.length else { return }
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = layout.rowHeights[index]
        p.maximumLineHeight = layout.rowHeights[index]
        p.lineBreakMode = .byTruncatingTail   // keep the hidden source on one fragment (no wrap)
        backing.addAttribute(.paragraphStyle, value: p, range: range)
        backing.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
        // Use a system-family font (not monospace): when the row is revealed for editing its font
        // switches to the system-family body font, and a same-family hidden font keeps the glyph
        // cache valid (a cross-family switch renders stale glyph IDs as garbage).
        backing.addAttribute(.font, value: NSFont.systemFont(ofSize: 8), range: range)
        backing.addAttribute(.tableRow, value: TableRowRef(layout: layout, index: index), range: range)
    }

    /// Collapse the `---|---` delimiter line to no visible height.
    private func collapseLine(_ range: NSRange) {
        guard range.location != NSNotFound, NSMaxRange(range) <= backing.length else { return }
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = 0.1
        p.maximumLineHeight = 0.1
        p.lineBreakMode = .byTruncatingTail
        backing.addAttribute(.paragraphStyle, value: p, range: range)
        backing.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
        backing.addAttribute(.font, value: NSFont.systemFont(ofSize: 0.1), range: range)
    }

    private func tableAvailableWidth() -> CGFloat {
        let w = layoutManagers.first?.textContainers.first?.size.width ?? 648
        // Leave a few points so the right-hand border isn't clipped at the container edge.
        return (w > 1 ? w : 648) - 4
    }

    /// A delimiter row is only pipes, colons, dashes and spaces, and contains at least one dash.
    private func isTableDelimiter(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") || t.hasPrefix(":") || t.hasPrefix("-") else { return false }
        return t.allSatisfy { "|:- \t".contains($0) }
    }

    private func parseAlignments(_ line: String) -> [NSTextAlignment] {
        splitRow(line).map { cell in
            let c = cell.trimmingCharacters(in: .whitespaces)
            let left = c.hasPrefix(":"), right = c.hasSuffix(":")
            if left && right { return .center }
            if right { return .right }
            return .left
        }
    }

    /// Split a table row on unescaped pipes, dropping the empty cells produced by outer pipes.
    private func splitRow(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var previous: Character = " "
        for ch in line {
            if ch == "|" && previous != "\\" {
                cells.append(current); current = ""
            } else {
                current.append(ch)
            }
            previous = ch
        }
        cells.append(current)
        if let first = cells.first, first.trimmingCharacters(in: .whitespaces).isEmpty { cells.removeFirst() }
        if let last = cells.last, last.trimmingCharacters(in: .whitespaces).isEmpty { cells.removeLast() }
        return cells.map {
            $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\|", with: "|")
        }
    }

    // MARK: - Images

    /// `![alt](url)` or `![alt](url "title")` alone on a line. g1 = alt, g2 = url, g3 = title.
    private static let imageLine = try! NSRegularExpression(
        pattern: #"^\s*!\[([^\]]*)\]\(\s*(\S+?)(?:\s+"([^"]*)")?\s*\)\s*$"#)
    /// Reference-style image `![alt][id]` (id may be empty → use alt). g1 = alt, g2 = id.
    private static let imageRef = try! NSRegularExpression(
        pattern: #"^\s*!\[([^\]]*)\]\[([^\]]*)\]\s*$"#)
    /// A reference definition `[id]: url "title"`. g1 = id, g2 = url, g3 = title.
    private static let refDef = try! NSRegularExpression(
        pattern: #"^\s*\[([^\]]+)\]:\s*(\S+)(?:\s+"([^"]*)")?\s*$"#)

    /// Scan the whole document for `[id]: url "title"` definitions (case-insensitive ids).
    private func collectReferenceDefinitions() -> [String: (url: String, title: String?)] {
        var defs: [String: (url: String, title: String?)] = [:]
        let ns = backing.string as NSString
        var pos = 0
        while pos < ns.length {
            let r = ns.lineRange(for: NSRange(location: pos, length: 0))
            let line = ns.substring(with: r).trimmingCharacters(in: .newlines)
            let lr = NSRange(location: 0, length: (line as NSString).length)
            if let m = Self.refDef.firstMatch(in: line, range: lr) {
                let lineNS = line as NSString
                let id = lineNS.substring(with: m.range(at: 1)).lowercased()
                let url = lineNS.substring(with: m.range(at: 2))
                let title = m.range(at: 3).location != NSNotFound ? lineNS.substring(with: m.range(at: 3)) : nil
                defs[id] = (url, title)
            }
            pos = NSMaxRange(r)
        }
        return defs
    }

    /// Collapse a `[id]: url` definition line (hidden like GitHub); revealed for editing when active.
    private func tryHideReferenceDefinition(lineRange: NSRange, isActive: Bool) -> Bool {
        guard !isActive else { return false }
        let ns = backing.string as NSString
        let line = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)
        let lr = NSRange(location: 0, length: (line as NSString).length)
        guard Self.refDef.firstMatch(in: line, range: lr) != nil else { return false }
        collapseLine(lineRange)
        return true
    }

    /// If the line is a standalone image, hide the markdown, reserve the image's height and tag it
    /// for drawing. Returns false (so the raw source shows) for non-images or when it's being edited.
    private func tryStyleImage(lineRange: NSRange) -> Bool {
        let ns = backing.string as NSString
        let line = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)
        let lr = NSRange(location: 0, length: (line as NSString).length)
        let lineNS = line as NSString

        // Resolve either the inline form `![alt](url)` or the reference form `![alt][id]`.
        let alt: String
        let url: String
        let title: String?
        if let m = Self.imageLine.firstMatch(in: line, range: lr) {
            alt = lineNS.substring(with: m.range(at: 1))
            url = lineNS.substring(with: m.range(at: 2))
            title = m.range(at: 3).location != NSNotFound ? lineNS.substring(with: m.range(at: 3)) : nil
        } else if let m = Self.imageRef.firstMatch(in: line, range: lr) {
            alt = lineNS.substring(with: m.range(at: 1))
            let idRange = m.range(at: 2)
            let idRaw = idRange.length > 0 ? lineNS.substring(with: idRange) : alt
            guard let def = referenceDefinitions[idRaw.lowercased()] else { return false }
            url = def.url
            title = def.title
        } else {
            return false
        }

        // Editing this line → reveal raw markdown.
        let ip = min(max(insertionPoint, 0), backing.length)
        let caretLine = ns.lineRange(for: NSRange(location: ip, length: 0))
        if caretLine.location == lineRange.location { return false }

        let size = imageDisplaySize(url: url)

        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = size.height
        p.maximumLineHeight = size.height
        p.lineBreakMode = .byTruncatingTail
        backing.addAttribute(.paragraphStyle, value: p, range: lineRange)
        backing.addAttribute(.foregroundColor, value: NSColor.clear, range: lineRange)
        backing.addAttribute(.font, value: NSFont.systemFont(ofSize: 8), range: lineRange)
        backing.addAttribute(.imageAttachment,
                             value: ImageRef(url: url, alt: alt, title: title, displaySize: size),
                             range: lineRange)
        return true
    }

    /// Display size: fit the image within the content width, capped in height. While the image is
    /// still loading, a modest placeholder box is reserved instead.
    private func imageDisplaySize(url: String) -> CGSize {
        let maxWidth = tableAvailableWidth()
        let maxHeight: CGFloat = 480
        guard let image = RemoteImageStore.shared.image(for: url),
              image.size.width > 0, image.size.height > 0 else {
            return CGSize(width: min(maxWidth, 260), height: 88)   // loading / failed placeholder
        }
        let natural = image.size
        var w = min(natural.width, maxWidth)
        var h = w * natural.height / natural.width
        if h > maxHeight { h = maxHeight; w = h * natural.width / natural.height }
        return CGSize(width: w, height: h)
    }

    // MARK: - Math (LaTeX via SwiftMath)

    /// Single-line `$$…$$` (display) or `$…$` (inline). g1 = latex.
    private static let mathBlockLine  = try! NSRegularExpression(pattern: #"^\s*\$\$(.+?)\$\$\s*$"#)
    private static let mathInlineLine = try! NSRegularExpression(pattern: #"^\s*\$([^$\n]+)\$\s*$"#)

    /// Render a standalone `$$…$$` / `$…$` line as a math image; nil if it isn't one or is being edited.
    private func tryStyleMathLine(lineRange: NSRange) -> NSRange? {
        let ns = backing.string as NSString
        let line = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)
        let lr = NSRange(location: 0, length: (line as NSString).length)
        let lineNS = line as NSString

        let latex: String
        let display: Bool
        if let m = Self.mathBlockLine.firstMatch(in: line, range: lr) {
            latex = lineNS.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces); display = true
        } else if let m = Self.mathInlineLine.firstMatch(in: line, range: lr) {
            latex = lineNS.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces); display = false
        } else {
            return nil
        }
        guard !latex.isEmpty, !isCaretIn(lineRange) else { return nil }
        guard let ref = renderMath(latex, display: display) else { return nil }
        reserveMathLine(lineRange, ref: ref)
        return lineRange
    }

    /// Finish a `$$ … $$` display block: render the content, host the image on the opening line and
    /// collapse the content + closing lines. Leaves everything raw when the caret is inside (editing).
    private func closeMathFence(open: NSRange, close: NSRange) {
        let blockRange = NSRange(location: open.location, length: NSMaxRange(close) - open.location)
        guard !isCaretIn(blockRange) else { return }
        let contentRange = NSRange(location: NSMaxRange(open), length: close.location - NSMaxRange(open))
        guard contentRange.length > 0 else { return }
        let latex = (backing.string as NSString).substring(with: contentRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !latex.isEmpty, let ref = renderMath(latex, display: true) else { return }
        reserveMathLine(open, ref: ref)
        collapseRange(contentRange)
        collapseLine(close)
    }

    /// Render LaTeX to an image sized to fit the content width.
    private func renderMath(_ latex: String, display: Bool) -> MathRef? {
        guard let image = MathRenderer.shared.image(latex: latex, display: display, dark: isDarkAppearance()) else {
            return nil
        }
        var size = image.size
        let maxWidth = tableAvailableWidth()
        if size.width > maxWidth, size.width > 0 {
            size = CGSize(width: maxWidth, height: size.height * (maxWidth / size.width))
        }
        return MathRef(image: image, displaySize: size)
    }

    private func reserveMathLine(_ range: NSRange, ref: MathRef) {
        guard range.location != NSNotFound, NSMaxRange(range) <= backing.length else { return }
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = ref.displaySize.height
        p.maximumLineHeight = ref.displaySize.height
        p.lineBreakMode = .byTruncatingTail
        backing.addAttribute(.paragraphStyle, value: p, range: range)
        backing.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
        backing.addAttribute(.font, value: NSFont.systemFont(ofSize: 8), range: range)
        backing.addAttribute(.mathImage, value: ref, range: range)
    }

    /// Collapse every line intersecting `range` to no visible height.
    private func collapseRange(_ range: NSRange) {
        let ns = backing.string as NSString
        var p = range.location
        while p < NSMaxRange(range) {
            let r = ns.lineRange(for: NSRange(location: p, length: 0))
            collapseLine(r)
            p = NSMaxRange(r)
        }
    }

    private func isCaretIn(_ range: NSRange) -> Bool {
        let ip = min(max(insertionPoint, 0), backing.length)
        let caretLine = (backing.string as NSString).lineRange(for: NSRange(location: ip, length: 0))
        return caretLine.location >= range.location && caretLine.location < NSMaxRange(range)
    }

    private func isDarkAppearance() -> Bool {
        let appearance = layoutManagers.first?.firstTextView?.effectiveAppearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Re-run the styling pass (e.g. after a remote image finishes loading) without a text edit.
    func reprocess() {
        guard backing.length > 0 else { return }
        applyStyles()
        refreshLayout()
    }

    /// Language token after the opening fence (```` ```js ```` → "js"), lowercased.
    private func fenceLanguage(_ line: String) -> String {
        var s = Substring(line)
        while s.first == "`" || s.first == "~" { s = s.dropFirst() }
        return s.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Apply the code panel styling + syntax highlighting to the content between fences.
    private func applyCodeBlock(contentRange: NSRange, language: String) {
        guard contentRange.length > 0,
              contentRange.location >= 0,
              NSMaxRange(contentRange) <= backing.length else { return }
        backing.addAttributes(Styles.codeBlock, range: contentRange)
        backing.addAttribute(.codeBlockBackground, value: true, range: contentRange)
        CodeHighlighter.highlight(backing, range: contentRange, language: language)
    }

    /// Collapse a ``` fence line to near-zero height (clear) when inactive; show it muted and
    /// editable when the cursor is on it.
    private func hideFenceLine(_ range: NSRange, isActive: Bool) {
        guard range.location != NSNotFound, range.length > 0,
              NSMaxRange(range) <= backing.length else { return }
        if isActive {
            backing.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
            backing.addAttribute(.font, value: Styles.monoFont, range: range)
        } else {
            backing.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
            backing.addAttribute(.font, value: Styles.fenceHiddenFont, range: range)
        }
    }

    // MARK: - Line dispatch

    private func styleLine(lineRange: NSRange, line: String, isActive: Bool) {
        if isHR(line) {
            backing.addAttributes(Styles.hr, range: lineRange)
            backing.addAttribute(.horizontalRule, value: true, range: lineRange)
            return
        }
        if let m = R.heading.firstMatch(in: backing.string, range: lineRange) {
            let syntaxRange = m.range(at: 1)
            let contentRange = m.range(at: 2)
            let level = min((backing.string as NSString).substring(with: syntaxRange).filter { $0 == "#" }.count, 6)
            backing.addAttributes(Styles.heading(level), range: lineRange)
            hide(syntaxRange, isActive: isActive)
            applyInline(in: contentRange, isActive: isActive)
            return
        }
        if let m = R.blockquote.firstMatch(in: backing.string, range: lineRange) {
            let markerRange = m.range(at: 1)
            let depth = blockquoteDepth(markerRange)
            backing.addAttributes(Styles.blockquote(depth: depth), range: lineRange)
            backing.addAttribute(.blockquoteBar, value: depth, range: lineRange)
            hide(markerRange, isActive: isActive)
            applyInline(in: m.range(at: 2), isActive: isActive)
            return
        }
        if let m = R.checkedBox.firstMatch(in: backing.string, range: lineRange) {
            styleCheckbox(m, lineRange: lineRange, checked: true, isActive: isActive)
            return
        }
        if let m = R.uncheckedBox.firstMatch(in: backing.string, range: lineRange) {
            styleCheckbox(m, lineRange: lineRange, checked: false, isActive: isActive)
            return
        }
        if let m = R.orderedList.firstMatch(in: backing.string, range: lineRange) {
            backing.addAttributes(Styles.listItem, range: lineRange)
            styleListMarker(m.range(at: 1), isActive: isActive)
            applyInline(in: m.range(at: 2), isActive: isActive)
            return
        }
        if let m = R.unorderedList.firstMatch(in: backing.string, range: lineRange) {
            backing.addAttributes(Styles.listItem, range: lineRange)
            styleListMarker(m.range(at: 1), isActive: isActive)
            applyInline(in: m.range(at: 2), isActive: isActive)
            return
        }
        applyInline(in: lineRange, isActive: isActive)
    }

    private func styleCheckbox(_ m: NSTextCheckingResult, lineRange: NSRange, checked: Bool, isActive: Bool) {
        let bulletRange  = m.range(at: 1)  // optional bullet prefix
        let boxRange     = m.range(at: 2)  // [], [ ], [x] or [X]
        let spaceRange   = m.range(at: 3)  // space(s) after checkbox
        let contentRange = m.range(at: 4)  // the text

        // Fixed indent so the text always sits CheckboxMetrics.gap past the icon (read & edit).
        backing.addAttributes(Styles.checkbox, range: lineRange)

        // Collapse the bullet/brackets/space to zero width ALWAYS (not active-dependent), so the
        // gap is constant. The icon is drawn by the layout manager at the line's left edge.
        if bulletRange.location != NSNotFound && bulletRange.length > 0 {
            collapse(bulletRange)
        }
        if boxRange.location != NSNotFound && boxRange.length > 0,
           boxRange.location + boxRange.length <= backing.length {
            collapse(boxRange)
            backing.addAttribute(.checkboxState, value: checked, range: boxRange)
        }
        if spaceRange.location != NSNotFound && spaceRange.length > 0 {
            collapse(spaceRange)
        }

        if contentRange.location != NSNotFound && contentRange.length > 0 {
            if checked {
                backing.addAttributes(Styles.checkedContent, range: contentRange)
            } else {
                applyInline(in: contentRange, isActive: isActive)
            }
        }
    }

    // MARK: - Inline styling

    /// Emphasis is parsed with a single left-to-right delimiter-stack pass (the same approach
    /// CommonMark uses) rather than one independent regex per format. Independent regex passes
    /// can't coordinate, so adjacent runs like `**B***I*` and nested runs like `**_x_**` break;
    /// a stack tracks which delimiters have been consumed so they compose correctly.
    private func applyInline(in range: NSRange, isActive: Bool) {
        guard range.location != NSNotFound, range.length > 1 else { return }
        // Links first; mask their full extent so code-span / emphasis scanning skips inside the URL.
        var masked = Set<Int>()
        styleLink(in: range, isActive: isActive, masked: &masked)
        tokenizeInline(in: range, isActive: isActive, masked: masked)
    }

    /// One opener delimiter run waiting on the stack for a matching closer.
    private struct InlineOpen { let ch: unichar; var count: Int; var start: Int }

    /// A composable inline style produced by a matched delimiter pair.
    private enum Emph { case bold, italic, strike, underline, mark }

    private func tokenizeInline(in range: NSRange, isActive: Bool, masked: Set<Int>) {
        let s  = backing.string as NSString
        let lo = range.location
        let hi = NSMaxRange(range)

        // Pass 1 — code spans are opaque: their contents are never parsed for emphasis.
        var codeMask = Set<Int>()
        var i = lo
        while i < hi {
            if masked.contains(i) || s.character(at: i) != Self.backtick { i += 1; continue }
            var k = i + 1
            while k < hi && (s.character(at: k) != Self.backtick || masked.contains(k)) { k += 1 }
            guard k < hi else { i += 1; continue }   // no closer → leave as literal
            let content = NSRange(location: i + 1, length: k - (i + 1))
            if content.length > 0 {
                backing.addAttributes(Styles.codeSpan, range: content)
                for c in (i + 1)..<k { codeMask.insert(c) }
            }
            hide(NSRange(location: i, length: 1), isActive: isActive)
            hide(NSRange(location: k, length: 1), isActive: isActive)
            i = k + 1
        }

        // Pass 2 — emphasis delimiter stack over the non-masked, non-code characters.
        var stack = [InlineOpen]()
        i = lo
        while i < hi {
            let c = s.character(at: i)
            if masked.contains(i) || codeMask.contains(i) || !Self.isDelim(c) { i += 1; continue }

            // Measure the contiguous run of this delimiter char.
            var j = i
            while j < hi && s.character(at: j) == c
                  && !masked.contains(j) && !codeMask.contains(j) { j += 1 }
            var runLen = j - i
            let runStart = i

            // Flanking (CommonMark): can this run open and/or close emphasis?
            let L: unichar? = i > lo ? s.character(at: i - 1) : nil
            let R: unichar? = j < hi ? s.character(at: j) : nil
            let leftFlank  = !Self.isSpace(R) && (!Self.isPunct(R) || Self.isSpace(L) || Self.isPunct(L))
            let rightFlank = !Self.isSpace(L) && (!Self.isPunct(L) || Self.isSpace(R) || Self.isPunct(R))
            let canOpen: Bool, canClose: Bool
            if Self.intraword(c) {
                // `_` and `-` never emphasize inside a word, so snake_case and well-known are safe.
                canOpen  = leftFlank  && (!rightFlank || Self.isPunct(L))
                canClose = rightFlank && (!leftFlank  || Self.isPunct(R))
            } else {
                canOpen = leftFlank
                canClose = rightFlank
            }

            // Try to close against the nearest matching opener.
            if canClose,
               let idx = stack.lastIndex(where: { $0.ch == c }),
               Self.bestChunk(c, min(runLen, stack[idx].count)) != nil {
                var open = stack[idx]
                while stack.count > idx + 1 { stack.removeLast() }   // drop unmatched inner openers
                // Content sits between the runs; it stays constant as we peel delimiters off the
                // inner edges, so all chunks of this pair style the same characters (→ ***x*** ⇒ B+I).
                let contentLo = open.start + open.count
                let contentHi = runStart
                var openRight = open.start + open.count   // opener consumed from its inner (right) edge
                var closeLeft = runStart                  // closer consumed from its inner (left) edge
                while runLen > 0, open.count > 0,
                      let (chunk, trait) = Self.bestChunk(c, min(runLen, open.count)) {
                    if contentHi > contentLo {
                        applyEmph(trait, range: NSRange(location: contentLo, length: contentHi - contentLo))
                    }
                    hide(NSRange(location: openRight - chunk, length: chunk), isActive: isActive)
                    hide(NSRange(location: closeLeft, length: chunk), isActive: isActive)
                    openRight -= chunk; closeLeft += chunk
                    open.count -= chunk; runLen -= chunk
                }
                if open.count > 0 { stack[idx] = open } else { stack.remove(at: idx) }
                // Whatever is left of this run (its outer remainder) can itself open.
                if runLen > 0 && canOpen { stack.append(InlineOpen(ch: c, count: runLen, start: closeLeft)) }
            } else if canOpen {
                stack.append(InlineOpen(ch: c, count: runLen, start: runStart))
            }

            i = j
        }
    }

    /// Apply one emphasis style. Bold/italic compose onto the existing font (so nested and
    /// adjacent traits stack instead of overwriting each other); strike/underline are independent
    /// attributes that already compose.
    private func applyEmph(_ trait: Emph, range: NSRange) {
        switch trait {
        case .bold:      addFontTrait(.boldFontMask, range: range)
        case .italic:    addFontTrait(.italicFontMask, range: range)
        case .strike:    backing.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .underline: backing.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .mark:      backing.addAttribute(.backgroundColor, value: Styles.markHighlight, range: range)
        }
    }

    /// Add a font trait to every character in `range` by reading its current font and converting
    /// it — never replacing `.font` wholesale, which would drop a previously applied trait.
    private func addFontTrait(_ trait: NSFontTraitMask, range: NSRange) {
        backing.enumerateAttribute(.font, in: range, options: []) { value, sub, _ in
            let base   = (value as? NSFont) ?? Styles.bodyFont
            let merged = NSFontManager.shared.convert(base, toHaveTrait: trait)
            backing.addAttribute(.font, value: merged, range: sub)
        }
    }

    private func styleLink(in range: NSRange, isActive: Bool, masked: inout Set<Int>) {
        R.link.enumerateMatches(in: backing.string, range: range) { match, _, _ in
            guard let m = match else { return }
            for k in m.range.location..<NSMaxRange(m.range) { masked.insert(k) }
            let textRange = m.range(at: 1)
            backing.addAttributes(Styles.link, range: textRange)
            // `[`
            hide(NSRange(location: m.range.location, length: 1), isActive: isActive)
            // `](url)`
            let suffixStart = NSMaxRange(textRange)
            let suffixLen   = NSMaxRange(m.range) - suffixStart
            if suffixLen > 0 {
                hide(NSRange(location: suffixStart, length: suffixLen), isActive: isActive)
            }
        }
    }

    // MARK: - Delimiter classification (UTF-16 units, to keep ranges aligned with the storage)

    private static let backtick: unichar = 0x60
    private static let star: unichar     = 0x2A
    private static let under: unichar    = 0x5F
    private static let tilde: unichar    = 0x7E
    private static let dash: unichar     = 0x2D
    private static let equals: unichar   = 0x3D

    private static func isDelim(_ u: unichar) -> Bool {
        u == star || u == under || u == tilde || u == dash || u == equals
    }
    /// `_` and `-` suppress intraword emphasis (so `snake_case` / `well-known` stay plain).
    private static func intraword(_ u: unichar) -> Bool { u == under || u == dash }

    private static func isSpace(_ u: unichar?) -> Bool {
        guard let u = u else { return true }   // edge of range acts as a whitespace boundary
        return u == 0x20 || u == 0x09 || u == 0x0A || u == 0x0D
    }
    private static func isWord(_ u: unichar?) -> Bool {
        guard let u = u else { return false }
        if u >= 0x30 && u <= 0x39 { return true }   // 0-9
        if u >= 0x41 && u <= 0x5A { return true }   // A-Z
        if u >= 0x61 && u <= 0x7A { return true }   // a-z
        return u >= 0x80                            // treat non-ASCII as word chars
    }
    private static func isPunct(_ u: unichar?) -> Bool {
        guard let u = u else { return false }
        return !isSpace(u) && !isWord(u)
    }

    /// The largest emphasis chunk `c` supports given `avail` delimiter chars on the smaller side:
    /// `*`/`_` → 2 = bold else 1 = italic; `~` → 2 = strike; `-` → 1 = underline; `=` → 2 = mark.
    private static func bestChunk(_ c: unichar, _ avail: Int) -> (Int, Emph)? {
        switch c {
        case star, under: return avail >= 2 ? (2, .bold) : (avail >= 1 ? (1, .italic) : nil)
        case tilde:       return avail >= 2 ? (2, .strike) : nil
        case dash:        return avail >= 1 ? (1, .underline) : nil
        case equals:      return avail >= 2 ? (2, .mark) : nil
        default:          return nil
        }
    }

    // MARK: - Syntax visibility

    // List markers (- / 1.) are never fully hidden — they ARE the visual bullet.
    // They're shown in a muted colour so they read as structural, not content.
    private func styleListMarker(_ range: NSRange, isActive: Bool) {
        guard range.location != NSNotFound, range.length > 0,
              range.location + range.length <= backing.length else { return }
        let color = isActive ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor
        backing.addAttribute(.foregroundColor, value: color, range: range)
        backing.addAttribute(.font, value: Styles.bodyFont, range: range)

        // Widen the gap after the marker (via kerning on its last character) so the text starts
        // exactly at Layout.contentIndent — aligning it with checkboxes, bullets, numbers, quotes.
        let markerStr = (backing.string as NSString).substring(with: range)
        let natural = (markerStr as NSString).size(withAttributes: [.font: Styles.bodyFont]).width
        let kern = max(Layout.contentIndent - natural, 4)
        backing.addAttribute(.kern, value: kern, range: NSRange(location: NSMaxRange(range) - 1, length: 1))
    }

    /// Collapse a range to zero visible width, regardless of active state. Used for checkbox
    /// brackets/bullet/space so the icon + text gap stays fixed in both read and edit mode.
    private func collapse(_ range: NSRange) {
        guard range.location != NSNotFound, range.length > 0,
              range.location + range.length <= backing.length else { return }
        backing.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
        backing.addAttribute(.font, value: NSFont.systemFont(ofSize: 0.01), range: range)
    }

    private func hide(_ range: NSRange, isActive: Bool) {
        guard range.location != NSNotFound, range.length > 0,
              range.location + range.length <= backing.length else { return }
        if isActive {
            backing.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
            backing.addAttribute(.font, value: Styles.bodyFont, range: range)
        } else {
            backing.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
            backing.addAttribute(.font, value: NSFont.systemFont(ofSize: 0.01), range: range)
        }
    }

    // MARK: - Helpers

    /// Nesting depth of a blockquote marker run = number of `>` in it (`> > >` → 3).
    private func blockquoteDepth(_ range: NSRange) -> Int {
        guard range.location != NSNotFound, range.length > 0 else { return 1 }
        let marker = (backing.string as NSString).substring(with: range)
        return max(marker.filter { $0 == ">" }.count, 1)
    }

    private func isHR(_ line: String) -> Bool {
        let s = line.filter { !$0.isWhitespace }
        return s.count >= 3 && (s.allSatisfy { $0 == "-" } || s.allSatisfy { $0 == "*" } || s.allSatisfy { $0 == "_" })
    }
}

// MARK: - Regex constants

private enum R {
    // Block — group 1 = syntax prefix, group 2 = content
    static let heading      = try! NSRegularExpression(pattern: #"^(#{1,6}[ \t]+)(.*?)[ \t]*$"#, options: .anchorsMatchLines)
    // Group 1 = the full marker run (`>`, `>>`, `> > >`, …), group 2 = content.
    static let blockquote   = try! NSRegularExpression(pattern: #"^((?:>[ \t]*)+)(.*?)$"#, options: .anchorsMatchLines)
    static let unorderedList = try! NSRegularExpression(pattern: #"^([ \t]*[*+\-][ \t]+)(.*?)$"#, options: .anchorsMatchLines)
    static let orderedList  = try! NSRegularExpression(pattern: #"^([ \t]*\d+\.[ \t]+)(.*?)$"#, options: .anchorsMatchLines)

    // Checkboxes — g1=bullet prefix, g2=box, g3=space, g4=content
    // Box accepts "[]" or "[ ]" (unchecked) / "[x]" "[X]" (checked); trailing space optional.
    static let uncheckedBox = try! NSRegularExpression(pattern: #"^([ \t]*(?:[*+\-][ \t]+)?)(\[ ?\])([ \t]*)(.*?)$"#, options: .anchorsMatchLines)
    static let checkedBox   = try! NSRegularExpression(pattern: #"^([ \t]*(?:[*+\-][ \t]+)?)(\[[xX]\])([ \t]*)(.*?)$"#, options: .anchorsMatchLines)

    // Inline — emphasis is handled by the delimiter-stack tokenizer; only links use a regex.
    static let link        = try! NSRegularExpression(pattern: #"\[([^\]\n]+)\]\([^)\n]+\)"#)
}

// MARK: - Style definitions

private enum Styles {
    static let bodyFont = NSFont.systemFont(ofSize: 15, weight: .regular)
    static let monoFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    /// Small font used to collapse hidden ``` fence lines to a thin spacer (which becomes the gap
    /// above/below the code panel).
    static let fenceHiddenFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

    static let bodyPara: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 4
        return p
    }()

    static let body: [NSAttributedString.Key: Any] = [
        .font: bodyFont,
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: bodyPara,
    ]

    static func heading(_ level: Int) -> [NSAttributedString.Key: Any] {
        let sizes: [Int: CGFloat] = [1: 28, 2: 22, 3: 18, 4: 16, 5: 15, 6: 13]
        let weights: [Int: NSFont.Weight] = [1: .bold, 2: .bold, 3: .semibold, 4: .semibold, 5: .semibold, 6: .semibold]
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = level <= 2 ? 10 : 4
        p.paragraphSpacing = 4
        p.lineSpacing = 2
        return [
            .font: NSFont.systemFont(ofSize: sizes[level] ?? 15, weight: weights[level] ?? .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: p,
        ]
    }

    static func blockquote(depth: Int) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        let indent = BlockquoteMetrics.contentIndent(depth: depth)
        p.headIndent = indent
        p.firstLineHeadIndent = indent
        p.lineSpacing = 4
        return [
            .font: NSFont.systemFont(ofSize: 15, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: p,
        ]
    }

    static let listItem: [NSAttributedString.Key: Any] = {
        let p = NSMutableParagraphStyle()
        // Marker sits at x=0 (kerned out to contentIndent); wrapped lines align under the content.
        p.headIndent = Layout.contentIndent
        p.firstLineHeadIndent = 0
        p.lineSpacing = 3
        p.paragraphSpacing = 2
        return [.font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: p]
    }()

    static let checkbox: [NSAttributedString.Key: Any] = {
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = CheckboxMetrics.contentIndent
        p.headIndent = CheckboxMetrics.contentIndent
        p.lineSpacing = 4
        p.paragraphSpacing = 2
        // Guarantee room for the icon even on an empty "[]" line (whose only glyphs are collapsed).
        p.minimumLineHeight = 20
        return [.font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: p]
    }()

    static let checkedContent: [NSAttributedString.Key: Any] = [
        .font: bodyFont,
        .foregroundColor: NSColor.tertiaryLabelColor,
        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
        .strikethroughColor: NSColor.tertiaryLabelColor,
    ]

    static let codeBlock: [NSAttributedString.Key: Any] = {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2
        // Left/right padding inside the rounded panel (the panel spans the full content width).
        p.firstLineHeadIndent = 10
        p.headIndent = 10
        p.tailIndent = -10
        return [
            .font: monoFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: p,
        ]
    }()

    /// Highlighter background for `==marked==` text — pale yellow (light) / muted yellow (dark),
    /// keeping the default text colour readable in both.
    static let markHighlight = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? NSColor(srgbRed: 0.60, green: 0.52, blue: 0.10, alpha: 0.45)
                      : NSColor(srgbRed: 0.99, green: 0.94, blue: 0.72, alpha: 1.0)
    }

    static let codeSpan: [NSAttributedString.Key: Any] = [
        .font: monoFont,
        .foregroundColor: NSColor.labelColor,
        .backgroundColor: NSColor(white: 0.5, alpha: 0.08),
    ]

    static let link: [NSAttributedString.Key: Any] = [
        .font: bodyFont,
        .foregroundColor: NSColor.linkColor,
        .underlineStyle: NSUnderlineStyle.single.rawValue,
    ]

    static let hr: [NSAttributedString.Key: Any] = {
        let p = NSMutableParagraphStyle()
        // Fixed line height gives breathing room above/below the drawn 2pt rule.
        p.minimumLineHeight = 18
        p.maximumLineHeight = 18
        return [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.clear,   // hide the literal dashes; the rule is drawn instead
            .paragraphStyle: p,
        ]
    }()
}
