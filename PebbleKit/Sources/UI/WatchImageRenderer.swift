public import API
public import CoreGraphics
public import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a picture the phone has into one the watch can show.
///
/// The watch asks for an exact size, so the picture is cropped to that shape
/// from the middle and scaled to fit — letterboxing would spend the watch's few
/// pixels on empty bands.
public enum WatchImageRenderer {
    public static func encode(_ image: CGImage, width: Int, height: Int) -> PebbleEncodedImage? {
        guard width > 0, height > 0,
              width <= ImagingCodec.maximumDimension,
              height <= ImagingCodec.maximumDimension,
              let pixels = argbPixels(image, width: width, height: height)
        else { return nil }
        return PebbleImageEncoder.encode(argb: pixels, width: width, height: height)
    }

    /// A picture the watch sent, as a PNG.
    public static func pngData(_ screenshot: PebbleScreenshot) -> Data? {
        guard screenshot.width > 0, screenshot.height > 0,
              screenshot.pixels.count >= screenshot.width * screenshot.height,
              let image = makeImage(screenshot)
        else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func makeImage(_ screenshot: PebbleScreenshot) -> CGImage? {
        var pixels = screenshot.pixels
        let bytesPerRow = screenshot.width * 4
        return pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let base = buffer.baseAddress,
                  let context = unsafe CGContext(
                      data: base,
                      width: screenshot.width,
                      height: screenshot.height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                          | CGBitmapInfo.byteOrder32Little.rawValue
                  )
            else { return nil }
            return context.makeImage()
        }
    }

    /// The picture as `0xAARRGGBB` a row at a time.
    static func argbPixels(_ image: CGImage, width: Int, height: Int) -> [UInt32]? {
        var pixels = [UInt32](repeating: 0, count: width * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = unsafe CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                          | CGBitmapInfo.byteOrder32Little.rawValue
                  )
            else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: cropRect(image, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    /// Where to put the picture so that the middle of it fills the space,
    /// which for a square watch icon means cutting the long side off.
    static func cropRect(_ image: CGImage, width: Int, height: Int) -> CGRect {
        let target = CGSize(width: width, height: height)
        let source = CGSize(width: image.width, height: image.height)
        guard source.width > 0, source.height > 0 else {
            return CGRect(origin: .zero, size: target)
        }
        let scale = max(target.width / source.width, target.height / source.height)
        let scaled = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(
            x: (target.width - scaled.width) / 2,
            y: (target.height - scaled.height) / 2,
            width: scaled.width,
            height: scaled.height
        )
    }
}
