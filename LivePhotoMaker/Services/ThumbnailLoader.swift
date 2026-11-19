import ImageIO
import UIKit

/// 从 JPG 生成列表缩略图，并做简单内存缓存。
enum ThumbnailLoader {
    private static let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 300
        return cache
    }()

    static func thumbnail(for url: URL, maxPixelSize: CGFloat = 160) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }

        return await Task.detached(priority: .utility) { () -> UIImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]

            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }

            let image = UIImage(cgImage: cgImage)
            cache.setObject(image, forKey: url as NSURL)
            return image
        }.value
    }
}
