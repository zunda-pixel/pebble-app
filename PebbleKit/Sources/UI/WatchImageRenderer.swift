public import API
public import CoreGraphics
import Foundation

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
