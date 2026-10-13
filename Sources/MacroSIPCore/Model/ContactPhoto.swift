import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Contact photos are small JPEGs; `ContactStore` keeps them in `photos/<id>.jpg` next to contacts.json.
public enum ContactPhoto {
    public static let maxPixels = 256

    /// Centre-crops the image to a square, scales it down to at most `maxPixels` and encodes JPEG.
    /// nil when `data` is not an image.
    public static func jpeg(from data: Data, quality: Double = 0.8) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels * 2,
              ] as CFDictionary)
        else { return nil }
        return jpeg(from: thumb, quality: quality)
    }

    public static func jpeg(from image: CGImage, quality: Double = 0.8) -> Data? {
        let side = min(image.width, image.height)
        let crop = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
        guard let square = image.cropping(to: crop) else { return nil }
        let out = min(side, maxPixels)
        guard let ctx = CGContext(
            data: nil, width: out, height: out, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: out, height: out))
        ctx.draw(square, in: CGRect(x: 0, y: 0, width: out, height: out))
        guard let scaled = ctx.makeImage() else { return nil }
        let buffer = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return buffer as Data
    }
}
