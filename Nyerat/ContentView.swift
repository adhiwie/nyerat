import SwiftUI

struct ContentView: View {
    @EnvironmentObject var manager: iCloudManager
    @State private var selectedFile: MarkdownFile?
    @StateObject private var editorController = EditorController()
    @AppStorage("formatToolbarExpanded") private var toolbarExpanded = true
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Drives the `+` item in the sidebar toolbar. Dropped instantly when the sidebar starts
    /// collapsing, but only restored once the expand animation has settled — while the column is
    /// mid-animation the item can't fit and would flash through the detail bar's `»` overflow.
    @State private var sidebarPlusVisible = true

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selectedFile: $selectedFile, sidebarVisible: sidebarPlusVisible)
                .environmentObject(manager)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            if let file = selectedFile {
                EditorView(
                    fileID: file.id,
                    loadContent: { manager.readContent(of: file) },
                    onSave: { manager.writeContent($0, to: file) },
                    controller: editorController
                )
                .ignoresSafeArea(.container, edges: [.top, .bottom])
                .id(file.id)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(alignment: .bottom) {
                    let bg = Color(nsColor: .textBackgroundColor)
                    LinearGradient(colors: [bg, bg.opacity(0)], startPoint: .bottom, endPoint: .top)
                        .frame(height: 40)
                        .allowsHitTesting(false)
                        .ignoresSafeArea()
                }
                .overlay(alignment: .bottomTrailing) {
                    countMenu
                        .padding(12)
                }
            } else {
                emptyState
            }
        }
        .onChange(of: columnVisibility) { _, newValue in
            if newValue == .detailOnly {
                sidebarPlusVisible = false
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    if columnVisibility != .detailOnly { sidebarPlusVisible = true }
                }
            }
        }
        .navigationTitle(selectedFile.map { $0.url.lastPathComponent } ?? "Nyerat")
        .toolbarBackground(selectedFile == nil ? .hidden : .automatic, for: .windowToolbar)
        .background(ScrollEdgeSoftener())
        .toolbar {
            if selectedFile != nil {
                FormatToolbar(controller: editorController, expanded: $toolbarExpanded)
            }
        }
    }

    private var countMenu: some View {
        let count = editorController.countMode == .words ? editorController.wordCount : editorController.characterCount
        let noun: String
        switch editorController.countMode {
        case .words:      noun = count == 1 ? "Word" : "Words"
        case .characters: noun = count == 1 ? "Character" : "Characters"
        }
        return Menu {
            Picker("Count", selection: $editorController.countMode) {
                Text("Words").tag(CountMode.words)
                Text("Characters").tag(CountMode.characters)
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 3) {
                Text("\(count.formatted()) \(noun)")
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .font(.system(size: 10))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .controlSize(.mini)
        .foregroundStyle(.secondary)
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.thinMaterial, in: Capsule())
        .pointerStyle(.link)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "note.text")
                .font(.system(size: 40))
                .foregroundStyle(.quaternary)
            Text("No note selected")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text("Press ⌘N to create a new note")
                .font(.callout)
                .foregroundStyle(.quaternary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
