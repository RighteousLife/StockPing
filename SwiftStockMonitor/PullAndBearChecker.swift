import Foundation
import WebKit

enum PullAndBearCheckerError: LocalizedError {
    case invalidURL
    case unsupportedMarket
    case pageLoadTimedOut
    case productUnavailable
    case productCodeMismatch(expected: String, actual: String)
    case colorUnavailable
    case selectedSizeUnavailable
    case ambiguousSizeState(String)
    case javascriptEvaluationTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Geçerli bir Pull&Bear Türkiye ürün URL'si girin."
        case .unsupportedMarket: "Şu anda yalnızca Pull&Bear Türkiye (/tr/) ürünleri destekleniyor."
        case .pageLoadTimedOut: "Pull&Bear ürün sayfası zamanında hazır olmadı."
        case .productUnavailable: "Pull&Bear ürün bilgisi sayfadan okunamadı."
        case .productCodeMismatch(let expected, let actual): "Pull&Bear ürün kimliği eşleşmedi. Beklenen: \(expected), bulunan: \(actual)."
        case .colorUnavailable: "Pull&Bear sayfasındaki seçili renk doğrulanamadı."
        case .selectedSizeUnavailable: "Takip edilen Pull&Bear bedeni sayfada bulunamadı."
        case .ambiguousSizeState(let size): "Pull&Bear \(size) bedeninin sayfa durumu net değil."
        case .javascriptEvaluationTimedOut: "Pull&Bear sayfası kontrol sırasında zamanında yanıt vermedi."
        }
    }
}

struct PullAndBearStructuredProduct: Decodable, Sendable {
    let productID: String
    let productName: String
    let reference: String?
    let displayReference: String?
    let colors: [PullAndBearStructuredColor]
}

struct PullAndBearStructuredColor: Decodable, Sendable {
    let id: String
    let name: String
    let isBuyable: Bool?
    let sizes: [PullAndBearStructuredSize]
}

struct PullAndBearStructuredSize: Decodable, Sendable {
    let id: String
    let name: String
    let sku: String
    let partnumber: String?
    let isBuyable: Bool?
    let visibilityValue: String?
    let backSoon: String?
    let price: String?
}

@MainActor
enum PullAndBearChecker {
    static let provider: StoreProvider = .pullAndBear
    private static let navigationTimeout: TimeInterval = 30
    private static let pollIntervalNanoseconds: UInt64 = 300_000_000
    static var shouldSimulateStructuredAPIFailureForTesting: Bool = false

    private struct PageSnapshot {
        let readyState: String
        let pageProductID: String?
        let productCode: String?
        let productName: String
        let colorName: String?
        let colorReference: String?
        let colorParameter: String?
        let sizes: [[String: Any]]
    }

    static func canHandle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "pullandbear.com" || host.hasSuffix(".pullandbear.com"),
              let market = url.path.split(separator: "/").first,
              market.lowercased() == "tr",
              productCode(in: url) != nil else { return false }
        return true
    }

    static func normalizedProductURL(from url: URL) -> URL? {
        guard canHandle(url), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.fragment = nil
        // Keep cS and every other retailer query parameter intact; they can select the product color.
        return components.url
    }

    nonisolated static func mapStructuredStock(
        visibilityValue: String?,
        backSoon: String?,
        isBuyable: Bool?
    ) -> Bool? {
        if isBuyable == false {
            return false
        }
        if backSoon == "1" || backSoon == "true" {
            return false
        }
        guard let vis = visibilityValue?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() else {
            return nil
        }
        switch vis {
        case "SHOW", "RUNNING_OUT":
            return true
        case "SOLD_OUT":
            return false
        default:
            return nil
        }
    }

    private static func referenceMatches(expectedCode: String, structuredReference: String?) -> Bool {
        guard let structuredReference, !structuredReference.isEmpty else { return true }
        return structuredReference.contains(expectedCode)
    }

    private static func fetchStructuredProduct(in webView: WKWebView, timeout: TimeInterval = 6.0) async -> PullAndBearStructuredProduct? {
        if shouldSimulateStructuredAPIFailureForTesting {
            return nil
        }
        let script = #"""
        const norm = v => (v || '').trim();
        const resources = performance.getEntriesByType('resource').map(r => r.name);
        let detailEndpoint = resources.find(u => u.includes('/product/') && u.includes('/detail'));
        if (!detailEndpoint) {
            const storeId = (typeof inditex !== 'undefined' && inditex.iStoreId) ? inditex.iStoreId : 25009521;
            const catalogId = (typeof inditex !== 'undefined' && inditex.iCatalogId) ? inditex.iCatalogId : 20309459;
            const langId = (typeof inditex !== 'undefined' && inditex.iLangId) ? inditex.iLangId : -43;
            const prodId = (typeof inditex !== 'undefined' && inditex.iProductId) ? inditex.iProductId : null;
            if (prodId) {
                detailEndpoint = `https://www.pullandbear.com/itxrest/2/catalog/store/${storeId}/${catalogId}/category/0/product/${prodId}/detail?languageId=${langId}&appId=1`;
            }
        }
        if (!detailEndpoint) {
            return JSON.stringify({ error: "no_endpoint" });
        }
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 6000);
        try {
            const resp = await fetch(detailEndpoint, { cache: 'no-store', signal: controller.signal });
            clearTimeout(timer);
            if (!resp.ok) {
                return JSON.stringify({ error: "http_" + resp.status });
            }
            const data = await resp.json();
            const summary = (data.bundleProductSummaries && data.bundleProductSummaries[0]) || data;
            const detail = summary.detail || {};
            const colors = (detail.colors || []).map(c => ({
                id: String(c.id != null ? c.id : ''),
                name: norm(c.name),
                isBuyable: Boolean(c.isBuyable),
                sizes: (c.sizes || []).map(s => ({
                    id: String(s.id != null ? s.id : ''),
                    name: norm(s.name),
                    sku: String(s.sku != null ? s.sku : ''),
                    partnumber: s.partnumber ? String(s.partnumber) : null,
                    isBuyable: Boolean(s.isBuyable),
                    visibilityValue: s.visibilityValue ? String(s.visibilityValue) : null,
                    backSoon: s.backSoon != null ? String(s.backSoon) : null,
                    price: s.price != null ? String(s.price) : null
                }))
            }));
            return JSON.stringify({
                productID: String(data.id || summary.id || ''),
                productName: norm(summary.name),
                reference: detail.reference ? String(detail.reference) : null,
                displayReference: detail.displayReference ? String(detail.displayReference) : null,
                colors: colors
            });
        } catch (err) {
            clearTimeout(timer);
            return JSON.stringify({ error: err.name === 'AbortError' ? 'timeout' : err.message });
        }
        """#

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let result = try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page) as? String,
               let data = result.data(using: .utf8),
               !result.contains("\"error\":\"no_endpoint\""),
               !result.contains("\"error\":") {
                if let structured = try? JSONDecoder().decode(PullAndBearStructuredProduct.self, from: data) {
                    return structured
                }
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
        return nil
    }

    private static func parseStructuredOutcome(
        structured: PullAndBearStructuredProduct,
        metadata: PullAndBearVariantMetadata
    ) -> StoreCheckOutcome? {
        let matchedColor = structured.colors.first(where: { color in
            if let param = metadata.colorParameter, !param.isEmpty, color.id == param { return true }
            if let colId = metadata.colorID, !colId.isEmpty, color.id == colId { return true }
            if let ref = metadata.colorReference, !ref.isEmpty, color.id == ref { return true }
            return color.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(metadata.colorName.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        }) ?? (structured.colors.count == 1 ? structured.colors.first : nil)

        guard let matchedColor else { return nil }

        let matchedSize = matchedColor.sizes.first(where: { size in
            if let expectedSKU = metadata.sku, !expectedSKU.isEmpty, size.sku == expectedSKU {
                return true
            }
            return size.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(metadata.sizeName.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        })

        guard let size = matchedSize else { return nil }
        guard let isAvailable = mapStructuredStock(
            visibilityValue: size.visibilityValue,
            backSoon: size.backSoon,
            isBuyable: size.isBuyable
        ) else {
            return nil
        }

        let now = Date()
        var snapshots: [VariantStockSnapshot] = []
        for color in structured.colors {
            for sz in color.sizes {
                let avail = mapStructuredStock(
                    visibilityValue: sz.visibilityValue,
                    backSoon: sz.backSoon,
                    isBuyable: sz.isBuyable
                )
                let variantID = !sz.sku.isEmpty ? sz.sku : "pullandbear:\(metadata.productCode):\(color.id):\(sz.name)"
                let title = structured.colors.count > 1 ? "\(color.name) / \(sz.name)" : sz.name
                let options = [
                    VariantOption(name: "Renk", value: color.name),
                    VariantOption(name: "Beden", value: sz.name)
                ]
                snapshots.append(VariantStockSnapshot(
                    id: variantID,
                    title: title,
                    options: options,
                    state: VariantAvailabilityState(availability: avail),
                    lastChecked: now
                ))
            }
        }

        let diagnosticDetail = "itxrest (sku: \(size.sku), visibility: \(size.visibilityValue ?? "nil"), backSoon: \(size.backSoon ?? "nil"), buyable: \(size.isBuyable.map(String.init) ?? "nil"))"
        return StoreCheckOutcome(isAvailable: isAvailable, variants: snapshots, diagnosticDetail: diagnosticDetail)
    }

    static func analyze(in webView: WKWebView, productURL: URL, activePageURL: URL?) async throws -> StoreProductAnalysis {
        guard canHandle(productURL), let code = productCode(in: productURL) else { throw PullAndBearCheckerError.invalidURL }

        // Primary: Try structured itxrest API
        if let structured = await fetchStructuredProduct(in: webView),
           referenceMatches(expectedCode: code, structuredReference: structured.reference) {
            let colorParameter = URLComponents(url: productURL, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name.caseInsensitiveCompare("cS") == .orderedSame })?.value

            let selectedColors: [PullAndBearStructuredColor]
            if let colorParameter, let matched = structured.colors.first(where: { $0.id == colorParameter }) {
                selectedColors = [matched]
            } else {
                selectedColors = structured.colors
            }

            var candidates: [StoreVariantCandidate] = []
            for color in selectedColors {
                for size in color.sizes {
                    let avail = mapStructuredStock(
                        visibilityValue: size.visibilityValue,
                        backSoon: size.backSoon,
                        isBuyable: size.isBuyable
                    )
                    let sku = !size.sku.isEmpty ? size.sku : nil
                    let variantID = sku ?? "pullandbear:\(code):\(color.id):\(size.name)"
                    let metadata = PullAndBearVariantMetadata(
                        productCode: code,
                        pageProductID: structured.productID,
                        colorParameter: color.id,
                        colorReference: color.id,
                        colorName: color.name,
                        sizeName: size.name,
                        sku: sku,
                        colorID: color.id,
                        partnumber: size.partnumber
                    )
                    let variant = SelectedVariant(
                        id: variantID,
                        title: selectedColors.count > 1 ? "\(color.name) / \(size.name)" : "\(color.name) / \(size.name)",
                        options: [
                            VariantOption(name: "Renk", value: color.name),
                            VariantOption(name: "Beden", value: size.name)
                        ],
                        availability: avail
                    )
                    candidates.append(StoreVariantCandidate(
                        variant: variant,
                        pullAndBearMetadata: metadata,
                        pullAndBearInitialAvailability: avail
                    ))
                }
            }
            if !candidates.isEmpty {
                let name = !structured.productName.isEmpty ? structured.productName : "Pull&Bear Ürün"
                return StoreProductAnalysis(provider: .pullAndBear, productName: name, variants: candidates)
            }
        }

        // Fallback: DOM / Shadow DOM parser
        let snapshot = try await waitForProduct(in: webView, expectedCode: code, sourceURL: productURL)
        if let pageCode = snapshot.productCode, pageCode != code {
            throw PullAndBearCheckerError.productCodeMismatch(expected: code, actual: pageCode)
        }
        guard let colorName = snapshot.colorName, !colorName.isEmpty else {
            throw PullAndBearCheckerError.colorUnavailable
        }

        let colorIdentity = snapshot.colorParameter ?? snapshot.colorReference ?? colorName
        let colorOptions = [VariantOption(name: "Renk", value: colorName)]
        let candidates = try snapshot.sizes.map { item -> StoreVariantCandidate in
            guard let name = item["name"] as? String, !name.isEmpty else {
                throw PullAndBearCheckerError.productUnavailable
            }
            let available = try availability(from: item, sizeName: name)
            let metadata = PullAndBearVariantMetadata(
                productCode: code,
                pageProductID: snapshot.pageProductID,
                colorParameter: snapshot.colorParameter,
                colorReference: snapshot.colorReference,
                colorName: colorName,
                sizeName: name
            )
            let variant = SelectedVariant(
                id: "pullandbear:\(code):\(colorIdentity):\(name)",
                title: "\(colorName) / \(name)",
                options: colorOptions + [VariantOption(name: "Beden", value: name)],
                availability: available
            )
            return StoreVariantCandidate(
                variant: variant,
                pullAndBearMetadata: metadata,
                pullAndBearInitialAvailability: available
            )
        }
        guard !candidates.isEmpty else { throw PullAndBearCheckerError.productUnavailable }
        return StoreProductAnalysis(provider: .pullAndBear, productName: snapshot.productName, variants: candidates)
    }

    static func checkWithVariants(in webView: WKWebView, product: TrackedProduct, activePageURL: URL?) async throws -> StoreCheckOutcome {
        guard let metadata = product.pullAndBearMetadata,
              canHandle(product.productURL),
              productCode(in: product.productURL) == metadata.productCode,
              let requestURL = normalizedProductURL(from: product.productURL) else {
            throw PullAndBearCheckerError.invalidURL
        }

        let previousTimeOrigin = try? await readTimeOrigin(in: webView)
        webView.load(URLRequest(url: requestURL, cachePolicy: .useProtocolCachePolicy, timeoutInterval: navigationTimeout))

        // Primary: in-session structured itxrest API
        if let structured = await fetchStructuredProduct(in: webView),
           referenceMatches(expectedCode: metadata.productCode, structuredReference: structured.reference) {
            if let outcome = parseStructuredOutcome(structured: structured, metadata: metadata) {
                return outcome
            }
        }

        // Fallback: DOM / Shadow DOM parser
        let snapshot = try await waitForProduct(
            in: webView,
            expectedCode: metadata.productCode,
            sourceURL: requestURL,
            previousTimeOrigin: previousTimeOrigin,
            requiresNewDocument: previousTimeOrigin != nil
        )
        if let pageCode = snapshot.productCode, pageCode != metadata.productCode {
            throw PullAndBearCheckerError.productCodeMismatch(expected: metadata.productCode, actual: pageCode)
        }
        guard let pageColorName = snapshot.colorName,
              pageColorName.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(metadata.colorName.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame else {
            throw PullAndBearCheckerError.colorUnavailable
        }
        if let expectedColor = metadata.colorParameter, snapshot.colorParameter != expectedColor {
            throw PullAndBearCheckerError.colorUnavailable
        }
        if let expectedReference = metadata.colorReference,
           let actualReference = snapshot.colorReference,
           actualReference != expectedReference && !actualReference.hasSuffix(expectedReference) && !expectedReference.hasSuffix(actualReference) {
            throw PullAndBearCheckerError.colorUnavailable
        }
        guard let size = snapshot.sizes.first(where: { ($0["name"] as? String)?.caseInsensitiveCompare(metadata.sizeName) == .orderedSame }) else {
            throw PullAndBearCheckerError.selectedSizeUnavailable
        }
        let isAvailable = try availability(from: size, sizeName: metadata.sizeName)

        let now = Date()
        let colorName = snapshot.colorName ?? metadata.colorName
        let colorIdentity = snapshot.colorParameter ?? snapshot.colorReference ?? colorName
        let colorOptions = [VariantOption(name: "Renk", value: colorName)]

        let snapshots = snapshot.sizes.compactMap { item -> VariantStockSnapshot? in
            guard let name = item["name"] as? String, !name.isEmpty else { return nil }
            let avail = try? availability(from: item, sizeName: name)
            return VariantStockSnapshot(
                id: "pullandbear:\(metadata.productCode):\(colorIdentity):\(name)",
                title: "\(colorName) / \(name)",
                options: colorOptions + [VariantOption(name: "Beden", value: name)],
                state: VariantAvailabilityState(availability: avail),
                lastChecked: now
            )
        }

        let domDiag = "dom_fallback (size: \(metadata.sizeName), available: \(isAvailable))"
        return StoreCheckOutcome(isAvailable: isAvailable, variants: snapshots, diagnosticDetail: domDiag)
    }

    static func check(in webView: WKWebView, product: TrackedProduct, activePageURL: URL?) async throws -> Bool {
        try await checkWithVariants(in: webView, product: product, activePageURL: activePageURL).isAvailable
    }

    nonisolated static func normalizePullAndBearStock(
        isDisabled: Bool,
        ariaDisabled: String?,
        classNames: String,
        visibleText: String,
        isSelectable: Bool
    ) throws -> Bool {
        let text = visibleText.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "tr_TR"))
        let classes = classNames.lowercased()
        let ariaSaysDisabled = ariaDisabled?.lowercased() == "true"
        let unavailablePhrases = [
            "bana haber ver", "gelince haber ver", "stoklara gelince haber ver",
            "benzer urunleri goruntule", "urun bulunamadi", "tukendi", "tukenmistir",
            "stokta yok", "stokta kalmadi", "stoklar tukendi",
            "notify me", "similar products", "out of stock", "unavailable",
            "coming soon", "back soon"
        ]
        if isDisabled || ariaSaysDisabled || classes.contains("is-back-soon") || classes.contains("is-disabled") ||
            classes.contains("unavailable") || classes.contains("out-of-stock") || unavailablePhrases.contains(where: text.contains) {
            return false
        }
        if isSelectable { return true }
        throw PullAndBearCheckerError.ambiguousSizeState(visibleText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func availability(from item: [String: Any], sizeName: String) throws -> Bool {
        guard let isDisabled = item["disabled"] as? Bool,
              let isSelectable = item["selectable"] as? Bool,
              let text = item["contextText"] as? String,
              let classes = item["classNames"] as? String else {
            throw PullAndBearCheckerError.ambiguousSizeState(sizeName)
        }
        do {
            return try normalizePullAndBearStock(
                isDisabled: isDisabled,
                ariaDisabled: item["ariaDisabled"] as? String,
                classNames: classes,
                visibleText: text,
                isSelectable: isSelectable
            )
        } catch {
            throw PullAndBearCheckerError.ambiguousSizeState(sizeName)
        }
    }

    private static func waitForProduct(
        in webView: WKWebView,
        expectedCode: String,
        sourceURL: URL,
        previousTimeOrigin: Double? = nil,
        requiresNewDocument: Bool = false
    ) async throws -> PageSnapshot {
        let deadline = Date().addingTimeInterval(navigationTimeout)
        while Date() < deadline {
            if let snapshot = try? await readPageSnapshot(in: webView, sourceURL: sourceURL), snapshot.readyState == "complete" {
                var isNewDocument = !requiresNewDocument
                if requiresNewDocument {
                    let currentTimeOrigin = await snapshotTimeOrigin(in: webView)
                    isNewDocument = currentTimeOrigin.map { $0 != previousTimeOrigin } == true
                }
                if isNewDocument, snapshot.productCode == expectedCode, !snapshot.sizes.isEmpty {
                    return snapshot
                }
            }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        throw PullAndBearCheckerError.pageLoadTimedOut
    }

    private static func snapshotTimeOrigin(in webView: WKWebView) async -> Double? {
        try? await readTimeOrigin(in: webView)
    }

    private static func readTimeOrigin(in webView: WKWebView) async throws -> Double? {
        let result = try await evaluateJavaScript("JSON.stringify(Number(performance.timeOrigin));", in: webView)
        return Double(result)
    }

    private static func readPageSnapshot(in webView: WKWebView, sourceURL: URL) async throws -> PageSnapshot {
        let result = try await evaluateJavaScript(
            #"""
            (() => {
            const norm = value => (value || '').replace(/\s+/g, ' ').trim();
            const read = root => {
              const found = [];
              const seen = new Set();
              const walk = node => {
                if (!node || seen.has(node)) return;
                seen.add(node);
                if (node.nodeType === Node.ELEMENT_NODE) {
                  const el = node;
                  if (el.tagName === 'SIZE-LIST') {
                    const all = el.shadowRoot ? [el.shadowRoot] : [el];
                    for (const scope of all) {
                      for (const item of scope.querySelectorAll('button,[role="button"],[role="option"],[role="radio"],[data-size]')) {
                        const direct = norm(item.getAttribute('aria-label') || item.getAttribute('data-size') || item.value || item.textContent);
                        const match = direct.match(/^(XXS|XXL|XS|XL|S|M|L|[0-9]{2,3})(?:\b|$)/i);
                        if (!match) continue;
                        let context = item;
                        let contextText = norm(context.innerText || context.textContent);
                        for (let i = 0; i < 3 && context.parentElement && context.parentElement !== scope; i++) {
                          const parentText = norm(context.parentElement.innerText || context.parentElement.textContent);
                          if (parentText.length > 160) break;
                          const sizeTokens = parentText.match(/\b(?:XXS|XXL|XS|XL|S|M|L|[0-9]{2,3})\b/gi) || [];
                          if (new Set(sizeTokens.map(x => x.toUpperCase())).size > 1) break;
                          context = context.parentElement;
                          contextText = parentText;
                          if (/bana haber ver|benzer ürünleri görüntüle/i.test(contextText)) break;
                        }
                        const cls = [item.className, context.className].map(v => typeof v === 'string' ? v : '').join(' ');
                        const identity = match[1].toUpperCase() + '|' + contextText + '|' + cls;
                        if (found.some(x => x.identity === identity)) continue;
                        const selectable = !item.disabled && item.getAttribute('aria-disabled') !== 'true' &&
                          (item.tagName === 'BUTTON' || ['button','option','radio'].includes(item.getAttribute('role')) || item.hasAttribute('data-size'));
                        found.push({ identity, name: match[1].toUpperCase(), disabled: Boolean(item.disabled), ariaDisabled: item.getAttribute('aria-disabled'), classNames: String(cls), contextText, selectable });
                      }
                    }
                  }
                  if (el.shadowRoot) walk(el.shadowRoot);
                  for (const child of el.children || []) walk(child);
                } else {
                  for (const child of node.children || []) walk(child);
                }
              };
              walk(root);
              return found;
            };
            const title = (() => {
              const all = [];
              const walk = root => { for (const el of root.querySelectorAll ? root.querySelectorAll('h1') : []) { const t = norm(el.innerText || el.textContent); if (t) all.push(t); } for (const el of root.querySelectorAll ? root.querySelectorAll('*') : []) if (el.shadowRoot) walk(el.shadowRoot); };
              walk(document);
              return all[0] || document.title.replace(/\s*\|\s*Pull&Bear.*$/i, '').trim();
            })();
            const refText = (() => {
              const parts = [];
              const walk = root => { for (const el of root.querySelectorAll ? root.querySelectorAll('[aria-label],h1,header,div,span') : []) { const t = norm(el.getAttribute('aria-label') || el.innerText || el.textContent); if (/ref(?:erans)?\.?\s*\d{4,}/i.test(t) && t.length < 180) parts.push(t); } for (const el of root.querySelectorAll ? root.querySelectorAll('*') : []) if (el.shadowRoot) walk(el.shadowRoot); };
              walk(document);
              return parts.sort((a,b) => a.length-b.length)[0] || '';
            })();
            const colorName = (refText.match(/(?:Ref(?:erans)?\.?\s*\d+\s*(?:[·-]|Renk)\s*)(.+)$/i) || [])[1] || (() => {
              const radios = [];
              const walk = root => { for (const el of root.querySelectorAll ? root.querySelectorAll('[role="radio"][aria-checked="true"],[role="radio"][aria-checked="true"] [aria-label]') : []) { const t = norm(el.getAttribute('aria-label') || el.textContent); if (t) radios.push(t); } for (const el of root.querySelectorAll ? root.querySelectorAll('*') : []) if (el.shadowRoot) walk(el.shadowRoot); };
              walk(document); return radios[0] || '';
            })();
            const productID = (() => { try { return typeof inditex !== 'undefined' && inditex.iProductId != null ? String(inditex.iProductId) : null; } catch (_) { return null; } })();
            const productReference = (() => { try { return typeof inditex !== 'undefined' && inditex.iProductReference ? String(inditex.iProductReference) : null; } catch (_) { return null; } })();
            const matchCode = productReference && productReference.match(/^(\d{8})/);
            return JSON.stringify({ readyState: document.readyState, productID, productReference, productCode: matchCode ? matchCode[1] : null, title, colorName: norm(colorName), colorReference: (refText.match(/Ref(?:erans)?\.?\s*(\d+)/i) || [])[1] || null, sizes: read(document) });
            })();
            """#,
            in: webView
        )
        guard let data = result.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let readyState = object["readyState"] as? String,
              let productName = object["title"] as? String,
              let sizes = object["sizes"] as? [[String: Any]] else {
            throw PullAndBearCheckerError.productUnavailable
        }
        var uniqueSizes: [[String: Any]] = []
        var seenSizeNames = Set<String>()
        for record in sizes {
            guard let name = record["name"] as? String else { throw PullAndBearCheckerError.productUnavailable }
            let normalizedName = name.uppercased()
            guard seenSizeNames.insert(normalizedName).inserted else {
                throw PullAndBearCheckerError.ambiguousSizeState(name)
            }
            uniqueSizes.append(record)
        }
        let pageReference = object["productReference"] as? String
        let referenceColor = object["colorReference"] as? String
        let colorParameter = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name.caseInsensitiveCompare("cS") == .orderedSame })?.value
        return PageSnapshot(
            readyState: readyState,
            pageProductID: object["productID"] as? String,
            productCode: (object["productCode"] as? String) ?? pageReference.flatMap { leadingProductCode(in: $0) },
            productName: productName,
            colorName: (object["colorName"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            colorReference: referenceColor,
            colorParameter: colorParameter,
            sizes: uniqueSizes
        )
    }

    private static func leadingProductCode(in reference: String) -> String? {
        guard let range = reference.range(of: #"^\d{8}"#, options: .regularExpression) else { return nil }
        return String(reference[range])
    }

    private static func evaluateJavaScript(_ script: String, in webView: WKWebView) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let gate = PullAndBearJavaScriptEvaluation(continuation: continuation)
            gate.timeoutTask = Task { @MainActor in
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return
                }
                gate.finish(.failure(PullAndBearCheckerError.javascriptEvaluationTimedOut))
            }

            webView.evaluateJavaScript(script) { result, error in
                Task { @MainActor in
                    if let error {
                        gate.finish(.failure(error))
                    } else if let result = result as? String {
                        gate.finish(.success(result))
                    } else {
                        gate.finish(.failure(PullAndBearCheckerError.productUnavailable))
                    }
                }
            }
        }
    }

    private static func productCode(in url: URL) -> String? {
        guard let match = url.path.range(of: #"-l(\d+)(?:\.html)?/?$"#, options: .regularExpression) else { return nil }
        let captured = String(url.path[match])
        guard let digits = captured.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return String(captured[digits])
    }
}

@MainActor
private final class PullAndBearJavaScriptEvaluation {
    private var continuation: CheckedContinuation<String, Error>?
    var timeoutTask: Task<Void, Never>?

    init(continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation.resume(with: result)
    }
}

extension PullAndBearChecker: StoreChecker {}
