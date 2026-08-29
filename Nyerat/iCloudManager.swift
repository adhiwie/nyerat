import Foundation
import Combine

@MainActor
final class iCloudManager: ObservableObject {
    static let shared = iCloudManager()

    @Published var files: [MarkdownFile] = []
    /// Flattened display rows (folders + files, with depth) for the sidebar.
    @Published var rows: [SidebarRow] = []

    private(set) var folderURL: URL?
    private var monitorSource: DispatchSourceFileSystemObject?

    private init() {
        folderURL = resolveFolder()
        loadFiles()
        startMonitoring()
    }

    private func resolveFolder() -> URL? {
        // iCloud Drive direct path — works without iCloud entitlement on non-sandboxed builds
        let home = FileManager.default.homeDirectoryForCurrentUser
        let iCloudDrive = home
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        let folder = iCloudDrive.appendingPathComponent("Nyerat")

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        } catch {
            // Fall back to ~/Documents/Nyerat
            let fallback = home.appendingPathComponent("Documents/Nyerat")
            try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
            return fallback
        }
    }

    func loadFiles() {
        guard let folder = folderURL else { files = []; rows = []; return }
        var allFiles: [MarkdownFile] = []
        var displayRows: [SidebarRow] = []
        scan(folder, depth: 0, files: &allFiles, rows: &displayRows)
        // `files` stays flat and newest-first (drives selection + the free-tier limit); `rows` keeps
        // the folder structure for display.
        files = allFiles.sorted { $0.modifiedDate > $1.modifiedDate }
        rows = displayRows
    }

    /// Recursively list a directory: files and subfolders interleaved, newest first. A folder is
    /// ranked by the newest file anywhere inside it. Returns the newest date in this subtree.
    @discardableResult
    private func scan(_ dir: URL, depth: Int, files: inout [MarkdownFile], rows: inout [SidebarRow]) -> Date {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: .skipsHiddenFiles) else { return .distantPast }

        // One entry per file or subfolder: its sort date plus the rows/files it contributes.
        var entries: [(date: Date, rows: [SidebarRow], files: [MarkdownFile])] = []

        for url in contents {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                var subFiles: [MarkdownFile] = []
                var subRows = [SidebarRow(url: url, depth: depth, file: nil)]
                let newest = scan(url, depth: depth + 1, files: &subFiles, rows: &subRows)
                entries.append((newest, subRows, subFiles))
            } else if url.pathExtension == "md" {
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let file = MarkdownFile(url: url, modifiedDate: date)
                entries.append((date, [SidebarRow(url: url, depth: depth, file: file)], [file]))
            }
        }

        entries.sort {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.rows[0].url.lastPathComponent
                .localizedStandardCompare($1.rows[0].url.lastPathComponent) == .orderedAscending
        }

        for entry in entries {
            rows.append(contentsOf: entry.rows)
            files.append(contentsOf: entry.files)
        }
        return entries.first?.date ?? .distantPast
    }

    func createFile(named name: String) -> MarkdownFile? {
        guard let folder = folderURL else { return nil }
        let safeName = name.isEmpty ? "Untitled" : name
        var url = folder.appendingPathComponent(safeName).appendingPathExtension("md")

        // Avoid collision
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(safeName) \(counter)").appendingPathExtension("md")
            counter += 1
        }

        FileManager.default.createFile(atPath: url.path, contents: Data())
        let file = MarkdownFile(url: url, modifiedDate: Date())
        loadFiles()
        return file
    }

    func deleteFile(_ file: MarkdownFile) {
        try? FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
        loadFiles()
    }

    func renameFile(_ file: MarkdownFile, to newName: String) -> MarkdownFile? {
        guard !newName.isEmpty else { return nil }
        // Rename within the file's own folder (not the root), so nested files stay put.
        let dest = file.url.deletingLastPathComponent()
            .appendingPathComponent(newName).appendingPathExtension("md")
        do {
            try FileManager.default.moveItem(at: file.url, to: dest)
            loadFiles()
            return files.first { $0.url == dest }
        } catch {
            return nil
        }
    }

    func readContent(of file: MarkdownFile) -> String {
        (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
    }

    func writeContent(_ content: String, to file: MarkdownFile) {
        try? content.write(to: file.url, atomically: true, encoding: .utf8)
        loadFiles()
    }

    private func startMonitoring() {
        guard let folder = folderURL else { return }
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.loadFiles() }
        source.setCancelHandler { close(fd) }
        source.resume()
        monitorSource = source
    }
}
