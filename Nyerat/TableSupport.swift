import AppKit

/// Reference to one rendered row within a `TableLayout`, stored as a text attribute on the
/// corresponding (hidden) source line so the layout manager can draw that row.
final class TableRowRef {
    let layout: TableLayout
    let index: Int          // 0 = header, 1… = body rows
    init(layout: TableLayout, index: Int) { self.layout = layout; self.index = index }
}

/// A parsed and measured GitHub-style table. Built once during the styling pass — which uses
/// `rowHeights` to reserve vertical space on the (hidden) source lines — and read back by the
/// layout manager to draw borders and wrapped cell text. Rendered rows are the header followed by
/// the body rows; the `---|---` delimiter row is dropped.
final class TableLayout {
    static let hPad: CGFloat = 10   // horizontal padding inside a cell
    static let vPad: CGFloat = 6    // vertical padding inside a cell

    let columnCount: Int
    let columnX: [CGFloat]              // left edge of each column + the table's right edge (count+1)
    let rowHeights: [CGFloat]           // [header, body0, body1, …]
    let cells: [[NSAttributedString]]   // same order; each row normalized to `columnCount` entries
    let width: CGFloat

    private static let borderColor = NSColor.separatorColor
    private static let headerFill = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? NSColor(white: 1, alpha: 0.05) : NSColor(white: 0.5, alpha: 0.07)
    }

    init?(headerCells: [String], bodyRows: [[String]], alignments: [NSTextAlignment],
          availableWidth: CGFloat, bodyFont: NSFont, headerFont: NSFont) {
        let columns = headerCells.count
        guard columns > 0 else { return nil }
        columnCount = columns

        var aligns = alignments
        while aligns.count < columns { aligns.append(.left) }
        aligns = Array(aligns.prefix(columns))

        func makeRow(_ raw: [String], font: NSFont) -> [NSAttributedString] {
            (0..<columns).map { c in
                let p = NSMutableParagraphStyle()
                p.alignment = aligns[c]
                p.lineSpacing = 1
                p.lineBreakMode = .byWordWrapping
                let text = c < raw.count ? raw[c] : ""
                return NSAttributedString(string: text, attributes: [
                    .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: p,
                ])
            }
        }

        var rows: [[NSAttributedString]] = [makeRow(headerCells, font: headerFont)]
        for body in bodyRows { rows.append(makeRow(body, font: bodyFont)) }
        cells = rows

        // Column widths: natural (unwrapped) width per column, then scaled so the whole table
        // fills `availableWidth` (wide columns therefore shrink and their cells wrap).
        let minCol: CGFloat = 48
        var natural = [CGFloat](repeating: minCol, count: columns)
        for row in rows {
            for c in 0..<columns {
                natural[c] = max(natural[c], ceil(row[c].size().width) + 2 * Self.hPad)
            }
        }
        let totalNatural = natural.reduce(0, +)
        let target = max(availableWidth, CGFloat(columns) * minCol)
        let scale = totalNatural > 0 ? target / totalNatural : 1
        var widths = natural.map { $0 * scale }
        widths[columns - 1] += target - widths.reduce(0, +)   // absorb rounding drift into last col

        var xs: [CGFloat] = [0]
        for c in 0..<columns { xs.append(xs[c] + widths[c]) }
        columnX = xs
        width = target

        // Row heights: wrap each cell to its column's content width; row = tallest cell + padding.
        rowHeights = rows.enumerated().map { ri, row in
            let font = ri == 0 ? headerFont : bodyFont
            var h = ceil(font.ascender - font.descender)
            for c in 0..<columns {
                let cw = max(widths[c] - 2 * Self.hPad, 1)
                let box = row[c].boundingRect(
                    with: NSSize(width: cw, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading])
                h = max(h, ceil(box.height))
            }
            return h + 2 * Self.vPad
        }
    }

    /// Draws one rendered row (header or body) into `rect` (already offset into view coordinates).
    /// `rect.height` is the reserved row height; `width` spans the whole table.
    func draw(row index: Int, at rect: NSRect) {
        guard index >= 0, index < rowHeights.count else { return }

        if index == 0 {
            Self.headerFill.setFill()
            NSRect(x: rect.minX, y: rect.minY, width: width, height: rect.height).fill()
        }

        for c in 0..<columnCount {
            let cellRect = NSRect(x: rect.minX + columnX[c] + Self.hPad,
                                  y: rect.minY + Self.vPad,
                                  width: (columnX[c + 1] - columnX[c]) - 2 * Self.hPad,
                                  height: rect.height - 2 * Self.vPad)
            cells[index][c].draw(with: cellRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        }

        Self.borderColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        for c in 0...columnCount {
            let x = rect.minX + columnX[c] + 0.5
            path.move(to: NSPoint(x: x, y: rect.minY))
            path.line(to: NSPoint(x: x, y: rect.maxY))
        }
        // Top edge for every row (this is the inter-row divider); bottom edge only for the last row.
        path.move(to: NSPoint(x: rect.minX, y: rect.minY + 0.5))
        path.line(to: NSPoint(x: rect.minX + width, y: rect.minY + 0.5))
        if index == rowHeights.count - 1 {
            path.move(to: NSPoint(x: rect.minX, y: rect.maxY - 0.5))
            path.line(to: NSPoint(x: rect.minX + width, y: rect.maxY - 0.5))
        }
        path.stroke()
    }
}
