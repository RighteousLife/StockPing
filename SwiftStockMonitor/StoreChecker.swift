import Foundation
import WebKit

struct StoreVariantCandidate: Identifiable, Sendable {
    var variant: SelectedVariant
    var zaraMetadata: ZaraVariantMetadata? = nil
    var bershkaMetadata: BershkaVariantMetadata? = nil
    var bershkaSnapshot: BershkaAvailabilitySnapshot? = nil
    var pullAndBearMetadata: PullAndBearVariantMetadata? = nil
    var hmMetadata: HMVariantMetadata? = nil
    var pullAndBearInitialAvailability: Bool? = nil

    var id: String { variant.id }
    var displayTitle: String { variant.displayTitle ?? variant.displayDescription }

    var initialAvailability: Bool? {
        variant.availability ?? pullAndBearInitialAvailability ?? bershkaSnapshot?.available
    }
}

struct DiscoveredOptionDimension: Identifiable, Hashable, Sendable {
    let name: String
    let values: [String]
    var id: String { name }
}

struct StoreProductAnalysis: Sendable {
    var provider: StoreProvider
    var productName: String
    var variants: [StoreVariantCandidate]

    var optionDimensions: [DiscoveredOptionDimension] {
        var dimensionMap: [String: [String]] = [:]
        var dimensionOrder: [String] = []

        for candidate in variants {
            for option in candidate.variant.options {
                let name = option.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let value = option.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !value.isEmpty else { continue }
                if dimensionMap[name] == nil {
                    dimensionMap[name] = []
                    dimensionOrder.append(name)
                }
                if !dimensionMap[name]!.contains(value) {
                    dimensionMap[name]!.append(value)
                }
            }
        }

        return dimensionOrder.map { name in
            DiscoveredOptionDimension(name: name, values: dimensionMap[name] ?? [])
        }
    }
}

struct StoreCheckOutcome: Sendable {
    let isAvailable: Bool
    let variants: [VariantStockSnapshot]
    var diagnosticDetail: String? = nil

    init(isAvailable: Bool, variants: [VariantStockSnapshot], diagnosticDetail: String? = nil) {
        self.isAvailable = isAvailable
        self.variants = variants
        self.diagnosticDetail = diagnosticDetail
    }
}

extension VariantStockSnapshot {
    init(from candidate: StoreVariantCandidate, lastChecked: Date? = nil) {
        self.id = candidate.id
        self.title = candidate.variant.title
        self.options = candidate.variant.options
        self.state = VariantAvailabilityState(availability: candidate.initialAvailability)
        self.lastChecked = lastChecked
    }
}

@MainActor
protocol StoreChecker {
    static var provider: StoreProvider { get }
    static func canHandle(_ url: URL) -> Bool
    static func normalizedProductURL(from url: URL) -> URL?
    static func analyze(in webView: WKWebView, productURL: URL, activePageURL: URL?) async throws -> StoreProductAnalysis
    static func check(in webView: WKWebView, product: TrackedProduct, activePageURL: URL?) async throws -> Bool
    static func checkWithVariants(in webView: WKWebView, product: TrackedProduct, activePageURL: URL?) async throws -> StoreCheckOutcome
}

extension StoreChecker {
    static func checkWithVariants(in webView: WKWebView, product: TrackedProduct, activePageURL: URL?) async throws -> StoreCheckOutcome {
        let available = try await check(in: webView, product: product, activePageURL: activePageURL)
        var snapshots = product.variantSnapshots ?? []
        let now = Date()
        if let idx = snapshots.firstIndex(where: { $0.id == product.selectedVariant.id }) {
            snapshots[idx].state = VariantAvailabilityState(availability: available)
            snapshots[idx].lastChecked = now
        } else {
            snapshots.append(VariantStockSnapshot(
                id: product.selectedVariant.id,
                title: product.selectedVariant.title,
                options: product.selectedVariant.options,
                state: VariantAvailabilityState(availability: available),
                lastChecked: now
            ))
        }
        return StoreCheckOutcome(isAvailable: available, variants: snapshots)
    }
}

@MainActor
enum StoreCheckerRouter {
    static func provider(for url: URL) -> StoreProvider? {
        checker(for: url)?.provider
    }

    static func normalizedProductURL(from input: String) -> URL? {
        guard let components = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil else { return nil }

        guard let url = components.url, let checker = checker(for: url) else { return nil }
        return checker.normalizedProductURL(from: url)
    }

    static func analyze(in webView: WKWebView, productURL: URL, activePageURL: URL?) async throws -> StoreProductAnalysis {
        guard let checker = checker(for: productURL) else { throw StoreCheckerError.unsupportedStore }
        return try await checker.analyze(in: webView, productURL: productURL, activePageURL: activePageURL)
    }

    static func check(in webView: WKWebView, product: TrackedProduct, activePageURL: URL?) async throws -> Bool {
        return try await checker(for: product.provider).check(
            in: webView,
            product: product,
            activePageURL: activePageURL
        )
    }

    static func checkWithVariants(in webView: WKWebView, product: TrackedProduct, activePageURL: URL?) async throws -> StoreCheckOutcome {
        return try await checker(for: product.provider).checkWithVariants(
            in: webView,
            product: product,
            activePageURL: activePageURL
        )
    }

    private static func checker(for url: URL) -> (any StoreChecker.Type)? {
        if HMChecker.canHandle(url) { return HMChecker.self }

        if PullAndBearChecker.canHandle(url) { return PullAndBearChecker.self }
        if BershkaChecker.canHandle(url) { return BershkaChecker.self }
        if ZaraChecker.canHandle(url) { return ZaraChecker.self }
        if ShopifyChecker.canHandle(url) { return ShopifyChecker.self }
        return nil
    }

    private static func checker(for provider: StoreProvider) -> any StoreChecker.Type {
        switch provider {
        case .shopify: ShopifyChecker.self
        case .zara: ZaraChecker.self
        case .bershka: BershkaChecker.self
        case .pullAndBear: PullAndBearChecker.self
        case .hm: HMChecker.self

        }
    }
}

enum StoreCheckerError: LocalizedError {
    case unsupportedStore

    var errorDescription: String? {
        switch self {
        case .unsupportedStore: "Bu mağaza türü henüz desteklenmiyor. Shopify, Zara Türkiye, Bershka Türkiye, Pull&Bear Türkiye veya H&M Türkiye ürün URL'si kullanın."
        }
    }
}

extension ShopifyChecker: StoreChecker {
    static var provider: StoreProvider { .shopify }

    static func normalizedProductURL(from url: URL) -> URL? {
        normalizedProductURL(from: url.absoluteString)
    }

    static func analyze(in webView: WKWebView, productURL: URL, activePageURL: URL?) async throws -> StoreProductAnalysis {
        let product = try await fetchProduct(in: webView, productURL: productURL, activePageURL: activePageURL)
        return StoreProductAnalysis(provider: .shopify, productName: product.title, variants: product.variants.map {
            StoreVariantCandidate(variant: $0.selectedVariant(availability: $0.available), zaraMetadata: nil)
        })
    }

    static func check(in webView: WKWebView, product: TrackedProduct, activePageURL: URL?) async throws -> Bool {
        let remote = try await fetchProduct(in: webView, productURL: product.productURL, activePageURL: activePageURL)
        guard let available = try variant(withID: product.variantID, in: remote).available else {
            throw ShopifyCheckerError.availabilityUnavailable
        }
        return available
    }

    static func checkWithVariants(in webView: WKWebView, product: TrackedProduct, activePageURL: URL?) async throws -> StoreCheckOutcome {
        let remote = try await fetchProduct(in: webView, productURL: product.productURL, activePageURL: activePageURL)
        guard let available = try variant(withID: product.variantID, in: remote).available else {
            throw ShopifyCheckerError.availabilityUnavailable
        }
        let now = Date()
        let snapshots = remote.variants.map { v in
            VariantStockSnapshot(
                id: v.id,
                title: v.title,
                options: v.options,
                state: VariantAvailabilityState(availability: v.available),
                lastChecked: now
            )
        }
        return StoreCheckOutcome(isAvailable: available, variants: snapshots)
    }
}
