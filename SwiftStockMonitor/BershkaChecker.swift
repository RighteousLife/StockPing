import CoreFoundation
import Foundation
import WebKit

struct BershkaAvailabilitySnapshot: Sendable {
    let rawStock: String?
    let isBuyable: Bool?
    let isLowStock: Bool?

    var available: Bool? {
        BershkaChecker.normalizedAvailability(stock: rawStock, isBuyable: isBuyable)
    }

    var displayLabel: String {
        switch available {
        case true: "Stokta · sayfa verisi"
        case false: "Stokta değil · sayfa verisi"
        case nil: "Stok durumu bilinmiyor"
        }
    }
}

enum BershkaCheckerError: LocalizedError {
    case invalidURL
    case unsupportedMarket
    case pageLoadTimedOut
    case productDataUnavailable
    case productIDMismatch(expected: String, actual: String)
    case colorNotFound(String)
    case missingColorProductID
    case noSizes
    case missingSKU(String)
    case ambiguousSKU(String)
    case selectedVariantNotFound
    case stockDataUnavailable(String)
    case unknownStock(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Geçerli bir Bershka Türkiye ürün URL'si girin."
        case .unsupportedMarket:
            "Şu anda yalnızca Bershka Türkiye (/tr/) ürünleri destekleniyor."
        case .pageLoadTimedOut:
            "Bershka ürün sayfası 30 saniye içinde hazır olmadı."
        case .productDataUnavailable:
            "Bershka ürün verisi sayfadan okunamadı."
        case .productIDMismatch(let expected, let actual):
            "Bershka ürün kimliği eşleşmedi. Beklenen: \(expected), bulunan: \(actual)."
        case .colorNotFound(let colorID):
            "Bershka ürün verisinde renk ID \(colorID) bulunamadı."
        case .missingColorProductID:
            "Bershka renk kaydının ürün kimliği bulunamadı."
        case .noSizes:
            "Bershka ürün renginde beden bulunamadı."
        case .missingSKU(let size):
            "Bershka \(size) bedeni için stok kimliği bulunamadı."
        case .ambiguousSKU(let size):
            "Bershka \(size) bedeni için birden fazla stok kimliği bulundu."
        case .selectedVariantNotFound:
            "Takip edilen Bershka bedeninin stok kaydı sayfada bulunamadı."
        case .stockDataUnavailable(let size):
            "Bershka \(size) bedeni için stok durumu okunamadı."
        case .unknownStock(let value):
            "Bershka bilinmeyen bir stok durumu döndürdü: \(value)."
        }
    }
}

@MainActor
enum BershkaChecker {
    private static let navigationTimeout: TimeInterval = 30
    private static let pollIntervalNanoseconds: UInt64 = 250_000_000

    private struct PageSnapshot {
        let url: String
        let readyState: String
        let timeOrigin: Double?
        let currentProduct: [String: Any]?
    }

    private struct SizeType {
        let sku: String
        let partnumber: String?
        let mastersSizeID: String?
    }

    private struct SizeRecord {
        let name: String
        let stock: String?
        let isBuyable: Bool?
        let isLowStock: Bool?
        let types: [SizeType]
    }

    private struct ColorRecord {
        let id: String
        let catentryID: String?
        let name: String
        let reference: String?
        let sizes: [SizeRecord]
    }

    static func canHandle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "bershka.com" || host.hasSuffix(".bershka.com"),
              let market = marketPath(in: url.path), market == "tr",
              productID(in: url) != nil else { return false }
        return true
    }

    static func normalizedProductURL(from url: URL) -> URL? {
        guard canHandle(url), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.fragment = nil
        if let queryItems = components.queryItems {
            let supportedItems = queryItems.filter { ["colorid", "stylismid"].contains($0.name.lowercased()) }
            components.queryItems = supportedItems.isEmpty ? nil : supportedItems
        }
        return components.url
    }

    private static func analyzePage(
        in webView: WKWebView,
        productURL: URL
    ) async throws -> StoreProductAnalysis {
        guard canHandle(productURL), marketPath(in: productURL.path) == "tr",
              let expectedProductID = productID(in: productURL) else { throw BershkaCheckerError.invalidURL }

        let state = try await waitForProductState(
            in: webView,
            expectedProductID: expectedProductID,
            previousTimeOrigin: nil,
            requiresNewDocument: false
        )
        let currentProduct = try validatedCurrentProduct(state.currentProduct, expectedProductID: expectedProductID)
        let colorRecords = try parseColors(from: currentProduct)
        guard !colorRecords.isEmpty else { throw BershkaCheckerError.noSizes }

        let requestedColorID = colorID(in: productURL)
        let selectedColors: [ColorRecord]
        if let requestedColorID {
            guard let color = colorRecords.first(where: { $0.id == requestedColorID }) else {
                throw BershkaCheckerError.colorNotFound(requestedColorID)
            }
            selectedColors = [color]
        } else {
            selectedColors = colorRecords
        }

        let productName = stringValue(currentProduct["name"])
            ?? stringValue(currentProduct["nameEn"])
        guard let productName, !productName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BershkaCheckerError.productDataUnavailable
        }

        var candidates: [StoreVariantCandidate] = []
        for color in selectedColors {
            guard let colorProductID = color.catentryID, !colorProductID.isEmpty else {
                throw BershkaCheckerError.missingColorProductID
            }
            for size in color.sizes {
                guard !size.types.isEmpty else { throw BershkaCheckerError.missingSKU(size.name) }
                let uniqueTypes = Dictionary(grouping: size.types, by: \.sku).compactMap { $0.value.first }
                guard uniqueTypes.count == 1, let type = uniqueTypes.first else {
                    throw BershkaCheckerError.ambiguousSKU(size.name)
                }

                let options = [
                    VariantOption(name: "Renk", value: color.name),
                    VariantOption(name: "Beden", value: size.name)
                ]
                let metadata = BershkaVariantMetadata(
                    productID: expectedProductID,
                    colorID: color.id,
                    colorProductID: colorProductID,
                    colorName: color.name,
                    sizeName: size.name,
                    sku: type.sku,
                    mastersSizeID: type.mastersSizeID,
                    partnumber: type.partnumber
                )
                let variant = SelectedVariant(
                    id: "bershka:\(expectedProductID):\(color.id):\(type.sku)",
                    title: "\(color.name) / \(size.name)",
                    options: options,
                    availability: nil
                )
                let snapshot = BershkaAvailabilitySnapshot(
                    rawStock: size.stock,
                    isBuyable: size.isBuyable,
                    isLowStock: size.isLowStock
                )
                candidates.append(StoreVariantCandidate(
                    variant: variant,
                    zaraMetadata: nil,
                    bershkaMetadata: metadata,
                    bershkaSnapshot: snapshot
                ))
            }
        }
        guard !candidates.isEmpty else { throw BershkaCheckerError.noSizes }
        return StoreProductAnalysis(provider: .bershka, productName: productName, variants: candidates)
    }

    static func check(in webView: WKWebView, product: TrackedProduct) async throws -> Bool {
        let gate = BershkaCheckGate()
        return try await gate.run(timeout: .seconds(Int64(navigationTimeout))) {
            try await checkPage(in: webView, product: product)
        }
    }

    private static func checkPage(in webView: WKWebView, product: TrackedProduct) async throws -> Bool {
        guard let metadata = product.bershkaMetadata,
              canHandle(product.productURL),
              productID(in: product.productURL) == metadata.productID,
              colorID(in: product.productURL).map({ $0 == metadata.colorID }) ?? true else {
            throw BershkaCheckerError.invalidURL
        }

        let previousTimeOrigin = try? await readTimeOrigin(in: webView)
        guard let requestURL = normalizedProductURL(from: product.productURL) else {
            throw BershkaCheckerError.invalidURL
        }
        // Reload a new document for each check. Normal WebKit caching may still apply.
        webView.load(URLRequest(url: requestURL, cachePolicy: .useProtocolCachePolicy, timeoutInterval: navigationTimeout))

        let state = try await waitForProductState(
            in: webView,
            expectedProductID: metadata.productID,
            previousTimeOrigin: previousTimeOrigin,
            requiresNewDocument: previousTimeOrigin != nil
        )
        let currentProduct = try validatedCurrentProduct(state.currentProduct, expectedProductID: metadata.productID)
        let colors = try parseColors(from: currentProduct)
        guard let color = colors.first(where: { $0.id == metadata.colorID }),
              color.catentryID == metadata.colorProductID,
              let size = color.sizes.first(where: { $0.name == metadata.sizeName }) else {
            throw BershkaCheckerError.selectedVariantNotFound
        }
        guard size.types.contains(where: { $0.sku == metadata.sku }) else {
            throw BershkaCheckerError.selectedVariantNotFound
        }
        guard let rawStock = size.stock else { throw BershkaCheckerError.stockDataUnavailable(size.name) }
        guard let available = normalizedAvailability(stock: rawStock, isBuyable: size.isBuyable) else {
            if rawStock == "in_stock" { throw BershkaCheckerError.stockDataUnavailable(size.name) }
            throw BershkaCheckerError.unknownStock(rawStock)
        }
        return available
    }

    nonisolated static func normalizedAvailability(stock: String?, isBuyable: Bool?) -> Bool? {
        guard let stock = stock?.lowercased() else { return nil }
        switch stock {
        case "in_stock":
            return isBuyable
        case "out_of_stock":
            return false
        default:
            return nil
        }
    }

    private static func waitForProductState(
        in webView: WKWebView,
        expectedProductID: String,
        previousTimeOrigin: Double?,
        requiresNewDocument: Bool
    ) async throws -> PageSnapshot {
        let deadline = Date().addingTimeInterval(navigationTimeout)
        var lastReadError: Error?
        var lastProductID: String?

        while Date() < deadline {
            do {
                let page = try await readPageSnapshot(in: webView)
                let isNewDocument = !requiresNewDocument || page.timeOrigin.map { origin in
                    guard let previousTimeOrigin else { return true }
                    return origin != previousTimeOrigin
                } == true
                if page.readyState == "complete", isNewDocument, let currentProduct = page.currentProduct {
                    let ids = [
                        stringValue(currentProduct["bundleId"]),
                        stringValue(currentProduct["parentId"])
                    ].compactMap { $0 }
                    lastProductID = ids.first
                    if ids.contains(expectedProductID) {
                        return page
                    }
                }
            } catch {
                lastReadError = error
            }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        if let lastProductID, lastProductID != expectedProductID {
            throw BershkaCheckerError.productIDMismatch(expected: expectedProductID, actual: lastProductID)
        }
        if let lastReadError {
            throw lastReadError
        }
        throw BershkaCheckerError.pageLoadTimedOut
    }

    private static func readTimeOrigin(in webView: WKWebView) async throws -> Double? {
        let result = try await webView.callAsyncJavaScript(
            "return JSON.stringify({ timeOrigin: Number(performance.timeOrigin) });",
            in: nil,
            contentWorld: .page
        )
        guard let json = result as? String,
              let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return doubleValue(object["timeOrigin"])
    }

    private static func readPageSnapshot(in webView: WKWebView) async throws -> PageSnapshot {
        let result = try await webView.callAsyncJavaScript(
            """
            const nuxt = window.__NUXT__;
            const current = nuxt?.pinia?.productDetail?.currentProduct ?? null;
            const str = value => value == null ? null : String(value);
            const bool = value => typeof value === 'boolean' ? value : null;
            const colors = current && Array.isArray(current.colors) ? current.colors.map(color => ({
              id: str(color.id),
              catentryId: str(color.catentryId),
              name: str(color.name),
              reference: str(color.reference),
              sizes: Array.isArray(color.sizes) ? color.sizes.map(size => ({
                name: str(size.name),
                stock: str(size.stock),
                isBuyable: bool(size.isBuyable),
                isLowStock: bool(size.isLowStock),
                types: Array.isArray(size.types) ? size.types.map(type => ({
                  sku: str(type.sku),
                  partnumber: str(type.partnumber),
                  mastersSizeId: str(type.mastersSizeId)
                })) : []
              })) : []
            })) : null;
            const result = {
              url: location.href,
              readyState: document.readyState,
              timeOrigin: Number(performance.timeOrigin),
              currentProduct: current ? {
                id: str(current.id),
                bundleId: str(current.bundleId),
                parentId: str(current.parentId),
                name: str(current.name),
                nameEn: str(current.nameEn),
                colors
              } : null
            };
            return JSON.stringify(result);
            """,
            in: nil,
            contentWorld: .page
        )
        guard let json = result as? String,
              let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BershkaCheckerError.productDataUnavailable
        }
        return PageSnapshot(
            url: object["url"] as? String ?? "",
            readyState: object["readyState"] as? String ?? "",
            timeOrigin: doubleValue(object["timeOrigin"]),
            currentProduct: object["currentProduct"] as? [String: Any]
        )
    }

    private static func validatedCurrentProduct(
        _ product: [String: Any]?,
        expectedProductID: String
    ) throws -> [String: Any] {
        guard let product else { throw BershkaCheckerError.productDataUnavailable }
        let ids = [stringValue(product["bundleId"]), stringValue(product["parentId"])].compactMap { $0 }
        guard ids.contains(expectedProductID) else {
            throw BershkaCheckerError.productIDMismatch(expected: expectedProductID, actual: ids.first ?? "bulunamadı")
        }
        return product
    }

    private static func parseColors(from currentProduct: [String: Any]) throws -> [ColorRecord] {
        guard let rawColors = currentProduct["colors"] as? [[String: Any]], !rawColors.isEmpty else {
            throw BershkaCheckerError.productDataUnavailable
        }
        return try rawColors.map { color in
            guard let id = stringValue(color["id"]),
                  let name = stringValue(color["name"]),
                  let catentryID = stringValue(color["catentryId"]) else {
                throw BershkaCheckerError.missingColorProductID
            }
            guard let rawSizes = color["sizes"] as? [[String: Any]], !rawSizes.isEmpty else {
                throw BershkaCheckerError.noSizes
            }
            let sizes = try rawSizes.map { size -> SizeRecord in
                guard let name = stringValue(size["name"]) else { throw BershkaCheckerError.noSizes }
                let types = (size["types"] as? [[String: Any]] ?? []).compactMap { type -> SizeType? in
                    guard let sku = stringValue(type["sku"]), !sku.isEmpty else { return nil }
                    return SizeType(
                        sku: sku,
                        partnumber: stringValue(type["partnumber"]),
                        mastersSizeID: stringValue(type["mastersSizeId"])
                    )
                }
                return SizeRecord(
                    name: name,
                    stock: stringValue(size["stock"]),
                    isBuyable: boolValue(size["isBuyable"]),
                    isLowStock: boolValue(size["isLowStock"]),
                    types: types
                )
            }
            return ColorRecord(
                id: id,
                catentryID: catentryID,
                name: name,
                reference: stringValue(color["reference"]),
                sizes: sizes
            )
        }
    }

    private static func productID(in url: URL) -> String? {
        guard let range = url.path.range(of: #"c0p([0-9]+)\.html$"#, options: .regularExpression) else { return nil }
        let code = String(url.path[range])
        return code.dropFirst(3).dropLast(5).isEmpty ? nil : String(code.dropFirst(3).dropLast(5))
    }

    private static func marketPath(in path: String) -> String? {
        path.split(separator: "/").first.map(String.init)
    }

    private static func colorID(in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name.caseInsensitiveCompare("colorId") == .orderedSame })?.value
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.stringValue
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        guard let value, let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        guard let value, let number = value as? NSNumber else { return nil }
        return number.doubleValue
    }
}

extension BershkaChecker: StoreChecker {
    static var provider: StoreProvider { .bershka }

    static func analyze(in webView: WKWebView, productURL: URL, activePageURL: URL?) async throws -> StoreProductAnalysis {
        try await analyzePage(in: webView, productURL: productURL)
    }

    static func check(in webView: WKWebView, product: TrackedProduct, activePageURL: URL?) async throws -> Bool {
        try await check(in: webView, product: product)
    }
}

@MainActor
private final class BershkaCheckGate {
    private struct ResultBox: @unchecked Sendable {
        let value: Bool
    }

    private var continuation: CheckedContinuation<ResultBox, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?

    func run(
        timeout: Duration,
        operation: @escaping @MainActor () async throws -> Bool
    ) async throws -> Bool {
        try Task.checkCancellation()

        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ResultBox, Error>) in
                self.continuation = continuation
                timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    self?.finish(.failure(BershkaCheckerError.pageLoadTimedOut))
                }

                operationTask = Task { [weak self] in
                    do {
                        let value = try await operation()
                        self?.finish(.success(ResultBox(value: value)))
                    } catch {
                        self?.finish(.failure(error))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(.failure(CancellationError()))
            }
        }
        return result.value
    }

    private func finish(_ result: Result<ResultBox, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        operationTask?.cancel()
        operationTask = nil
        continuation.resume(with: result)
    }
}
