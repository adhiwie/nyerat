import AppKit
import SwiftUI

/// Requests the soft (progressive-blur) scroll edge effect for the window's titlebar — the public
/// macOS 26 way to get the native progressive blur where content scrolls under the toolbar.
struct ScrollEdgeSoftener: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: nsView.window) }
    }

    private func apply(to window: NSWindow?) {
        guard let window else { return }
        for accessory in window.titlebarAccessoryViewControllers {
            accessory.preferredScrollEdgeEffectStyle = .soft
        }
    }
}

/// Reports the `NSWindow` hosting a SwiftUI view, so a view can tell whether an app-wide command
/// was aimed at its own window.
struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The view is moved into its window after `makeNSView`, and between windows when tabs are
        // merged or torn off, so the binding is refreshed on every update rather than set once.
        DispatchQueue.main.async {
            if window !== nsView.window { window = nsView.window }
        }
    }
}
