import Foundation
import WebKit

enum HMCheckerError: LocalizedError {
    case invalidURL
    case notHMProduct
    case productUnavailable
    case variantNotFound(String)
    case availabilityUnavailable
    case javascriptEvaluationTimedOut
    case ambiguousSizeState(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Geçersiz H&M ürün bağlantısı."
        case .notHMProduct: return "Bu bağlantı bir H&M Türkiye ürününe ait değil."
        case .productUnavailable: return "H&M ürün verisine ulaşılamadı."
        case .variantNotFound(let id): return "H&M varyantı bulunamadı (\(id))."
        case .availabilityUnavailable: return "H&M stok verisi alınamadı."
        case .javascriptEvaluationTimedOut: return "H&M sorgusu zaman aşımına uğradı."
        case .ambiguousSizeState(let size): return "Beden durumu belirsiz: \(size)"
        }
    }
}

private struct HMCheckEvaluationResult: Decodable {
    let source: String
    let productName: String
    let baseProductCode: String?
    let articleCode: String?
    let variants: [HMVariantRaw]
    let error: String?
}

private struct HMVariantRaw: Decodable {
    let sku: String
    let articleCode: String?
    let colorName: String?
    let sizeName: String?
    let inStock: Bool
    let fewPieceLeft: Bool?
}

private struct HMPageSnapshot {
    let source: String
    let articleID: String
    let baseProductCode: String?
    let productName: String
    let variants: [HMVariantRaw]
}

@MainActor
enum HMChecker: StoreChecker {
    static var provider: StoreProvider { .hm }

    // Controlled fallback testing flags (defaults to false in production)
    static var shouldSimulateAPIFailureForTesting: Bool = false
    static var shouldSimulateNextDataFailureForTesting: Bool = false
    static var shouldSimulateJsonLdFailureForTesting: Bool = false

    static func canHandle(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(),
              host == "hm.com" || host.hasSuffix(".hm.com") else {
            return false
        }
        let path = url.path.lowercased()
        guard path.contains("/tr_tr/") else { return false }
        return path.range(of: #"productpage\.\d{7,10}\.html"#, options: .regularExpression) != nil
    }

    static func normalizedProductURL(from url: URL) -> URL? {
        guard canHandle(url), let articleID = articleID(from: url) else { return nil }
        return URL(string: "https://www2.hm.com/tr_tr/productpage.\(articleID).html")
    }

    private static func articleID(from url: URL) -> String? {
        let path = url.path
        guard let match = path.range(of: #"productpage\.(\d{7,10})\.html"#, options: .regularExpression) else {
            return nil
        }
        let matched = String(path[match])
        let digitsOnly = matched
            .replacingOccurrences(of: "productpage.", with: "")
            .replacingOccurrences(of: ".html", with: "")
        return digitsOnly.isEmpty ? nil : digitsOnly
    }

    static func analyze(in webView: WKWebView, productURL: URL, activePageURL: URL?) async throws -> StoreProductAnalysis {
        let snapshot = try await fetchSnapshot(in: webView, url: productURL)
        guard !snapshot.variants.isEmpty else {
            throw HMCheckerError.productUnavailable
        }

        var candidates: [StoreVariantCandidate] = []
        for raw in snapshot.variants {
            var options: [VariantOption] = []
            if let color = raw.colorName?.trimmingCharacters(in: .whitespacesAndNewlines), !color.isEmpty {
                options.append(VariantOption(name: "Renk", value: color))
            }
            if let size = raw.sizeName?.trimmingCharacters(in: .whitespacesAndNewlines), !size.isEmpty && size != "Standart" {
                options.append(VariantOption(name: "Beden", value: size))
            }

            let displayTitle: String
            if !options.isEmpty {
                displayTitle = options.map(\.value).joined(separator: " · ")
            } else {
                displayTitle = raw.sizeName ?? snapshot.productName
            }

            let selectedVariant = SelectedVariant(
                id: raw.sku,
                title: displayTitle,
                options: options,
                availability: raw.inStock
            )

            let metadata = HMVariantMetadata(
                articleID: raw.articleCode ?? snapshot.articleID,
                variantID: raw.sku,
                compositeID: raw.sku,
                colorName: raw.colorName,
                sizeName: raw.sizeName
            )

            candidates.append(StoreVariantCandidate(variant: selectedVariant, hmMetadata: metadata))
        }

        return StoreProductAnalysis(
            provider: .hm,
            productName: snapshot.productName,
            variants: candidates
        )
    }

    static func check(in webView: WKWebView, product: TrackedProduct, activePageURL: URL?) async throws -> Bool {
        let snapshot = try await fetchSnapshot(in: webView, url: product.productURL)
        guard let match = findMatchingVariant(for: product, in: snapshot.variants) else {
            throw HMCheckerError.variantNotFound(product.selectedVariant.id)
        }
        return match.inStock
    }

    static func checkWithVariants(in webView: WKWebView, product: TrackedProduct, activePageURL: URL?) async throws -> StoreCheckOutcome {
        let snapshot = try await fetchSnapshot(in: webView, url: product.productURL)
        guard let targetMatch = findMatchingVariant(for: product, in: snapshot.variants) else {
            throw HMCheckerError.variantNotFound(product.selectedVariant.id)
        }

        let now = Date()
        var currentSnapshots: [VariantStockSnapshot] = []

        for raw in snapshot.variants {
            var options: [VariantOption] = []
            if let color = raw.colorName?.trimmingCharacters(in: .whitespacesAndNewlines), !color.isEmpty {
                options.append(VariantOption(name: "Renk", value: color))
            }
            if let size = raw.sizeName?.trimmingCharacters(in: .whitespacesAndNewlines), !size.isEmpty && size != "Standart" {
                options.append(VariantOption(name: "Beden", value: size))
            }

            let displayTitle: String
            if !options.isEmpty {
                displayTitle = options.map(\.value).joined(separator: " · ")
            } else {
                displayTitle = raw.sizeName ?? snapshot.productName
            }

            currentSnapshots.append(VariantStockSnapshot(
                id: raw.sku,
                title: displayTitle,
                options: options,
                state: raw.inStock ? .inStock : .outOfStock,
                lastChecked: now
            ))
        }

        let inStockCount = currentSnapshots.filter { $0.state == .inStock }.count
        let diagnosticDetail = "H&M → \(snapshot.source) · \(currentSnapshots.count) varyant (\(inStockCount) stokta)"

        return StoreCheckOutcome(
            isAvailable: targetMatch.inStock,
            variants: currentSnapshots,
            diagnosticDetail: diagnosticDetail
        )
    }

    private static func findMatchingVariant(for product: TrackedProduct, in variants: [HMVariantRaw]) -> HMVariantRaw? {
        let targetID = product.selectedVariant.id.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Exact SKU / variantID match
        if let match = variants.first(where: { $0.sku.caseInsensitiveCompare(targetID) == .orderedSame }) {
            return match
        }

        // 2. Metadata variantID match
        if let metaVariantID = product.hmMetadata?.variantID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !metaVariantID.isEmpty,
           let match = variants.first(where: { $0.sku.caseInsensitiveCompare(metaVariantID) == .orderedSame }) {
            return match
        }

        // 3. Match by Color and Size if available
        let targetColor = product.hmMetadata?.colorName?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? product.selectedVariant.options.first(where: { $0.name.caseInsensitiveCompare("Renk") == .orderedSame })?.value
        let targetSize = product.hmMetadata?.sizeName?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? product.selectedVariant.options.first(where: { $0.name.caseInsensitiveCompare("Beden") == .orderedSame })?.value

        if let targetColor, !targetColor.isEmpty, let targetSize, !targetSize.isEmpty {
            if let match = variants.first(where: {
                $0.colorName?.caseInsensitiveCompare(targetColor) == .orderedSame &&
                $0.sizeName?.caseInsensitiveCompare(targetSize) == .orderedSame
            }) {
                return match
            }
        }

        // 4. Match by Size only within same articleID
        if let targetArticle = product.hmMetadata?.articleID,
           let targetSize, !targetSize.isEmpty {
            if let match = variants.first(where: {
                $0.articleCode == targetArticle &&
                $0.sizeName?.caseInsensitiveCompare(targetSize) == .orderedSame
            }) {
                return match
            }
        }

        // 5. If single variant exists in both product and variants list
        if variants.count == 1 {
            return variants[0]
        }

        return nil
    }

    private static func fetchSnapshot(in webView: WKWebView, url: URL) async throws -> HMPageSnapshot {
        guard let articleID = articleID(from: url) else {
            throw HMCheckerError.invalidURL
        }

        let simAPIFail = shouldSimulateAPIFailureForTesting ? "true" : "false"
        let simNextDataFail = shouldSimulateNextDataFailureForTesting ? "true" : "false"
        let simJsonLdFail = shouldSimulateJsonLdFailureForTesting ? "true" : "false"

        let script = #"""
        (async () => {
            const simulateAPIFail = \#(simAPIFail);
            const simulateNextDataFail = \#(simNextDataFail);
            const simulateJsonLdFail = \#(simJsonLdFail);

            function norm(s) { return s ? s.trim().replace(/\s+/g, ' ') : ''; }

            const urlMatch = window.location.pathname.match(/productpage\.(\d{7,10})\.html/);
            const urlArticle = urlMatch ? urlMatch[1] : null;
            let baseProductCode = urlArticle ? urlArticle.slice(0, 7) : null;
            let productName = norm(document.title.replace(/\|\s*H&M.*$/i, ''));
            let currentArticleCode = urlArticle;
            let rawVariations = null;
            let ssrAvail = null;

            const nextEl = document.getElementById('__NEXT_DATA__');
            if (!simulateNextDataFail && nextEl) {
                try {
                    const data = JSON.parse(nextEl.textContent);
                    const ppp = data?.props?.pageProps?.productPageProps;
                    if (ppp) {
                        currentArticleCode = ppp.articleCode || currentArticleCode;
                        ssrAvail = ppp.ssrAvailability;
                        const pad = ppp.aemData?.productArticleDetails;
                        if (pad) {
                            if (pad.productName) productName = pad.productName;
                            if (pad.baseProductCode) {
                                const bp = pad.baseProductCode.split('_')[0];
                                if (bp && /^\d{7}$/.test(bp)) baseProductCode = bp;
                            }
                            if (pad.variations) rawVariations = pad.variations;
                        }
                    }
                } catch(e) {}
            }

            let catalog = [];
            if (rawVariations) {
                for (const artCode of Object.keys(rawVariations)) {
                    const v = rawVariations[artCode];
                    const colorName = v.name || v.colourDescription || '';
                    if (v.sizes && v.sizes.length > 0) {
                        for (const s of v.sizes) {
                            catalog.push({
                                sku: s.sizeCode,
                                articleCode: artCode,
                                colorName: colorName,
                                sizeName: s.name || s.size
                            });
                        }
                    } else {
                        catalog.push({
                            sku: artCode,
                            articleCode: artCode,
                            colorName: colorName,
                            sizeName: 'Standart'
                        });
                    }
                }
            }

            // Tier 1: ofg.hm.com in-session fetch
            let availabilitySet = null;
            let fewPieceSet = new Set();
            let usedSource = null;

            if (!simulateAPIFail && baseProductCode) {
                try {
                    const ctrl = new AbortController();
                    const tid = setTimeout(() => ctrl.abort(), 6000);
                    const resp = await fetch('https://ofg.hm.com/pdh-availability/v1/product/tr/availability/' + baseProductCode, {
                        headers: { 'Accept': 'application/json' },
                        signal: ctrl.signal
                    });
                    clearTimeout(tid);
                    if (resp.ok) {
                        const json = await resp.json();
                        if (json && Array.isArray(json.availability)) {
                            availabilitySet = new Set(json.availability.map(String));
                            if (Array.isArray(json.fewPieceLeft)) {
                                fewPieceSet = new Set(json.fewPieceLeft.map(String));
                            }
                            usedSource = 'ofg.hm.com (Live API)';
                        }
                    }
                } catch(e) {}
            }

            // Tier 2: __NEXT_DATA__ SSR availability
            if (!availabilitySet && ssrAvail && Array.isArray(ssrAvail.availability)) {
                availabilitySet = new Set(ssrAvail.availability.map(String));
                if (Array.isArray(ssrAvail.fewPieceLeft)) {
                    fewPieceSet = new Set(ssrAvail.fewPieceLeft.map(String));
                }
                usedSource = '__NEXT_DATA__ (SSR Availability)';
            }

            // If we have availabilitySet and catalog, resolve stock
            if (availabilitySet && catalog.length > 0) {
                const variants = catalog.map(item => ({
                    sku: item.sku,
                    articleCode: item.articleCode,
                    colorName: item.colorName,
                    sizeName: item.sizeName,
                    inStock: availabilitySet.has(item.sku),
                    fewPieceLeft: fewPieceSet.has(item.sku)
                }));
                return JSON.stringify({
                    source: usedSource,
                    productName,
                    baseProductCode,
                    articleCode: currentArticleCode,
                    variants,
                    error: null
                });
            }

            // Tier 3: JSON-LD fallback
            let jsonLdVariants = [];
            if (!simulateJsonLdFail) {
                try {
                    const scripts = Array.from(document.querySelectorAll('script[type="application/ld+json"]'));
                for (const s of scripts) {
                    const ld = JSON.parse(s.textContent);
                    if (ld && ld['@type'] === 'ProductGroup' && Array.isArray(ld.hasVariant)) {
                        for (const v of ld.hasVariant) {
                            const avail = v.offers && v.offers.availability ? v.offers.availability.includes('InStock') : false;
                            jsonLdVariants.push({
                                sku: v.sku || '',
                                articleCode: v.offers?.url?.match(/productpage\.(\d{10})/)?.[1] || null,
                                colorName: v.color || '',
                                sizeName: v.size || 'Standart',
                                inStock: avail,
                                fewPieceLeft: false
                            });
                        }
                    }
                }
            } catch(e) {}
            }

            if (jsonLdVariants.length > 0) {
                return JSON.stringify({
                    source: 'JSON-LD',
                    productName,
                    baseProductCode,
                    articleCode: currentArticleCode,
                    variants: jsonLdVariants,
                    error: null
                });
            }

            // Tier 4: DOM size selector fallback
            let domVariants = [];
            try {
                const sizeButtons = Array.from(document.querySelectorAll('[data-testid^="sizeButton-"], [data-testid="size-selector"] button, [data-testid="size-selector"] [role="radio"]'));
                for (const btn of sizeButtons) {
                    const label = btn.getAttribute('aria-label') || btn.textContent || '';
                    const sizeMatch = label.match(/^([A-Za-z0-9\/]+)/);
                    const sizeName = sizeMatch ? sizeMatch[1] : norm(btn.textContent);
                    const disabled = btn.disabled || btn.getAttribute('aria-disabled') === 'true';
                    const outOfStock = disabled || /tükendi/i.test(label);
                    if (sizeName) {
                        domVariants.push({
                            sku: (currentArticleCode || 'HM') + '_' + sizeName,
                            articleCode: currentArticleCode,
                            colorName: '',
                            sizeName: sizeName,
                            inStock: !outOfStock,
                            fewPieceLeft: false
                        });
                    }
                }
            } catch(e) {}

            if (domVariants.length > 0) {
                return JSON.stringify({
                    source: 'DOM (Size Selector)',
                    productName,
                    baseProductCode,
                    articleCode: currentArticleCode,
                    variants: domVariants,
                    error: null
                });
            }

            return JSON.stringify({
                source: 'None',
                productName,
                baseProductCode,
                articleCode: currentArticleCode,
                variants: [],
                error: 'all_sources_failed'
            });
        })()
        """#

        let resultString = try await evaluateJavaScript(script, in: webView)
        guard let data = resultString.data(using: .utf8) else {
            throw HMCheckerError.productUnavailable
        }

        let result: HMCheckEvaluationResult
        do {
            result = try JSONDecoder().decode(HMCheckEvaluationResult.self, from: data)
        } catch {
            throw HMCheckerError.productUnavailable
        }

        if let error = result.error, !error.isEmpty {
            throw HMCheckerError.productUnavailable
        }

        guard !result.variants.isEmpty else {
            throw HMCheckerError.productUnavailable
        }

        return HMPageSnapshot(
            source: result.source,
            articleID: result.articleCode ?? articleID,
            baseProductCode: result.baseProductCode,
            productName: result.productName.isEmpty ? "H&M Ürünü" : result.productName,
            variants: result.variants
        )
    }

    private static func evaluateJavaScript(_ script: String, in webView: WKWebView) async throws -> String {
        let evalTask = Task { @MainActor in
            let asyncScript = "return await " + script
            let rawResult = try await webView.callAsyncJavaScript(
                asyncScript,
                arguments: [:],
                in: nil,
                contentWorld: .page
            )
            guard let string = rawResult as? String else {
                throw HMCheckerError.productUnavailable
            }
            return string
        }

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw HMCheckerError.javascriptEvaluationTimedOut
            }
            group.addTask {
                try await evalTask.value
            }

            do {
                guard let result = try await group.next() else {
                    throw HMCheckerError.productUnavailable
                }
                group.cancelAll()
                evalTask.cancel()
                return result
            } catch {
                group.cancelAll()
                evalTask.cancel()
                throw error
            }
        }
    }
}

