import Foundation

/// The chrome's text kept legible whatever the terminal's theme (P14,
/// A11Y-U1): WCAG's contrast between a colour and the grounds it is drawn
/// on, and the least change that reaches a floor — more opaque first, then
/// mixed toward white on a dark ground or black on a light one. Pure, on
/// sRGB components in 0…1.
package enum ChromeContrast {
    package struct RGB: Equatable, Sendable {
        package var red: Double
        package var green: Double
        package var blue: Double

        package init(_ red: Double, _ green: Double, _ blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        package init(_ color: ThemeColor) { self.init(color.red, color.green, color.blue) }

        /// `self` drawn at `alpha` over `ground`.
        package func over(_ ground: RGB, alpha: Double) -> RGB {
            RGB(red * alpha + ground.red * (1 - alpha), green * alpha + ground.green * (1 - alpha), blue * alpha + ground.blue * (1 - alpha))
        }

        /// `self` moved `fraction` of the way to `other`.
        package func mixed(_ fraction: Double, with other: RGB) -> RGB { other.over(self, alpha: fraction) }

        package static let white = RGB(1, 1, 1)
        package static let black = RGB(0, 0, 0)
    }

    /// The secondary text's floor, and the tertiary's (the review's: 4.5:1, 3:1).
    package static let secondary = 4.5
    package static let tertiary = 3.0

    /// WCAG's relative luminance.
    package static func luminance(_ color: RGB) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    /// WCAG's contrast ratio, 1…21.
    package static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// What text in `color` at `alpha` must be to read at `floor` on every
    /// one of `grounds`: the alpha raised first (in steps, to 1), then the
    /// colour mixed toward white or black — whichever the grounds' darkness
    /// asks — until it reads. As it was when it already does.
    package static func floored(_ color: RGB, alpha: Double, on grounds: [RGB], floor: Double, dark: Bool) -> (color: RGB, alpha: Double) {
        func reads(_ candidate: RGB, _ a: Double) -> Bool { grounds.allSatisfy { ratio(candidate.over($0, alpha: a), $0) >= floor } }
        if reads(color, alpha) { return (color, alpha) }
        var a = alpha
        while a < 1 {
            a = min(1, a + 0.02)
            if reads(color, a) { return (color, a) }
        }
        // Toward whichever end reads better on these grounds — by their
        // luminance, not the theme's brightness: a saturated blue is
        // "light" by HSB and dark to the eye (C64).
        let toward = worst(.white, on: grounds) >= worst(.black, on: grounds) ? RGB.white : RGB.black
        var fraction = 0.0
        while fraction < 1 {
            fraction = min(1, fraction + 0.02)
            let moved = color.mixed(fraction, with: toward)
            if reads(moved, 1) { return (moved, 1) }
        }
        // No colour reaches it on these grounds (a red one, Hot Dog Stand):
        // the end that reads best.
        return (toward, 1)
    }

    /// The lowest contrast `color` has on any of `grounds`.
    package static func worst(_ color: RGB, on grounds: [RGB]) -> Double {
        grounds.map { ratio(color, $0) }.min() ?? 21
    }

    /// The most any colour can reach on all of `grounds`: white's or black's.
    package static func reachable(on grounds: [RGB]) -> Double {
        max(worst(.white, on: grounds), worst(.black, on: grounds))
    }
}
