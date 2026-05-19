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

    /// Insets full-bleed Pop art onto a standard app-icon presentation canvas.
    ///
    /// SACRED CODE:
    /// `contentScale` 0.832 and `cornerRadiusRatio` 0.2237 MUST stay equal to
    /// `PopletIconRendering.contentScale` / `.cornerRadiusRatio` in the
    /// DockPopsPoplet target. This path bakes the *closed* Dock tile; that path
    /// renders the *live running* tile. If the two diverge, a poplet's icon
    /// visibly changes size the instant it launches. The targets do not share
    /// code — changing one constant means changing the other by hand.
    ///
    /// 0.832: macOS 26 (Tahoe) shrinks normal app icons to ~83.2% of the Dock
    /// slot, but renders a generated Poplet's icon as-is. Baking the inset in
    /// at 0.832 matches sibling app icons. (Measured via
    /// NSWorkspace.icon(forFile:) across 10 apps — 8 landed on 83.2%.)
    func normalizedPopletAppIcon(
        canvasSize: CGFloat = 1024,
        contentScale: CGFloat = 0.832,
        cornerRadiusRatio: CGFloat = 0.2237
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
        let cornerRadius = targetRect.width * cornerRadiusRatio
        let mask = CGPath(
            roundedRect: targetRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        context.addPath(mask)
        context.clip()
        context.draw(cgImage, in: targetRect)

        guard let outputImage = context.makeImage() else { return nil }
        return NSImage(cgImage: outputImage, size: NSSize(width: canvasSize, height: canvasSize))
    }
}
