import Foundation
import ImageIO

/// The small copy of an avatar that Ember serves in its place: a PNG or JPEG within 512×512.
/// The web makes one in the browser; `EmberClient.changeAvatar` makes one with ImageIO.
public struct AvatarVariant: Hashable, Sendable {
    /// The picture's bytes.
    public var data: Data
    /// `image/png` or `image/jpeg`. Ember also takes `image/webp`.
    public var contentType: String

    /// A variant of `data` and `contentType`. Ember refuses one that isn't a WebP, PNG or JPEG, or
    /// is larger than 512×512.
    public init(data: Data, contentType: String) {
        self.data = data
        self.contentType = contentType
    }

    /// The widest and tallest a variant may be.
    public static let box = 512

    /// A variant of the picture in `data`, scaled down to fit 512×512 and turned upright: a PNG when
    /// it has transparency, a JPEG otherwise. Nil when ImageIO can't read it.
    public init?(of data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.box,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width <= Self.box, image.height <= Self.box
        else { return nil }
        let opaque: Bool = switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: true
        default: false
        }
        let (type, contentType) = opaque ? ("public.jpeg", "image/jpeg") : ("public.png", "image/png")
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type as CFString, 1, nil) else { return nil }
        let properties: [CFString: Any] = opaque ? [kCGImageDestinationLossyCompressionQuality: 0.85] : [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        self.init(data: output as Data, contentType: contentType)
    }
}
