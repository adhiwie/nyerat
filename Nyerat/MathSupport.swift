import AppKit
import SwiftMath

/// Attribute value holding a rendered LaTeX image for a hidden math source line.
final class MathRef {
    let image: NSImage
    let displaySize: CGSize
    init(image: NSImage, displaySize: CGSize) {
        self.image = image
        self.displaySize = displaySize
    }
}

/// Renders LaTeX to images via SwiftMath (native CoreText, no WebView). Cached by latex + mode +
/// appearance, so repeated styling passes are cheap and light/dark each get correctly-coloured math.
final class MathRenderer {
    static let shared = MathRenderer()

    private var cache: [String: NSImage] = [:]

    func image(latex: String, display: Bool, dark: Bool) -> NSImage? {
        let key = "\(dark ? "D" : "L")|\(display ? "B" : "I")|\(latex)"
        if let cached = cache[key] { return cached }

        let color: NSColor = dark ? .white : .black
        let math = MTMathImage(latex: latex,
                               fontSize: display ? 20 : 17,
                               textColor: color,
                               labelMode: display ? .display : .text)
        let (error, image) = math.asImage()
        guard error == nil, let image, image.size.width > 0, image.size.height > 0 else { return nil }
        cache[key] = image
        return image
    }
}
