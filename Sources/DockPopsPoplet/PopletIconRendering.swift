import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image-pipeline helpers for poplet icon rendering. `normalizedCanvas` shapes
/// the running poplet's live Dock tile to match DockPops Main's live tile
/// (`DockIconCompositor.insetAndMaskForDock`): inset, then rounded-rect mask.
enum PopletIconRendering {
    static let canvasSize: Int = 1024
    /// Matches Main's `insetForDock` — an 824px icon on a 1024 canvas — so the
    /// running poplet's Dock tile is sized like Main's.
    static let contentScale: CGFloat = 824.0 / 1024.0
    /// Matches Main's `insetAndMaskForDock` rounded-rect corner radius
    /// (`insetEdge * 0.2237`, circular-arc curve).
    static let cornerRadiusRatio: CGFloat = 0.2237

    static func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func loadImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Renders the live Dock tile the way DockPops Main renders its own
    /// (`insetAndMaskForDock`): the full-bleed `PopIcons` art is inset to
    /// `contentScale` of the canvas and clipped to a rounded rect so the
    /// running poplet's corner shape matches Main's.
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
