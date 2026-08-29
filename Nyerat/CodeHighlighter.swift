import AppKit

/// Lightweight, regex-based syntax highlighter for fenced code blocks. It is deliberately simple
/// (a few ordered passes with a "masked" set so tokens inside strings/comments aren't recoloured)
/// rather than a full parser — enough to make common JS / TS / CSS / HTML read clearly.
enum CodeHighlighter {

    // MARK: - Theme (light / dark aware)

    private static func themed(_ light: (CGFloat, CGFloat, CGFloat),
                               _ dark: (CGFloat, CGFloat, CGFloat)) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        }
    }

    private static let keyword  = themed((0.63, 0.14, 0.16), (1.00, 0.47, 0.44))  // red
    private static let string   = themed((0.05, 0.46, 0.13), (0.49, 0.91, 0.53))  // green
    private static let number   = themed((0.13, 0.10, 0.79), (0.47, 0.76, 1.00))  // blue
    private static let comment  = themed((0.44, 0.48, 0.52), (0.55, 0.58, 0.62))  // grey
    private static let function = themed((0.44, 0.26, 0.76), (0.82, 0.66, 1.00))  // purple
    private static let type     = themed((0.00, 0.36, 0.77), (0.47, 0.76, 1.00))  // blue
    private static let property = themed((0.75, 0.36, 0.05), (1.00, 0.65, 0.34))  // orange
    private static let tag      = themed((0.13, 0.53, 0.23), (0.49, 0.91, 0.53))  // green

    // MARK: - Entry point

    static func highlight(_ storage: NSMutableAttributedString, range: NSRange, language: String) {
        guard range.length > 0 else { return }
        switch canonical(language) {
        case "javascript", "typescript":
            highlightCLike(storage, range, keywords: language.hasPrefix("t") ? tsKeywords : jsKeywords,
                           types: language.hasPrefix("t"))
        case "css":
            highlightCSS(storage, range)
        case "html":
            highlightHTML(storage, range)
        default:
            break  // unknown / no language → plain monospaced text
        }
    }

    private static func canonical(_ language: String) -> String {
        switch language.lowercased() {
        case "js", "javascript", "jsx", "node":      return "javascript"
        case "ts", "typescript", "tsx":              return "typescript"
        case "css", "scss", "less":                  return "css"
        case "html", "htm", "xml", "svg", "vue":     return "html"
        default:                                     return language.lowercased()
        }
    }

    // MARK: - Keyword sets

    private static let jsKeywords: Set<String> = [
        "var", "let", "const", "function", "return", "if", "else", "for", "while", "do", "switch",
        "case", "break", "continue", "new", "delete", "typeof", "instanceof", "in", "of", "this",
        "class", "extends", "super", "import", "export", "from", "as", "default", "try", "catch",
        "finally", "throw", "async", "await", "yield", "void", "null", "undefined", "true", "false",
    ]
    private static let tsKeywords: Set<String> = jsKeywords.union([
        "interface", "type", "enum", "implements", "public", "private", "protected", "readonly",
        "abstract", "namespace", "declare", "is", "keyof", "infer", "satisfies",
    ])
    private static let tsTypes: Set<String> = [
        "string", "number", "boolean", "any", "unknown", "never", "void", "object", "symbol",
        "bigint", "Array", "Promise", "Record", "Partial", "Readonly", "Map", "Set",
    ]

    // MARK: - C-like (JS / TS)

    private static func highlightCLike(_ s: NSMutableAttributedString, _ range: NSRange,
                                       keywords: Set<String>, types: Bool) {
        var masked = IndexSet()
        // Comments and strings first, and mask them so nothing inside is recoloured.
        apply(#"/\*[\s\S]*?\*/"#, color: comment, s, range, &masked, mask: true, respect: true)
        apply(#"//[^\n]*"#,        color: comment, s, range, &masked, mask: true, respect: true)
        apply("\"(?:\\\\.|[^\"\\\\\\n])*\"", color: string, s, range, &masked, mask: true, respect: true)
        apply("'(?:\\\\.|[^'\\\\\\n])*'",     color: string, s, range, &masked, mask: true, respect: true)
        apply("`(?:\\\\.|[^`\\\\])*`",        color: string, s, range, &masked, mask: true, respect: true)

        // Function/method names: identifier immediately before "(".
        apply(#"\b([A-Za-z_$][\w$]*)\s*(?=\()"#, group: 1, color: function, s, range, &masked,
              mask: false, respect: true, skipWords: keywords)

        if types {
            applyWords(tsTypes, color: type, s, range, &masked)
        }
        applyWords(keywords, color: keyword, s, range, &masked)
        apply(#"\b\d+(?:\.\d+)?\b"#, color: number, s, range, &masked, mask: false, respect: true)
    }

    // MARK: - CSS

    private static func highlightCSS(_ s: NSMutableAttributedString, _ range: NSRange) {
        var masked = IndexSet()
        apply(#"/\*[\s\S]*?\*/"#, color: comment, s, range, &masked, mask: true, respect: true)
        apply("\"(?:\\\\.|[^\"\\\\\\n])*\"", color: string, s, range, &masked, mask: true, respect: true)
        apply("'(?:\\\\.|[^'\\\\\\n])*'",     color: string, s, range, &masked, mask: true, respect: true)
        apply(#"@[A-Za-z-]+"#,           color: keyword,  s, range, &masked, mask: false, respect: true)
        apply(#"[A-Za-z-]+(?=\s*:)"#,    color: property, s, range, &masked, mask: false, respect: true)
        apply(#"#[0-9A-Fa-f]{3,8}\b"#,   color: number,   s, range, &masked, mask: false, respect: true)
        apply(#"\b\d+(?:\.\d+)?[A-Za-z%]*"#, color: number, s, range, &masked, mask: false, respect: true)
    }

    // MARK: - HTML

    private static func highlightHTML(_ s: NSMutableAttributedString, _ range: NSRange) {
        var masked = IndexSet()
        apply(#"<!--[\s\S]*?-->"#, color: comment, s, range, &masked, mask: true, respect: true)
        apply("\"(?:\\\\.|[^\"\\n])*\"", color: string, s, range, &masked, mask: true, respect: true)
        apply("'(?:\\\\.|[^'\\n])*'",     color: string, s, range, &masked, mask: true, respect: true)
        apply(#"</?([A-Za-z][\w-]*)"#, group: 1, color: tag,      s, range, &masked, mask: false, respect: true)
        apply(#"[A-Za-z-]+(?==)"#,               color: property, s, range, &masked, mask: false, respect: true)
    }

    // MARK: - Helpers

    /// Applies `color` to every match of `pattern`. `mask` records the matched range so later
    /// passes skip it; `respect` skips matches that start inside an already-masked range.
    /// `skipWords` skips matches whose text is in the given set (e.g. keywords used as calls).
    private static func apply(_ pattern: String, options: NSRegularExpression.Options = [],
                              group: Int = 0, color: NSColor,
                              _ storage: NSMutableAttributedString, _ range: NSRange,
                              _ masked: inout IndexSet, mask: Bool, respect: Bool,
                              skipWords: Set<String> = []) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
        let string = storage.string
        // Snapshot masked so mask-writes during this pass don't affect its own respect checks.
        let snapshot = masked
        regex.enumerateMatches(in: string, range: range) { match, _, _ in
            guard let match = match else { return }
            let r = match.range(at: group)
            guard r.location != NSNotFound, r.length > 0 else { return }
            if respect && snapshot.contains(r.location) { return }
            if !skipWords.isEmpty {
                let word = (string as NSString).substring(with: r)
                if skipWords.contains(word) { return }
            }
            storage.addAttribute(.foregroundColor, value: color, range: r)
            if mask { masked.insert(integersIn: r.location..<NSMaxRange(r)) }
        }
    }

    private static func applyWords(_ words: Set<String>, color: NSColor,
                                   _ storage: NSMutableAttributedString, _ range: NSRange,
                                   _ masked: inout IndexSet) {
        guard !words.isEmpty else { return }
        let pattern = #"\b(?:"# + words.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + #")\b"#
        apply(pattern, color: color, storage, range, &masked, mask: false, respect: true)
    }
}
