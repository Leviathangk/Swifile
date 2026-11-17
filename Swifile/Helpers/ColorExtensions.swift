import SwiftUI

extension Color {
    /// 通过十六进制字符串创建颜色，支持 RGB、RRGGBB 和 AARRGGBB。
    init?(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var number: UInt64 = 0
        guard Scanner(string: value).scanHexInt64(&number) else { return nil }

        let alpha: UInt64
        let red: UInt64
        let green: UInt64
        let blue: UInt64

        switch value.count {
        case 3:
            alpha = 255
            red = (number >> 8) * 17
            green = ((number >> 4) & 0xF) * 17
            blue = (number & 0xF) * 17
        case 6:
            alpha = 255
            red = number >> 16
            green = (number >> 8) & 0xFF
            blue = number & 0xFF
        case 8:
            alpha = number >> 24
            red = (number >> 16) & 0xFF
            green = (number >> 8) & 0xFF
            blue = number & 0xFF
        default:
            return nil
        }

        self.init(
            .sRGB,
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: Double(alpha) / 255
        )
    }
}
