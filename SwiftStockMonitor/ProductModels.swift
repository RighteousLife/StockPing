import Foundation
import SwiftUI

struct VariantOption: Codable, Hashable, Identifiable, Sendable {
    let name: String
    let value: String

    var id: String { "\(name)=\(value)" }
}

struct SelectedVariant: Codable, Hashable, Sendable {
    let id: String
    var title: String
    var options: [VariantOption]
    var availability: Bool?

    var displayTitle: String? {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.caseInsensitiveCompare("Default Title") != .orderedSame else {
            return nil
        }
        return normalized
    }

    var displayDescription: String {
        if !options.isEmpty {
            return options.map { "\($0.name): \($0.value)" }.joined(separator: " · ")
        }
        return displayTitle ?? "Tek seçenek"
    }
}

enum StoreProvider: String, Codable, Sendable, CaseIterable {
    case shopify
    case zara
    case bershka
    case pullAndBear

    var displayName: String {
        switch self {
        case .shopify: "Shopify"
        case .zara: "Zara"
        case .bershka: "Bershka"
        case .pullAndBear: "Pull&Bear"
        }
    }
}

struct ZaraVariantMetadata: Codable, Hashable, Sendable {
    var productGroupID: String
    var marketPath: String
    var storeID: Int
    var colorID: String
    var colorProductID: String
    var colorName: String
    var sizeID: String?
    var equivalentSizeID: String?
    var availabilitySKU: String
    var reference: String?
}

struct BershkaVariantMetadata: Codable, Hashable, Sendable {
    var productID: String
    var colorID: String
    var colorProductID: String
    var colorName: String
    var sizeName: String
    var sku: String
    var mastersSizeID: String?
    var partnumber: String?
}

struct PullAndBearVariantMetadata: Codable, Hashable, Sendable {
    var productCode: String
    var pageProductID: String?
    var colorParameter: String?
    var colorReference: String?
    var colorName: String
    var sizeName: String

    var colorIdentity: String { colorParameter ?? colorReference ?? colorName }
}

enum ProductStatus: String, Codable, Sendable {
    case inStock
    case outOfStock
    case checking
    case error
    case paused
    case unchecked

    var label: String {
        switch self {
        case .inStock: "Stokta"
        case .outOfStock: "Stokta değil"
        case .checking: "Kontrol ediliyor..."
        case .error: "Kontrol hatası"
        case .paused: "Takip duraklatıldı"
        case .unchecked: "Henüz kontrol edilmedi"
        }
    }

    var symbol: String {
        switch self {
        case .inStock: "checkmark.circle.fill"
        case .outOfStock: "xmark.circle.fill"
        case .checking: "arrow.triangle.2.circlepath"
        case .error: "exclamationmark.triangle.fill"
        case .paused: "pause.circle.fill"
        case .unchecked: "minus.circle"
        }
    }

    var color: Color {
        switch self {
        case .inStock: .green
        case .outOfStock: .red
        case .checking: .blue
        case .error: .orange
        case .paused, .unchecked: .secondary
        }
    }
}

enum DiagnosticOutcome: String, Codable, Sendable {
    case success
    case stockChanged
    case networkUnavailable
    case providerFailure
    case timeout
    case pageLoadFailure
    case cancelled
    case unknown

    var title: String {
        switch self {
        case .success: "Başarılı"
        case .stockChanged: "Stok Değişimi"
        case .networkUnavailable: "Ağ Bağlantısı Yok"
        case .providerFailure: "Sağlayıcı Hatası"
        case .timeout: "Zaman Aşımı"
        case .pageLoadFailure: "Sayfa Yüklenemedi"
        case .cancelled: "İptal Edildi"
        case .unknown: "Bilinmiyor"
        }
    }

    var symbol: String {
        switch self {
        case .success, .stockChanged: "checkmark.circle.fill"
        case .networkUnavailable: "wifi.slash"
        case .timeout: "clock.badge.exclamationmark.fill"
        case .pageLoadFailure, .providerFailure, .unknown: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .success, .stockChanged: .green
        case .networkUnavailable, .timeout: .orange
        case .pageLoadFailure, .providerFailure: .red
        case .cancelled, .unknown: .secondary
        }
    }
}

struct ProviderDiagnostic: Codable, Hashable, Sendable {
    var providerName: String
    var checkerName: String
    var startedAt: Date
    var completedAt: Date
    var durationSeconds: Double
    var outcome: DiagnosticOutcome
    var stockResult: Bool?
    var networkStatus: String
    var errorCategory: String?
    var userMessage: String
    var technicalDetail: String?
    var lastSuccessfulCheckDate: Date?

    var formattedDuration: String {
        if durationSeconds < 1.0 {
            return "<1 sn"
        }
        let formatted = String(format: "%.1f", durationSeconds).replacingOccurrences(of: ".", with: ",")
        return "\(formatted) sn"
    }
}

enum TechnicalDetailSanitizer {
    static func sanitize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        let sensitivePatterns = [
            "(?i)bearer\\s+[A-Za-z0-9\\-\\._~\\+/]+=*",
            "(?i)(cookie|set-cookie|authorization|token|secret|password|apikey|api_key):?\\s*[^;\\s,]+",
            "(?i)<script[\\s\\S]*?>[\\s\\S]*?<\\/script>",
            "<[^>]+>",
            "\\{[\\s\\S]*?\\}"
        ]

        for pattern in sensitivePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "[Gizlendi]")
            }
        }

        let pathPattern = "/Users/[^\\s/:]+"
        if let regex = try? NSRegularExpression(pattern: pathPattern) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "/[Kullanıcı]")
        }

        if text.count > 250 {
            text = String(text.prefix(250)) + "..."
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension StoreProvider {
    var defaultCheckerName: String {
        switch self {
        case .shopify: "ShopifyChecker"
        case .zara: "ZaraChecker"
        case .bershka: "BershkaChecker"
        case .pullAndBear: "PullAndBearChecker"
        }
    }
}

extension TrackedProduct {
    var providerDisplayName: String {
        switch provider {
        case .zara:
            return "Zara Türkiye"
        case .bershka:
            return "Bershka Türkiye"
        case .pullAndBear:
            return "Pull&Bear Türkiye"
        case .shopify:
            if let host = productURL.host() {
                return "Shopify (\(host))"
            }
            return "Shopify"
        }
    }
}

struct TrackedProduct: Identifiable {
    let id: UUID
    let productName: String
    let productURL: URL
    var selectedVariant: SelectedVariant
    var lastChecked: Date?
    var checkIntervalMinutes: Int
    var nextCheckDate: Date?
    var isPaused: Bool
    var lastCheckError: String?
    var lastAvailabilityTransition: AvailabilityTransition?
    var provider: StoreProvider = .shopify
    var zaraMetadata: ZaraVariantMetadata? = nil
    var bershkaMetadata: BershkaVariantMetadata? = nil
    var pullAndBearMetadata: PullAndBearVariantMetadata? = nil
    var events: [ProductEvent] = []
    var latestDiagnostic: ProviderDiagnostic? = nil
    var group: String? = nil
    var tags: [String] = []
    var consecutiveUnchangedChecks: Int = 0
    var consecutiveFailureChecks: Int = 0
    var isPriority: Bool = false
    var note: String? = nil
    var isMacOSNotificationEnabled: Bool = true
    var isEmailNotificationEnabled: Bool = true

    var variantID: String { selectedVariant.id }
    var variantTitle: String { selectedVariant.displayTitle ?? "Tek seçenek" }
    var lastKnownAvailable: Bool? {
        get { selectedVariant.availability }
        set { selectedVariant.availability = newValue }
    }

    var status: ProductStatus {
        if isPaused { return .paused }
        if lastCheckError != nil { return .error }
        if selectedVariant.availability == true { return .inStock }
        if selectedVariant.availability == false { return .outOfStock }
        return .unchecked
    }

    var stockStatistics: StockStatistics {
        StockStatistics.calculate(
            from: events,
            currentAvailability: lastKnownAvailable,
            referenceDate: .now
        )
    }


    mutating func record(_ type: ProductEventType, previousState: Bool? = nil, newState: Bool? = nil, at date: Date = .now) {
        events.append(ProductEvent(date: date, type: type, previousState: previousState, newState: newState))
        if events.count > 50 {
            events.removeFirst(events.count - 50)
        }
    }

    func isDuplicate(of other: TrackedProduct) -> Bool {
        guard provider == other.provider else { return false }
        if provider == .zara,
           let m1 = zaraMetadata,
           let m2 = other.zaraMetadata {
            return m1.productGroupID == m2.productGroupID &&
                   m1.colorProductID == m2.colorProductID &&
                   m1.availabilitySKU == m2.availabilitySKU
        }
        if provider == .bershka,
           let m1 = bershkaMetadata,
           let m2 = other.bershkaMetadata {
            return m1.productID == m2.productID &&
                   m1.colorID == m2.colorID &&
                   m1.sku == m2.sku
        }
        if provider == .pullAndBear,
           let m1 = pullAndBearMetadata,
           let m2 = other.pullAndBearMetadata {
            return m1.productCode == m2.productCode &&
                   m1.colorIdentity == m2.colorIdentity &&
                   m1.sizeName.caseInsensitiveCompare(m2.sizeName) == .orderedSame
        }
        return ShopifyChecker.productIdentity(for: productURL) == ShopifyChecker.productIdentity(for: other.productURL) &&
               variantID == other.variantID
    }

    func matches(candidate: StoreVariantCandidate, productURL: URL, provider: StoreProvider) -> Bool {
        guard self.provider == provider else { return false }
        if provider == .zara,
           let m1 = zaraMetadata,
           let m2 = candidate.zaraMetadata {
            return m1.productGroupID == m2.productGroupID &&
                   m1.colorProductID == m2.colorProductID &&
                   m1.availabilitySKU == m2.availabilitySKU
        }
        if provider == .bershka,
           let m1 = bershkaMetadata,
           let m2 = candidate.bershkaMetadata {
            return m1.productID == m2.productID &&
                   m1.colorID == m2.colorID &&
                   m1.sku == m2.sku
        }
        if provider == .pullAndBear,
           let m1 = pullAndBearMetadata,
           let m2 = candidate.pullAndBearMetadata {
            return m1.productCode == m2.productCode &&
                   m1.colorIdentity == m2.colorIdentity &&
                   m1.sizeName.caseInsensitiveCompare(m2.sizeName) == .orderedSame
        }
        return ShopifyChecker.productIdentity(for: self.productURL) == ShopifyChecker.productIdentity(for: productURL) &&
               variantID == candidate.variant.id
    }

    static let reflectedLightVinyl = TrackedProduct(
        id: UUID(),
        productName: "Patient Zero (Reflected Light Version) Vinyl",
        productURL: URL(string: "https://storeeu.taylorswift.com/products/patient-zero-reflected-light-version-vinyl")!,
        selectedVariant: SelectedVariant(id: "55676790047096", title: "OS", options: [], availability: nil),
        lastChecked: nil,
        checkIntervalMinutes: 1,
        nextCheckDate: nil,
        isPaused: false,
        lastCheckError: nil,
        lastAvailabilityTransition: nil
    )

    static let hisHaloVinyl = TrackedProduct(
        id: UUID(),
        productName: "Patient Zero (His Halo Version) Vinyl",
        productURL: URL(string: "https://storeeu.taylorswift.com/products/patient-zero-his-halo-version-vinyl")!,
        selectedVariant: SelectedVariant(id: "55676790014328", title: "OS", options: [], availability: nil),
        lastChecked: nil,
        checkIntervalMinutes: 1,
        nextCheckDate: nil,
        isPaused: false,
        lastCheckError: nil,
        lastAvailabilityTransition: nil
    )
}

enum AvailabilityTransition: Equatable, Sendable {
    case initial(available: Bool)
    case restocked
    case wentOutOfStock
    case unchanged(available: Bool)
}

private struct SavedTrackedProduct: Codable {
    let id: UUID
    let productName: String
    let productURL: URL
    let selectedVariant: SelectedVariant
    let lastChecked: Date?
    let checkIntervalMinutes: Int
    let nextCheckDate: Date?
    let isPaused: Bool
    let lastCheckError: String?
    let provider: StoreProvider
    let zaraMetadata: ZaraVariantMetadata?
    let bershkaMetadata: BershkaVariantMetadata?
    let pullAndBearMetadata: PullAndBearVariantMetadata?
    let events: [ProductEvent]
    let latestDiagnostic: ProviderDiagnostic?
    let group: String?
    let tags: [String]
    let consecutiveUnchangedChecks: Int
    let consecutiveFailureChecks: Int
    let isPriority: Bool
    let note: String?
    let isMacOSNotificationEnabled: Bool
    let isEmailNotificationEnabled: Bool

    init(_ product: TrackedProduct) {
        id = product.id
        productName = product.productName
        productURL = product.productURL
        selectedVariant = product.selectedVariant
        lastChecked = product.lastChecked
        checkIntervalMinutes = product.checkIntervalMinutes
        nextCheckDate = product.nextCheckDate
        isPaused = product.isPaused
        lastCheckError = product.lastCheckError
        provider = product.provider
        zaraMetadata = product.zaraMetadata
        bershkaMetadata = product.bershkaMetadata
        pullAndBearMetadata = product.pullAndBearMetadata
        events = product.events
        latestDiagnostic = product.latestDiagnostic
        group = product.group
        tags = product.tags
        consecutiveUnchangedChecks = product.consecutiveUnchangedChecks
        consecutiveFailureChecks = product.consecutiveFailureChecks
        isPriority = product.isPriority
        note = product.note
        isMacOSNotificationEnabled = product.isMacOSNotificationEnabled
        isEmailNotificationEnabled = product.isEmailNotificationEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, productName, productURL, selectedVariant, lastChecked
        case checkIntervalMinutes, nextCheckDate, isPaused, lastCheckError
        case provider, zaraMetadata, bershkaMetadata, pullAndBearMetadata, events, latestDiagnostic
        case group, tags
        case consecutiveUnchangedChecks, consecutiveFailureChecks
        case isPriority, note, isMacOSNotificationEnabled, isEmailNotificationEnabled
        // Fields written by trackedProducts.v1 before SelectedVariant was introduced.
        case variantID, variantTitle, lastKnownAvailable, status, options
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        productName = try values.decode(String.self, forKey: .productName)
        productURL = try values.decode(URL.self, forKey: .productURL)
        lastChecked = try values.decodeIfPresent(Date.self, forKey: .lastChecked)
        checkIntervalMinutes = max(1, try values.decodeIfPresent(Int.self, forKey: .checkIntervalMinutes) ?? 1)
        isPaused = try values.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false

        if let savedVariant = try values.decodeIfPresent(SelectedVariant.self, forKey: .selectedVariant) {
            selectedVariant = savedVariant
        } else {
            selectedVariant = SelectedVariant(
                id: try values.decode(String.self, forKey: .variantID),
                title: try values.decode(String.self, forKey: .variantTitle),
                options: try values.decodeIfPresent([VariantOption].self, forKey: .options) ?? [],
                availability: try values.decodeIfPresent(Bool.self, forKey: .lastKnownAvailable)
            )
        }

        nextCheckDate = try values.decodeIfPresent(Date.self, forKey: .nextCheckDate)
            ?? lastChecked?.addingTimeInterval(TimeInterval(checkIntervalMinutes * 60))
        let savedError = try values.decodeIfPresent(String.self, forKey: .lastCheckError)
        let oldStatus = try values.decodeIfPresent(String.self, forKey: .status)
        lastCheckError = savedError ?? (oldStatus == "Kontrol başarısız" ? "Önceki kontrol başarısız." : nil)
        provider = try values.decodeIfPresent(StoreProvider.self, forKey: .provider) ?? .shopify
        zaraMetadata = try values.decodeIfPresent(ZaraVariantMetadata.self, forKey: .zaraMetadata)
        bershkaMetadata = try values.decodeIfPresent(BershkaVariantMetadata.self, forKey: .bershkaMetadata)
        pullAndBearMetadata = try values.decodeIfPresent(PullAndBearVariantMetadata.self, forKey: .pullAndBearMetadata)
        events = Array((try values.decodeIfPresent([ProductEvent].self, forKey: .events) ?? []).suffix(50))
        latestDiagnostic = try values.decodeIfPresent(ProviderDiagnostic.self, forKey: .latestDiagnostic)
        group = try values.decodeIfPresent(String.self, forKey: .group)
        tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
        consecutiveUnchangedChecks = try values.decodeIfPresent(Int.self, forKey: .consecutiveUnchangedChecks) ?? 0
        consecutiveFailureChecks = try values.decodeIfPresent(Int.self, forKey: .consecutiveFailureChecks) ?? 0
        isPriority = try values.decodeIfPresent(Bool.self, forKey: .isPriority) ?? false
        note = try values.decodeIfPresent(String.self, forKey: .note)
        isMacOSNotificationEnabled = try values.decodeIfPresent(Bool.self, forKey: .isMacOSNotificationEnabled) ?? true
        isEmailNotificationEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEmailNotificationEnabled) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(productName, forKey: .productName)
        try values.encode(productURL, forKey: .productURL)
        try values.encode(selectedVariant, forKey: .selectedVariant)
        try values.encodeIfPresent(lastChecked, forKey: .lastChecked)
        try values.encode(checkIntervalMinutes, forKey: .checkIntervalMinutes)
        try values.encodeIfPresent(nextCheckDate, forKey: .nextCheckDate)
        try values.encode(isPaused, forKey: .isPaused)
        try values.encodeIfPresent(lastCheckError, forKey: .lastCheckError)
        try values.encode(provider, forKey: .provider)
        try values.encodeIfPresent(zaraMetadata, forKey: .zaraMetadata)
        try values.encodeIfPresent(bershkaMetadata, forKey: .bershkaMetadata)
        try values.encodeIfPresent(pullAndBearMetadata, forKey: .pullAndBearMetadata)
        try values.encode(events, forKey: .events)
        try values.encodeIfPresent(latestDiagnostic, forKey: .latestDiagnostic)
        try values.encodeIfPresent(group, forKey: .group)
        if !tags.isEmpty {
            try values.encode(tags, forKey: .tags)
        }
        if consecutiveUnchangedChecks > 0 {
            try values.encode(consecutiveUnchangedChecks, forKey: .consecutiveUnchangedChecks)
        }
        if consecutiveFailureChecks > 0 {
            try values.encode(consecutiveFailureChecks, forKey: .consecutiveFailureChecks)
        }
        if isPriority {
            try values.encode(isPriority, forKey: .isPriority)
        }
        if let note, !note.isEmpty {
            try values.encode(note, forKey: .note)
        }
        if !isMacOSNotificationEnabled {
            try values.encode(isMacOSNotificationEnabled, forKey: .isMacOSNotificationEnabled)
        }
        if !isEmailNotificationEnabled {
            try values.encode(isEmailNotificationEnabled, forKey: .isEmailNotificationEnabled)
        }
    }
}

enum TrackedProductStore {
    static let storageKey = "trackedProducts.v1"
    private static let starterProducts = [TrackedProduct.reflectedLightVinyl, TrackedProduct.hisHaloVinyl]

    static func load() -> [TrackedProduct] {
        let products: [TrackedProduct]
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            products = records.compactMap { record in
                guard let recordData = try? JSONSerialization.data(withJSONObject: record),
                      let saved = try? JSONDecoder().decode(SavedTrackedProduct.self, from: recordData) else {
                    return nil
                }
                return saved.trackedProduct
            }
        } else {
            products = starterProducts
        }
        save(products)
        return products
    }

    static func save(_ products: [TrackedProduct]) {
        do {
            let data = try JSONEncoder().encode(products.map(SavedTrackedProduct.init))
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            // Leave the current in-memory list usable if encoding unexpectedly fails.
        }
    }
}

private extension SavedTrackedProduct {
    var trackedProduct: TrackedProduct {
        TrackedProduct(
            id: id,
            productName: productName,
            productURL: productURL,
            selectedVariant: selectedVariant,
            lastChecked: lastChecked,
            checkIntervalMinutes: checkIntervalMinutes,
            nextCheckDate: nextCheckDate,
            isPaused: isPaused,
            lastCheckError: lastCheckError,
            lastAvailabilityTransition: nil,
            provider: provider,
            zaraMetadata: zaraMetadata,
            bershkaMetadata: bershkaMetadata,
            pullAndBearMetadata: pullAndBearMetadata,
            events: events,
            latestDiagnostic: latestDiagnostic,
            group: group,
            tags: tags,
            consecutiveUnchangedChecks: consecutiveUnchangedChecks,
            consecutiveFailureChecks: consecutiveFailureChecks,
            isPriority: isPriority,
            note: note,
            isMacOSNotificationEnabled: isMacOSNotificationEnabled,
            isEmailNotificationEnabled: isEmailNotificationEnabled
        )
    }
}

enum ProductCheckInterval {
    static let minutes = [1, 2, 5, 10, 30, 60, 120, 300, 720, 1440]

    static func title(for minutes: Int) -> String {
        switch minutes {
        case 60: "1 saat"
        case 120: "2 saat"
        case 300: "5 saat"
        case 720: "12 saat"
        case 1440: "24 saat"
        default: "\(minutes) dakika"
        }
    }

    static func shortTitle(for minutes: Int) -> String {
        switch minutes {
        case 60: "1 sa"
        case 120: "2 sa"
        case 300: "5 sa"
        case 720: "12 sa"
        case 1440: "24 sa"
        default: "\(minutes) dk"
        }
    }
}

struct AdaptiveMonitoringPolicy: Sendable {
    static let maxAdaptiveIntervalMinutes: Int = 30

    static func effectiveIntervalMinutes(
        baseMinutes: Int,
        status: ProductStatus,
        consecutiveUnchangedChecks: Int,
        consecutiveFailureChecks: Int,
        isEnabled: Bool
    ) -> Int {
        guard isEnabled else { return baseMinutes }

        // Progressive backoff for repeated check failures
        if consecutiveFailureChecks >= 5 {
            return min(maxAdaptiveIntervalMinutes, max(baseMinutes * 3, 15))
        } else if consecutiveFailureChecks >= 3 {
            return min(maxAdaptiveIntervalMinutes, baseMinutes * 2)
        }

        // Only scale back checking for confirmed out-of-stock products
        guard status == .outOfStock else { return baseMinutes }

        // Tier 2: 9 or more consecutive unchanged out-of-stock checks
        if consecutiveUnchangedChecks >= 9 {
            if baseMinutes <= 2 {
                return min(maxAdaptiveIntervalMinutes, baseMinutes * 4)
            } else {
                return min(maxAdaptiveIntervalMinutes, max(baseMinutes + 10, baseMinutes * 2))
            }
        }
        // Tier 1: 4 to 8 consecutive unchanged out-of-stock checks
        else if consecutiveUnchangedChecks >= 4 {
            if baseMinutes <= 2 {
                return min(maxAdaptiveIntervalMinutes, baseMinutes * 2)
            } else {
                return min(maxAdaptiveIntervalMinutes, max(baseMinutes + 5, (baseMinutes * 3) / 2))
            }
        }

        // Tier 0: < 4 unchanged checks
        return baseMinutes
    }

    static func reason(
        baseMinutes: Int,
        effectiveMinutes: Int,
        status: ProductStatus,
        consecutiveUnchangedChecks: Int,
        consecutiveFailureChecks: Int,
        isEnabled: Bool
    ) -> String? {
        guard isEnabled, effectiveMinutes != baseMinutes else { return nil }
        if consecutiveFailureChecks >= 3 {
            return "Arka arkaya \(consecutiveFailureChecks) kontrol başarısız olduğu için istek sıklığı azaltıldı (\(effectiveMinutes) dk)."
        }
        if status == .outOfStock && consecutiveUnchangedChecks >= 4 {
            return "Ürün \(consecutiveUnchangedChecks) kontroldür stokta olmadığı için kontrol sıklığı akıllı olarak azaltıldı (\(effectiveMinutes) dk)."
        }
        return "Akıllı kontrol aralığı etkin (\(effectiveMinutes) dk)."
    }
}

