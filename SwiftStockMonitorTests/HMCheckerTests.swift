import XCTest
@testable import StockPing

@MainActor
final class HMCheckerTests: XCTestCase {

    // MARK: - 1. URL Tests

    func testValidHMURLs() {
        let url1 = URL(string: "https://www2.hm.com/tr_tr/productpage.1347084009.html")!
        let url2 = URL(string: "https://www.hm.com/tr_tr/productpage.1300648004.html")!
        let urlWithQuery = URL(string: "https://www2.hm.com/tr_tr/productpage.1347084009.html?color=009&size=002#details")!

        XCTAssertTrue(HMChecker.canHandle(url1))
        XCTAssertTrue(HMChecker.canHandle(url2))
        XCTAssertTrue(HMChecker.canHandle(urlWithQuery))
    }

    func testInvalidHMURLs() {
        let nonTR = URL(string: "https://www2.hm.com/en_gb/productpage.1347084009.html")!
        let nonHM = URL(string: "https://example.com/tr_tr/productpage.1347084009.html")!
        let nonProduct = URL(string: "https://www2.hm.com/tr_tr/kadin.html")!

        XCTAssertFalse(HMChecker.canHandle(nonTR))
        XCTAssertFalse(HMChecker.canHandle(nonHM))
        XCTAssertFalse(HMChecker.canHandle(nonProduct))
    }

    func testNormalizedProductURL() {
        let url = URL(string: "https://www2.hm.com/tr_tr/productpage.1347084009.html?color=009#details")!
        let normalized = HMChecker.normalizedProductURL(from: url)
        XCTAssertEqual(normalized?.absoluteString, "https://www2.hm.com/tr_tr/productpage.1347084009.html")
    }

    // MARK: - 2. Routing Tests

    func testRouterDetection() {
        let url = URL(string: "https://www2.hm.com/tr_tr/productpage.1347084009.html")!
        XCTAssertEqual(StoreCheckerRouter.provider(for: url), .hm)
        let normalized = StoreCheckerRouter.normalizedProductURL(from: "https://www2.hm.com/tr_tr/productpage.1347084009.html?ref=123")
        XCTAssertEqual(normalized?.absoluteString, "https://www2.hm.com/tr_tr/productpage.1347084009.html")
    }

    // MARK: - 3. API Response Decoding Tests

    private struct OFGResponseFixture: Decodable {
        let availability: [String]
        let fewPieceLeft: [String]?
    }

    func testOFGJSONDecoding() throws {
        let json = """
        {
            "availability": ["1347084009002", "1347084009003", "1347084009004"],
            "fewPieceLeft": ["1347084009003"]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(OFGResponseFixture.self, from: json)
        XCTAssertEqual(decoded.availability.count, 3)
        XCTAssertEqual(decoded.fewPieceLeft?.count, 1)
        XCTAssertEqual(decoded.fewPieceLeft?.first, "1347084009003")
    }

    func testEmptyOFGJSONDecoding() throws {
        let json = """
        {
            "availability": [],
            "fewPieceLeft": []
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(OFGResponseFixture.self, from: json)
        XCTAssertTrue(decoded.availability.isEmpty)
        XCTAssertTrue(decoded.fewPieceLeft?.isEmpty == true)
    }

    // MARK: - 4. Stock Semantics & Safety

    func testAvailabilitySemantics() {
        let availSet = Set(["1347084009002", "1347084009003"])
        let fewSet = Set(["1347084009003"])

        let inStock = "1347084009002"
        let lowStock = "1347084009003"
        let outOfStock = "1347084009005"

        XCTAssertTrue(availSet.contains(inStock))
        XCTAssertTrue(availSet.contains(lowStock))
        XCTAssertTrue(fewSet.contains(lowStock))
        XCTAssertFalse(availSet.contains(outOfStock))
    }

    func testErrorDescriptions() {
        XCTAssertTrue(HMCheckerError.invalidURL.errorDescription?.contains("Geçersiz H&M") == true)
        XCTAssertTrue(HMCheckerError.notHMProduct.errorDescription?.contains("H&M Türkiye") == true)
        XCTAssertTrue(HMCheckerError.productUnavailable.errorDescription?.contains("ürün verisine ulaşılamadı") == true)
        XCTAssertTrue(HMCheckerError.variantNotFound("123").errorDescription?.contains("123") == true)
    }

    // MARK: - 5. Fallback Simulation Flags

    func testFallbackFlags() {
        XCTAssertFalse(HMChecker.shouldSimulateAPIFailureForTesting)
        XCTAssertFalse(HMChecker.shouldSimulateNextDataFailureForTesting)
        XCTAssertFalse(HMChecker.shouldSimulateJsonLdFailureForTesting)

        HMChecker.shouldSimulateAPIFailureForTesting = true
        XCTAssertTrue(HMChecker.shouldSimulateAPIFailureForTesting)
        HMChecker.shouldSimulateAPIFailureForTesting = false
        XCTAssertFalse(HMChecker.shouldSimulateAPIFailureForTesting)
    }

    // MARK: - 6. Color x Size Isolation

    func testColorSizeIsolation() {
        let bordoXS = VariantStockSnapshot(id: "1347084009002", title: "Bordo · XS", options: [VariantOption(name: "Renk", value: "Bordo"), VariantOption(name: "Beden", value: "XS")], state: .inStock)
        let lacivertXS = VariantStockSnapshot(id: "1347084006002", title: "Lacivert · XS", options: [VariantOption(name: "Renk", value: "Lacivert"), VariantOption(name: "Beden", value: "XS")], state: .outOfStock)

        XCTAssertEqual(bordoXS.state, .inStock)
        XCTAssertEqual(lacivertXS.state, .outOfStock)
        XCTAssertNotEqual(bordoXS.id, lacivertXS.id)
    }

    // MARK: - 7. Metadata Persistence

    func testMetadataPersistence() {
        let meta = HMVariantMetadata(
            articleID: "1347084009",
            variantID: "1347084009002",
            compositeID: "1347084009002",
            colorName: "Bordo",
            sizeName: "XS"
        )
        let product = TrackedProduct(
            id: UUID(),
            productName: "H&M Kazak",
            productURL: URL(string: "https://www2.hm.com/tr_tr/productpage.1347084009.html")!,
            selectedVariant: SelectedVariant(id: "1347084009002", title: "Bordo · XS", options: [], availability: true),
            lastChecked: nil,
            checkIntervalMinutes: 10,
            nextCheckDate: nil,
            isPaused: false,
            lastCheckError: nil,
            lastAvailabilityTransition: nil,
            provider: .hm,
            hmMetadata: meta
        )

        TrackedProductStore.save([product])
        let loaded = TrackedProductStore.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.provider, .hm)
        XCTAssertEqual(loaded.first?.hmMetadata?.articleID, "1347084009")
        XCTAssertEqual(loaded.first?.hmMetadata?.variantID, "1347084009002")
        XCTAssertEqual(loaded.first?.hmMetadata?.colorName, "Bordo")
        XCTAssertEqual(loaded.first?.hmMetadata?.sizeName, "XS")
    }

    // MARK: - 8. Provider Health

    func testProviderHealth() {
        let prod = TrackedProduct(
            id: UUID(),
            productName: "H&M Kazak",
            productURL: URL(string: "https://www2.hm.com/tr_tr/productpage.1347084009.html")!,
            selectedVariant: SelectedVariant(id: "1347084009002", title: "Bordo · XS", options: [], availability: true),
            lastChecked: Date(),
            checkIntervalMinutes: 10,
            nextCheckDate: nil,
            isPaused: false,
            lastCheckError: nil,
            lastAvailabilityTransition: nil,
            provider: .hm
        )

        let healthy = ProviderHealthSummary.calculate(for: .hm, products: [prod], isNetworkAvailable: true)
        XCTAssertEqual(healthy.health, .healthy)

        var errProd = prod
        errProd.lastCheckError = "Ağ hatası"
        let warning = ProviderHealthSummary.calculate(for: .hm, products: [errProd], isNetworkAvailable: true)
        XCTAssertEqual(warning.health, .warning)

        let empty = ProviderHealthSummary.calculate(for: .hm, products: [], isNetworkAvailable: true)
        XCTAssertEqual(empty.health, .unknown)
    }
}
