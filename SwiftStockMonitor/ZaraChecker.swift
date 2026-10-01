import CoreFoundation
import Foundation
import WebKit

enum ZaraCheckerError: LocalizedError {
    case invalidURL
    case unsupportedMarket
    case pageDataUnavailable
    case malformedPageData
    case noColors
    case noSizes
    case missingVariantSKU
    case availabilityRequestFailed(String)
    case invalidAvailabilityJSON
    case selectedSizeNotReturned
    case unknownAvailability(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Geçerli bir Zara Türkiye ürün URL'si girin."
        case .unsupportedMarket: "Şu anda yalnızca Zara Türkiye (/tr/tr/) destekleniyor."
        case .pageDataUnavailable: "Zara ürün verisi sayfadan alınamadı."
        case .malformedPageData: "Zara ürün verisi beklenen biçimde değil."
        case .noColors: "Ürün verisinde renk bulunamadı."
        case .noSizes: "Ürün verisinde beden bulunamadı."
        case .missingVariantSKU: "Seçilen bedenin Zara stok kimliği bulunamadı."
        case .availabilityRequestFailed(let detail): "Zara stok bilgisine erişilemedi. \(detail)"
        case .invalidAvailabilityJSON: "Zara stok yanıtı okunamadı."
        case .selectedSizeNotReturned: "Seçilen bedenin stok kaydı Zara yanıtında bulunamadı."
        case .unknownAvailability(let value): "Zara bilinmeyen bir stok durumu döndürdü: \(value)"
        }
    }
}

@MainActor
enum ZaraChecker {
    static let provider: StoreProvider = .zara
    private static let turkeyStoreID = 11766

    static func canHandle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              (host == "zara.com" || host == "www.zara.com"),
              let path = marketPath(in: url.path), path.market == "tr/tr" else { return false }
        return productCode(in: path.remainingPath) != nil
    }

    static func normalizedProductURL(from url: URL) -> URL? {
        guard canHandle(url), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    static func analyze(in webView: WKWebView, productURL: URL) async throws -> StoreProductAnalysis {
        guard canHandle(productURL), let market = marketPath(in: productURL.path) else { throw ZaraCheckerError.invalidURL }
        guard market.market == "tr/tr" else { throw ZaraCheckerError.unsupportedMarket }

        let pageState = try await readPageState(in: webView)
        guard let product = pageState.payload["product"] as? [String: Any],
              let detail = product["detail"] as? [String: Any] else { throw ZaraCheckerError.malformedPageData }
        guard let colors = detail["colors"] as? [[String: Any]], !colors.isEmpty else { throw ZaraCheckerError.noColors }

        let groupID = productCode(in: market.remainingPath) ?? stringValue(detail["reference"])?.split(separator: "-").first.map(String.init) ?? ""
        let parsedStoreID = integerValue(pageState.appConfig["storeId"] ?? pageState.appConfig["storeID"]) ?? turkeyStoreID
        let storeID = parsedStoreID > 0 ? parsedStoreID : turkeyStoreID
        let productName = (detail["name"] as? String)
            ?? (product["name"] as? String)
            ?? (detail["seo"] as? [String: Any])?["name"] as? String
            ?? (pageState.payload["name"] as? String)
        guard let productName, !productName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ZaraCheckerError.malformedPageData
        }

        var candidates: [StoreVariantCandidate] = []
        for color in colors {
            guard let colorID = stringValue(color["id"]),
                  let colorProductID = stringValue(color["productId"]),
                  let colorName = color["name"] as? String,
                  let sizes = color["sizes"] as? [[String: Any]], !sizes.isEmpty else { continue }

            for size in sizes {
                guard let name = size["name"] as? String,
                      let sku = stringValue(size["sku"]), !sku.isEmpty else { continue }
                let title = "\(colorName) / \(name)"
                let options = [VariantOption(name: "Renk", value: colorName), VariantOption(name: "Beden", value: name)]
                let metadata = ZaraVariantMetadata(
                    productGroupID: groupID,
                    marketPath: market.market,
                    storeID: storeID,
                    colorID: colorID,
                    colorProductID: colorProductID,
                    colorName: colorName,
                    sizeID: stringValue(size["id"]),
                    equivalentSizeID: stringValue(size["equivalentSizeId"]),
                    availabilitySKU: sku,
                    reference: stringValue(size["reference"])
                )
                // A color-qualified identity permits the same size label on different colors.
                let variant = SelectedVariant(id: "\(colorProductID):\(sku)", title: title, options: options, availability: nil)
                candidates.append(StoreVariantCandidate(variant: variant, zaraMetadata: metadata))
            }
        }
        guard !candidates.isEmpty else { throw ZaraCheckerError.noSizes }
        return StoreProductAnalysis(provider: .zara, productName: productName, variants: candidates)
    }

    static func checkWithVariants(in webView: WKWebView, product: TrackedProduct) async throws -> StoreCheckOutcome {
        guard let metadata = product.zaraMetadata,
              !metadata.availabilitySKU.isEmpty,
              !metadata.colorProductID.isEmpty else { throw ZaraCheckerError.missingVariantSKU }

        let storeID = metadata.storeID > 0 ? metadata.storeID : turkeyStoreID
        let url = URL(string: "https://www.zara.com/api/storefront/1/stores/\(storeID)/products/id/\(metadata.colorProductID)/availability")!
        let result = try await webView.callAsyncJavaScript(
            """
            const controller = new AbortController();
            const timeout = setTimeout(() => controller.abort(), 15000);
            try {
              const response = await fetch(endpoint, {
                method: 'GET', cache: 'no-store', credentials: 'same-origin',
                headers: { 'Accept': 'application/json' },
                signal: controller.signal
              });
              return {
                status: response.status,
                url: response.url,
                contentType: response.headers.get('content-type'),
                body: await response.text()
              };
            } catch (error) {
              if (controller.signal.aborted) {
                return { status: 408, timedOut: true };
              }
              throw error;
            } finally {
              clearTimeout(timeout);
            }
            """,
            arguments: ["endpoint": url.absoluteString],
            in: nil,
            contentWorld: .page
        )
        guard let response = result as? [String: Any] else { throw ZaraCheckerError.invalidAvailabilityJSON }
        if response["timedOut"] as? Bool == true {
            throw ZaraCheckerError.availabilityRequestFailed("Zaman aşımı (15s).")
        }
        guard let status = integerValue(response["status"]),
              let body = response["body"] as? String else { throw ZaraCheckerError.invalidAvailabilityJSON }
        guard (200..<300).contains(status) else {
            throw ZaraCheckerError.availabilityRequestFailed("HTTP \(status).")
        }
        guard let data = body.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sizes = root["sizes"] as? [[String: Any]] else { throw ZaraCheckerError.invalidAvailabilityJSON }
        guard let selected = sizes.first(where: { stringValue($0["sku"]) == metadata.availabilitySKU }),
              let availability = selected["availability"] as? String else { throw ZaraCheckerError.selectedSizeNotReturned }

        let isAvailable: Bool
        switch availability.lowercased() {
        case "in_stock", "low_on_stock": isAvailable = true
        case "out_of_stock", "back_soon", "coming_soon": isAvailable = false
        default: throw ZaraCheckerError.unknownAvailability(availability)
        }

        var availabilityBySKU: [String: Bool] = [:]
        for s in sizes {
            if let sku = stringValue(s["sku"]), let raw = s["availability"] as? String {
                switch raw.lowercased() {
                case "in_stock", "low_on_stock": availabilityBySKU[sku] = true
                case "out_of_stock", "back_soon", "coming_soon": availabilityBySKU[sku] = false
                default: break
                }
            }
        }

        let now = Date()
        var updated = product.variantSnapshots ?? []
        if updated.isEmpty {
            updated = [VariantStockSnapshot(from: product.selectedVariant, lastChecked: now)]
        }

        for i in updated.indices {
            let snap = updated[i]
            let components = snap.id.split(separator: ":")
            let sku = components.count > 1 ? String(components[1]) : snap.id
            if let avail = availabilityBySKU[sku] {
                updated[i].state = VariantAvailabilityState(availability: avail)
                updated[i].lastChecked = now
            } else if snap.id == product.selectedVariant.id {
                updated[i].state = VariantAvailabilityState(availability: isAvailable)
                updated[i].lastChecked = now
            }
        }

        return StoreCheckOutcome(isAvailable: isAvailable, variants: updated)
    }

    static func check(in webView: WKWebView, product: TrackedProduct) async throws -> Bool {
        try await checkWithVariants(in: webView, product: product).isAvailable
    }

    private struct PageState {
        let payload: [String: Any]
        let appConfig: [String: Any]
    }

    private static func readPageState(in webView: WKWebView) async throws -> PageState {
        let result = try await webView.callAsyncJavaScript(
            """
            return JSON.stringify({ payload: window.zara?.viewPayload ?? null, appConfig: window.zara?.appConfig ?? {} });
            """,
            in: nil,
            contentWorld: .page
        )
        guard let jsonString = result as? String,
              let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["payload"] as? [String: Any] else { throw ZaraCheckerError.pageDataUnavailable }
        return PageState(payload: payload, appConfig: root["appConfig"] as? [String: Any] ?? [:])
    }

    private static func marketPath(in path: String) -> (market: String, remainingPath: String)? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 3 else { return nil }
        return ("\(parts[0])/\(parts[1])", "/" + parts.dropFirst(2).joined(separator: "/"))
    }

    private static func productCode(in path: String) -> String? {
        guard let range = path.range(of: #"p(\d+)\.html"#, options: .regularExpression) else { return nil }
        let match = String(path[range])
        return match.dropFirst().dropLast(5).isEmpty ? nil : String(match.dropFirst().dropLast(5))
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.stringValue
    }

    private static func integerValue(_ value: Any?) -> Int? {
        guard let string = stringValue(value) else { return nil }
        return Int(string)
    }
}

extension ZaraChecker: StoreChecker {
    static func analyze(in webView: WKWebView, productURL: URL, activePageURL: URL?) async throws -> StoreProductAnalysis {
        try await analyze(in: webView, productURL: productURL)
    }

    static func check(in webView: WKWebView, product: TrackedProduct, activePageURL: URL?) async throws -> Bool {
        try await check(in: webView, product: product)
    }

    static func checkWithVariants(in webView: WKWebView, product: TrackedProduct, activePageURL: URL?) async throws -> StoreCheckOutcome {
        try await checkWithVariants(in: webView, product: product)
    }
}
