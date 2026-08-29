import SwiftUI
import AppKit

struct EditorView: NSViewRepresentable {
    /// Identity of the file being edited. Used to detect genuine file switches.
    let fileID: URL
    /// Reads the current content from disk (called only on a file switch).
    var loadContent: () -> String
    var onSave: (String) -> Void
    /// Registered so the format bar can act on this text view.
    var controller: EditorController

    func makeNSView(context: Context) -> NSScrollView {
        let textStorage = MarkdownTextStorage()
        let layoutManager = CheckboxLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        // Width is managed manually in MarkdownTextView.layout() to cap and center the content.
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)

        let textView = MarkdownTextView(frame: .zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 60, height: 40)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.drawsBackground = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.usesFindPanel = true

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true

        context.coordinator.textStorage = textStorage
        context.coordinator.controller = controller
        controller.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? MarkdownTextView,
              let ts = context.coordinator.textStorage else { return }

        // The ONLY time we touch the text is when the file actually changes. Typing, the
        // debounced save (which calls loadFiles → re-renders this view), list continuation,
        // and renumbering never change fileID, so updateNSView leaves the buffer (and cursor)
        // completely alone during editing. This is what fixes the cursor jumping to the end.
        guard context.coordinator.loadedFileID != fileID else { return }
        context.coordinator.loadedFileID = fileID

        let text = loadContent()
        ts.replaceCharacters(in: NSRange(location: 0, length: ts.length), with: text)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        ts.insertionPoint = 0
        let counts = renderedCounts(text)
        controller.wordCount = counts.words
        controller.characterCount = counts.characters
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSave: onSave) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onSave: (String) -> Void
        weak var textStorage: MarkdownTextStorage?
        /// Which file is currently loaded into the text view, so we only reload on a real switch.
        var loadedFileID: URL?
        weak var controller: EditorController?
        private var saveTask: Task<Void, Never>?
        private var imageObserver: NSObjectProtocol?

        init(onSave: @escaping (String) -> Void) {
            self.onSave = onSave
            super.init()
            // When a remote image finishes loading, re-run styling so its real size lays out.
            imageObserver = NotificationCenter.default.addObserver(
                forName: .nyeratImageLoaded, object: nil, queue: .main) { [weak self] _ in
                self?.textStorage?.reprocess()
            }
        }

        deinit {
            if let imageObserver { NotificationCenter.default.removeObserver(imageObserver) }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView,
                  let ts = textStorage else { return }
            ts.insertionPoint = tv.selectedRange().location
        }

        func textDidChange(_ notification: Notification) {
            guard let ts = textStorage else { return }
            let raw = ts.string
            let counts = renderedCounts(raw)
            controller?.wordCount = counts.words
            controller?.characterCount = counts.characters
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                await MainActor.run { self.onSave(raw) }
            }
        }
    }
}

// MARK: - Custom NSTextView (list continuation + checkbox toggle)

final class MarkdownTextView: NSTextView {

    // MARK: Centered, max-width content

    private let maxContentWidth: CGFloat = 648
    private let minSideInset: CGFloat = 24

    override func layout() {
        super.layout()
        guard let container = textContainer else { return }
        let available = bounds.width
        let contentWidth = max(0, min(maxContentWidth, available - minSideInset * 2))
        let horizontal = max((available - contentWidth) / 2, minSideInset)

        if abs(textContainerInset.width - horizontal) > 0.5 {
            textContainerInset = NSSize(width: horizontal, height: textContainerInset.height)
        }
        if abs(container.size.width - contentWidth) > 0.5 {
            container.size = NSSize(width: contentWidth, height: container.size.height)
        }
    }

    // MARK: Table rendering

    // Tables are drawn here (not in the layout manager) because each cell is rendered with
    // NSAttributedString.draw — doing that inside NSLayoutManager.drawGlyphs reenters the text
    // system and corrupts glyph rendering. Drawing from the view's own draw pass is safe.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let lm = layoutManager, let ts = textStorage else { return }
        let origin = textContainerOrigin
        let full = NSRange(location: 0, length: ts.length)
        ts.enumerateAttribute(.tableRow, in: full, options: []) { value, range, _ in
            guard let ref = value as? TableRowRef else { return }
            let gr = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard gr.length > 0 else { return }
            let frag = lm.lineFragmentRect(forGlyphAt: gr.location, effectiveRange: nil)
            let rect = NSRect(x: frag.minX + origin.x, y: frag.minY + origin.y,
                              width: ref.layout.width, height: frag.height)
            guard rect.intersects(dirtyRect) else { return }
            NSGraphicsContext.saveGraphicsState()
            ref.layout.draw(row: ref.index, at: rect)
            NSGraphicsContext.restoreGraphicsState()
        }

        ts.enumerateAttribute(.imageAttachment, in: full, options: []) { value, range, _ in
            guard let ref = value as? ImageRef else { return }
            let gr = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard gr.length > 0 else { return }
            let frag = lm.lineFragmentRect(forGlyphAt: gr.location, effectiveRange: nil)
            let rect = NSRect(x: frag.minX + origin.x, y: frag.minY + origin.y,
                              width: ref.displaySize.width, height: ref.displaySize.height)
            guard rect.intersects(dirtyRect) else { return }
            NSGraphicsContext.saveGraphicsState()
            self.drawImage(ref, in: rect)
            NSGraphicsContext.restoreGraphicsState()
        }

        ts.enumerateAttribute(.mathImage, in: full, options: []) { value, range, _ in
            guard let ref = value as? MathRef else { return }
            let gr = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard gr.length > 0 else { return }
            let frag = lm.lineFragmentRect(forGlyphAt: gr.location, effectiveRange: nil)
            let rect = NSRect(x: frag.minX + origin.x, y: frag.minY + origin.y,
                              width: ref.displaySize.width, height: ref.displaySize.height)
            guard rect.intersects(dirtyRect) else { return }
            NSGraphicsContext.saveGraphicsState()
            ref.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                           respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    // Re-render math (its colour is baked into the image) when switching light/dark.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        (textStorage as? MarkdownTextStorage)?.reprocess()
    }

    private func drawImage(_ ref: ImageRef, in rect: NSRect) {
        if let image = RemoteImageStore.shared.image(for: ref.url) {
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        } else {
            // Placeholder while loading (or a broken-image hint on failure).
            NSColor(white: 0.5, alpha: 0.1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            let failed = RemoteImageStore.shared.hasFailed(ref.url)
            let label = failed ? "⚠︎ \(ref.alt.isEmpty ? "Image unavailable" : ref.alt)"
                               : "Loading \(ref.alt.isEmpty ? "image" : ref.alt)…"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let size = (label as NSString).size(withAttributes: attrs)
            (label as NSString).draw(at: NSPoint(x: rect.minX + 10, y: rect.midY - size.height / 2),
                                     withAttributes: attrs)
        }
    }

    // MARK: List continuation on Enter

    private static let orderedRegex   = try! NSRegularExpression(pattern: #"^([ \t]*)(\d+)(\.[ \t]+)(.*?)$"#)
    private static let unorderedRegex = try! NSRegularExpression(pattern: #"^([ \t]*)([*+\-])([ \t]+)(.*?)$"#)
    // g1 = indent + optional bullet, g2 = box, g3 = space, g4 = content
    private static let checkboxRegex  = try! NSRegularExpression(pattern: #"^([ \t]*(?:[*+\-][ \t]+)?)(\[[ xX]?\])([ \t]*)(.*?)$"#)
    // g1 = full marker run (">", ">>", "> > >", …), g2 = content
    private static let blockquoteRegex = try! NSRegularExpression(pattern: #"^((?:>[ \t]*)+)(.*?)$"#)

    override func insertNewline(_ sender: Any?) {
        guard let ts = textStorage, ts.length > 0 else { super.insertNewline(sender); return }

        let loc       = selectedRange().location
        let docNS     = ts.string as NSString
        let safePos   = min(loc, ts.length - 1)
        let lineRange = docNS.lineRange(for: NSRange(location: safePos, length: 0))
        let line      = docNS.substring(with: lineRange).trimmingCharacters(in: .newlines)
        let lineNS    = line as NSString
        let lr        = NSRange(location: 0, length: lineNS.length)

        // Task checkbox — must be checked BEFORE the unordered list (since "- [ ] x" also
        // matches a bullet list). A continued checkbox is always created unchecked.
        if let m = Self.checkboxRegex.firstMatch(in: line, range: lr) {
            let prefixGroup = lineNS.substring(with: m.range(at: 1))  // indent + optional bullet
            let content     = lineNS.substring(with: m.range(at: 4))
            let empty       = content.trimmingCharacters(in: .whitespaces).isEmpty
            let prefix      = "\(prefixGroup)[ ] "
            continueList(prefix: prefix, contentEmpty: empty, renumber: false,
                         loc: loc, lineRange: lineRange, in: ts)
            return
        }

        // Blockquote — continue at the same nesting depth (normalized to "> " per level).
        if let m = Self.blockquoteRegex.firstMatch(in: line, range: lr) {
            let marker  = lineNS.substring(with: m.range(at: 1))
            let depth   = max(marker.filter { $0 == ">" }.count, 1)
            let content = lineNS.substring(with: m.range(at: 2))
            let empty   = content.trimmingCharacters(in: .whitespaces).isEmpty
            let prefix  = String(repeating: "> ", count: depth)
            continueList(prefix: prefix, contentEmpty: empty, renumber: false,
                         loc: loc, lineRange: lineRange, in: ts)
            return
        }

        // Ordered list
        if let m = Self.orderedRegex.firstMatch(in: line, range: lr) {
            let indent  = lineNS.substring(with: m.range(at: 1))
            let numStr  = lineNS.substring(with: m.range(at: 2))
            let sep     = lineNS.substring(with: m.range(at: 3))
            let content = lineNS.substring(with: m.range(at: 4))
            let empty   = content.trimmingCharacters(in: .whitespaces).isEmpty
            let prefix  = "\(indent)\((Int(numStr) ?? 1) + 1)\(sep)"
            continueList(prefix: prefix, contentEmpty: empty, renumber: true,
                         loc: loc, lineRange: lineRange, in: ts)
            return
        }

        // Unordered list
        if let m = Self.unorderedRegex.firstMatch(in: line, range: lr) {
            let indent  = lineNS.substring(with: m.range(at: 1))
            let marker  = lineNS.substring(with: m.range(at: 2))
            let space   = lineNS.substring(with: m.range(at: 3))
            let content = lineNS.substring(with: m.range(at: 4))
            let empty   = content.trimmingCharacters(in: .whitespaces).isEmpty
            let prefix  = "\(indent)\(marker)\(space)"
            continueList(prefix: prefix, contentEmpty: empty, renumber: false,
                         loc: loc, lineRange: lineRange, in: ts)
            return
        }

        super.insertNewline(sender)
    }

    /// Performs the whole list-continuation edit as ONE atomic replaceCharacters, then sets
    /// the cursor exactly once. Doing it in a single edit (instead of super.insertNewline +
    /// separate storage edits) keeps the SwiftUI binding consistent with the text storage,
    /// so updateNSView never sees a mismatch and never resets the text / cursor.
    private func continueList(prefix: String, contentEmpty: Bool, renumber: Bool,
                              loc: Int, lineRange: NSRange, in ts: NSTextStorage) {
        // Empty item → exit the list: replace the whole line with a bare newline.
        if contentEmpty {
            guard shouldChangeText(in: lineRange, replacementString: "\n") else { return }
            ts.replaceCharacters(in: lineRange, with: "\n")
            didChangeText()
            setSelectedRange(NSRange(location: lineRange.location, length: 0))
            return
        }

        // Everything from the cursor to the end of the document is rewritten in one shot:
        //   newline + new prefix + (text that was after the cursor) + (renumbered following lines)
        let docNS = ts.string as NSString
        let tailNS = docNS.substring(from: loc) as NSString   // text after the cursor

        let firstNL = tailNS.range(of: "\n")
        let afterCursor: String      // remainder of the current line (after the cursor)
        let following: String        // subsequent lines, including the leading "\n" (or empty)
        if firstNL.location == NSNotFound {
            afterCursor = tailNS as String
            following   = ""
        } else {
            afterCursor = tailNS.substring(to: firstNL.location)
            following   = tailNS.substring(from: firstNL.location)
        }

        var newFollowing = following
        if renumber && !following.isEmpty {
            // Drop the leading "\n", renumber the consecutive ordered lines, re-add the "\n".
            let body = (following as NSString).substring(from: 1)
            newFollowing = "\n" + incrementLeadingOrderedNumbers(in: body)
        }

        let newTail      = "\n" + prefix + afterCursor + newFollowing
        let replaceRange = NSRange(location: loc, length: ts.length - loc)
        guard shouldChangeText(in: replaceRange, replacementString: newTail) else { return }
        ts.replaceCharacters(in: replaceRange, with: newTail)
        didChangeText()

        // Cursor sits right after the inserted prefix, before any moved-down text.
        let cursor = min(loc + 1 + (prefix as NSString).length, ts.length)
        setSelectedRange(NSRange(location: cursor, length: 0))
    }

    /// Returns `text` with the number of each leading consecutive ordered-list line
    /// incremented by 1. Stops at the first non-ordered line and appends the rest verbatim.
    private func incrementLeadingOrderedNumbers(in text: String) -> String {
        let ns = text as NSString
        var result = ""
        var pos = 0
        var renumbering = true
        while pos < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: pos, length: 0))
            let chunk     = ns.substring(with: lineRange)   // includes trailing newline, if any
            if renumbering {
                let line   = chunk.trimmingCharacters(in: .newlines)
                let lineNS = line as NSString
                if let m = Self.orderedRegex.firstMatch(
                    in: line, range: NSRange(location: 0, length: lineNS.length)) {
                    let indent  = lineNS.substring(with: m.range(at: 1))
                    let numStr  = lineNS.substring(with: m.range(at: 2))
                    let sep     = lineNS.substring(with: m.range(at: 3))
                    let content = lineNS.substring(with: m.range(at: 4))
                    let ending  = String(chunk.dropFirst(line.count))   // preserved newline(s)
                    result += "\(indent)\((Int(numStr) ?? 1) + 1)\(sep)\(content)\(ending)"
                } else {
                    renumbering = false
                    result += chunk
                }
            } else {
                result += chunk
            }
            pos = NSMaxRange(lineRange)
        }
        return result
    }

    // MARK: Checkbox mouse handling

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if let (box, checked) = checkbox(at: pt),
           let ts = textStorage as? MarkdownTextStorage {
            ts.replaceCharacters(in: box, with: checked ? "[ ]" : "[x]")
            return
        }
        super.mouseDown(with: event)
    }

    // Show a normal arrow pointer (not the I-beam) when hovering over a checkbox.
    override func cursorUpdate(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if checkbox(at: pt) != nil {
            NSCursor.arrow.set()
            return
        }
        super.cursorUpdate(with: event)
    }

    private func charIndex(at point: NSPoint) -> Int? {
        guard let lm = layoutManager, let tc = textContainer else { return nil }
        let p = NSPoint(x: point.x - textContainerInset.width,
                        y: point.y - textContainerInset.height)
        let i = lm.characterIndex(for: p, in: tc, fractionOfDistanceBetweenInsertionPoints: nil)
        return i < (textStorage?.length ?? 0) ? i : nil
    }

    /// If `point` (view coords) is over a checkbox box, returns its absolute range and checked state.
    private func checkbox(at point: NSPoint) -> (range: NSRange, checked: Bool)? {
        guard let idx = charIndex(at: point),
              let ts = textStorage as? MarkdownTextStorage else { return nil }
        let ns = ts.string as NSString
        let lineRange = ns.lineRange(for: NSRange(location: idx, length: 0))
        let line = ns.substring(with: lineRange)
        let lr = NSRange(location: 0, length: (line as NSString).length)

        // Match the box at the start of the line (after optional indent / bullet). Group 2 is the box.
        let checked   = try! NSRegularExpression(pattern: #"^([ \t]*(?:[*+\-][ \t]+)?)(\[[xX]\])"#)
        let unchecked = try! NSRegularExpression(pattern: #"^([ \t]*(?:[*+\-][ \t]+)?)(\[ ?\])"#)

        func boxRange(_ m: NSTextCheckingResult) -> NSRange {
            let b = m.range(at: 2)
            return NSRange(location: lineRange.location + b.location, length: b.length)
        }
        func hit(_ box: NSRange) -> Bool { idx >= box.location && idx < NSMaxRange(box) }

        if let m = checked.firstMatch(in: line, range: lr) {
            let box = boxRange(m)
            if hit(box) { return (box, true) }
        }
        if let m = unchecked.firstMatch(in: line, range: lr) {
            let box = boxRange(m)
            if hit(box) { return (box, false) }
        }
        return nil
    }
}

// MARK: - Custom drawing layout manager

/// Draws a checkbox icon over any range tagged with `.checkboxState`, and a thin full-width line
/// over any range tagged with `.horizontalRule`. The underlying glyphs are rendered transparent.
final class CheckboxLayoutManager: NSLayoutManager {

    /// Fill for the fenced code-block panel, tuned per appearance.
    private static let codeBlockFill = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0.5, alpha: 0.09)
    }

    // Backgrounds are drawn before glyphs, so the code panel sits behind the code text.
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let ts = textStorage else { return }

        let full = NSRange(location: 0, length: ts.length)
        ts.enumerateAttribute(.codeBlockBackground, in: full, options: []) { value, range, _ in
            guard (value as? Bool) == true else { return }
            let gr = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard gr.length > 0 else { return }

            var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
            var top = CGFloat.greatestFiniteMagnitude, bottom = -CGFloat.greatestFiniteMagnitude
            self.enumerateLineFragments(forGlyphRange: gr) { rect, _, _, _, _ in
                minX = min(minX, rect.minX); maxX = max(maxX, rect.maxX)
                top = min(top, rect.minY);   bottom = max(bottom, rect.maxY)
            }
            guard minX.isFinite, bottom > top else { return }

            let padV: CGFloat = 6
            let box = NSRect(x: minX + origin.x, y: top + origin.y - padV,
                             width: maxX - minX, height: (bottom - top) + padV * 2)
            Self.codeBlockFill.set()
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        }
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let ts = textStorage else { return }

        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        // Blockquote bars — nested quotes get one vertical bar per nesting level. Each line tagged
        // with depth d contributes a segment to columns 1…d; segments in the same column on
        // vertically-adjacent lines are merged, so every column is a single rounded rect spanning
        // its true top-to-bottom extent (tiered rounded caps, like a real nested quote).
        drawBlockquoteBars(in: ts, origin: origin)

        // Horizontal rules — a 2pt line spanning the line fragment, vertically centered.
        ts.enumerateAttribute(.horizontalRule, in: charRange, options: []) { value, range, _ in
            guard (value as? Bool) == true else { return }
            let gr = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard gr.length > 0 else { return }
            let frag = lineFragmentRect(forGlyphAt: gr.location, effectiveRange: nil)
            let thickness: CGFloat = 2
            let rect = NSRect(x: frag.minX + origin.x,
                              y: frag.midY - thickness / 2 + origin.y,
                              width: frag.width,
                              height: thickness)
            NSColor.separatorColor.set()
            rect.fill()
        }

        ts.enumerateAttribute(.checkboxState, in: charRange, options: []) { value, range, _ in
            guard let checked = value as? Bool else { return }
            let gr = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard gr.length > 0 else { return }

            // Draw the icon at the line's left edge (not the box glyph, which is zero-width).
            // The text content is indented by CheckboxMetrics.contentIndent, so icon-right → text
            // is exactly CheckboxMetrics.gap.
            let frag = lineFragmentRect(forGlyphAt: gr.location, effectiveRange: nil)
            let used = lineFragmentUsedRect(forGlyphAt: gr.location, effectiveRange: nil)
            let side = CheckboxMetrics.iconSide
            let drawRect = NSRect(x: frag.minX + origin.x,
                                  y: used.midY - side / 2 + origin.y,
                                  width: side, height: side)
            drawCheckbox(checked: checked, in: drawRect)
        }
    }

    /// Draws all nested blockquote bars for the document. Enumerated over the full storage (not
    /// just the visible glyph range) so a bar's rounded caps land at the quote's real ends rather
    /// than at the scroll boundary; off-screen rects are cheaply clipped by the drawing system.
    private func drawBlockquoteBars(in ts: NSTextStorage, origin: NSPoint) {
        var columns: [Int: [(top: CGFloat, bottom: CGFloat)]] = [:]  // nesting level → segments
        var fragMinX = CGFloat.greatestFiniteMagnitude

        let fullRange = NSRange(location: 0, length: ts.length)
        ts.enumerateAttribute(.blockquoteBar, in: fullRange, options: []) { value, range, _ in
            guard let depth = value as? Int, depth > 0 else { return }
            let gr = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard gr.length > 0 else { return }
            self.enumerateLineFragments(forGlyphRange: gr) { rect, _, _, _, _ in
                fragMinX = min(fragMinX, rect.minX)
                for level in 1...depth {
                    columns[level, default: []].append((rect.minY, rect.maxY))
                }
            }
        }
        guard fragMinX.isFinite else { return }

        NSColor.tertiaryLabelColor.set()
        for (level, segments) in columns {
            let x = fragMinX + origin.x + BlockquoteMetrics.barX(level: level)
            for seg in mergeSegments(segments) {
                let rect = NSRect(x: x, y: seg.top + origin.y,
                                  width: BlockquoteMetrics.barWidth, height: seg.bottom - seg.top)
                NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            }
        }
    }

    /// Merge vertically-adjacent segments (sorted by top) into continuous runs so each column
    /// draws as one bar with rounded caps only at its extremes.
    private func mergeSegments(_ segments: [(top: CGFloat, bottom: CGFloat)]) -> [(top: CGFloat, bottom: CGFloat)] {
        guard !segments.isEmpty else { return [] }
        let sorted = segments.sorted { $0.top < $1.top }
        var result: [(top: CGFloat, bottom: CGFloat)] = []
        var current = sorted[0]
        for seg in sorted.dropFirst() {
            if seg.top <= current.bottom + 0.5 {
                current.bottom = max(current.bottom, seg.bottom)
            } else {
                result.append(current)
                current = seg
            }
        }
        result.append(current)
        return result
    }

    private func drawCheckbox(checked: Bool, in rect: NSRect) {
        // Checked = outlined box with a literal checkmark (not a blue-filled box).
        let symbol = checked ? "checkmark.square" : "square"
        let color  = NSColor.secondaryLabelColor
        let config = NSImage.SymbolConfiguration(pointSize: rect.height, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        image.draw(in: rect, from: .zero, operation: .sourceOver,
                   fraction: 1, respectFlipped: true, hints: nil)
    }
}
