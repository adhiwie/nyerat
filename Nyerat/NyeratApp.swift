import SwiftUI

@main
struct NyeratApp: App {
    @StateObject private var manager = iCloudManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(manager)
        }
        .defaultSize(width: 1100, height: 700)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .newItem) {
                Button("New File") {
                    NotificationCenter.default.post(name: .newFile, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let newFile = Notification.Name("NyeratNewFile")
}
