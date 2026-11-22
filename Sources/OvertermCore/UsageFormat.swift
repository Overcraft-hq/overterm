import Foundation
import SwiftUI

package enum UsageFormat {
    /// "$4.12", "$0.03", "$1,204" — money, as money is written.
    package static func money(_ dollars: Double) -> String {
        if dollars >= 1000 { return "$" + String(format: "%.0f", dollars) }
        if dollars >= 1 { return "$" + String(format: "%.2f", dollars) }
        if dollars >= 0.01 { return "$" + String(format: "%.2f", dollars) }
        return dollars > 0 ? "<$0.01" : "$0.00"
    }

    /// How old a provider's own figures are: "just now", "20 min ago".
    package static func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 90 { return "just now" }
        if seconds < 5400 { return "\(seconds / 60) min ago" }
        if seconds < 172_800 { return "\(seconds / 3600) h ago" }
        return "\(seconds / 86_400) d ago"
    }
}
