import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image-pipeline helpers for poplet icon rendering. `normalizedCanvas` shapes
/// poplet Dock tiles on a standard app-icon presentation canvas: inset, then
/// rounded-rect mask.
enum PopletIconRendering {
    static let canvasSize: Int = 1024
    /// Keeps poplet artwork visually aligned with standard macOS Dock icons.
    static let contentScale: CGFloat = 0.86
    /// Rounded-rect corner radius (`insetEdge * 0.2237`, circular-arc curve).
    static let cornerRadiusRatio: CGFloat = 0.2237

    static func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func loadImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Renders the full-bleed `PopIcons` art on a presentation canvas so open
    /// and closed poplet Dock tiles share the same visual size.
    static func normalizedCanvas(from source: CGImage) -> CGImage? {
        let canvas = CGFloat(canvasSize)
        let contentEdge = canvas * contentScale
        let inset = (canvas - contentEdge) / 2
        let targetRect = CGRect(x: inset, y: inset, width: contentEdge, height: contentEdge)

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

        let cornerRadius = contentEdge * cornerRadiusRatio
        let mask = CGPath(
            roundedRect: targetRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        context.addPath(mask)
        context.clip()
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
