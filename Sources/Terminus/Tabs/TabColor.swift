import SwiftUI

/// Colours a tab can be marked with — a fixed, Chrome-tab-group-like set
/// rather than a picker, so marks stay distinguishable at a glance.
enum TabColor: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, cyan, blue, purple, pink, gray

    var id: String { rawValue }

    var name: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .red: Color(red: 0.94, green: 0.33, blue: 0.31)
        case .orange: Color(red: 0.98, green: 0.58, blue: 0.24)
        case .yellow: Color(red: 1.00, green: 0.88, blue: 0.29)
        case .green: Color(red: 0.36, green: 0.78, blue: 0.44)
        case .cyan: Color(red: 0.30, green: 0.78, blue: 0.85)
        case .blue: Color(red: 0.36, green: 0.56, blue: 0.96)
        case .purple: Color(red: 0.66, green: 0.47, blue: 0.94)
        case .pink: Color(red: 0.95, green: 0.45, blue: 0.70)
        case .gray: Color(red: 0.60, green: 0.60, blue: 0.62)
        }
    }
}
