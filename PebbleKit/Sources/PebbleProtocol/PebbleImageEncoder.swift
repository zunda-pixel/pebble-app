/// The watch's screen has two bits per channel — sixty-four colours — and
/// reads no more than sixteen of them per picture, from a palette sent with it.
public enum PebbleImageEncoder {
    static let maximumColours = 16

    /// - Parameter argb: one pixel per entry, row by row, as `0xAARRGGBB`.
    public static func encode(argb: [UInt32], width: Int, height: Int) -> PebbleEncodedImage? {
        guard width > 0, height > 0, argb.count >= width * height else { return nil }

        let palette = choosePalette(argb: argb)
        let paletteRed = palette.map { expand(($0 >> 4) & 0x3) }
        let paletteGreen = palette.map { expand(($0 >> 2) & 0x3) }
        let paletteBlue = palette.map { expand($0 & 0x3) }

        let stride = (width + 1) / 2
        var pixels = [UInt8](repeating: 0, count: stride * height)
        var currentError = [Double](repeating: 0, count: width * 3)
        var nextError = [Double](repeating: 0, count: width * 3)

        for y in 0..<height {
            for x in 0..<width {
                let pixel = argb[y * width + x]
                // Clamped before the error is measured: measuring from an out-of-range value
                // makes the error grow instead of settle.
                let red = clampChannel(Int((pixel >> 16) & 0xFF) + Int(currentError[x * 3]))
                let green = clampChannel(Int((pixel >> 8) & 0xFF) + Int(currentError[x * 3 + 1]))
                let blue = clampChannel(Int(pixel & 0xFF) + Int(currentError[x * 3 + 2]))
                let index = nearest(
                    red: red, green: green, blue: blue,
                    paletteRed: paletteRed, paletteGreen: paletteGreen, paletteBlue: paletteBlue
                )

                let byteIndex = y * stride + x / 2
                if x % 2 == 0 {
                    pixels[byteIndex] = (pixels[byteIndex] & 0x0F) | (UInt8(index) << 4)
                } else {
                    pixels[byteIndex] = (pixels[byteIndex] & 0xF0) | UInt8(index)
                }

                let errorRed = Double(red - paletteRed[index])
                let errorGreen = Double(green - paletteGreen[index])
                let errorBlue = Double(blue - paletteBlue[index])
                if x + 1 < width {
                    diffuse(&currentError, at: x + 1, errorRed, errorGreen, errorBlue, 7.0 / 16.0)
                }
                if y + 1 < height {
                    if x > 0 {
                        diffuse(&nextError, at: x - 1, errorRed, errorGreen, errorBlue, 3.0 / 16.0)
                    }
                    diffuse(&nextError, at: x, errorRed, errorGreen, errorBlue, 5.0 / 16.0)
                    if x + 1 < width {
                        diffuse(&nextError, at: x + 1, errorRed, errorGreen, errorBlue, 1.0 / 16.0)
                    }
                }
            }
            swap(&currentError, &nextError)
            for index in nextError.indices { nextError[index] = 0 }
        }

        return PebbleEncodedImage(
            width: width,
            height: height,
            palette: palette.map { colour(($0 >> 4) & 0x3, ($0 >> 2) & 0x3, $0 & 0x3) },
            pixels: pixels
        )
    }

    private struct Box {
        var colours: [(red: Int, green: Int, blue: Int, count: Int)]

        var population: Int { colours.reduce(0) { $0 + $1.count } }

        func spread(_ channel: (Int, Int, Int, Int) -> Int) -> Int {
            var low = 3
            var high = 0
            for colour in colours {
                let value = channel(colour.red, colour.green, colour.blue, colour.count)
                low = min(low, value)
                high = max(high, value)
            }
            return high - low
        }

        var widestSpread: Int {
            max(spread { red, _, _, _ in red }, spread { _, green, _, _ in green }, spread { _, _, blue, _ in blue })
        }

        var longestAxis: Int {
            let red = spread { red, _, _, _ in red }
            let green = spread { _, green, _, _ in green }
            let blue = spread { _, _, blue, _ in blue }
            if red >= green && red >= blue { return 0 }
            return green >= blue ? 1 : 2
        }
    }

    // Split along whichever axis the picture's colours are most spread over,
    // weighted by how much of the picture each accounts for.
    private static func choosePalette(argb: [UInt32]) -> [UInt8] {
        var counts: [UInt8: Int] = [:]
        for pixel in argb {
            let key = UInt8(quantise(Int((pixel >> 16) & 0xFF)) << 4
                | quantise(Int((pixel >> 8) & 0xFF)) << 2
                | quantise(Int(pixel & 0xFF)))
            counts[key, default: 0] += 1
        }
        var boxes = [Box(colours: counts.map { key, count in
            (red: Int(key >> 4) & 0x3, green: Int(key >> 2) & 0x3, blue: Int(key) & 0x3, count: count)
        })]
        guard !boxes[0].colours.isEmpty else { return [0] }

        while boxes.count < maximumColours {
            let candidates = boxes.indices.filter { boxes[$0].colours.count > 1 }
            guard let index = candidates.max(by: {
                boxes[$0].widestSpread * boxes[$0].population < boxes[$1].widestSpread * boxes[$1].population
            }) else { break }
            var box = boxes[index]
            let axis = box.longestAxis
            box.colours.sort {
                switch axis {
                case 0: $0.red < $1.red
                case 1: $0.green < $1.green
                default: $0.blue < $1.blue
                }
            }
            let split = splitPoint(box)
            boxes[index] = Box(colours: Array(box.colours[..<split]))
            boxes.append(Box(colours: Array(box.colours[split...])))
        }

        var palette: [UInt8] = []
        for box in boxes where !box.colours.isEmpty {
            let total = box.population
            let red = round(box.colours.reduce(0) { $0 + $1.red * $1.count }, total)
            let green = round(box.colours.reduce(0) { $0 + $1.green * $1.count }, total)
            let blue = round(box.colours.reduce(0) { $0 + $1.blue * $1.count }, total)
            let packed = UInt8(red << 4 | green << 2 | blue)
            if !palette.contains(packed) { palette.append(packed) }
        }
        return palette.isEmpty ? [0] : palette
    }

    private static func splitPoint(_ box: Box) -> Int {
        let half = box.population / 2
        var running = 0
        for index in box.colours.indices {
            running += box.colours[index].count
            if running > half {
                return min(max(index + 1, 1), box.colours.count - 1)
            }
        }
        return box.colours.count - 1
    }

    private static func nearest(
        red: Int,
        green: Int,
        blue: Int,
        paletteRed: [Int],
        paletteGreen: [Int],
        paletteBlue: [Int]
    ) -> Int {
        var best = 0
        var bestDistance = Int.max
        for index in paletteRed.indices {
            let dr = red - paletteRed[index]
            let dg = green - paletteGreen[index]
            let db = blue - paletteBlue[index]
            let distance = dr * dr + dg * dg + db * db
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    private static func diffuse(
        _ error: inout [Double],
        at x: Int,
        _ red: Double,
        _ green: Double,
        _ blue: Double,
        _ weight: Double
    ) {
        error[x * 3] += red * weight
        error[x * 3 + 1] += green * weight
        error[x * 3 + 2] += blue * weight
    }

    // Eight bits down to the two the screen has: 0, 85, 170, 255.
    private static func quantise(_ value: Int) -> Int { (min(max(value, 0), 255) * 3 + 127) / 255 }
    private static func expand(_ value: UInt8) -> Int { Int(value) * 85 }
    private static func clampChannel(_ value: Int) -> Int { min(max(value, 0), 255) }
    private static func round(_ sum: Int, _ count: Int) -> Int {
        count == 0 ? 0 : (sum * 2 + count) / (count * 2)
    }

    // A `GColor8`: opaque, then two bits each of red, green and blue.
    private static func colour(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> UInt8 {
        0b1100_0000 | (red << 4) | (green << 2) | blue
    }
}
