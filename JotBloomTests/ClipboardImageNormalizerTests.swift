import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import JotBloomCore

final class ClipboardImageNormalizerTests: XCTestCase {
    private let normalizer = SystemClipboardImageNormalizer()

    func testPNGJPEGAndTIFFDecodeToNormalizedPNG() throws {
        for type in [UTType.png, UTType.jpeg, UTType.tiff] {
            let input = try makeImageData(type: type, width: 20, height: 10)
            let result = try normalizer.normalize(input)

            XCTAssertEqual(result.widthPixels, 20, type.identifier)
            XCTAssertEqual(result.heightPixels, 10, type.identifier)
            XCTAssertEqual(Array(result.pngData.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
            XCTAssertEqual(result.sha256.count, 64)
            XCTAssertTrue(
                result.sha256.allSatisfy { $0.isNumber || ("a"..."f").contains(String($0)) }
            )
        }
    }

    func testOrientationIsAppliedBeforeDimensionsAndHash() throws {
        let input = try makeImageData(
            type: .tiff,
            width: 30,
            height: 10,
            properties: [kCGImagePropertyOrientation: 6]
        )

        let result = try normalizer.normalize(input)

        XCTAssertEqual(result.widthPixels, 10)
        XCTAssertEqual(result.heightPixels, 30)
    }

    func testThumbnailMaximumDimensionIsTwoHundredPixels() throws {
        let input = try makeImageData(type: .png, width: 400, height: 100)
        let result = try normalizer.normalize(input)
        guard let source = CGImageSourceCreateWithData(
            result.thumbnailPNGData as CFData,
            nil
        ),
        let properties = CGImageSourceCopyPropertiesAtIndex(
            source,
            0,
            nil
        ) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
        let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return XCTFail("Missing thumbnail properties")
        }

        XCTAssertEqual(width.intValue, 200)
        XCTAssertEqual(height.intValue, 50)
    }

    func testNormalizationIsDeterministic() throws {
        let input = try makeImageData(type: .png, width: 12, height: 8)
        XCTAssertEqual(
            try normalizer.normalize(input),
            try normalizer.normalize(input)
        )
    }

    func testInvalidImageIsRejected() {
        XCTAssertThrowsError(try normalizer.normalize(Data("not-image".utf8))) { error in
            XCTAssertEqual(
                error as? ClipboardImageNormalizationError,
                .invalidImage
            )
        }
    }

    private func makeImageData(
        type: UTType,
        width: Int,
        height: Int,
        properties: [CFString: Any] = [:]
    ) throws -> Data {
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
        context.setFillColor(
            CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        )
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw ClipboardImageNormalizationError.encodingFailed
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            type.identifier as CFString,
            1,
            nil
        ) else {
            throw ClipboardImageNormalizationError.encodingFailed
        }
        CGImageDestinationAddImage(
            destination,
            image,
            properties as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw ClipboardImageNormalizationError.encodingFailed
        }
        return output as Data
    }
}
