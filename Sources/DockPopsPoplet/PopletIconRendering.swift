import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image-pipeline helpers shared by the live Dock tile path and the on-disk
/// ICNS healer. Both need to resize and normalize the raw pop composite so the
/// live tile and the baked bundle icon stay visually identical.
enum PopletIconRendering {
    /// Matches the margin the companion applies when baking the original ICNS
    /// (`NSImage.normalizedPopletAppIcon`). Keeping these in sync means the
    /// running tile and the at-rest Finder icon look the same.
    static let canvasSize: Int = 1024
    static let contentScale: CGFloat = 0.86

    static func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Produces a 1024x1024 canvas with the source centered and inset so the
    /// composite matches the margin used by the companion's baked ICNS.
    static func normalizedCanvas(from source: CGImage) -> CGImage? {
        let canvas = CGFloat(canvasSize)
        let inset = (canvas - (canvas * contentScale)) / 2
        let targetRect = CGRect(
            x: inset,
            y: inset,
            width: canvas * contentScale,
            height: canvas * contentScale
        )

        guard
            let context = CGContext(
                data: nil,
                width: canvasSize,
                height: canvasSize,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }

        context.interpolationQuality = .high
        context.clear(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))
        context.draw(source, in: targetRect)
        return context.makeImage()
    }

    static func resizedPNGData(from source: CGImage, pixelSize: Int) -> Data? {
        guard
            let context = CGContext(
                data: nil,
                width: pixelSize,
                height: pixelSize,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }

        context.interpolationQuality = .high
        context.clear(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
        context.draw(source, in: CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))

        guard let resized = context.makeImage() else { return nil }
        return pngData(from: resized)
    }

    static func pngData(from image: CGImage) -> Data? {
        let buffer = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                buffer,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return buffer as Data
    }
}
