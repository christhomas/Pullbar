import AppKit

/// Lines up the second line of every pull request row in columns: the
/// details on the left, then the status columns (review, checks, conflicts,
/// comments) as a block that ends at the right edge of the widest row.
///
/// Menu items can't lay out views cheaply, so the columns are tab-separated
/// text with left-aligned tab stops measured across all rows. Left alignment
/// keeps each column's icon in the same place whatever the number after it.
struct MenuColumns {
    /// Space between columns, in points.
    static let gap: CGFloat = 20

    /// Which columns hold text in at least one row. Empty ones are skipped,
    /// so a column that never has content leaves no gap.
    private let used: [Int]
    private let paragraphStyle: NSParagraphStyle

    /// - Parameters:
    ///   - rows: Each row's columns. Column 0 is the details text; the rest
    ///     are status columns. Every row has the same number of columns.
    ///   - titles: The first lines of the rows. When a title is wider than
    ///     the details and status columns together, the status block moves
    ///     right to end at that title's right edge.
    init(rows: [[NSAttributedString]], titles: [NSAttributedString]) {
        let count = rows.first?.count ?? 0
        let widths = (0..<count).map { column in
            rows.map { ceil($0[column].size().width) }.max() ?? 0
        }
        used = (0..<count).filter { $0 == 0 || widths[$0] > 0 }

        let status = used.dropFirst()
        let statusWidth = status.reduce(0) { $0 + Self.gap + widths[$1] }
        let widestTitle = titles.map { ceil($0.size().width) }.max() ?? 0
        let rightEdge = max((widths.first ?? 0) + statusWidth, widestTitle)

        var tabs: [NSTextTab] = []
        var x = rightEdge - statusWidth
        for column in status {
            x += Self.gap
            tabs.append(NSTextTab(textAlignment: .left, location: x))
            x += widths[column]
        }
        let style = NSMutableParagraphStyle()
        style.tabStops = tabs
        paragraphStyle = style
    }

    /// One row's second line: its columns joined by tabs.
    func line(_ columns: [NSAttributedString]) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for (index, column) in used.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "\t")) }
            text.append(columns[column])
        }
        text.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: text.length))
        return text
    }
}
