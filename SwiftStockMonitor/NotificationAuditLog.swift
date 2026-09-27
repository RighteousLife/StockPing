import Foundation
import SwiftUI

enum NotificationAuditChannel: String, Codable, Sendable {
    case macOS
    case email

    var title: String {
        switch self {
        case .macOS: "macOS Bildirimi"
        case .email: "E-posta"
        }
    }

    var symbol: String {
        switch self {
        case .macOS: "bell.badge.fill"
        case .email: "envelope.fill"
        }
    }
}

enum NotificationAuditStatus: String, Codable, Sendable {
    case sent
    case failed
    case skipped

    var title: String {
        switch self {
        case .sent: "Gönderildi"
        case .failed: "Başarısız"
        case .skipped: "Atlandı (Devre Dışı)"
        }
    }

    var color: Color {
        switch self {
        case .sent: .green
        case .failed: .red
        case .skipped: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .sent: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .skipped: "minus.circle.fill"
        }
    }
}

struct NotificationAuditEvent: Identifiable, Codable, Sendable {
    var id: UUID = UUID()
    var date: Date
    var productID: UUID
    var productName: String
    var variantTitle: String
    var channel: NotificationAuditChannel
    var status: NotificationAuditStatus
    var message: String?
}

@MainActor
final class NotificationAuditManager: ObservableObject {
    static let shared = NotificationAuditManager()

    private let storageKey = "notificationAuditLogs.v1"
    private let maxEntries = 150

    @Published private(set) var events: [NotificationAuditEvent] = []

    private init() {
        loadEvents()
    }

    func record(
        productID: UUID,
        productName: String,
        variantTitle: String,
        channel: NotificationAuditChannel,
        status: NotificationAuditStatus,
        message: String? = nil,
        date: Date = Date()
    ) {
        let event = NotificationAuditEvent(
            id: UUID(),
            date: date,
            productID: productID,
            productName: productName,
            variantTitle: variantTitle,
            channel: channel,
            status: status,
            message: message
        )
        events.append(event)
        if events.count > maxEntries {
            events.removeFirst(events.count - maxEntries)
        }
        saveEvents()
    }

    func events(for productID: UUID) -> [NotificationAuditEvent] {
        events.filter { $0.productID == productID }.sorted { $0.date > $1.date }
    }

    func clearAll() {
        events.removeAll()
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    private func loadEvents() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([NotificationAuditEvent].self, from: data) else {
            events = []
            return
        }
        events = Array(decoded.suffix(maxEntries))
    }

    private func saveEvents() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
