import AppKit
import Foundation

extension NSImage {
    var resolvedCGImage: CGImage? {
        var proposedRect = CGRect(origin: .zero, size: size)
        if let cgImage = cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) {
            return cgImage
        }

        return representations
            .compactMap { ($0 as? NSBitmapImageRep)?.cgImage }
            .first
    }

    var pixelSize: CGSize {
        if let cgImage = resolvedCGImage {
            return CGSize(width: cgImage.width, height: cgImage.height)
        }
        return size
    }

    var pngRepresentation: Data? {
        guard let cgImage = resolvedCGImage else { return nil }
        let representation = NSBitmapImageRep(cgImage: cgImage)
        return representation.representation(using: .png, properties: [:])
    }

    func pngRepresentation(squarePixelSize: Int) -> Data? {
        guard let cgImage = resolvedCGImage else { return nil }

        guard
            let context = CGContext(
                data: nil,
                width: squarePixelSize,
                height: squarePixelSize,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }

        context.interpolationQuality = .high
        context.clear(CGRect(x: 0, y: 0, width: squarePixelSize, height: squarePixelSize))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: squarePixelSize, height: squarePixelSize))

        guard let outputImage = context.makeImage() else { return nil }
        let representation = NSBitmapImageRep(cgImage: outputImage)
        return representation.representation(using: .png, properties: [:])
    }

    func normalizedPopletAppIcon(
        canvasSize: CGFloat = 1024,
        contentScale: CGFloat = 0.86
    ) -> NSImage? {
        guard let cgImage = resolvedCGImage else { return nil }

        let targetRect = CGRect(
            x: (canvasSize - (canvasSize * contentScale)) / 2,
            y: (canvasSize - (canvasSize * contentScale)) / 2,
            width: canvasSize * contentScale,
            height: canvasSize * contentScale
        )

        guard
            let context = CGContext(
                data: nil,
                width: Int(canvasSize),
                height: Int(canvasSize),
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
        context.draw(cgImage, in: targetRect)

        guard let outputImage = context.makeImage() else { return nil }
        return NSImage(cgImage: outputImage, size: NSSize(width: canvasSize, height: canvasSize))
    }
}
