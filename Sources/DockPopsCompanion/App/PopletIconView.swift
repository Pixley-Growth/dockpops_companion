import SwiftUI

struct PopletIconView: View {
    let image: NSImage
    let size: CGFloat

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.12), radius: size * 0.08, y: size * 0.04)
    }
}
