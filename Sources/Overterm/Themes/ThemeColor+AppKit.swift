import AppKit
import SwiftUI

/// A theme colour as AppKit and SwiftUI draw it.
extension ThemeColor {
    package var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
    package var color: Color { Color(nsColor: nsColor) }
}
