import Foundation

struct MarkdownFile: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    var modifiedDate: Date

    var displayName: String {
        url.deletingPathExtension().lastPathComponent
    }

    static func == (lhs: MarkdownFile, rhs: MarkdownFile) -> Bool { lhs.url == rhs.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

/// One row in the sidebar's (possibly nested) list: a folder header or a file, at a given depth.
struct SidebarRow: Identifiable, Hashable {
    let url: URL
    let depth: Int
    /// Non-nil for file rows; nil marks a folder header.
    let file: MarkdownFile?

    var id: URL { url }
    var isFolder: Bool { file == nil }
    var name: String { file?.displayName ?? url.lastPathComponent }
}
