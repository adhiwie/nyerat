import SwiftUI
import AppKit

struct SidebarView: View {
    @EnvironmentObject var manager: iCloudManager
    @Binding var selectedFile: MarkdownFile?
    /// Whether the sidebar column is currently shown. The `+` toolbar item only exists while it
    /// is: a hidden sidebar's toolbar items would otherwise land in the detail bar's `»` overflow.
    var sidebarVisible: Bool = true
    @State private var renamingFile: MarkdownFile?
    @State private var renameText = ""
    /// This sidebar's window, so the File-menu "New File" command can be matched to the one window
    /// it was aimed at rather than acted on by every open window.
    @State private var hostWindow: NSWindow?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selectedFile) {
                ForEach(manager.rows) { row in
                    rowView(row)
                        .padding(.leading, CGFloat(row.depth) * 12)
                }
            }
            .listStyle(.sidebar)
        }
        .background(WindowReader(window: $hostWindow))
        .onReceive(NotificationCenter.default.publisher(for: .newFile)) { notification in
            guard notification.object as? NSWindow === hostWindow else { return }
            newFile()
        }
        .onAppear {
            // Honours a "New File" issued while the app had no window open, which opened this one.
            if NewFileRequest.consume() { newFile() }
        }
        .toolbar {
            if sidebarVisible {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newFile()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("New File (⌘N)")
                }
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func rowView(_ row: SidebarRow) -> some View {
        if let file = row.file {
            fileRow(file)
                .tag(file)
        } else {
            folderRow(row)
                .selectionDisabled(true)
        }
    }

    private func folderRow(_ row: SidebarRow) -> some View {
        Label(row.name, systemImage: "folder")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .contextMenu {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([row.url])
                }
            }
    }

    @ViewBuilder
    private func fileRow(_ file: MarkdownFile) -> some View {
        if renamingFile == file {
            TextField("", text: $renameText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit { commitRename(file) }
                .onExitCommand { renamingFile = nil }
        } else {
            Text(file.displayName)
                .font(.system(size: 13))
                .lineLimit(1)
                .contextMenu {
                    Button("Rename") { beginRename(file) }
                    Button("Reveal in Finder") { revealInFinder(file) }
                    Divider()
                    Button("Delete", role: .destructive) {
                        if selectedFile == file { selectedFile = nil }
                        manager.deleteFile(file)
                    }
                }
        }
    }

    private func newFile() {
        if let file = manager.createFile(named: "Untitled") {
            selectedFile = file
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                beginRename(file)
            }
        }
    }

    private func revealInFinder(_ file: MarkdownFile) {
        // Opens the containing folder in Finder and highlights the file.
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    private func beginRename(_ file: MarkdownFile) {
        renamingFile = file
        renameText = file.displayName
    }

    private func commitRename(_ file: MarkdownFile) {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != file.displayName {
            if let renamed = manager.renameFile(file, to: trimmed) {
                selectedFile = renamed
            }
        }
        renamingFile = nil
    }
}
