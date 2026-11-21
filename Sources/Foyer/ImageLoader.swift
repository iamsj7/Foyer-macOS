import SwiftUI
import AppKit
import ImageIO

/// Downloads artwork and decodes it at the size it is shown. Full-resolution posters and
/// backdrops would otherwise be decoded on the main thread and held in memory at their native size.
enum ImageLoader {
    private final class Box { let image: NSImage; init(_ image: NSImage) { self.image = image } }

    private static let cache: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>()
        c.totalCostLimit = 150 * 1024 * 1024
        c.countLimit = 400
        return c
    }()

    /// Pixel sizes round up to 128 px steps, so small layout changes reuse the same decoded image.
    static func bucket(_ points: CGFloat, scale: CGFloat) -> Int {
        let px = max(1, Int((points * scale).rounded(.up)))
        return min(4096, (px + 127) / 128 * 128)
    }

    private static func key(_ url: URL, _ maxPixels: Int) -> NSString { "\(maxPixels)|\(url.absoluteString)" as NSString }

    static func cached(_ url: URL, maxPixels: Int) -> NSImage? { cache.object(forKey: key(url, maxPixels))?.image }

    /// Fetches through URLSession.shared (its URLCache is kept) and decodes off the main thread.
    static func load(_ url: URL, maxPixels: Int) async -> NSImage? {
        if let hit = cached(url, maxPixels: maxPixels) { return hit }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              !Task.isCancelled else { return nil }
        let decoded = await Task.detached(priority: .utility) { downsample(data, maxPixels: maxPixels) }.value
        guard let decoded, !Task.isCancelled else { return nil }
        let cost = decoded.cgImage.width * decoded.cgImage.height * 4
        cache.setObject(Box(decoded.image), forKey: key(url, maxPixels), cost: cost)
        return decoded.image
    }

    private static func downsample(_ data: Data, maxPixels: Int) -> (image: NSImage, cgImage: CGImage)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return (NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)), cg)
    }
}

/// Fills its frame with remote artwork; quiet placeholder while loading.
struct Artwork: View {
    let url: URL?
    @Environment(\.displayScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var size: CGSize = .zero
    @State private var loaded: Loaded?

    private struct Loaded: Equatable { let url: URL; let pixels: Int; let image: NSImage }
    private struct LoadKey: Hashable { let url: URL?; let pixels: Int }

    private var pixels: Int { ImageLoader.bucket(max(size.width, size.height), scale: scale) }

    var body: some View {
        let key = LoadKey(url: url, pixels: pixels)
        // The image is an overlay so its fill-aspect overflow never changes the measured size.
        Rectangle().fill(.quaternary)
            .overlay {
                if let loaded, loaded.url == url {
                    Image(nsImage: loaded.image)
                        .resizable().aspectRatio(contentMode: .fill)
                        .transition(.opacity)
                }
            }
        .clipped()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .task(id: key) {
            guard let url, size.width > 0, size.height > 0 else { loaded = nil; return }
            let px = pixels
            if let hit = ImageLoader.cached(url, maxPixels: px) {
                loaded = Loaded(url: url, pixels: px, image: hit)
                return
            }
            guard let image = await ImageLoader.load(url, maxPixels: px), !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) {
                loaded = Loaded(url: url, pixels: px, image: image)
            }
        }
    }
}
