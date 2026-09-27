import SwiftUI

enum ProductEventType: String, Codable, Sendable {
    case stockArrived
    case stockDepleted
    case checkFailed
    case checkRecovered
    case trackingPaused
    case trackingResumed

    var title: String {
        switch self {
        case .stockArrived: "Stok geldi"
        case .stockDepleted: "Stok tükendi"
        case .checkFailed: "Kontrol başarısız"
        case .checkRecovered: "Kontrol yeniden başarılı"
        case .trackingPaused: "Takip duraklatıldı"
        case .trackingResumed: "Takip yeniden başlatıldı"
        }
    }

    var symbol: String {
        switch self {
        case .stockArrived: "checkmark.circle.fill"
        case .stockDepleted: "xmark.circle.fill"
        case .checkFailed: "exclamationmark.triangle.fill"
        case .checkRecovered: "arrow.clockwise.circle.fill"
        case .trackingPaused: "pause.circle.fill"
        case .trackingResumed: "play.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .stockArrived, .checkRecovered, .trackingResumed: .green
        case .stockDepleted: .red
        case .checkFailed: .orange
        case .trackingPaused: .secondary
        }
    }
}

struct ProductEvent: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var date: Date
    var type: ProductEventType
    var previousState: Bool?
    var newState: Bool?

    init(id: UUID = UUID(), date: Date, type: ProductEventType, previousState: Bool? = nil, newState: Bool? = nil) {
        self.id = id
        self.date = date
        self.type = type
        self.previousState = previousState
        self.newState = newState
    }
}

struct StockInterval: Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    let startDate: Date
    let endDate: Date? // nil if ongoing

    var duration: TimeInterval? {
        guard let endDate else { return nil }
        return max(0, endDate.timeIntervalSince(startDate))
    }

    var isOngoing: Bool {
        endDate == nil
    }
}

enum StockDurationFormatter {
    static func format(seconds: TimeInterval) -> String {
        let totalSeconds = max(0, seconds)
        if totalSeconds < 60 {
            return "< 1 dk"
        }

        let totalMinutes = Int(round(totalSeconds / 60.0))
        if totalMinutes < 60 {
            return "\(max(1, totalMinutes)) dk"
        }

        let hours = totalMinutes / 60
        let remainingMinutes = totalMinutes % 60
        if hours < 24 {
            if remainingMinutes > 0 {
                return "\(hours) sa \(remainingMinutes) dk"
            } else {
                return "\(hours) sa"
            }
        }

        let days = hours / 24
        let remainingHours = hours % 24
        if remainingHours > 0 {
            return "\(days) gün \(remainingHours) sa"
        } else {
            return "\(days) gün"
        }
    }
}

struct StockStatistics: Equatable, Sendable {
    let lastStockChangeDate: Date?
    let lastInStockDate: Date?
    let isCurrentlyInStock: Bool
    let totalRestockCount: Int
    let recentRestockCount30Days: Int
    let completedIntervals: [StockInterval]
    let ongoingInterval: StockInterval?
    let averageDuration: TimeInterval?
    let minDuration: TimeInterval?
    let maxDuration: TimeInterval?
    let latestDuration: TimeInterval?

    var hasStockHistory: Bool {
        totalRestockCount > 0 || lastStockChangeDate != nil
    }

    var formattedAverageDuration: String? {
        averageDuration.map { StockDurationFormatter.format(seconds: $0) }
    }

    var formattedMinDuration: String? {
        minDuration.map { StockDurationFormatter.format(seconds: $0) }
    }

    var formattedMaxDuration: String? {
        maxDuration.map { StockDurationFormatter.format(seconds: $0) }
    }

    var formattedLatestDuration: String? {
        latestDuration.map { StockDurationFormatter.format(seconds: $0) }
    }

    var latestInStockDurationDescription: String? {
        if isCurrentlyInStock || ongoingInterval != nil {
            return "Devam ediyor"
        }
        if let formatted = formattedLatestDuration {
            return formatted
        }
        return nil
    }

    static func calculate(
        from events: [ProductEvent],
        currentAvailability: Bool? = nil,
        referenceDate: Date = .now
    ) -> StockStatistics {
        // Stable-sort events by date
        let stockEventsWithIndex = events.enumerated()
            .filter { (_, event) in
                event.type == .stockArrived || event.type == .stockDepleted
            }
            .sorted { lhs, rhs in
                if lhs.element.date != rhs.element.date {
                    return lhs.element.date < rhs.element.date
                }
                return lhs.offset < rhs.offset
            }
            .map { $0.element }

        let lastStockChangeDate = stockEventsWithIndex.last?.date

        let restockEvents = stockEventsWithIndex.filter { $0.type == .stockArrived }
        let totalRestockCount = restockEvents.count

        let thirtyDaysAgo = referenceDate.addingTimeInterval(-30 * 24 * 3600)
        let recentRestockCount30Days = restockEvents.filter { $0.date >= thirtyDaysAgo }.count

        var completedIntervals: [StockInterval] = []
        var pendingArrivalDate: Date? = nil

        for event in stockEventsWithIndex {
            if event.type == .stockArrived {
                // An unclosed arrival is replaced with the newer arrival without guessing duration
                pendingArrivalDate = event.date
            } else if event.type == .stockDepleted {
                if let arrivalDate = pendingArrivalDate {
                    if event.date >= arrivalDate {
                        completedIntervals.append(StockInterval(startDate: arrivalDate, endDate: event.date))
                    }
                    pendingArrivalDate = nil
                }
            }
        }

        let isCurrentlyInStock: Bool
        let ongoingInterval: StockInterval?

        if let arrivalDate = pendingArrivalDate {
            if currentAvailability == true || (currentAvailability == nil && stockEventsWithIndex.last?.type == .stockArrived) {
                isCurrentlyInStock = true
                ongoingInterval = StockInterval(startDate: arrivalDate, endDate: nil)
            } else {
                isCurrentlyInStock = false
                ongoingInterval = nil
            }
        } else {
            isCurrentlyInStock = currentAvailability == true
            ongoingInterval = nil
        }

        let lastInStockDate: Date?
        if isCurrentlyInStock {
            lastInStockDate = ongoingInterval?.startDate ?? referenceDate
        } else if let latestCompleted = completedIntervals.last {
            lastInStockDate = latestCompleted.endDate
        } else if let latestDepleted = stockEventsWithIndex.last(where: { $0.type == .stockDepleted }) {
            lastInStockDate = latestDepleted.date
        } else if let latestArrived = stockEventsWithIndex.last(where: { $0.type == .stockArrived }) {
            lastInStockDate = latestArrived.date
        } else {
            lastInStockDate = nil
        }

        let durations = completedIntervals.compactMap { $0.duration }
        let averageDuration: TimeInterval? = durations.isEmpty ? nil : (durations.reduce(0, +) / Double(durations.count))
        let minDuration: TimeInterval? = durations.min()
        let maxDuration: TimeInterval? = durations.max()
        let latestDuration: TimeInterval? = completedIntervals.last?.duration

        return StockStatistics(
            lastStockChangeDate: lastStockChangeDate,
            lastInStockDate: lastInStockDate,
            isCurrentlyInStock: isCurrentlyInStock,
            totalRestockCount: totalRestockCount,
            recentRestockCount30Days: recentRestockCount30Days,
            completedIntervals: completedIntervals,
            ongoingInterval: ongoingInterval,
            averageDuration: averageDuration,
            minDuration: minDuration,
            maxDuration: maxDuration,
            latestDuration: latestDuration
        )
    }
}

