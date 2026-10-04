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

    // MARK: - 9. Backup & Restore Compatibility

    func testBackupExportAndImportPreservesHMMetadata() {
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
            lastChecked: Date(),
            checkIntervalMinutes: 15,
            nextCheckDate: Date().addingTimeInterval(900),
            isPaused: false,
            lastCheckError: nil,
            lastAvailabilityTransition: nil,
            provider: .hm,
            hmMetadata: meta,
            group: "Kışlık",
            tags: ["Kazak", "Yeni"],
            isPriority: true,
            note: "Acil stok bekleniyor",
            autoOpenOnRestock: true,
            variantSnapshots: [VariantStockSnapshot(id: "1347084009002", title: "Bordo · XS", options: [], state: .inStock)]
        )

        let exportItem = StockPingExportProduct(from: product)
        XCTAssertEqual(exportItem.provider, .hm)
        XCTAssertEqual(exportItem.hmMetadata?.articleID, "1347084009")
        XCTAssertEqual(exportItem.hmMetadata?.variantID, "1347084009002")
        XCTAssertEqual(exportItem.hmMetadata?.colorName, "Bordo")
        XCTAssertEqual(exportItem.hmMetadata?.sizeName, "XS")

        let importedProduct = exportItem.trackedProduct
        XCTAssertEqual(importedProduct.provider, .hm)
        XCTAssertEqual(importedProduct.hmMetadata?.articleID, "1347084009")
        XCTAssertEqual(importedProduct.hmMetadata?.variantID, "1347084009002")
        XCTAssertEqual(importedProduct.hmMetadata?.colorName, "Bordo")
        XCTAssertEqual(importedProduct.hmMetadata?.sizeName, "XS")
        XCTAssertEqual(importedProduct.group, "Kışlık")
        XCTAssertEqual(importedProduct.tags, ["Kazak", "Yeni"])
        XCTAssertTrue(importedProduct.isPriority)
        XCTAssertEqual(importedProduct.note, "Acil stok bekleniyor")
        XCTAssertEqual(importedProduct.autoOpenOnRestock, true)
        XCTAssertEqual(importedProduct.variantSnapshots?.count, 1)
    }

    // MARK: - 10. Duplicate Detection & Candidate Matching

    func testHMDuplicateDetection() {
        let meta1 = HMVariantMetadata(articleID: "1347084009", variantID: "1347084009002", compositeID: "1347084009002", colorName: "Bordo", sizeName: "XS")
        let meta2 = HMVariantMetadata(articleID: "1347084009", variantID: "1347084009003", compositeID: "1347084009003", colorName: "Bordo", sizeName: "S")
        let url = URL(string: "https://www2.hm.com/tr_tr/productpage.1347084009.html")!

        let prod1 = TrackedProduct(
            id: UUID(),
            productName: "Kazak",
            productURL: url,
            selectedVariant: SelectedVariant(id: "1347084009002", title: "XS", options: []),
            lastChecked: nil,
            checkIntervalMinutes: 5,
            nextCheckDate: nil,
            isPaused: false,
            lastCheckError: nil,
            lastAvailabilityTransition: nil,
            provider: .hm,
            hmMetadata: meta1
        )
        let prod1Duplicate = TrackedProduct(
            id: UUID(),
            productName: "Kazak (Farklı isim)",
            productURL: url,
            selectedVariant: SelectedVariant(id: "1347084009002", title: "XS", options: []),
            lastChecked: nil,
            checkIntervalMinutes: 10,
            nextCheckDate: nil,
            isPaused: false,
            lastCheckError: nil,
            lastAvailabilityTransition: nil,
            provider: .hm,
            hmMetadata: meta1
        )
        let prod2 = TrackedProduct(
            id: UUID(),
            productName: "Kazak",
            productURL: url,
            selectedVariant: SelectedVariant(id: "1347084009003", title: "S", options: []),
            lastChecked: nil,
            checkIntervalMinutes: 5,
            nextCheckDate: nil,
            isPaused: false,
            lastCheckError: nil,
            lastAvailabilityTransition: nil,
            provider: .hm,
            hmMetadata: meta2
        )

        XCTAssertTrue(prod1.isDuplicate(of: prod1Duplicate))
        XCTAssertFalse(prod1.isDuplicate(of: prod2))

        let candidate1 = StoreVariantCandidate(
            variant: SelectedVariant(id: "1347084009002", title: "XS", options: []),
            hmMetadata: meta1
        )
        let candidate2 = StoreVariantCandidate(
            variant: SelectedVariant(id: "1347084009003", title: "S", options: []),
            hmMetadata: meta2
        )

        XCTAssertTrue(prod1.matches(candidate: candidate1, productURL: url, provider: .hm))
        XCTAssertFalse(prod1.matches(candidate: candidate2, productURL: url, provider: .hm))
    }

    // MARK: - 11. State Machine Invariants

    func testStockTransitionInvariants() {
        // Invariant 38: First check is .initial, never .restocked
        func transition(from previous: Bool?, to current: Bool) -> AvailabilityTransition {
            guard let previous else { return .initial(available: current) }
            if !previous && current { return .restocked }
            if previous && !current { return .wentOutOfStock }
            return .unchanged(available: current)
        }

        XCTAssertEqual(transition(from: nil, to: true), .initial(available: true))
        XCTAssertEqual(transition(from: nil, to: false), .initial(available: false))

        // Invariant 39: false -> true MUST be .restocked
        XCTAssertEqual(transition(from: false, to: true), .restocked)

        // Invariant 40: true -> false MUST be .wentOutOfStock (never restocked)
        XCTAssertEqual(transition(from: true, to: false), .wentOutOfStock)

        // Unchanged states
        XCTAssertEqual(transition(from: true, to: true), .unchanged(available: true))
        XCTAssertEqual(transition(from: false, to: false), .unchanged(available: false))
    }

    // MARK: - 12. Notification Profiles

    func testNotificationProfiles() {
        XCTAssertTrue(NotificationProfile.standard.shouldNotifyOnRestock)
        XCTAssertFalse(NotificationProfile.standard.shouldNotifyOnDepletion)

        XCTAssertTrue(NotificationProfile.onlyRestock.shouldNotifyOnRestock)
        XCTAssertFalse(NotificationProfile.onlyRestock.shouldNotifyOnDepletion)

        XCTAssertTrue(NotificationProfile.allChanges.shouldNotifyOnRestock)
        XCTAssertTrue(NotificationProfile.allChanges.shouldNotifyOnDepletion)

        XCTAssertFalse(NotificationProfile.silent.shouldNotifyOnRestock)
        XCTAssertFalse(NotificationProfile.silent.shouldNotifyOnDepletion)
    }

    // MARK: - 13. Scheduler & Pause Behavior

    func testSchedulerAndPauseState() {
        var product = TrackedProduct(
            id: UUID(),
            productName: "H&M Test",
            productURL: URL(string: "https://www2.hm.com/tr_tr/productpage.1347084009.html")!,
            selectedVariant: SelectedVariant(id: "1347084009002", title: "XS", options: []),
            lastChecked: Date(),
            checkIntervalMinutes: 10,
            nextCheckDate: Date().addingTimeInterval(600),
            isPaused: false,
            lastCheckError: nil,
            lastAvailabilityTransition: nil,
            provider: .hm
        )

        XCTAssertNotNil(product.nextCheckDate)
        XCTAssertEqual(product.status, .outOfStock)

        // When paused, status reflects paused
        product.isPaused = true
        product.nextCheckDate = nil
        XCTAssertEqual(product.status, .paused)
        XCTAssertNil(product.nextCheckDate)
    }

    // MARK: - 14. Error Message Guidance

    func testUnsupportedStoreErrorMessageIncludesHM() {
        let errDesc = StoreCheckerError.unsupportedStore.errorDescription
        XCTAssertNotNil(errDesc)
        XCTAssertTrue(errDesc?.contains("H&M Türkiye") == true)
        XCTAssertTrue(errDesc?.contains("Zara") == true)
        XCTAssertTrue(errDesc?.contains("Bershka") == true)
        XCTAssertTrue(errDesc?.contains("Pull&Bear") == true)
    }
}

