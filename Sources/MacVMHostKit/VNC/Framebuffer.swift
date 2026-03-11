import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A decoded VNC framebuffer: a BGRA pixel buffer (`B, G, R, X` byte order per
/// pixel, matching `RFBPixelFormat.bgra32`) plus helpers to turn it into an image.
struct Framebuffer {
    let width: Int
    let height: Int
    /// `width * height * 4` bytes, BGRA order.
    var pixels: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.pixels = [UInt8](repeating: 0, count: max(0, width * height * 4))
    }

    /// Copy a decoded rectangle of BGRA pixels into the buffer at (x, y).
    mutating func blit(_ rectPixels: [UInt8], x: Int, y: Int, width rectWidth: Int, height rectHeight: Int) {
        guard rectWidth > 0, rectHeight > 0 else { return }
        let bytesPerRow = width * 4
        let rectBytesPerRow = rectWidth * 4

        for row in 0..<rectHeight {
            let destinationY = y + row
            guard destinationY >= 0, destinationY < height else { continue }
            let destinationStart = destinationY * bytesPerRow + x * 4
            let sourceStart = row * rectBytesPerRow
            let copyBytes = min(rectBytesPerRow, bytesPerRow - x * 4)
            guard copyBytes > 0, sourceStart + copyBytes <= rectPixels.count else { continue }
            pixels.replaceSubrange(
                destinationStart..<(destinationStart + copyBytes),
                with: rectPixels[sourceStart..<(sourceStart + copyBytes)]
            )
        }
    }

    func cgImage() -> CGImage? {
        guard width > 0, height > 0, pixels.count == width * height * 4 else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // Little-endian 32-bit pixels with alpha in the high byte skipped: memory
        // order B, G, R, X is interpreted as ARGB-little == our BGRA buffer.
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    func pngData() -> Data? {
        guard let image = cgImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
