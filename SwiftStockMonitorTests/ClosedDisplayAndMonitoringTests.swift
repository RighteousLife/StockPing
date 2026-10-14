import XCTest
@testable import StockPing

@MainActor
final class ClosedDisplayAndMonitoringTests: XCTestCase {

    // MARK: - 1. Product Reliability Calculation Tests

    func testProductReliabilityInitialState() {
        let product = TrackedProduct(
            id: UUID(),
            productName: "Test Ceket",
            productURL: URL(string: "https://www.zara.com/tr/tr/test-p12345.html")!,
            selectedVariant: SelectedVariant(id: "123", title: "M", options: [], availability: nil),
            lastChecked: nil,
            checkIntervalMinutes: 5,
            nextCheckDate: nil,
            isPaused: false,
            lastCheckError: nil,
            lastAvailabilityTransition: nil,
            provider: .zara
        )

        let reliability = ProductReliability.calculate(for: product)
        XCTAssertEqual(reliability.level, .unknown)
        XCTAssertEqual(reliability.level.displayName, "Bilinmiyor")
        XCTAssertEqual(reliability.consecutiveFailures, 0)
        XCTAssertTrue(reliability.description.contains("Henüz kontrol yapılmadı"))
    }

    func testProductReliabilityHighState() {
        var product = TrackedProduct(
            id: UUID(),
            productName: "Test Elbise",
            productURL: URL(string: "https://www2.hm.com/tr_tr/productpage.1347084009.html")!,
            selectedVariant: SelectedVariant(id: "1347084009002", title: "S", options: [], availability: true),
            lastChecked: Date(),
            checkIntervalMinutes: 5,
            nextCheckDate: Date().addingTimeInterval(300),
            isPaused: false,
            lastCheckError: nil,
            lastAvailabilityTransition: nil,
            provider: .hm
        )
        product.consecutiveUnchangedChecks = 5
        product.consecutiveFailureChecks = 0

        let reliability = ProductReliability.calculate(for: product)
        XCTAssertEqual(reliability.level, .high)
        XCTAssertEqual(reliability.level.displayName, "Yüksek")
        XCTAssertEqual(reliability.consecutiveFailures, 0)
        XCTAssertTrue(reliability.description.contains("sorunsuz"))
    }

    func testProductReliabilityWarningStateOnFailures() {
        var product = TrackedProduct(
            id: UUID(),
            productName: "Test Pantolon",
            productURL: URL(string: "https://www.bershka.com/tr/test-p123.html")!,
            selectedVariant: SelectedVariant(id: "456", title: "38", options: [], availability: false),
            lastChecked: Date(),
            checkIntervalMinutes: 5,
            nextCheckDate: Date().addingTimeInterval(300),
            isPaused: false,
            lastCheckError: "Ağ bağlantı hatası",
            lastAvailabilityTransition: nil,
            provider: .bershka
        )
        product.consecutiveFailureChecks = 3

        let reliability = ProductReliability.calculate(for: product)
        XCTAssertEqual(reliability.level, .warning)
        XCTAssertEqual(reliability.level.displayName, "Uyarı")
        XCTAssertEqual(reliability.consecutiveFailures, 3)
        XCTAssertTrue(reliability.reason.contains("Ağ bağlantı hatası"))
    }

    func testProductReliabilityWarningOnDiagnosticFailure() {
        var product = TrackedProduct(
            id: UUID(),
            productName: "Test Gömlek",
            productURL: URL(string: "https://www.pullandbear.com/tr/test-p789.html")!,
            selectedVariant: SelectedVariant(id: "789", title: "L", options: [], availability: false),
            lastChecked: Date(),
            checkIntervalMinutes: 5,
            nextCheckDate: Date().addingTimeInterval(300),
            isPaused: false,
            lastCheckError: nil,
            lastAvailabilityTransition: nil,
            provider: .pullAndBear
        )
        product.latestDiagnostic = ProviderDiagnostic(
            providerName: "Pull&Bear Türkiye",
            checkerName: "PullAndBearChecker",
            startedAt: Date().addingTimeInterval(-10),
            completedAt: Date(),
            durationSeconds: 10.0,
            outcome: .timeout,
            stockResult: nil,
            networkStatus: "Bağlı",
            errorCategory: "Timeout",
            userMessage: "Sunucu yanıt vermedi",
            technicalDetail: "Timeout after 10s",
            lastSuccessfulCheckDate: Date().addingTimeInterval(-3600)
        )

        let reliability = ProductReliability.calculate(for: product)
        XCTAssertEqual(reliability.level, .warning)
        XCTAssertTrue(reliability.reason.contains("Sunucu yanıt vermedi"))
    }

    // MARK: - 2. Menu Bar State & Invariants

    func testMenuBarGlobalPauseState() {
        let state = SwiftStockMenuBarState()
        XCTAssertFalse(state.isGlobalMonitoringPaused)

        state.isGlobalMonitoringPaused = true
        XCTAssertTrue(state.isGlobalMonitoringPaused)

        state.nextCheckCountdownText = "Taramalar duraklatıldı"
        XCTAssertEqual(state.nextCheckCountdownText, "Taramalar duraklatıldı")

        state.isGlobalMonitoringPaused = false
        XCTAssertFalse(state.isGlobalMonitoringPaused)
    }

    func testMenuBarActionsAndNavigation() {
        let state = SwiftStockMenuBarState()
        XCTAssertEqual(state.manualCheckRequestID, 0)

        state.requestManualCheck()
        XCTAssertEqual(state.manualCheckRequestID, 1)

        let testID = UUID()
        state.selectProductAndOpen(testID)
        XCTAssertEqual(state.selectedProductToOpen, testID)
    }

    // MARK: - 3. Power and Closed-Display Management

    func testSystemPowerSourceStateDetection() {
        let state = SystemPowerSourceState.current()
        // Running on real Apple Silicon Mac or CI; state should be cleanly populated
        XCTAssertNotNil(state.isConnectedToAC)
        if let battery = state.batteryPercentage {
            XCTAssertGreaterThanOrEqual(battery, 0)
            XCTAssertLessThanOrEqual(battery, 100)
        }
    }

    func testHelperAuthorizationStatusProperties() {
        XCTAssertEqual(HelperAuthorizationStatus.authorized.title, "Yetkili (Hazır)")
        XCTAssertEqual(HelperAuthorizationStatus.notAuthorized.title, "Yetki Gerekli")
        XCTAssertEqual(HelperAuthorizationStatus.unknown.title, "Kontrol Edilmedi")
    }

    func testClosedDisplayManagerDefaults() {
        let manager = ClosedDisplayManager.shared
        XCTAssertFalse(manager.isSleepDisabled)
        // checkAuthorization executes non-destructively
        manager.checkAuthorization()
        XCTAssertNotEqual(manager.authorizationStatus, .unknown)
    }

    func testMonitoringPowerModes() {
        let allModes = MonitoringPowerMode.allCases
        XCTAssertTrue(allModes.contains(.allowDisplaySleepKeepMacAwake))
        XCTAssertTrue(allModes.contains(.normal))
        XCTAssertTrue(allModes.contains(.keepMacAndDisplayAwake))

        for mode in allModes {
            XCTAssertFalse(mode.title.isEmpty)
            XCTAssertFalse(mode.description.isEmpty)
        }
    }

    // MARK: - 4. Dynamic Dock & Activation Policy Lifecycle Tests

    func testDynamicActivationPolicyLifecycle() {
        let windowController = MainWindowController()

        // 1. Initial State: Policy is regular
        windowController.updateActivationPolicy(.regular)
        XCTAssertEqual(windowController.currentActivationPolicy, .regular)

        // 2. Hide window: updates activation policy to accessory
        windowController.hideMainWindow(window: nil)
        XCTAssertEqual(windowController.currentActivationPolicy, .accessory, "Hiding window must switch to accessory policy (hidden from Dock)")

        // 3. Show window: restores activation policy to regular
        windowController.showMainWindow()
        XCTAssertEqual(windowController.currentActivationPolicy, .regular, "Reopening window must restore regular activation policy (visible in Dock)")
    }

    func testAppDelegateReopenHandlerRestoresMainWindow() {
        let appDelegate = SwiftStockAppDelegate()
        MainWindowController.shared.updateActivationPolicy(.accessory)
        XCTAssertEqual(MainWindowController.shared.currentActivationPolicy, .accessory)

        let handled = appDelegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        XCTAssertTrue(handled)
        XCTAssertEqual(MainWindowController.shared.currentActivationPolicy, .regular, "applicationShouldHandleReopen must restore regular activation policy")
    }

    func testCloseToHideWindowDelegateInterceptionAndTermination() {
        let controller = MainWindowController()
        let delegate = CloseToHideWindowDelegate(forwarding: nil, controller: controller)

        // 1. Normal close: intercepts, hides window, switches policy to accessory, returns false
        SwiftStockAppDelegate.isTerminating = false
        controller.updateActivationPolicy(.regular)
        let dummyWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let shouldClose = delegate.windowShouldClose(dummyWindow)
        XCTAssertFalse(shouldClose, "windowShouldClose must return false to preserve background execution")
        XCTAssertEqual(controller.currentActivationPolicy, .accessory, "Closing window must update policy to accessory")

        // 2. Terminating in progress: allows window to close
        SwiftStockAppDelegate.isTerminating = true
        let shouldCloseOnTerminate = delegate.windowShouldClose(dummyWindow)
        XCTAssertTrue(shouldCloseOnTerminate, "windowShouldClose must return true when app is terminating")
        SwiftStockAppDelegate.isTerminating = false
    }

    // MARK: - 5. Smart Tracking Rules Tests

    func testSmartTrackingRuleExactVariant() {
        let variantA = SelectedVariant(id: "A1", title: "Siyah - S", options: [
            VariantOption(name: "Renk", value: "Siyah"),
            VariantOption(name: "Beden", value: "S")
        ], availability: false)

        var product = TrackedProduct(
            id: UUID(),
            productName: "Test Tişört",
            productURL: URL(string: "https://shop.example.com/products/test")!,
            selectedVariant: variantA,
            lastChecked: Date(),
            checkIntervalMinutes: 5,
            nextCheckDate: Date(),
            isPaused: false,
            lastCheckError: nil,
            lastAvailabilityTransition: nil,
            provider: .shopify,
            trackingRule: .exactVariant,
            alertCondition: .anyMatching
        )

        let snapshots = [
            VariantStockSnapshot(id: "A1", title: "Siyah - S", options: variantA.options, state: .outOfStock, lastChecked: Date()),
            VariantStockSnapshot(id: "A2", title: "Siyah - M", options: [VariantOption(name: "Renk", value: "Siyah"), VariantOption(name: "Beden", value: "M")], state: .inStock, lastChecked: Date())
        ]

        let eval = product.evaluateLogicalStock(snapshots: snapshots)
        XCTAssertFalse(eval.isAvailable, "Exact variant A1 is out of stock, so logical evaluation must be false even though A2 is in stock")
        XCTAssertEqual(eval.matchingCount, 0)
    }

    func testSmartTrackingRuleAnySizeInSelectedColor() {
        let variantA = SelectedVariant(id: "A1", title: "Siyah - S", options: [
            VariantOption(name: "Renk", value: "Siyah"),
            VariantOption(name: "Beden", value: "S")
        ], availability: false)

        var product = TrackedProduct(
            id: UUID(),
            productName: "Test Tişört",
            productURL: URL(string: "https://shop.example.com/products/test")!,
            selectedVariant: variantA,
            lastChecked: Date(),
            checkIntervalMinutes: 5,
            nextCheckDate: Date(),
            isPaused: false,
            lastCheckError: nil,
            lastAvailabilityTransition: nil,
            provider: .shopify,
            trackingRule: .anySizeInSelectedColor,
            alertCondition: .anyMatching
        )

        let snapshots = [
            VariantStockSnapshot(id: "A1", title: "Siyah - S", options: variantA.options, state: .outOfStock, lastChecked: Date()),
            VariantStockSnapshot(id: "A2", title: "Siyah - M", options: [VariantOption(name: "Renk", value: "Siyah"), VariantOption(name: "Beden", value: "M")], state: .inStock, lastChecked: Date()),
            VariantStockSnapshot(id: "B1", title: "Beyaz - S", options: [VariantOption(name: "Renk", value: "Beyaz"), VariantOption(name: "Beden", value: "S")], state: .inStock, lastChecked: Date())
        ]

        let eval = product.evaluateLogicalStock(snapshots: snapshots)
        XCTAssertTrue(eval.isAvailable, "Any size in Siyah: A2 (Siyah - M) is in stock, so evaluation must be true")
        XCTAssertEqual(eval.matchingCount, 1)
        XCTAssertEqual(eval.matchingSnapshots.first?.id, "A2")
    }

    func testSmartTrackingRuleSelectedSizeInAnyColor() {
        let variantA = SelectedVariant(id: "A1", title: "Siyah - M", options: [
            VariantOption(name: "Renk", value: "Siyah"),
            VariantOption(name: "Beden", value: "M")
        ], availability: false)

        var product = TrackedProduct(
            id: UUID(),
            productName: "Test Kazak",
            productURL: URL(string: "https://shop.example.com/products/test")!,
            selectedVariant: variantA,
            lastChecked: Date(),
            checkIntervalMinutes: 5,
            nextCheckDate: Date(),
            isPaused: false,
            lastCheckError: nil,
            lastAvailabilityTransition: nil,
            provider: .shopify,
            trackingRule: .selectedSizeInAnyColor,
            alertCondition: .anyMatching
        )

        let snapshots = [
            VariantStockSnapshot(id: "A1", title: "Siyah - M", options: variantA.options, state: .outOfStock, lastChecked: Date()),
            VariantStockSnapshot(id: "B1", title: "Kırmızı - M", options: [VariantOption(name: "Renk", value: "Kırmızı"), VariantOption(name: "Beden", value: "M")], state: .inStock, lastChecked: Date()),
            VariantStockSnapshot(id: "A2", title: "Siyah - L", options: [VariantOption(name: "Renk", value: "Siyah"), VariantOption(name: "Beden", value: "L")], state: .inStock, lastChecked: Date())
        ]

        let eval = product.evaluateLogicalStock(snapshots: snapshots)
        XCTAssertTrue(eval.isAvailable, "Selected size M in any color: Kırmızı - M is in stock, so evaluation must be true")
        XCTAssertEqual(eval.matchingCount, 1)
        XCTAssertEqual(eval.matchingSnapshots.first?.id, "B1")
    }

    func testSmartTrackingRuleAnyVariant() {
        let variantA = SelectedVariant(id: "A1", title: "Siyah - S", options: [], availability: false)

        var product = TrackedProduct(
            id: UUID(),
            productName: "Test Mont",
            productURL: URL(string: "https://shop.example.com/products/test")!,
            selectedVariant: variantA,
            lastChecked: Date(),
            checkIntervalMinutes: 5,
            nextCheckDate: Date(),
            isPaused: false,
            lastCheckError: nil,
            lastAvailabilityTransition: nil,
            provider: .shopify,
            trackingRule: .anyVariant,
            alertCondition: .anyMatching
        )

        let snapshots = [
            VariantStockSnapshot(id: "A1", title: "Siyah - S", options: [], state: .outOfStock, lastChecked: Date()),
            VariantStockSnapshot(id: "C1", title: "Yeşil - XL", options: [], state: .inStock, lastChecked: Date())
        ]

        let eval = product.evaluateLogicalStock(snapshots: snapshots)
        XCTAssertTrue(eval.isAvailable)
        XCTAssertEqual(eval.matchingCount, 1)
    }

    // MARK: - 6. Smart Alert Conditions Tests

    func testSmartAlertConditionMinimumCount() {
        let variantA = SelectedVariant(id: "A1", title: "Siyah - S", options: [
            VariantOption(name: "Renk", value: "Siyah"),
            VariantOption(name: "Beden", value: "S")
        ], availability: false)

        var product = TrackedProduct(
            id: UUID(),
            productName: "Test Tişört",
            productURL: URL(string: "https://shop.example.com/products/test")!,
            selectedVariant: variantA,
            lastChecked: Date(),
            checkIntervalMinutes: 5,
            nextCheckDate: Date(),
            isPaused: false,
            lastCheckError: nil,
            lastAvailabilityTransition: nil,
            provider: .shopify,
            trackingRule: .anySizeInSelectedColor,
            alertCondition: .minimumCount(2)
        )

        // Only 1 variant in stock -> should evaluate to false
        let snapshots1 = [
            VariantStockSnapshot(id: "A1", title: "Siyah - S", options: variantA.options, state: .inStock, lastChecked: Date()),
            VariantStockSnapshot(id: "A2", title: "Siyah - M", options: [VariantOption(name: "Renk", value: "Siyah"), VariantOption(name: "Beden", value: "M")], state: .outOfStock, lastChecked: Date())
        ]
        let eval1 = product.evaluateLogicalStock(snapshots: snapshots1)
        XCTAssertFalse(eval1.isAvailable, "Threshold is 2, but only 1 matching variant is in stock")

        // 2 variants in stock -> should evaluate to true
        let snapshots2 = [
            VariantStockSnapshot(id: "A1", title: "Siyah - S", options: variantA.options, state: .inStock, lastChecked: Date()),
            VariantStockSnapshot(id: "A2", title: "Siyah - M", options: [VariantOption(name: "Renk", value: "Siyah"), VariantOption(name: "Beden", value: "M")], state: .inStock, lastChecked: Date())
        ]
        let eval2 = product.evaluateLogicalStock(snapshots: snapshots2)
        XCTAssertTrue(eval2.isAvailable, "Threshold of 2 satisfied")
        XCTAssertEqual(eval2.matchingCount, 2)
    }

    // MARK: - 7. Restock Burst Mode & Adaptive Policy Tests

    func testRestockBurstModeEffectiveInterval() {
        let now = Date()
        let futureBurst = now.addingTimeInterval(1800) // 30 min in future

        // 1. Burst mode active: should return burstIntervalMinutes (e.g. 2 min)
        let interval = AdaptiveMonitoringPolicy.effectiveIntervalMinutes(
            baseMinutes: 10,
            status: .inStock,
            consecutiveUnchangedChecks: 0,
            consecutiveFailureChecks: 0,
            isEnabled: true,
            burstExpiresAt: futureBurst,
            burstIntervalMinutes: 2
        )
        XCTAssertEqual(interval, 2, "Burst mode should reduce check interval to 2 minutes")

        // 2. Failure backoff precedence: consecutiveFailureChecks >= 3 must override burst mode
        let failInterval = AdaptiveMonitoringPolicy.effectiveIntervalMinutes(
            baseMinutes: 10,
            status: .error,
            consecutiveUnchangedChecks: 0,
            consecutiveFailureChecks: 3,
            isEnabled: true,
            burstExpiresAt: futureBurst,
            burstIntervalMinutes: 2
        )
        XCTAssertEqual(failInterval, 20, "Failure backoff must take precedence over burst mode")

        // 3. Expired burst mode: restores normal interval
        let pastBurst = now.addingTimeInterval(-60)
        let normalInterval = AdaptiveMonitoringPolicy.effectiveIntervalMinutes(
            baseMinutes: 10,
            status: .inStock,
            consecutiveUnchangedChecks: 0,
            consecutiveFailureChecks: 0,
            isEnabled: true,
            burstExpiresAt: pastBurst,
            burstIntervalMinutes: 2
        )
        XCTAssertEqual(normalInterval, 10, "Expired burst mode should restore base interval")
    }

    // MARK: - 8. Provider Health 0 Products Test

    func testProviderHealthSummaryZeroProducts() {
        let emptyProducts: [TrackedProduct] = []
        let summaries = ProviderHealthSummary.allSummaries(for: emptyProducts, isNetworkAvailable: true)

        for summary in summaries {
            XCTAssertEqual(summary.productCount, 0)
            XCTAssertEqual(summary.health, .notTracked)
            XCTAssertEqual(summary.health.title, "Takip edilmiyor")
        }
    }

    // MARK: - 9. Backward Compatibility & Persistence Tests

    func testSavedTrackedProductBackwardCompatibility() throws {
        // JSON representing a legacy TrackedProduct without smart tracking and burst fields
        let legacyJSON = """
        {
            "id": "E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
            "productName": "Eski Format Ürün",
            "productURL": "https://www.zara.com/tr/tr/test-p12345.html",
            "selectedVariant": {
                "id": "999",
                "title": "M",
                "options": [],
                "availability": false
            },
            "checkIntervalMinutes": 5,
            "isPaused": false,
            "provider": "zara",
            "events": []
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let saved = try decoder.decode(SavedTrackedProduct.self, from: legacyJSON)
        let product = saved.toTrackedProduct()

        XCTAssertEqual(product.productName, "Eski Format Ürün")
        XCTAssertEqual(product.trackingRule, .exactVariant, "Legacy save must default to exactVariant")
        XCTAssertEqual(product.alertCondition, .anyMatching, "Legacy save must default to anyMatching")
        XCTAssertNil(product.verificationPreference)
        XCTAssertNil(product.burstPreference)
        XCTAssertFalse(product.isBurstActive)
    }

    func testExportProductBackupRoundTrip() throws {
        var product = TrackedProduct(
            id: UUID(),
            productName: "Gelişmiş Takip Ürünü",
            productURL: URL(string: "https://www.bershka.com/tr/test.html")!,
            selectedVariant: SelectedVariant(id: "123", title: "M", options: [], availability: true),
            lastChecked: Date(),
            checkIntervalMinutes: 10,
            nextCheckDate: Date().addingTimeInterval(600),
            isPaused: false,
            lastCheckError: nil,
            lastAvailabilityTransition: nil,
            provider: .bershka,
            trackingRule: .anySizeInSelectedColor,
            alertCondition: .minimumCount(3)
        )
        product.verificationPreference = .twoConfirmations
        product.burstPreference = true

        let exportItem = StockPingExportProduct(from: product)
        let encoder = JSONEncoder()
        let data = try encoder.encode(exportItem)

        let decoder = JSONDecoder()
        let importedItem = try decoder.decode(StockPingExportProduct.self, from: data)
        let restoredProduct = importedItem.trackedProduct

        XCTAssertEqual(restoredProduct.trackingRule, .anySizeInSelectedColor)
        XCTAssertEqual(restoredProduct.alertCondition, .minimumCount(3))
        XCTAssertEqual(restoredProduct.verificationPreference, .twoConfirmations)
        XCTAssertEqual(restoredProduct.burstPreference, true)
    }

    // MARK: - 10. Product List Empty State Resolution Tests

    func testEmptyStateWhenNoProductsExist() {
        let state = ProductListEmptyState.resolve(
            totalProductCount: 0,
            searchText: "",
            statusFilter: .all
        )
        XCTAssertEqual(state.title, "Takip Edilen Ürün Yok")
        XCTAssertEqual(state.systemImage, "shippingbox")
        XCTAssertEqual(state.actionType, .addProduct)
        XCTAssertEqual(state.actionTitle, "Ürün Ekle")
    }

    func testEmptyStateWhenSearchYieldsNoResults() {
        let state = ProductListEmptyState.resolve(
            totalProductCount: 10,
            searchText: "Kırmızı Triko",
            statusFilter: .all
        )
        XCTAssertEqual(state.title, "Sonuç Bulunamadı")
        XCTAssertEqual(state.systemImage, "magnifyingglass")
        XCTAssertEqual(state.actionType, .clearSearch)
        XCTAssertTrue(state.description.contains("Kırmızı Triko"))
    }

    func testEmptyStateWhenStatusFilterHasNoMatches() {
        let errorState = ProductListEmptyState.resolve(
            totalProductCount: 5,
            searchText: "",
            statusFilter: .error
        )
        XCTAssertEqual(errorState.title, "Hatalı Ürün Yok")
        XCTAssertEqual(errorState.systemImage, "exclamationmark.triangle")
        XCTAssertEqual(errorState.actionType, .clearFilters)

        let inStockState = ProductListEmptyState.resolve(
            totalProductCount: 5,
            searchText: "",
            statusFilter: .inStock
        )
        XCTAssertEqual(inStockState.title, "Stokta Ürün Yok")
        XCTAssertEqual(inStockState.systemImage, "checkmark.circle")
        XCTAssertEqual(inStockState.actionType, .clearFilters)

        let outOfStockState = ProductListEmptyState.resolve(
            totalProductCount: 5,
            searchText: "",
            statusFilter: .outOfStock
        )
        XCTAssertEqual(outOfStockState.title, "Tükendi Durumunda Ürün Yok")
        XCTAssertEqual(outOfStockState.actionType, .clearFilters)
    }

    func testEmptyStateWhenProviderGroupOrTagFilterHasNoMatches() {
        let providerState = ProductListEmptyState.resolve(
            totalProductCount: 5,
            searchText: "",
            statusFilter: .all,
            providerFilter: .zara
        )
        XCTAssertEqual(providerState.title, "Zara Ürünü Yok")
        XCTAssertEqual(providerState.actionType, .clearFilters)

        let groupState = ProductListEmptyState.resolve(
            totalProductCount: 5,
            searchText: "",
            statusFilter: .all,
            groupFilter: "Favoriler"
        )
        XCTAssertEqual(groupState.title, "'Favoriler' Grubunda Ürün Yok")
        XCTAssertEqual(groupState.actionType, .clearFilters)

        let tagState = ProductListEmptyState.resolve(
            totalProductCount: 5,
            searchText: "",
            statusFilter: .all,
            tagFilter: "İndirim"
        )
        XCTAssertEqual(tagState.title, "'#İndirim' Etiketli Ürün Yok")
        XCTAssertEqual(tagState.actionType, .clearFilters)
    }

    // MARK: - 11. Product Scheduling Description Tests

    func testSchedulingDescriptionGlobalPaused() {
        let description = ProductSchedulingDescription.describe(
            isGlobalMonitoringPaused: true,
            isProductPaused: false,
            isChecking: false,
            automaticCheckingEnabled: true,
            lastChecked: Date(),
            nextCheckDate: Date().addingTimeInterval(120)
        )
        XCTAssertEqual(description, "Taramalar duraklatıldı")
    }

    func testSchedulingDescriptionProductPaused() {
        let description = ProductSchedulingDescription.describe(
            isGlobalMonitoringPaused: false,
            isProductPaused: true,
            isChecking: false,
            automaticCheckingEnabled: true,
            lastChecked: Date(),
            nextCheckDate: Date().addingTimeInterval(120)
        )
        XCTAssertEqual(description, "İzleme duraklatıldı")
    }

    func testSchedulingDescriptionCurrentlyChecking() {
        let description = ProductSchedulingDescription.describe(
            isGlobalMonitoringPaused: false,
            isProductPaused: false,
            isChecking: true,
            automaticCheckingEnabled: true,
            lastChecked: Date(),
            nextCheckDate: Date().addingTimeInterval(120)
        )
        XCTAssertEqual(description, "Kontrol ediliyor...")
    }

    func testSchedulingDescriptionAutomaticCheckingDisabled() {
        let description = ProductSchedulingDescription.describe(
            isGlobalMonitoringPaused: false,
            isProductPaused: false,
            isChecking: false,
            automaticCheckingEnabled: false,
            lastChecked: Date(),
            nextCheckDate: Date().addingTimeInterval(120)
        )
        XCTAssertEqual(description, "Otomatik kontrol kapalı")
    }

    func testSchedulingDescriptionDueNow() {
        let now = Date()
        let description = ProductSchedulingDescription.describe(
            isGlobalMonitoringPaused: false,
            isProductPaused: false,
            isChecking: false,
            automaticCheckingEnabled: true,
            lastChecked: now.addingTimeInterval(-300),
            nextCheckDate: now.addingTimeInterval(-5),
            now: now
        )
        XCTAssertEqual(description, "Kontrol sırada")
    }

    func testSchedulingDescriptionCountingDown() {
        let now = Date()
        let inSeconds = ProductSchedulingDescription.describe(
            isGlobalMonitoringPaused: false,
            isProductPaused: false,
            isChecking: false,
            automaticCheckingEnabled: true,
            lastChecked: now.addingTimeInterval(-60),
            nextCheckDate: now.addingTimeInterval(45),
            now: now
        )
        XCTAssertEqual(inSeconds, "45 sn")

        let inMinutesExact = ProductSchedulingDescription.describe(
            isGlobalMonitoringPaused: false,
            isProductPaused: false,
            isChecking: false,
            automaticCheckingEnabled: true,
            lastChecked: now.addingTimeInterval(-60),
            nextCheckDate: now.addingTimeInterval(180),
            now: now
        )
        XCTAssertEqual(inMinutesExact, "3 dk")

        let inMinutesAndSeconds = ProductSchedulingDescription.describe(
            isGlobalMonitoringPaused: false,
            isProductPaused: false,
            isChecking: false,
            automaticCheckingEnabled: true,
            lastChecked: now.addingTimeInterval(-60),
            nextCheckDate: now.addingTimeInterval(150),
            now: now
        )
        XCTAssertEqual(inMinutesAndSeconds, "2 dk 30 sn")
    }
}

