import AppKit
import SwiftUI

@main
struct NyeratApp: App {
    @StateObject private var manager = iCloudManager.shared

    /// Identifies the main `WindowGroup` so the File and Window menus can open a fresh instance
    /// after every window has been closed.
    static let mainWindowID = "main"

    var body: some Scene {
        WindowGroup(id: NyeratApp.mainWindowID) {
            ContentView()
                .environmentObject(manager)
        }
        .defaultSize(width: 1100, height: 700)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            SidebarCommands()
            NyeratCommands()
        }
    }
}

/// `WindowGroup` fills the automatic `.newItem` group with a lone "New Window" under ⌘N. "New File"
/// wants that shortcut, so replacing the group means re-declaring both items here — without a
/// window-opening command the app cannot be reopened once its last window closes.
struct NyeratCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New File") {
                // Whether a window exists has to be settled here. Posting first and treating an
                // unclaimed request as "no window" is not enough: a window that is closing still
                // has a subscribed sidebar, which swallows the request and creates nothing.
                if let window = Self.existingMainWindow {
                    window.makeKeyAndOrderFront(nil)
                    NewFileRequest.post(to: window)
                } else {
                    NewFileRequest.markPending()
                    openWindow(id: NyeratApp.mainWindowID)
                }
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("New Window") {
                openWindow(id: NyeratApp.mainWindowID)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandGroup(after: .windowList) {
            Button("Nyerat Window") {
                if let window = Self.existingMainWindow {
                    window.makeKeyAndOrderFront(nil)
                } else {
                    openWindow(id: NyeratApp.mainWindowID)
                }
            }
            .keyboardShortcut("0", modifiers: .command)
        }
    }

    /// A window the user can be sent back to, or nil when there is genuinely none to return to.
    /// `NSApp.windows` alone will not do: for a while after a close it still lists the departing
    /// window, and ordering that one front shows nothing. A closed window reports `isVisible` false
    /// and is never miniaturized, and key/main are never a closed window either — so each clause
    /// below only ever names a live window, and together they still find one in the moments when
    /// AppKit has left key and main nil.
    private static var existingMainWindow: NSWindow? {
        NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first { $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized) }
    }
}

/// Carries the File-menu "New File" command to one specific window's sidebar. Every open window
/// observes the notification, so it names its target window rather than relying on which window is
/// frontmost: `makeKeyAndOrderFront` does not take effect in time for a `controlActiveState` test
/// made right after it, which silently created no file at all.
enum NewFileRequest {
    /// Set when the command arrives with no window to send it to. The next sidebar to appear takes
    /// it, which is how "New File" works from the menu bar while the app has no windows.
    private static var isPending = false

    /// Leaves the request waiting for the next sidebar to appear.
    static func markPending() {
        isPending = true
    }

    /// Hands the request to `window`'s sidebar, and to no other window's.
    static func post(to window: NSWindow) {
        NotificationCenter.default.post(name: .newFile, object: window)
    }

    /// Claims a request left by `markPending`, if any.
    static func consume() -> Bool {
        guard isPending else { return false }
        isPending = false
        return true
    }
}

extension Notification.Name {
    static let newFile = Notification.Name("NyeratNewFile")
}
