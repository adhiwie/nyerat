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
