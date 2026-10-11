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
}
