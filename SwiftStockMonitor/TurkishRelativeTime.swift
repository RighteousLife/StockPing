import Foundation

enum TurkishRelativeTime {
    static func string(from date: Date, now: Date = .now) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(date)))
        if elapsed < 60 { return "Az önce" }
        if elapsed < 3_600 { return "\(max(1, elapsed / 60)) dakika önce" }
        if elapsed < 86_400 { return "\(max(1, elapsed / 3_600)) saat önce" }
        return "\(max(1, elapsed / 86_400)) gün önce"
    }
}
