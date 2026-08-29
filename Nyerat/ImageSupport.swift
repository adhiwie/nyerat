import AppKit

/// Attribute value describing a rendered markdown image, stored on its hidden source line so the
/// text view can draw the image into the reserved vertical space.
final class ImageRef {
    let url: String
    let alt: String
    let title: String?
    let displaySize: CGSize
    init(url: String, alt: String, title: String?, displaySize: CGSize) {
        self.url = url
        self.alt = alt
        self.title = title
        self.displaySize = displaySize
    }
}

extension Notification.Name {
    /// Posted when a remote image finishes loading, so open editors can re-render.
    static let nyeratImageLoaded = Notification.Name("nyeratImageLoaded")
}

/// Loads and caches images referenced by markdown — remote (http/https) or local (file path / URL).
/// Everything runs on the main thread except the network fetch, whose result is hopped back to main.
final class RemoteImageStore {
    static let shared = RemoteImageStore()

    private var cache: [String: NSImage] = [:]
    private var loading: Set<String> = []
    private var failed: Set<String> = []

    /// The cached image, or nil while it loads (kicking off a fetch the first time it's requested).
    /// `failed` keys return nil without retrying.
    func image(for key: String) -> NSImage? {
        if let image = cache[key] { return image }
        load(key)
        return nil
    }

    func hasFailed(_ key: String) -> Bool { failed.contains(key) }

    private func load(_ key: String) {
        guard !loading.contains(key), !failed.contains(key) else { return }

        if let local = localImage(for: key) {
            cache[key] = local
            return
        }
        guard let url = URL(string: key), let scheme = url.scheme,
              scheme == "http" || scheme == "https" else {
            failed.insert(key)
            return
        }
        loading.insert(key)
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let image = data.flatMap { NSImage(data: $0) }
            DispatchQueue.main.async {
                self.loading.remove(key)
                if let image {
                    self.cache[key] = image
                    NotificationCenter.default.post(name: .nyeratImageLoaded, object: nil)
                } else {
                    self.failed.insert(key)
                    NotificationCenter.default.post(name: .nyeratImageLoaded, object: nil)
                }
            }
        }.resume()
    }

    private func localImage(for key: String) -> NSImage? {
        if key.hasPrefix("file://"), let url = URL(string: key) {
            return NSImage(contentsOf: url)
        }
        if key.hasPrefix("/") {
            return NSImage(contentsOfFile: key)
        }
        return nil
    }
}
