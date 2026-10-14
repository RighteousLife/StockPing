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

enum SmartTrackingRule: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case exactVariant
    case anySizeInSelectedColor
    case selectedSizeInAnyColor
    case anyVariant

    var id: Self { self }

    var title: String {
        switch self {
        case .exactVariant: return "Tam varyant"
        case .anySizeInSelectedColor: return "Bu rengin herhangi bir bedeni"
        case .selectedSizeInAnyColor: return "Bu bedenin herhangi bir rengi"
        case .anyVariant: return "Ürünün herhangi bir varyantı"
        }
    }

    var shortTitle: String {
        switch self {
        case .exactVariant: return "Tam varyant"
        case .anySizeInSelectedColor: return "Rengin her bedeni"
        case .selectedSizeInAnyColor: return "Bedenin her rengi"
        case .anyVariant: return "Tüm varyantlar"
        }
    }

    var description: String {
        switch self {
        case .exactVariant:
            return "Yalnızca seçilen varyant takip edilir."
        case .anySizeInSelectedColor:
            return "Seçilen rengin herhangi bir bedeni stokta olduğunda bildirilir."
        case .selectedSizeInAnyColor:
            return "Seçilen bedenin herhangi bir rengi stokta olduğunda bildirilir."
        case .anyVariant:
            return "Ürünün herhangi bir varyantı stokta olduğunda bildirilir."
        }
    }

    var symbol: String {
        switch self {
        case .exactVariant: return "target"
        case .anySizeInSelectedColor: return "tshirt"
        case .selectedSizeInAnyColor: return "paintpalette"
        case .anyVariant: return "square.grid.2x2"
        }
    }

    func previewText(selectedVariant: SelectedVariant, colorName: String? = nil, sizeName: String? = nil) -> String {
        switch self {
        case .exactVariant:
            let title = selectedVariant.displayTitle ?? "seçilen varyant"
            return "Yalnızca \(title) takip edilecek."
        case .anySizeInSelectedColor:
            if let color = colorName, !color.isEmpty {
                return "\(color) rengin herhangi bir bedeni takip edilecek."
            }
            return "Seçilen rengin herhangi bir bedeni takip edilecek."
        case .selectedSizeInAnyColor:
            if let size = sizeName, !size.isEmpty {
                return "\(size) bedenin herhangi bir rengi takip edilecek."
            }
            return "Seçilen bedenin herhangi bir rengi takip edilecek."
        case .anyVariant:
            return "Ürünün herhangi bir varyantı stokta olduğunda bildirim alacaksınız."
        }
    }

    func preview(color: String? = nil, size: String? = nil) -> String {
        switch self {
        case .exactVariant:
            if let color, let size { return "Yalnızca bu renk (\(color)) ve bu beden (\(size)) için stok geldiğinde uyarılır." }
            return "Yalnızca seçilen kesin varyant için stok geldiğinde uyarılır."
        case .anySizeInSelectedColor:
            let c = color ?? "seçili renk"
            return "\(c) renginin herhangi bir bedeni stoğa girdiğinde uyarılır."
        case .selectedSizeInAnyColor:
            let s = size ?? "seçili beden"
            return "\(s) bedeninin herhangi bir rengi stoğa girdiğinde uyarılır."
        case .anyVariant:
            return "Ürünün herhangi bir rengi veya bedeni stoğa girdiğinde uyarılır."
        }
    }

    static func isColorOptionName(_ name: String) -> Bool {
        let lower = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return lower.contains("renk") || lower.contains("color") || lower.contains("colour")
    }

    static func isSizeOptionName(_ name: String) -> Bool {
        let lower = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return lower.contains("beden") || lower.contains("size") || lower.contains("boy") || lower.contains("numara")
    }
}

enum SmartAlertCondition: Hashable, Codable, Sendable {
    case anyMatching
    case minimumCount(Int)

    var title: String {
        switch self {
        case .anyMatching:
            return "Herhangi biri stokta olduğunda"
        case .minimumCount(let count):
            return "En az \(count) varyant stokta olduğunda"
        }
    }

    var threshold: Int {
        switch self {
        case .anyMatching: return 1
        case .minimumCount(let n): return max(1, n)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, count
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        if type == "minimumCount", let count = try container.decodeIfPresent(Int.self, forKey: .count) {
            self = .minimumCount(max(1, count))
        } else {
            self = .anyMatching
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .anyMatching:
            try container.encode("anyMatching", forKey: .type)
        case .minimumCount(let count):
            try container.encode("minimumCount", forKey: .type)
            try container.encode(count, forKey: .count)
        }
    }
}

enum RestockVerificationMode: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case off
    case oneConfirmation
    case twoConfirmations

    var id: Self { self }

    var title: String {
        switch self {
        case .off: return "Kapalı"
        case .oneConfirmation: return "1 kez doğrula"
        case .twoConfirmations: return "2 kez doğrula"
        }
    }

    var requiredConfirmations: Int {
        switch self {
        case .off: return 0
        case .oneConfirmation: return 1
        case .twoConfirmations: return 2
        }
    }

    var description: String {
        switch self {
        case .off: return "Stok tespit edildiğinde anında bildirim gönderilir."
        case .oneConfirmation: return "Stok tespit edildiğinde arka planda 1 ek hızlı kontrolle teyit edildikten sonra bildirilir."
        case .twoConfirmations: return "Stok tespit edildiğinde arka planda 2 ardışık kontrolle teyit edildikten sonra bildirilir."
        }
    }
}

enum VariantAvailabilityState: String, Codable, Hashable, Sendable, CaseIterable {
    case inStock
    case outOfStock
    case unknown

    var title: String {
        switch self {
        case .inStock: "Stokta"
        case .outOfStock: "Tükendi"
        case .unknown: "Bilinmiyor"
        }
    }

    var symbol: String {
        switch self {
        case .inStock: "checkmark.circle.fill"
        case .outOfStock: "xmark.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .inStock: .green
        case .outOfStock: .red
        case .unknown: .secondary
        }
    }

    init(availability: Bool?) {
        switch availability {
        case true: self = .inStock
        case false: self = .outOfStock
        case nil: self = .unknown
        }
    }

    var boolValue: Bool? {
        switch self {
        case .inStock: true
        case .outOfStock: false
        case .unknown: nil
        }
    }

    var isAvailable: Bool? {
        boolValue
    }
}

struct VariantStockSnapshot: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var title: String
    var options: [VariantOption]
    var state: VariantAvailabilityState
    var lastChecked: Date?

    var availability: Bool? {
        state.boolValue
    }

    var displayTitle: String {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.isEmpty && normalized.caseInsensitiveCompare("Default Title") != .orderedSame {
            return normalized
        }
        if !options.isEmpty {
            return options.map(\.value).joined(separator: " · ")
        }
        return "Tek seçenek"
    }

    func optionValue(for dimensionName: String) -> String? {
        options.first(where: { $0.name.caseInsensitiveCompare(dimensionName) == .orderedSame })?.value
    }

    var colorValue: String? {
        options.first(where: { SmartTrackingRule.isColorOptionName($0.name) })?.value
    }

    var sizeValue: String? {
        options.first(where: { SmartTrackingRule.isSizeOptionName($0.name) })?.value
    }

    init(
        id: String,
        title: String,
        options: [VariantOption] = [],
        state: VariantAvailabilityState = .unknown,
        lastChecked: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.options = options
        self.state = state
        self.lastChecked = lastChecked
    }

    init(from variant: SelectedVariant, lastChecked: Date? = nil) {
        self.id = variant.id
        self.title = variant.title
        self.options = variant.options
        self.state = VariantAvailabilityState(availability: variant.availability)
        self.lastChecked = lastChecked
    }
}

struct VariantStockSummary: Hashable, Sendable {
    let totalCount: Int
    let inStockCount: Int
    let outOfStockCount: Int
    let unknownCount: Int
    let lastChecked: Date?

    var summaryText: String {
        "\(inStockCount) / \(totalCount) stokta"
    }

    static func calculate(for variants: [VariantStockSnapshot]) -> VariantStockSummary {
        let total = variants.count
        let inStock = variants.filter { $0.state == .inStock }.count
        let outOfStock = variants.filter { $0.state == .outOfStock }.count
        let unknown = variants.filter { $0.state == .unknown }.count
        let latestCheck = variants.compactMap(\.lastChecked).max()

        return VariantStockSummary(
            totalCount: total,
            inStockCount: inStock,
            outOfStockCount: outOfStock,
            unknownCount: unknown,
            lastChecked: latestCheck
        )
    }
}

enum StoreProvider: String, Codable, Sendable, CaseIterable {
    case shopify
    case zara
    case bershka
    case pullAndBear
    case hm


        var displayName: String {
        switch self {
        case .shopify: return "Shopify"
        case .zara: return "Zara"
        case .bershka: return "Bershka"
        case .pullAndBear: return "Pull&Bear"
        case .hm: return "H&M"
        }
    }
}

enum NotificationProfile: String, Codable, CaseIterable, Sendable {
    case standard
    case onlyRestock
    case allChanges
    case silent

    var title: String {
        switch self {
        case .standard: "Standart (Yalnızca Stok Geldiğinde)"
        case .onlyRestock: "Yalnızca Stok Geldiğinde"
        case .allChanges: "Tüm Değişiklikler (Giriş & Çıkış)"
        case .silent: "Sessiz (Bildirim Yok)"
        }
    }

    var shortTitle: String {
        switch self {
        case .standard: "Standart"
        case .onlyRestock: "Yalnızca Stok"
        case .allChanges: "Tüm Değişimler"
        case .silent: "Sessiz"
        }
    }

    var symbol: String {
        switch self {
        case .standard: "bell"
        case .onlyRestock: "bell.badge"
        case .allChanges: "bell.badge.fill"
        case .silent: "bell.slash"
        }
    }

    var shouldNotifyOnRestock: Bool {
        switch self {
        case .standard, .onlyRestock, .allChanges: true
        case .silent: false
        }
    }

    var shouldNotifyOnDepletion: Bool {
        switch self {
        case .allChanges: true
        case .standard, .onlyRestock, .silent: false
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

struct HMVariantMetadata: Codable, Hashable, Sendable {
    var articleID: String
    var variantID: String?
    var compositeID: String
    var colorName: String?
    var sizeName: String?
}

struct PullAndBearVariantMetadata: Codable, Hashable, Sendable {
    var productCode: String
    var pageProductID: String?
    var colorParameter: String?
    var colorReference: String?
    var colorName: String
    var sizeName: String
    var sku: String?
    var colorID: String?
    var partnumber: String?

    var colorIdentity: String { colorParameter ?? colorReference ?? colorName }

    init(
        productCode: String,
        pageProductID: String? = nil,
        colorParameter: String? = nil,
        colorReference: String? = nil,
        colorName: String,
        sizeName: String,
        sku: String? = nil,
        colorID: String? = nil,
        partnumber: String? = nil
    ) {
        self.productCode = productCode
        self.pageProductID = pageProductID
        self.colorParameter = colorParameter
        self.colorReference = colorReference
        self.colorName = colorName
        self.sizeName = sizeName
        self.sku = sku
        self.colorID = colorID
        self.partnumber = partnumber
    }
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

enum ProviderHealth: String, Codable, Sendable, CaseIterable {
    case healthy
    case warning
    case unknown
    case notTracked
    case networkUnavailable

    var title: String {
        switch self {
        case .healthy: "Sorunsuz"
        case .warning: "Uyarı"
        case .unknown: "Bilinmiyor"
        case .notTracked: "Takip edilmiyor"
        case .networkUnavailable: "Ağ Yok"
        }
    }

    var symbol: String {
        switch self {
        case .healthy: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        case .notTracked: "slash.circle"
        case .networkUnavailable: "wifi.slash"
        }
    }

    var color: Color {
        switch self {
        case .healthy: .green
        case .warning: .orange
        case .unknown, .notTracked: .secondary
        case .networkUnavailable: .red
        }
    }
}

struct ProviderHealthSummary: Identifiable, Sendable {
    let provider: StoreProvider
    let health: ProviderHealth
    let productCount: Int
    let activeProductCount: Int
    let lastSuccessfulCheckDate: Date?
    let lastErrorMessage: String?

    var id: StoreProvider { provider }

    static func calculate(
        for provider: StoreProvider,
        products: [TrackedProduct],
        isNetworkAvailable: Bool
    ) -> ProviderHealthSummary {
        let providerProducts = products.filter { $0.provider == provider }
        let count = providerProducts.count
        let activeProducts = providerProducts.filter { !$0.isPaused }
        let activeCount = activeProducts.count

        guard isNetworkAvailable else {
            return ProviderHealthSummary(
                provider: provider,
                health: .networkUnavailable,
                productCount: count,
                activeProductCount: activeCount,
                lastSuccessfulCheckDate: nil,
                lastErrorMessage: "Ağ bağlantısı yok"
            )
        }

        if providerProducts.isEmpty {
            return ProviderHealthSummary(
                provider: provider,
                health: .notTracked,
                productCount: 0,
                activeProductCount: 0,
                lastSuccessfulCheckDate: nil,
                lastErrorMessage: nil
            )
        }

        let lastSuccess = providerProducts
            .compactMap { $0.latestDiagnostic?.lastSuccessfulCheckDate ?? ($0.lastCheckError == nil ? $0.lastChecked : nil) }
            .max()

        let recentError = activeProducts.first(where: { $0.lastCheckError != nil })?.lastCheckError
            ?? activeProducts.compactMap { p -> String? in
                if let diag = p.latestDiagnostic, diag.outcome == .providerFailure || diag.outcome == .timeout || diag.outcome == .pageLoadFailure {
                    return diag.userMessage
                }
                return nil
            }.first

        let hasError = activeProducts.contains { p in
            p.status == .error || p.lastCheckError != nil ||
            p.latestDiagnostic?.outcome == .providerFailure ||
            p.latestDiagnostic?.outcome == .timeout ||
            p.latestDiagnostic?.outcome == .pageLoadFailure
        }

        let hasSuccess = providerProducts.contains { p in
            p.lastChecked != nil && p.lastCheckError == nil
        }

        let health: ProviderHealth
        if hasError {
            health = .warning
        } else if hasSuccess {
            health = .healthy
        } else {
            health = .unknown
        }

        return ProviderHealthSummary(
            provider: provider,
            health: health,
            productCount: count,
            activeProductCount: activeCount,
            lastSuccessfulCheckDate: lastSuccess,
            lastErrorMessage: recentError
        )
    }

    static func allSummaries(
        for products: [TrackedProduct],
        isNetworkAvailable: Bool
    ) -> [ProviderHealthSummary] {
        StoreProvider.allCases.map { calculate(for: $0, products: products, isNetworkAvailable: isNetworkAvailable) }
    }
}

enum ProductReliabilityLevel: String, Codable, Sendable, CaseIterable {
    case high
    case warning
    case unknown

    var title: String {
        switch self {
        case .high: "Yüksek"
        case .warning: "Uyarı"
        case .unknown: "Bilinmiyor"
        }
    }

    var displayName: String { title }

    var symbol: String {
        switch self {
        case .high: "shield.checkmark.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .high: .green
        case .warning: .orange
        case .unknown: .secondary
        }
    }
}

struct ProductReliability: Sendable, Hashable {
    let level: ProductReliabilityLevel
    let description: String
    let consecutiveFailures: Int
    let lastSuccessfulCheck: Date?
    let diagnosticOutcome: DiagnosticOutcome?

    var reason: String { description }

    static func calculate(for product: TrackedProduct) -> ProductReliability {
        let failures = product.consecutiveFailureChecks
        let lastSuccess = product.latestDiagnostic?.lastSuccessfulCheckDate ?? (product.lastCheckError == nil ? product.lastChecked : nil)
        let outcome = product.latestDiagnostic?.outcome

        if product.status == .error || product.lastCheckError != nil || failures > 0 || outcome == .providerFailure || outcome == .timeout || outcome == .pageLoadFailure {
            let reason = product.lastCheckError ?? product.latestDiagnostic?.userMessage ?? "Son kontrollerde hata tespit edildi"
            return ProductReliability(
                level: .warning,
                description: reason,
                consecutiveFailures: max(1, failures),
                lastSuccessfulCheck: lastSuccess,
                diagnosticOutcome: outcome
            )
        } else if product.lastChecked != nil && failures == 0 {
            return ProductReliability(
                level: .high,
                description: "Kontroller sorunsuz çalışıyor",
                consecutiveFailures: 0,
                lastSuccessfulCheck: lastSuccess,
                diagnosticOutcome: outcome ?? .success
            )
        } else {
            return ProductReliability(
                level: .unknown,
                description: "Henüz kontrol yapılmadı",
                consecutiveFailures: 0,
                lastSuccessfulCheck: nil,
                diagnosticOutcome: nil
            )
        }
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
        case .shopify: return "ShopifyChecker"
        case .zara: return "ZaraChecker"
        case .bershka: return "BershkaChecker"
        case .pullAndBear: return "PullAndBearChecker"
        case .hm: return "HMChecker"
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
        case .hm:
            return "H&M Türkiye"
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
    var hmMetadata: HMVariantMetadata? = nil

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
    var notificationProfile: NotificationProfile = .standard
    var autoOpenOnRestock: Bool? = nil
    var variantSnapshots: [VariantStockSnapshot]? = nil

    var trackingRule: SmartTrackingRule = .exactVariant
    var alertCondition: SmartAlertCondition = .anyMatching
    var verificationPreference: RestockVerificationMode? = nil
    var burstPreference: Bool? = nil
    var burstExpiresAt: Date? = nil
    var pendingVerificationCount: Int = 0
    var logicalAvailability: Bool? = nil

    var isBurstActive: Bool {
        guard let burstExpiresAt else { return false }
        return burstExpiresAt > Date()
    }

    var effectiveAvailability: Bool? {
        logicalAvailability ?? selectedVariant.availability
    }

    var selectedColorName: String? {
        if let color = zaraMetadata?.colorName, !color.isEmpty { return color }
        if let color = bershkaMetadata?.colorName, !color.isEmpty { return color }
        if let color = hmMetadata?.colorName, !color.isEmpty { return color }
        if let color = pullAndBearMetadata?.colorName, !color.isEmpty { return color }
        return selectedVariant.options.first(where: { SmartTrackingRule.isColorOptionName($0.name) })?.value
    }

    var selectedSizeName: String? {
        if let size = bershkaMetadata?.sizeName, !size.isEmpty { return size }
        if let size = hmMetadata?.sizeName, !size.isEmpty { return size }
        if let size = pullAndBearMetadata?.sizeName, !size.isEmpty { return size }
        if let size = selectedVariant.options.first(where: { SmartTrackingRule.isSizeOptionName($0.name) })?.value {
            return size
        }
        if provider == .zara {
            return selectedVariant.displayTitle
        }
        return nil
    }

    struct LogicalStockEvaluation: Sendable, Hashable {
        let isAvailable: Bool
        let matchingCount: Int
        let matchingSnapshots: [VariantStockSnapshot]
        let candidateSnapshots: [VariantStockSnapshot]
    }

    func evaluateLogicalStock(snapshots: [VariantStockSnapshot]) -> LogicalStockEvaluation {
        let allCandidates = snapshots.isEmpty ? currentVariantSnapshots : snapshots
        let matchedCandidates: [VariantStockSnapshot]

        switch trackingRule {
        case .exactVariant:
            if let exact = allCandidates.first(where: { $0.id == selectedVariant.id }) {
                matchedCandidates = [exact]
            } else if let exact = allCandidates.first(where: { $0.displayTitle.caseInsensitiveCompare(selectedVariant.displayTitle ?? "") == .orderedSame }) {
                matchedCandidates = [exact]
            } else {
                matchedCandidates = [VariantStockSnapshot(from: selectedVariant, lastChecked: lastChecked)]
            }

        case .anySizeInSelectedColor:
            if let myColor = selectedColorName?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !myColor.isEmpty {
                let filtered = allCandidates.filter { snap in
                    if let c = snap.colorValue?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty {
                        return c == myColor
                    }
                    return true
                }
                matchedCandidates = filtered.isEmpty ? allCandidates : filtered
            } else {
                matchedCandidates = allCandidates
            }

        case .selectedSizeInAnyColor:
            if let mySize = selectedSizeName?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !mySize.isEmpty {
                let filtered = allCandidates.filter { snap in
                    if let s = snap.sizeValue?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                        return s == mySize
                    }
                    if snap.displayTitle.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == mySize {
                        return true
                    }
                    return false
                }
                matchedCandidates = filtered.isEmpty ? allCandidates : filtered
            } else {
                matchedCandidates = allCandidates
            }

        case .anyVariant:
            matchedCandidates = allCandidates
        }

        let inStockSnapshots = matchedCandidates.filter { $0.state == .inStock }
        let count = inStockSnapshots.count
        let isAvailable = count >= alertCondition.threshold

        return LogicalStockEvaluation(
            isAvailable: isAvailable,
            matchingCount: count,
            matchingSnapshots: inStockSnapshots,
            candidateSnapshots: matchedCandidates
        )
    }

    var currentVariantSnapshots: [VariantStockSnapshot] {
        if let snapshots = variantSnapshots, !snapshots.isEmpty {
            return snapshots
        }
        return [VariantStockSnapshot(from: selectedVariant, lastChecked: lastChecked)]
    }

    var variantStockSummary: VariantStockSummary {
        VariantStockSummary.calculate(for: currentVariantSnapshots)
    }

    var variantID: String { selectedVariant.id }
    var variantTitle: String { selectedVariant.displayTitle ?? "Tek seçenek" }
    var lastKnownAvailable: Bool? {
        get { selectedVariant.availability }
        set { selectedVariant.availability = newValue }
    }

    var status: ProductStatus {
        if isPaused { return .paused }
        if lastCheckError != nil { return .error }
        if effectiveAvailability == true { return .inStock }
        if effectiveAvailability == false { return .outOfStock }
        return .unchecked
    }

    var stockAvailabilityStatus: ProductStatus {
        if effectiveAvailability == true { return .inStock }
        if effectiveAvailability == false { return .outOfStock }
        return .unchecked
    }

    var hasCheckFailure: Bool {
        lastCheckError != nil || consecutiveFailureChecks > 0
    }

    var lastSuccessfulCheckDate: Date? {
        latestDiagnostic?.lastSuccessfulCheckDate ?? (lastCheckError == nil ? lastChecked : nil)
    }

    var reliability: ProductReliability {
        ProductReliability.calculate(for: self)
    }

    var stockStatistics: StockStatistics {
        StockStatistics.calculate(
            from: events,
            currentAvailability: lastKnownAvailable,
            referenceDate: .now
        )
    }

    func periodMetrics(for period: StockAnalyticsPeriod, referenceDate: Date = .now) -> StockPeriodMetrics {
        stockStatistics.periodMetrics(for: period, allEvents: events, referenceDate: referenceDate)
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
        if provider == .hm {
            if let m1 = hmMetadata, let m2 = other.hmMetadata {
                return m1.articleID == m2.articleID && m1.variantID == m2.variantID
            }
            return HMChecker.normalizedProductURL(from: productURL) == HMChecker.normalizedProductURL(from: other.productURL) &&
                   variantID == other.variantID
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
        if provider == .hm {
            if let m1 = hmMetadata, let m2 = candidate.hmMetadata {
                return m1.articleID == m2.articleID && m1.variantID == m2.variantID
            }
            return HMChecker.normalizedProductURL(from: self.productURL) == HMChecker.normalizedProductURL(from: productURL) &&
                   variantID == candidate.variant.id
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

struct SavedTrackedProduct: Codable {
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
    let hmMetadata: HMVariantMetadata?

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
    let notificationProfile: NotificationProfile
    let autoOpenOnRestock: Bool?
    let variantSnapshots: [VariantStockSnapshot]?

    let trackingRule: SmartTrackingRule
    let alertCondition: SmartAlertCondition
    let verificationPreference: RestockVerificationMode?
    let burstPreference: Bool?
    let burstExpiresAt: Date?
    let pendingVerificationCount: Int
    let logicalAvailability: Bool?

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
        hmMetadata = product.hmMetadata

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
        notificationProfile = product.notificationProfile
        autoOpenOnRestock = product.autoOpenOnRestock
        variantSnapshots = product.variantSnapshots

        trackingRule = product.trackingRule
        alertCondition = product.alertCondition
        verificationPreference = product.verificationPreference
        burstPreference = product.burstPreference
        burstExpiresAt = product.burstExpiresAt
        pendingVerificationCount = product.pendingVerificationCount
        logicalAvailability = product.logicalAvailability
    }

    private enum CodingKeys: String, CodingKey {
        case id, productName, productURL, selectedVariant, lastChecked
        case checkIntervalMinutes, nextCheckDate, isPaused, lastCheckError
        case provider, zaraMetadata, bershkaMetadata, pullAndBearMetadata, hmMetadata, events, latestDiagnostic
        case group, tags
        case consecutiveUnchangedChecks, consecutiveFailureChecks
        case isPriority, note, isMacOSNotificationEnabled, isEmailNotificationEnabled
        case notificationProfile, autoOpenOnRestock, variantSnapshots
        case trackingRule, alertCondition, verificationPreference, burstPreference, burstExpiresAt, pendingVerificationCount, logicalAvailability
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
        hmMetadata = try values.decodeIfPresent(HMVariantMetadata.self, forKey: .hmMetadata)

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
        notificationProfile = try values.decodeIfPresent(NotificationProfile.self, forKey: .notificationProfile) ?? .standard
        autoOpenOnRestock = try values.decodeIfPresent(Bool.self, forKey: .autoOpenOnRestock)
        variantSnapshots = try values.decodeIfPresent([VariantStockSnapshot].self, forKey: .variantSnapshots)

        trackingRule = try values.decodeIfPresent(SmartTrackingRule.self, forKey: .trackingRule) ?? .exactVariant
        alertCondition = try values.decodeIfPresent(SmartAlertCondition.self, forKey: .alertCondition) ?? .anyMatching
        verificationPreference = try values.decodeIfPresent(RestockVerificationMode.self, forKey: .verificationPreference)
        burstPreference = try values.decodeIfPresent(Bool.self, forKey: .burstPreference)
        burstExpiresAt = try values.decodeIfPresent(Date.self, forKey: .burstExpiresAt)
        pendingVerificationCount = try values.decodeIfPresent(Int.self, forKey: .pendingVerificationCount) ?? 0
        logicalAvailability = try values.decodeIfPresent(Bool.self, forKey: .logicalAvailability)
            ?? (try values.decodeIfPresent(Bool.self, forKey: .lastKnownAvailable))
            ?? selectedVariant.availability
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
        try values.encodeIfPresent(hmMetadata, forKey: .hmMetadata)

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
        if notificationProfile != .standard {
            try values.encode(notificationProfile, forKey: .notificationProfile)
        }
        try values.encodeIfPresent(autoOpenOnRestock, forKey: .autoOpenOnRestock)
        if let variantSnapshots, !variantSnapshots.isEmpty {
            try values.encode(Array(variantSnapshots.prefix(50)), forKey: .variantSnapshots)
        }

        if trackingRule != .exactVariant {
            try values.encode(trackingRule, forKey: .trackingRule)
        }
        if alertCondition != .anyMatching {
            try values.encode(alertCondition, forKey: .alertCondition)
        }
        try values.encodeIfPresent(verificationPreference, forKey: .verificationPreference)
        try values.encodeIfPresent(burstPreference, forKey: .burstPreference)
        try values.encodeIfPresent(burstExpiresAt, forKey: .burstExpiresAt)
        if pendingVerificationCount > 0 {
            try values.encode(pendingVerificationCount, forKey: .pendingVerificationCount)
        }
        try values.encodeIfPresent(logicalAvailability, forKey: .logicalAvailability)
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

extension SavedTrackedProduct {
    func toTrackedProduct() -> TrackedProduct {
        trackedProduct
    }

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
            hmMetadata: hmMetadata,

            events: events,
            latestDiagnostic: latestDiagnostic,
            group: group,
            tags: tags,
            consecutiveUnchangedChecks: consecutiveUnchangedChecks,
            consecutiveFailureChecks: consecutiveFailureChecks,
            isPriority: isPriority,
            note: note,
            isMacOSNotificationEnabled: isMacOSNotificationEnabled,
            isEmailNotificationEnabled: isEmailNotificationEnabled,
            notificationProfile: notificationProfile,
            autoOpenOnRestock: autoOpenOnRestock,
            variantSnapshots: variantSnapshots,
            trackingRule: trackingRule,
            alertCondition: alertCondition,
            verificationPreference: verificationPreference,
            burstPreference: burstPreference,
            burstExpiresAt: burstExpiresAt,
            pendingVerificationCount: pendingVerificationCount,
            logicalAvailability: logicalAvailability
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
        isEnabled: Bool,
        burstExpiresAt: Date? = nil,
        burstIntervalMinutes: Int = 2
    ) -> Int {
        // Progressive backoff for repeated check failures ALWAYS takes precedence (failure backoff üstün)
        if consecutiveFailureChecks >= 5 {
            return min(maxAdaptiveIntervalMinutes, max(baseMinutes * 3, 15))
        } else if consecutiveFailureChecks >= 3 {
            return min(maxAdaptiveIntervalMinutes, baseMinutes * 2)
        }

        // Restock Burst Mode: high frequency (1-2 min) for temporary duration following restock
        if let burstExpiresAt, burstExpiresAt > Date() {
            return min(baseMinutes, max(1, burstIntervalMinutes))
        }

        guard isEnabled else { return baseMinutes }

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
        isEnabled: Bool,
        burstExpiresAt: Date? = nil
    ) -> String? {
        if consecutiveFailureChecks >= 3 {
            return "Arka arkaya \(consecutiveFailureChecks) kontrol başarısız olduğu için istek sıklığı azaltıldı (\(effectiveMinutes) dk)."
        }
        if let burstExpiresAt, burstExpiresAt > Date() {
            let minsRemaining = max(1, Int(burstExpiresAt.timeIntervalSinceNow / 60))
            return "Stok geldiği için burst takip modu devrede (\(effectiveMinutes) dk, \(minsRemaining) dk kaldı)."
        }
        guard isEnabled, effectiveMinutes != baseMinutes else { return nil }
        if status == .outOfStock && consecutiveUnchangedChecks >= 4 {
            return "Ürün \(consecutiveUnchangedChecks) kontroldür stokta olmadığı için kontrol sıklığı akıllı olarak azaltıldı (\(effectiveMinutes) dk)."
        }
        return "Akıllı kontrol aralığı etkin (\(effectiveMinutes) dk)."
    }
}

struct MonitoringSchedule: Codable, Hashable, Sendable {
    var isEnabled: Bool
    var startHour: Int
    var startMinute: Int
    var endHour: Int
    var endMinute: Int
    var allowedWeekdays: Set<Int> // 1 = Sunday, 2 = Monday, ... 7 = Saturday

    init(
        isEnabled: Bool = false,
        startHour: Int = 9,
        startMinute: Int = 0,
        endHour: Int = 23,
        endMinute: Int = 0,
        allowedWeekdays: Set<Int> = Set(1...7)
    ) {
        self.isEnabled = isEnabled
        self.startHour = max(0, min(23, startHour))
        self.startMinute = max(0, min(59, startMinute))
        self.endHour = max(0, min(23, endHour))
        self.endMinute = max(0, min(59, endMinute))
        self.allowedWeekdays = allowedWeekdays.isEmpty ? Set(1...7) : allowedWeekdays
    }

    var isOvernight: Bool {
        let startMinutes = startHour * 60 + startMinute
        let endMinutes = endHour * 60 + endMinute
        return startMinutes > endMinutes
    }

    func isActive(at date: Date = .now, calendar: Calendar = .current) -> Bool {
        guard isEnabled else { return true }

        let weekday = calendar.component(.weekday, from: date)
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let currentMinutes = hour * 60 + minute

        let startMinutes = startHour * 60 + startMinute
        let endMinutes = endHour * 60 + endMinute

        if startMinutes < endMinutes {
            // Same-day window
            guard allowedWeekdays.contains(weekday) else { return false }
            return currentMinutes >= startMinutes && currentMinutes < endMinutes
        } else if startMinutes > endMinutes {
            // Overnight window
            if currentMinutes >= startMinutes {
                return allowedWeekdays.contains(weekday)
            } else if currentMinutes < endMinutes {
                let yesterday = calendar.date(byAdding: .day, value: -1, to: date) ?? date
                let yesterdayWeekday = calendar.component(.weekday, from: yesterday)
                return allowedWeekdays.contains(yesterdayWeekday)
            } else {
                return false
            }
        } else {
            // All-day window
            return allowedWeekdays.contains(weekday)
        }
    }

    func nextStartDate(after date: Date = .now, calendar: Calendar = .current) -> Date? {
        guard isEnabled else { return nil }

        for dayOffset in 0...8 {
            guard let candidateDay = calendar.date(byAdding: .day, value: dayOffset, to: date) else { continue }
            var components = calendar.dateComponents([.year, .month, .day], from: candidateDay)
            components.hour = startHour
            components.minute = startMinute
            components.second = 0
            guard let candidateDate = calendar.date(from: components) else { continue }

            if candidateDate > date {
                let candidateWeekday = calendar.component(.weekday, from: candidateDate)
                if allowedWeekdays.contains(candidateWeekday) {
                    return candidateDate
                }
            }
        }
        return nil
    }

    var formattedTimeRange: String {
        let startStr = String(format: "%02d:%02d", startHour, startMinute)
        let endStr = String(format: "%02d:%02d", endHour, endMinute)
        return "\(startStr) – \(endStr)"
    }
}

// MARK: - Product List Filtering, Sorting & Empty State Helpers

enum ProductListFilter: String, CaseIterable, Identifiable, Sendable {
    case all, inStock, outOfStock, checking, error, paused, priority, burst, recentRestock, noGroup

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "Tümü"
        case .inStock: "Stokta"
        case .outOfStock: "Stokta değil"
        case .checking: "Kontrol ediliyor"
        case .error: "Kontrol sorunu"
        case .paused: "Duraklatıldı"
        case .priority: "Öncelikli"
        case .burst: "Burst modunda"
        case .recentRestock: "Yakın zamanda restock"
        case .noGroup: "Grupsuz"
        }
    }
}

enum ProductListSort: String, CaseIterable, Identifiable, Sendable {
    case defaultOrder, priorityFirst, productName, lastChecked, nextCheck

    var id: Self { self }

    var title: String {
        switch self {
        case .defaultOrder: "Varsayılan sıra"
        case .priorityFirst: "Öncelikliler başta"
        case .productName: "Ürün adı"
        case .lastChecked: "Son kontrol"
        case .nextCheck: "Sonraki kontrol"
        }
    }
}

enum ProductListEmptyStateAction: Equatable, Sendable {
    case addProduct
    case clearSearch
    case clearFilters
}

struct ProductListEmptyState: Equatable, Sendable {
    let title: String
    let systemImage: String
    let description: String
    let actionTitle: String
    let actionType: ProductListEmptyStateAction

    static func resolve(
        totalProductCount: Int,
        searchText: String,
        statusFilter: ProductListFilter,
        providerFilter: StoreProvider? = nil,
        groupFilter: String? = nil,
        tagFilter: String? = nil
    ) -> ProductListEmptyState {
        if totalProductCount == 0 {
            return ProductListEmptyState(
                title: "Takip Edilen Ürün Yok",
                systemImage: "shippingbox",
                description: "Bir ürün ekleyerek stok takibine başlayın.",
                actionTitle: "Ürün Ekle",
                actionType: .addProduct
            )
        }

        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearch.isEmpty {
            return ProductListEmptyState(
                title: "Sonuç Bulunamadı",
                systemImage: "magnifyingglass",
                description: "'\(trimmedSearch)' aramasıyla eşleşen ürün bulunamadı.",
                actionTitle: "Aramayı Temizle",
                actionType: .clearSearch
            )
        }

        if statusFilter != .all {
            let filterName: String
            let iconName: String
            switch statusFilter {
            case .all:
                filterName = "Ürün"
                iconName = "line.3.horizontal.decrease.circle"
            case .inStock:
                filterName = "Stokta Ürün"
                iconName = "checkmark.circle"
            case .outOfStock:
                filterName = "Tükendi Durumunda Ürün"
                iconName = "xmark.circle"
            case .checking:
                filterName = "Kontrol Edilen Ürün"
                iconName = "arrow.triangle.2.circlepath"
            case .error:
                filterName = "Hatalı Ürün"
                iconName = "exclamationmark.triangle"
            case .paused:
                filterName = "Duraklatılmış Ürün"
                iconName = "pause.circle"
            case .priority:
                filterName = "Öncelikli Ürün"
                iconName = "star"
            case .burst:
                filterName = "Burst Modunda Ürün"
                iconName = "bolt"
            case .recentRestock:
                filterName = "Yeni Restock Olan Ürün"
                iconName = "bell.badge"
            case .noGroup:
                filterName = "Grupsuz Ürün"
                iconName = "folder.badge.minus"
            }
            return ProductListEmptyState(
                title: "\(filterName) Yok",
                systemImage: iconName,
                description: "Şu anda bu filtre ölçütüne uygun takip edilen ürün bulunmuyor.",
                actionTitle: "Filtreleri Temizle",
                actionType: .clearFilters
            )
        }

        if let provider = providerFilter {
            return ProductListEmptyState(
                title: "\(provider.displayName) Ürünü Yok",
                systemImage: "storefront",
                description: "Seçili mağazaya ait takip edilen ürün bulunmuyor.",
                actionTitle: "Filtreleri Temizle",
                actionType: .clearFilters
            )
        }

        if let group = groupFilter, !group.isEmpty {
            return ProductListEmptyState(
                title: "'\(group)' Grubunda Ürün Yok",
                systemImage: "folder",
                description: "Bu grupta takip edilen ürün bulunmuyor.",
                actionTitle: "Filtreleri Temizle",
                actionType: .clearFilters
            )
        }

        if let tag = tagFilter, !tag.isEmpty {
            return ProductListEmptyState(
                title: "'#\(tag)' Etiketli Ürün Yok",
                systemImage: "tag",
                description: "Bu etikete sahip takip edilen ürün bulunmuyor.",
                actionTitle: "Filtreleri Temizle",
                actionType: .clearFilters
            )
        }

        return ProductListEmptyState(
            title: "Filtreye Uygun Ürün Yok",
            systemImage: "line.3.horizontal.decrease.circle",
            description: "Mevcut filtre ölçütlerine uygun ürün bulunamadı.",
            actionTitle: "Filtreleri Temizle",
            actionType: .clearFilters
        )
    }
}

// MARK: - Product Scheduling Description Helper

struct ProductSchedulingDescription: Sendable {
    static func describe(
        isGlobalMonitoringPaused: Bool,
        isProductPaused: Bool,
        isChecking: Bool,
        automaticCheckingEnabled: Bool,
        lastChecked: Date?,
        nextCheckDate: Date?,
        now: Date = Date()
    ) -> String {
        if isGlobalMonitoringPaused {
            return "Taramalar duraklatıldı"
        }
        if isProductPaused {
            return "İzleme duraklatıldı"
        }
        if isChecking {
            return "Kontrol ediliyor..."
        }
        guard automaticCheckingEnabled else {
            return "Otomatik kontrol kapalı"
        }
        guard lastChecked != nil, let nextCheckDate else {
            return "Henüz kontrol planlanmadı"
        }
        let seconds = Int(nextCheckDate.timeIntervalSince(now).rounded(.up))
        guard seconds > 0 else {
            return "Kontrol sırada"
        }
        if seconds < 60 {
            return "\(seconds) sn"
        }
        let minutes = seconds / 60
        let remainder = seconds % 60
        return remainder == 0 ? "\(minutes) dk" : "\(minutes) dk \(remainder) sn"
    }
}


