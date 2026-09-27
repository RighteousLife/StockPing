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
