import Foundation

internal struct ThreadFolderColor: Hashable {
    internal let red: Double
    internal let green: Double
    internal let blue: Double
    internal let alpha: Double

    internal static func random() -> ThreadFolderColor {
        // Generate pleasant, non-white colors using HSV then convert to RGB.
        let hue = Double.random(in: 0...1)
        let saturation = Double.random(in: 0.45...0.75)
        let brightness = Double.random(in: 0.65...0.9)
        let rgb = Self.rgb(hue: hue, saturation: saturation, brightness: brightness)
        return ThreadFolderColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1.0)
    }

    private static func rgb(hue: Double, saturation: Double, brightness: Double) -> (r: Double, g: Double, b: Double) {
        guard saturation > 0 else { return (brightness, brightness, brightness) }
        let h = hue * 6
        let sector = floor(h)
        let fraction = h - sector
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * fraction)
        let t = brightness * (1 - saturation * (1 - fraction))

        switch Int(sector) % 6 {
        case 0: return (brightness, t, p)
        case 1: return (q, brightness, p)
        case 2: return (p, brightness, t)
        case 3: return (p, q, brightness)
        case 4: return (t, p, brightness)
        default: return (brightness, p, q)
        }
    }
}

internal struct ThreadFolder: Identifiable, Hashable {
    internal let id: String
    internal var title: String
    internal var color: ThreadFolderColor
    internal var threadIDs: Set<String>
    internal var parentID: String?
}
