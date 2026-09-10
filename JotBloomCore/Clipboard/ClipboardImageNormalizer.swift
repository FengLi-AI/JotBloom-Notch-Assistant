import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public protocol ClipboardImageNormalizing: Sendable {
    func normalize(_ data: Data) throws -> NormalizedClipboardImage
}

public enum ClipboardImageNormalizationError: Error, Equatable, LocalizedError {
    case invalidImage
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "无法读取这张图片。"
        case .encodingFailed:
            return "无法处理这张图片。"
        }
    }
}

public struct SystemClipboardImageNormalizer: ClipboardImageNormalizing {
    public static let thumbnailMaximumPixelSize = 200

    public init() {}

    public func normalize(_ data: Data) throws -> NormalizedClipboardImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  source,
                  0,
                  nil
              ) as? [CFString: Any],
              let rawWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let rawHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              rawWidth.intValue > 0,
              rawHeight.intValue > 0 else {
            throw ClipboardImageNormalizationError.invalidImage
        }

        let fullSizeLimit = max(rawWidth.intValue, rawHeight.intValue)
        guard let decodedImage = makeImage(
            from: source,
            maximumPixelSize: fullSizeLimit
        ) else {
            throw ClipboardImageNormalizationError.invalidImage
        }
        let image = try renderStandardRGBA(decodedImage)

        let pngData = try encodePNG(image)
        let thumbnail = try makeThumbnail(from: image)
        let thumbnailPNGData = try encodePNG(thumbnail)
        let digest = SHA256.hash(data: pngData)
            .map { String(format: "%02x", $0) }
            .joined()

        return NormalizedClipboardImage(
            pngData: pngData,
            thumbnailPNGData: thumbnailPNGData,
            widthPixels: image.width,
            heightPixels: image.height,
            sha256: digest
        )
    }

    private func makeImage(
        from source: CGImageSource,
        maximumPixelSize: Int
    ) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        )
    }

    private func makeThumbnail(from image: CGImage) throws -> CGImage {
        let maximumDimension = max(image.width, image.height)
        guard maximumDimension > Self.thumbnailMaximumPixelSize else {
            return image
        }

        let scale = CGFloat(Self.thumbnailMaximumPixelSize)
            / CGFloat(maximumDimension)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ClipboardImageNormalizationError.encodingFailed
        }
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        guard let thumbnail = context.makeImage() else {
            throw ClipboardImageNormalizationError.encodingFailed
        }
        return thumbnail
    }

    private func renderStandardRGBA(_ image: CGImage) throws -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ClipboardImageNormalizationError.encodingFailed
        }
        context.interpolationQuality = .none
        context.draw(
            image,
            in: CGRect(
                x: 0,
                y: 0,
                width: image.width,
                height: image.height
            )
        )
        guard let rendered = context.makeImage() else {
            throw ClipboardImageNormalizationError.encodingFailed
        }
        return rendered
    }

    private func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ClipboardImageNormalizationError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ClipboardImageNormalizationError.encodingFailed
        }
        return data as Data
    }
}
