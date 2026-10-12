import SwiftUI
import WebKit
import UserNotifications
import AppKit
import ServiceManagement
import Combine
import Network

private enum ProductListFilter: String, CaseIterable, Identifiable {
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

private enum ProductListSort: String, CaseIterable, Identifiable {
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

extension Notification.Name {
    static let exportBackupRequested = Notification.Name("exportBackupRequested")
    static let importBackupRequested = Notification.Name("importBackupRequested")
    static let didDetectRestockEvent = Notification.Name("didDetectRestockEvent")
}

struct InAppRestockEvent: Identifiable, Equatable {
    let id = UUID()
    let productID: UUID
    let productName: String
    let variantTitle: String
    let productURL: URL
    let date = Date()
}

@main
struct SwiftStockMonitorApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: SwiftStockAppDelegate
    @StateObject private var menuBarState = SwiftStockMenuBarState()
    @StateObject private var windowController = MainWindowController.shared

    var body: some Scene {
        Window("StockPing", id: "main") {
            ContentView()
                .environmentObject(menuBarState)
                .environmentObject(windowController)
        }
        .defaultSize(width: 980, height: 640)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .newItem) {
                Divider()
                Button("Yedek Dışa Aktar...") {
                    NotificationCenter.default.post(name: .exportBackupRequested, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button("Yedekten İçe Aktar...") {
                    NotificationCenter.default.post(name: .importBackupRequested, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra("StockPing", systemImage: "bell.badge") {
            SwiftStockMenuBarContent()
                .environmentObject(menuBarState)
                .environmentObject(windowController)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .background(SettingsWindowConfigurator())
        }
        .defaultSize(width: 760, height: 650)
        .windowResizability(.contentMinSize)
    }
}

@MainActor
final class SwiftStockAppDelegate: NSObject, NSApplicationDelegate {
    static var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainWindowController.shared.updateActivationPolicy(.regular)
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            _ = MainWindowController.shared.showMainWindow()
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.isTerminating = true
        SleepPreventionManager.shared.configure(isMonitoringActive: false, mode: .normal)
        ClosedDisplayManager.shared.emergencyRestoreOnTermination()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

extension SwiftStockAppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let productIDString = userInfo["productID"] as? String
        let urlString = userInfo["productURL"] as? String
        completionHandler()

        Task { @MainActor in
            var targetURL: URL?
            if let productIDString, let productID = UUID(uuidString: productIDString) {
                let savedProducts = TrackedProductStore.load()
                if let product = savedProducts.first(where: { $0.id == productID }) {
                    targetURL = product.productURL
                }
            }
            if targetURL == nil, let urlString, let fallbackURL = URL(string: urlString) {
                targetURL = fallbackURL
            }

            guard let url = targetURL,
                  ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
            NSWorkspace.shared.open(url)
        }
    }
}

@MainActor
final class SwiftStockMenuBarState: ObservableObject {
    @Published var productCount = 0
    @Published var inStockCount = 0
    @Published var outOfStockCount = 0
    @Published var unknownStockCount = 0
    @Published var pausedCount = 0
    @Published var priorityCount = 0
    @Published var errorCount = 0
    @Published var isChecking = false
    @Published var isAllPaused = false
    @Published var isGlobalMonitoringPaused = false
    @Published var nextCheckCountdownText: String? = nil
    @Published var lastCheckedText = "Henüz kontrol yapılmadı"
    @Published var recentStockMovements: [MenuBarStockMovement] = []
    @Published var providerHealthText = "Tüm mağazalar normal"
    @Published var scheduleStatusText: String? = nil
    @Published private(set) var manualCheckRequestID = 0
    @Published var selectedProductToOpen: UUID? = nil

    func requestManualCheck() {
        manualCheckRequestID += 1
    }

    func selectProductAndOpen(_ id: UUID) {
        selectedProductToOpen = id
    }
}

@MainActor
final class MainWindowController: ObservableObject {
    static let shared = MainWindowController()
    private(set) weak var mainWindow: NSWindow?
    private var closeDelegateProxy: CloseToHideWindowDelegate?
    @Published private(set) var currentActivationPolicy: NSApplication.ActivationPolicy = .regular

    var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
    }

    func updateActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        currentActivationPolicy = policy
        if !isRunningTests {
            NSApp.setActivationPolicy(policy)
        }
    }

    func attach(to window: NSWindow) {
        if mainWindow === window {
            if let closeDelegateProxy,
               (window.delegate as AnyObject?) !== closeDelegateProxy {
                window.delegate = closeDelegateProxy
            }
            return
        }

        let proxy = CloseToHideWindowDelegate(forwarding: window.delegate, controller: self)
        closeDelegateProxy = proxy
        mainWindow = window
        window.delegate = proxy
    }

    @discardableResult
    func showMainWindow() -> Bool {
        updateActivationPolicy(.regular)
        let targetWindow: NSWindow? = {
            if let mainWindow { return mainWindow }
            return NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) })
        }()

        guard let targetWindow else { return false }
        if targetWindow.isMiniaturized {
            targetWindow.deminiaturize(nil)
        }
        targetWindow.orderFront(nil)
        targetWindow.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        return true
    }

    func hideMainWindow(window: NSWindow? = nil) {
        let target = window ?? mainWindow
        target?.orderOut(nil)
        updateActivationPolicy(.accessory)
    }
}

@MainActor
final class CloseToHideWindowDelegate: NSObject, NSWindowDelegate {
    private weak var downstreamDelegate: (any NSWindowDelegate)?
    private weak var controller: MainWindowController?

    init(forwarding delegate: (any NSWindowDelegate)?, controller: MainWindowController? = nil) {
        self.downstreamDelegate = delegate
        self.controller = controller
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !SwiftStockAppDelegate.isTerminating else { return true }
        if let controller {
            controller.hideMainWindow(window: sender)
        } else {
            MainWindowController.shared.hideMainWindow(window: sender)
        }
        return false
    }

    override func responds(to selector: Selector!) -> Bool {
        if selector == #selector(NSWindowDelegate.windowShouldClose(_:)) {
            return true
        }

        return super.responds(to: selector) || originalDelegateResponds(to: selector)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        guard originalDelegateResponds(to: selector) else {
            return super.forwardingTarget(for: selector)
        }
        return downstreamDelegate
    }

    private func originalDelegateResponds(to selector: Selector) -> Bool {
        (downstreamDelegate as? NSObject)?.responds(to: selector) ?? false
    }
}

@MainActor
private struct SwiftStockMenuBarContent: View {
    @EnvironmentObject private var menuBarState: SwiftStockMenuBarState
    @EnvironmentObject private var windowController: MainWindowController
    @ObservedObject private var networkMonitor = NetworkReachabilityMonitor.shared
    @AppStorage("isGlobalMonitoringPaused") private var isGlobalMonitoringPaused = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // 1. Üst Başlık ve Durum
        Text("StockPing")
            .font(.headline)

        if networkMonitor.status == .unavailable {
            Text("⚠️ Ağ bağlantısı yok")
        } else if networkMonitor.status == .recovering {
            Text("🔄 Ağ kontrol ediliyor...")
        } else if menuBarState.isChecking {
            Text("⏳ Kontroller yapılıyor...")
        } else if isGlobalMonitoringPaused {
            Text("⏸️ Taramalar duraklatıldı")
        } else if menuBarState.isAllPaused {
            Text("⏸️ Tüm takipler duraklatıldı")
        } else {
            Text("● \(menuBarState.productCount) ürün izleniyor")
        }

        Divider()

        // Stok Sayıları ve Detaylar
        Text("Stokta: \(menuBarState.inStockCount)  ·  Stok dışı: \(menuBarState.outOfStockCount)")
        if menuBarState.pausedCount > 0 {
            Text("Duraklatıldı: \(menuBarState.pausedCount)")
        }
        if menuBarState.priorityCount > 0 {
            Text("Öncelikli: \(menuBarState.priorityCount)")
        }
        if menuBarState.errorCount > 0 {
            Text("Hata: \(menuBarState.errorCount)")
        }
        Text("Son kontrol: \(menuBarState.lastCheckedText)")
            .font(.caption)

        if let countdown = menuBarState.nextCheckCountdownText {
            Text("⏰ \(countdown)")
                .font(.caption)
        } else if let schedText = menuBarState.scheduleStatusText {
            Text("⏰ \(schedText)")
                .font(.caption)
        }
        Text("🏪 \(menuBarState.providerHealthText)")
            .font(.caption)

        Divider()

        // 2. Hızlı Eylemler
        Button("Şimdi Tümünü Kontrol Et", systemImage: "arrow.clockwise") {
            menuBarState.requestManualCheck()
        }
        .disabled(!networkMonitor.canProceedWithChecks || menuBarState.isChecking)

        Button(isGlobalMonitoringPaused ? "Taramaları Devam Ettir" : "Taramaları Duraklat",
               systemImage: isGlobalMonitoringPaused ? "play.fill" : "pause.fill") {
            isGlobalMonitoringPaused.toggle()
        }

        Divider()

        // 3. Son Stok Hareketleri
        Text("Son stok hareketleri")
            .font(.subheadline)

        if menuBarState.recentStockMovements.isEmpty {
            Text("Henüz stok hareketi yok")
                .foregroundStyle(.secondary)
        } else {
            ForEach(menuBarState.recentStockMovements) { movement in
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    if !windowController.showMainWindow() {
                        openWindow(id: "main")
                    }
                    menuBarState.selectProductAndOpen(movement.productID)
                } label: {
                    Text("\(movement.productName) — \(movement.eventTitle) • \(movement.relativeTime)")
                }
            }
        }

        Divider()

        // 4. Uygulama ve Ayarlar
        Button("StockPing'i Aç", systemImage: "macwindow") {
            NSApp.activate(ignoringOtherApps: true)
            if !windowController.showMainWindow() {
                openWindow(id: "main")
            }
        }

        Button("Ayarlar…", systemImage: "gearshape") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }

        Divider()

        // 5. Çıkış
        Button("Çıkış", systemImage: "power") {
            NSApplication.shared.terminate(nil)
        }
    }
}

@MainActor
private final class WindowObserverView: NSView {
    var onWindowAvailable: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            onWindowAvailable?(window)
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                self.onWindowAvailable?(window)
            }
        }
    }
}

private struct WindowCloseBehaviorInstaller: NSViewRepresentable {
    let controller: MainWindowController

    func makeNSView(context: Context) -> WindowObserverView {
        let view = WindowObserverView()
        view.onWindowAvailable = { [weak controller] window in
            controller?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ view: WindowObserverView, context: Context) {
        if let window = view.window {
            controller.attach(to: window)
        }
    }
}

@MainActor
final class NetworkReachabilityMonitor: ObservableObject {
    static let shared = NetworkReachabilityMonitor()

    enum Status: Equatable {
        case available
        case unavailable
        case recovering
    }

    @Published private(set) var status: Status = .available
    @Published private(set) var isConnected: Bool = true

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.swiftstock.monitor.network", qos: .utility)
    private var stabilizationTask: Task<Void, Never>?
    private var hasReceivedInitialPath = false
    private var isWaking = false

    private init() {
        self.monitor = NWPathMonitor()
        setupPathMonitor()
        setupSleepWakeObservers()
    }

    deinit {
        monitor.cancel()
        stabilizationTask?.cancel()
    }

    var canProceedWithChecks: Bool {
        status == .available
    }

    private func setupPathMonitor() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.handlePathUpdate(path)
            }
        }
        monitor.start(queue: queue)
    }

    private func handlePathUpdate(_ path: NWPath) {
        let isSatisfied = path.status == .satisfied

        if !hasReceivedInitialPath {
            hasReceivedInitialPath = true
            isConnected = isSatisfied
            status = isSatisfied ? .available : .unavailable
            return
        }

        if isSatisfied {
            if !isConnected || status == .unavailable || isWaking {
                startStabilization(reason: isWaking ? "wake" : "recovery")
            } else if status != .recovering {
                status = .available
                isConnected = true
            }
        } else {
            stabilizationTask?.cancel()
            stabilizationTask = nil
            isWaking = false
            isConnected = false
            status = .unavailable
            print("[NetworkGuard] Ağ bağlantısı kesildi. Stok kontrolleri bekletiliyor.")
        }
    }

    private func setupSleepWakeObservers() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleWillSleep()
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleDidWake()
            }
        }
    }

    private func handleWillSleep() {
        stabilizationTask?.cancel()
        stabilizationTask = nil
        isWaking = true
        status = .recovering
        print("[NetworkGuard] Sistem uykuya geçiyor. Kontroller duraklatıldı.")
    }

    private func handleDidWake() {
        print("[NetworkGuard] Sistem uyandı. Ağ stabilizasyonu bekleniyor...")
        isWaking = true
        startStabilization(reason: "wake")
    }

    private func startStabilization(reason: String) {
        stabilizationTask?.cancel()
        status = .recovering

        stabilizationTask = Task { @MainActor in
            // Stabilization delay: 2.5 seconds
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }

            isWaking = false
            let isSatisfied = monitor.currentPath.status == .satisfied
            if isSatisfied {
                isConnected = true
                status = .available
                print("[NetworkGuard] Ağ bağlantısı doğrulandı ve stabilize oldu (\(reason)).")
            } else {
                isConnected = false
                status = .unavailable
                print("[NetworkGuard] Stabilizasyon sonrası ağ bağlantısı henüz yok (\(reason)).")
            }
        }
    }
}

private struct PowerStateChangeModifier: ViewModifier {
    let closedDisplayMonitoringEnabled: Bool
    let closedDisplayRequireACPower: Bool
    let closedDisplayMinBatteryLevel: Int
    let monitoringPowerMode: MonitoringPowerMode
    let isCheckSequenceRunning: Bool
    let onSync: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: closedDisplayMonitoringEnabled) { _, _ in onSync() }
            .onChange(of: closedDisplayRequireACPower) { _, _ in onSync() }
            .onChange(of: closedDisplayMinBatteryLevel) { _, _ in onSync() }
            .onChange(of: monitoringPowerMode) { _, _ in onSync() }
            .onChange(of: isCheckSequenceRunning) { _, _ in onSync() }
    }
}

struct ContentView: View {
    @EnvironmentObject private var menuBarState: SwiftStockMenuBarState
    @EnvironmentObject private var windowController: MainWindowController
    @AppStorage("automaticCheckingEnabled") private var automaticCheckingEnabled = true
    @AppStorage("checkIntervalMinutes") private var checkIntervalMinutes = 1
    @AppStorage("stockNotificationsEnabled") private var stockNotificationsEnabled = true
    @AppStorage("emailNotificationsEnabled") private var emailNotificationsEnabled = false
    @AppStorage("monitoringPowerMode") private var monitoringPowerMode: MonitoringPowerMode = .allowDisplaySleepKeepMacAwake
    @AppStorage("adaptiveMonitoringEnabled") private var adaptiveMonitoringEnabled = false
    @AppStorage("monitoringScheduleEnabled") private var monitoringScheduleEnabled = false
    @AppStorage("monitoringScheduleStartHour") private var monitoringScheduleStartHour = 9
    @AppStorage("monitoringScheduleStartMinute") private var monitoringScheduleStartMinute = 0
    @AppStorage("monitoringScheduleEndHour") private var monitoringScheduleEndHour = 23
    @AppStorage("monitoringScheduleEndMinute") private var monitoringScheduleEndMinute = 0
    @AppStorage("monitoringScheduleWeekdays") private var monitoringScheduleWeekdays = "1,2,3,4,5,6,7"
    @AppStorage("autoOpenOnRestockEnabled") private var autoOpenOnRestockEnabled = false
    @AppStorage("isGlobalMonitoringPaused") private var isGlobalMonitoringPaused = false
    @AppStorage("closedDisplayMonitoringEnabled") private var closedDisplayMonitoringEnabled = false
    @AppStorage("closedDisplayRequireACPower") private var closedDisplayRequireACPower = true
    @AppStorage("closedDisplayMinBatteryLevel") private var closedDisplayMinBatteryLevel = 20
    @AppStorage("restockVerificationMode") private var globalVerificationMode: RestockVerificationMode = .off
    @AppStorage("restockBurstModeEnabled") private var restockBurstModeEnabled = true
    @AppStorage("restockBurstIntervalMinutes") private var restockBurstIntervalMinutes = 2
    @AppStorage("restockBurstDurationMinutes") private var restockBurstDurationMinutes = 30

    private var currentMonitoringSchedule: MonitoringSchedule {
        let weekdayInts = monitoringScheduleWeekdays
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let allowedSet = weekdayInts.isEmpty ? Set(1...7) : Set(weekdayInts)
        return MonitoringSchedule(
            isEnabled: monitoringScheduleEnabled,
            startHour: monitoringScheduleStartHour,
            startMinute: monitoringScheduleStartMinute,
            endHour: monitoringScheduleEndHour,
            endMinute: monitoringScheduleEndMinute,
            allowedWeekdays: allowedSet
        )
    }
    @State private var trackedProducts: [TrackedProduct]
    @State private var selectedProductID: UUID
    @State private var isSelectionMode = false
    @State private var selectedProductIDs: Set<UUID> = []
    @State private var productSearchText = ""
    @State private var productStatusFilter: ProductListFilter = .all
    @State private var selectedProviderFilter: StoreProvider? = nil
    @State private var selectedGroupFilter: String? = nil
    @State private var selectedTagFilter: String? = nil
    @ObservedObject private var orgStore = ProductOrganizationStore.shared
    @State private var productListSort: ProductListSort = .defaultOrder
    @State private var productIDsPendingDeletion: [UUID] = []
    @State private var isDeleteConfirmationPresented = false
    @State private var isChecking = false
    @State private var checkingProductID: UUID?
    @State private var checkRequestID = 0
    @State private var storeConnectionStatus = "Bağlanıyor..."
    @State private var storeConnectionError: String?
    @State private var activeSheet: ContentSheet?
    @State private var isCheckSequenceRunning = false
    @State private var automaticCheckTimer: Timer?
    @State private var currentTimerGeneration: UUID?
    @State private var pendingCheckContinuation: CheckedContinuation<Void, Never>?
    @State private var checkSequenceTask: Task<Void, Never>?
    @State private var showingDashboard = false
    @State private var showingInspector = false
    @State private var activeRestockBanner: InAppRestockEvent?
    @State private var showingNoteAlert = false
    @State private var noteDraftText = ""
    @State private var isDropTargeted = false
    @FocusState private var isSearchFocused: Bool
    @StateObject private var networkMonitor = NetworkReachabilityMonitor.shared

    init() {
        let products = TrackedProductStore.load()
        _trackedProducts = State(initialValue: products)
        _selectedProductID = State(initialValue: products.first?.id ?? UUID())
        ProductOrganizationStore.shared.syncFromProducts(products)
    }

    private var isAnyFilterActive: Bool {
        productStatusFilter != .all ||
        selectedProviderFilter != nil ||
        selectedGroupFilter != nil ||
        selectedTagFilter != nil ||
        !productSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func clearAllFilters() {
        productStatusFilter = .all
        selectedProviderFilter = nil
        selectedGroupFilter = nil
        selectedTagFilter = nil
        productSearchText = ""
    }

    private func handleIncomingDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.url") {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    DispatchQueue.main.async {
                        if let url, StoreCheckerRouter.canHandle(url) {
                            activeSheet = .addProduct(initialURL: url.absoluteString)
                        }
                    }
                }
                return true
            } else if provider.hasItemConformingToTypeIdentifier("public.utf8-plain-text") || provider.hasItemConformingToTypeIdentifier("public.plain-text") {
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    DispatchQueue.main.async {
                        if let text, let parsed = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), StoreCheckerRouter.canHandle(parsed) {
                            activeSheet = .addProduct(initialURL: parsed.absoluteString)
                        }
                    }
                }
                return true
            }
        }
        return false
    }

    private var isMonitoringActive: Bool {
        !isGlobalMonitoringPaused && ((automaticCheckingEnabled && trackedProducts.contains(where: { !$0.isPaused })) || isCheckSequenceRunning)
    }

    private func syncPowerPrevention() {
        SleepPreventionManager.shared.configure(
            isMonitoringActive: isMonitoringActive,
            mode: monitoringPowerMode,
            closedDisplayEnabled: closedDisplayMonitoringEnabled,
            requireACPower: closedDisplayRequireACPower,
            minBatteryLevel: closedDisplayMinBatteryLevel
        )
    }

    private var activeMonitoredProductsCount: Int {
        trackedProducts.filter { !$0.isPaused }.count
    }

    private var earliestNextCheckDate: Date? {
        let active = trackedProducts.filter { !$0.isPaused }
        if active.contains(where: { $0.nextCheckDate == nil }) {
            return Date.distantPast
        }
        return active.compactMap(\.nextCheckDate).min()
    }

    private var selectedProductIndex: Int? {
        trackedProducts.firstIndex { $0.id == selectedProductID }
    }

    private var visibleTrackedProducts: [TrackedProduct] {
        let filteredProducts = trackedProducts.filter { product in
            let query = productSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let searchTokens = [
                product.productName,
                storeName(for: product),
                product.variantTitle,
                product.group ?? "",
                product.tags.joined(separator: " "),
                product.note ?? ""
            ]
            let matchesSearch = query.isEmpty || searchTokens.contains { $0.localizedCaseInsensitiveContains(query) }
            let status = visibleStatus(for: product)
            let matchesStatus: Bool
            switch productStatusFilter {
            case .all: matchesStatus = true
            case .inStock: matchesStatus = status == .inStock
            case .outOfStock: matchesStatus = status == .outOfStock
            case .checking: matchesStatus = status == .checking
            case .error: matchesStatus = status == .error
            case .paused: matchesStatus = status == .paused
            case .priority: matchesStatus = product.isPriority
            case .burst: matchesStatus = product.isBurstActive
            case .recentRestock:
                let cutoff = Date().addingTimeInterval(-24 * 3600)
                matchesStatus = product.events.contains { $0.type == .stockArrived && $0.date >= cutoff }
            case .noGroup: matchesStatus = (product.group == nil || product.group?.isEmpty == true)
            }

            let matchesProvider: Bool
            if let selectedProvider = selectedProviderFilter {
                matchesProvider = product.provider == selectedProvider
            } else {
                matchesProvider = true
            }

            let matchesGroup: Bool
            if let selectedGroup = selectedGroupFilter {
                matchesGroup = product.group?.caseInsensitiveCompare(selectedGroup) == .orderedSame
            } else {
                matchesGroup = true
            }

            let matchesTag: Bool
            if let selectedTag = selectedTagFilter {
                matchesTag = product.tags.contains { $0.caseInsensitiveCompare(selectedTag) == .orderedSame }
            } else {
                matchesTag = true
            }

            return matchesSearch && matchesStatus && matchesProvider && matchesGroup && matchesTag
        }

        guard productListSort != .defaultOrder else { return filteredProducts }
        let locale = Locale(identifier: "tr_TR")
        return filteredProducts.enumerated().sorted { lhs, rhs in
            switch productListSort {
            case .defaultOrder:
                return lhs.offset < rhs.offset
            case .priorityFirst:
                if lhs.element.isPriority != rhs.element.isPriority {
                    return lhs.element.isPriority && !rhs.element.isPriority
                }
                return lhs.offset < rhs.offset
            case .productName:
                let comparison = lhs.element.productName.compare(rhs.element.productName, options: [.caseInsensitive], locale: locale)
                return comparison == .orderedSame ? lhs.offset < rhs.offset : comparison == .orderedAscending
            case .lastChecked:
                switch (lhs.element.lastChecked, rhs.element.lastChecked) {
                case let (left?, right?) where left != right:
                    return left > right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return lhs.offset < rhs.offset
                }
            case .nextCheck:
                switch (lhs.element.nextCheckDate, rhs.element.nextCheckDate) {
                case let (left?, right?) where left != right:
                    return left < right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return lhs.offset < rhs.offset
                }
            }
        }.map(\.element)
    }

    private func storeName(for product: TrackedProduct) -> String {
        switch product.provider {
        case .zara: "Zara Türkiye"
        case .bershka: "Bershka Türkiye"
        case .pullAndBear: "Pull&Bear Türkiye"
        case .hm: "H&M Türkiye"
        case .shopify: product.productURL.host() ?? "Shopify mağazası"
        }
    }

    private var listSelection: Binding<Set<UUID>> {
        Binding(
            get: { isSelectionMode ? selectedProductIDs : Set([selectedProductID]) },
            set: { newSelection in
                if isSelectionMode {
                    selectedProductIDs = newSelection
                } else if let productID = newSelection.first {
                    selectedProductID = productID
                }
            }
        )
    }

    private func selectionBinding(for productID: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedProductIDs.contains(productID) },
            set: { isSelected in
                if isSelected {
                    selectedProductIDs.insert(productID)
                } else {
                    selectedProductIDs.remove(productID)
                }
            }
        )
    }

    private func exitSelectionMode() {
        isSelectionMode = false
        selectedProductIDs = []
    }

    private func requestProductDeletion(_ productIDs: [UUID]) {
        guard !isCheckSequenceRunning, !productIDs.isEmpty else { return }
        productIDsPendingDeletion = Array(Set(productIDs)).filter { id in
            trackedProducts.contains { $0.id == id }
        }
        guard !productIDsPendingDeletion.isEmpty else { return }
        isDeleteConfirmationPresented = true
    }

    private func confirmProductDeletion() {
        guard !isCheckSequenceRunning else { return }
        let deletingIDs = productIDsPendingDeletion
        for productID in deletingIDs {
            deleteProduct(productID)
        }
        productIDsPendingDeletion = []
        if isSelectionMode {
            exitSelectionMode()
        }
    }

    var body: some View {
        mainContentWithSheets
            .background { webViewHost }
            .background {
                WindowCloseBehaviorInstaller(controller: windowController)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .background { keyboardShortcutHandlers }
            .onAppear(perform: handleOnAppear)
            .onChange(of: selectedProductID) { _, _ in
                showingDashboard = false
                refreshMenuBarSummary()
            }
            .onChange(of: trackedProducts.map(\.id)) { _, currentIDs in
                selectedProductIDs.formIntersection(currentIDs)
            }
            .onChange(of: visibleTrackedProducts.map(\.id)) { _, visibleIDs in
                selectedProductIDs.formIntersection(visibleIDs)
                if !visibleIDs.contains(selectedProductID) {
                    selectedProductID = visibleIDs.first ?? UUID()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportBackupRequested)) { _ in
                exportBackup()
            }
            .onReceive(NotificationCenter.default.publisher(for: .importBackupRequested)) { _ in
                importBackup()
            }
            .onChange(of: automaticCheckingEnabled) { _, isEnabled in
                if isEnabled {
                    configureAutomaticMonitoring(runImmediately: true)
                } else {
                    stopAutomaticMonitoring()
                }
                syncPowerPrevention()
            }
            .onChange(of: checkIntervalMinutes) { _, _ in
                // This setting only supplies the initial interval for products added later.
            }
            .onChange(of: adaptiveMonitoringEnabled) { _, isEnabled in
                handleAdaptiveMonitoringChanged(isEnabled)
            }
            .onChange(of: isGlobalMonitoringPaused) { _, isPaused in
                handleGlobalPauseChanged(isPaused)
            }
            .modifier(PowerStateChangeModifier(
                closedDisplayMonitoringEnabled: closedDisplayMonitoringEnabled,
                closedDisplayRequireACPower: closedDisplayRequireACPower,
                closedDisplayMinBatteryLevel: closedDisplayMinBatteryLevel,
                monitoringPowerMode: monitoringPowerMode,
                isCheckSequenceRunning: isCheckSequenceRunning,
                onSync: syncPowerPrevention
            ))
            .onChange(of: trackedProducts.map { "\($0.id):\($0.isPaused)" }) { _, _ in
                syncPowerPrevention()
            }
            .onChange(of: menuBarState.manualCheckRequestID) { _, _ in
                startManualCheckAll()
            }
            .onChange(of: menuBarState.selectedProductToOpen) { _, productID in
                handleOpenProductFromMenuBar(productID)
            }
            .onChange(of: networkMonitor.status) { oldStatus, newStatus in
                handleNetworkStatusChanged(oldStatus: oldStatus, newStatus: newStatus)
            }
            .onReceive(NotificationCenter.default.publisher(for: .didDetectRestockEvent)) { notification in
                handleRestockNotification(notification)
            }
    }

    @ViewBuilder
    private var mainSplitView: some View {
        NavigationSplitView {
            sidebarPane
        } detail: {
            detailPane
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                selectionToolbarControls
                actionToolbarControls
            }
        }
        .frame(minWidth: 760, minHeight: 500)
    }

    @ViewBuilder
    private var mainContentWithSheets: some View {
        mainSplitView
            .sheet(item: $activeSheet) { sheet in
                sheetContent(for: sheet)
            }
            .confirmationDialog(
                deleteConfirmationTitle,
                isPresented: $isDeleteConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Sil", role: .destructive) {
                    confirmProductDeletion()
                }
                Button("İptal", role: .cancel) {
                    productIDsPendingDeletion = []
                }
            } message: {
                Text("Seçilen ürünler takipten kaldırılacak.")
            }
            .inspector(isPresented: $showingInspector) {
                inspectorContent
            }
            .alert("Not Düzenle", isPresented: $showingNoteAlert) {
                TextField("Not girin...", text: $noteDraftText)
                Button("Kaydet") {
                    let trimmed = noteDraftText.trimmingCharacters(in: .whitespacesAndNewlines)
                    updateNote(trimmed.isEmpty ? nil : trimmed, for: selectedProductID)
                }
                Button("İptal", role: .cancel) { }
            }
    }

    @ViewBuilder
    private var sidebarPane: some View {
        VStack(spacing: 0) {
            if !trackedProducts.isEmpty {
                sidebarFilterBar
                Divider()
            }

            List(selection: listSelection) {
                Section {
                    ForEach(visibleTrackedProducts) { product in
                        sidebarRow(for: product)
                    }
                } header: {
                    sidebarSectionHeader
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $productSearchText, placement: .sidebar, prompt: "Ürün, mağaza, grup veya etiket ara...")
            .searchFocused($isSearchFocused)
            .onDrop(of: [.url, .plainText], isTargeted: $isDropTargeted) { providers in
                handleIncomingDrop(providers)
            }
            .overlay {
                if isDropTargeted {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                            .background(Color.accentColor.opacity(0.08))
                        Label("Ürün bağlantısını bırakın", systemImage: "link.badge.plus")
                            .font(.headline)
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(8)
                } else if visibleTrackedProducts.isEmpty {
                    ContentUnavailableView {
                        Label(productSearchText.isEmpty ? "Takip edilen ürün yok" : "Sonuç bulunamadı", systemImage: "shippingbox")
                    } description: {
                        Text(productSearchText.isEmpty ? "Bir ürün ekleyerek stok takibine başlayın." : "Arama veya filtre ölçütlerini değiştirmeyi deneyin.")
                    } actions: {
                        if isAnyFilterActive {
                            Button("Filtreleri Temizle") {
                                clearAllFilters()
                            }
                        } else {
                            Button("Ürün Ekle", systemImage: "plus") { activeSheet = .addProduct(initialURL: nil) }
                        }
                    }
                }
            }
            .onDeleteCommand {
                guard isSelectionMode, !selectedProductIDs.isEmpty else { return }
                requestProductDeletion(Array(selectedProductIDs))
            }

            Divider()

            sidebarFooter
        }
        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
    }

    @ViewBuilder
    private var sidebarFilterBar: some View {
        HStack(spacing: 4) {
            FilterSegmentButton(
                title: "Tümü",
                count: trackedProducts.count,
                isSelected: productStatusFilter == .all
            ) {
                productStatusFilter = .all
            }

            FilterSegmentButton(
                title: "Stokta",
                count: trackedProducts.filter { $0.effectiveAvailability == true }.count,
                isSelected: productStatusFilter == .inStock,
                tint: .green
            ) {
                productStatusFilter = .inStock
            }

            FilterSegmentButton(
                title: "Tükendi",
                count: trackedProducts.filter { $0.effectiveAvailability == false }.count,
                isSelected: productStatusFilter == .outOfStock,
                tint: .secondary
            ) {
                productStatusFilter = .outOfStock
            }

            FilterSegmentButton(
                title: "Hata",
                count: trackedProducts.filter { $0.hasCheckFailure }.count,
                isSelected: productStatusFilter == .error,
                tint: .orange
            ) {
                productStatusFilter = .error
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            Label("\(visibleTrackedProducts.count) / \(trackedProducts.count) ürün", systemImage: "shippingbox")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                activeSheet = .addProduct(initialURL: nil)
            } label: {
                Label("Ürün Ekle", systemImage: "plus")
            }
            .labelStyle(.iconOnly)
            .help("Ürün Ekle (⌘N)")
            .disabled(isCheckSequenceRunning)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var detailPane: some View {
        VStack(spacing: 0) {
            if let banner = activeRestockBanner {
                InAppRestockBannerView(banner: banner) {
                    if trackedProducts.contains(where: { $0.id == banner.productID }) {
                        selectedProductID = banner.productID
                        showingDashboard = false
                    }
                } onDismiss: {
                    withAnimation {
                        activeRestockBanner = nil
                    }
                }
                Divider()
            }

            GlobalMonitoringStatusBar(
                automaticCheckingEnabled: automaticCheckingEnabled,
                isCheckSequenceRunning: isCheckSequenceRunning,
                activeProductCount: activeMonitoredProductsCount,
                totalProductCount: trackedProducts.count,
                nextCheckDate: earliestNextCheckDate,
                powerMode: monitoringPowerMode,
                networkStatus: networkMonitor.status,
                isGlobalMonitoringPaused: isGlobalMonitoringPaused,
                onToggleGlobalPause: { isGlobalMonitoringPaused.toggle() }
            )
            Divider()
            mainDetailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var webViewHost: some View {
        let webViewProductID = checkingProductID ?? selectedProductID
        if let webViewProductIndex = trackedProducts.firstIndex(where: { $0.id == webViewProductID }) {
            let webViewProduct = trackedProducts[webViewProductIndex]
            StorePageWebView(
                product: $trackedProducts[webViewProductIndex],
                checkRequestID: checkRequestID,
                isChecking: $isChecking,
                status: $storeConnectionStatus,
                errorMessage: $storeConnectionError,
                notificationsEnabled: stockNotificationsEnabled,
                emailNotificationsEnabled: emailNotificationsEnabled,
                adaptiveMonitoringEnabled: adaptiveMonitoringEnabled,
                autoOpenOnRestockEnabled: autoOpenOnRestockEnabled,
                verificationMode: globalVerificationMode,
                burstModeEnabled: restockBurstModeEnabled,
                burstIntervalMinutes: restockBurstIntervalMinutes,
                burstDurationMinutes: restockBurstDurationMinutes,
                onCheckComplete: completeCurrentCheck
            )
            .frame(
                width: webViewProduct.provider == .pullAndBear ? 1200 : 1,
                height: webViewProduct.provider == .pullAndBear ? 800 : 1
            )
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var inspectorContent: some View {
        if let selectedProductIndex {
            let product = trackedProducts[selectedProductIndex]
            ProductInspectorView(
                product: product,
                storeName: storeName(for: product),
                onOpenProduct: { NSWorkspace.shared.open(product.productURL) },
                onTogglePause: { setPaused(!product.isPaused, for: product.id) },
                onTogglePriority: { togglePriority(for: product.id) },
                onIntervalChange: { updateCheckInterval($0, for: product.id) },
                onGroupChange: { updateGroup($0, for: product.id) },
                onAddTag: { addTag($0, for: product.id) },
                onRemoveTag: { removeTag($0, for: product.id) }
            )
        } else {
            VStack(spacing: 12) {
                Image(systemName: "sidebar.trailing")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text("Ürün Seçilmedi")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Ayrıntıları görmek ve düzenlemek için kenar çubuğundan bir ürün seçin.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func sheetContent(for sheet: ContentSheet) -> some View {
        switch sheet {
        case .addProduct(let initialURL):
            AddProductSheet(
                defaultIntervalMinutes: checkIntervalMinutes,
                existingProducts: trackedProducts,
                initialURL: initialURL,
                onAddMultiple: handleAddedProducts
            )
        }
    }

    private func handleSpaceShortcut() {
        guard let idx = selectedProductIndex else { return }
        setPaused(!trackedProducts[idx].isPaused, for: trackedProducts[idx].id)
    }

    private func handleReturnShortcut() {
        guard let idx = selectedProductIndex else { return }
        NSWorkspace.shared.open(trackedProducts[idx].productURL)
    }

    private func handleDeleteShortcut() {
        guard let idx = selectedProductIndex, !isCheckSequenceRunning else { return }
        requestProductDeletion([trackedProducts[idx].id])
    }

    @ViewBuilder
    private var keyboardShortcutHandlers: some View {
        Group {
            Button("") {
                isSearchFocused = true
            }
            .keyboardShortcut("k", modifiers: .command)

            Button("", action: handleSpaceShortcut)
                .keyboardShortcut(.space, modifiers: [])

            Button("", action: handleReturnShortcut)
                .keyboardShortcut(.return, modifiers: [])

            Button("", action: handleDeleteShortcut)
                .keyboardShortcut(.delete, modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
    }

    private func handleOpenProductFromMenuBar(_ productID: UUID?) {
        guard let productID else { return }
        if trackedProducts.contains(where: { $0.id == productID }) {
            selectedProductID = productID
        }
    }

    private func handleNetworkStatusChanged(oldStatus: NetworkReachabilityMonitor.Status, newStatus: NetworkReachabilityMonitor.Status) {
        if newStatus == .available && oldStatus != .available {
            print("[NetworkGuard] Ağ bağlantısı hazır ve stabilize oldu. Bekleyen kontroller yürütülüyor.")
            runDueAutomaticChecks()
            scheduleNextAutomaticCheck()
        }
    }

    private func handleRestockNotification(_ notification: Notification) {
        guard let event = notification.object as? InAppRestockEvent else { return }
        withAnimation {
            activeRestockBanner = event
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if activeRestockBanner?.productID == event.productID {
                withAnimation {
                    activeRestockBanner = nil
                }
            }
        }
    }

    private func handleOnAppear() {
        refreshMenuBarSummary()
        configureAutomaticMonitoring(runImmediately: true)
        syncPowerPrevention()
    }

    private var deleteConfirmationTitle: String {
        productIDsPendingDeletion.count == 1 ? "Ürünü Sil?" : "\(productIDsPendingDeletion.count) Ürünü Sil?"
    }

    @ViewBuilder
    private var mainDetailContent: some View {
        if showingDashboard {
            MonitoringDashboardView(
                products: trackedProducts,
                onSelectProduct: { id in
                    selectedProductID = id
                    showingDashboard = false
                },
                onAddProduct: {
                    activeSheet = .addProduct
                }
            )
        } else if let selectedProductIndex {
            productDetailPane(for: selectedProductIndex)
        } else if trackedProducts.isEmpty {
            EmptyProductsView {
                activeSheet = .addProduct
            }
        } else {
            MonitoringDashboardView(
                products: trackedProducts,
                onSelectProduct: { id in
                    selectedProductID = id
                    showingDashboard = false
                },
                onAddProduct: {
                    activeSheet = .addProduct
                }
            )
        }
    }

    @ViewBuilder
    private func productDetailPane(for index: Int) -> some View {
        let product = trackedProducts[index]
        ProductDetailView(
            product: product,
            status: visibleStatus(for: product),
            storeConnectionStatus: storeConnectionStatus,
            storeConnectionError: storeConnectionError,
            automaticCheckingEnabled: automaticCheckingEnabled,
            canDelete: !isCheckSequenceRunning,
            canChangeInterval: !isCheckSequenceRunning,
            onOpenProduct: { NSWorkspace.shared.open(product.productURL) },
            onDelete: { requestProductDeletion([product.id]) },
            onIntervalChange: { updateCheckInterval($0, for: product.id) },
            onGroupChange: { updateGroup($0, for: product.id) },
            onAddTag: { addTag($0, for: product.id) },
            onRemoveTag: { removeTag($0, for: product.id) },
            onTogglePause: { setPaused(!product.isPaused, for: product.id) },
            onTogglePriority: { togglePriority(for: product.id) },
            onUpdateNote: { updateNote($0, for: product.id) },
            onToggleMacOSNotification: { toggleMacOSNotification(for: product.id) },
            onToggleEmailNotification: { toggleEmailNotification(for: product.id) },
            onNotificationProfileChange: { updateNotificationProfile($0, for: product.id) },
            onAutoOpenChange: { updateAutoOpenOnRestock($0, for: product.id) },
            onTrackingRuleChange: { updateTrackingRule($0, for: product.id) },
            onAlertConditionChange: { updateAlertCondition($0, for: product.id) },
            onVerificationPreferenceChange: { updateVerificationPreference($0, for: product.id) },
            onBurstPreferenceChange: { updateBurstPreference($0, for: product.id) }
        )
    }

    @ViewBuilder
    private func sidebarRow(for product: TrackedProduct) -> some View {
        HStack(spacing: 10) {
            if isSelectionMode {
                Toggle(product.productName, isOn: selectionBinding(for: product.id))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
            }
            ProductSidebarRow(product: product, status: visibleStatus(for: product))
        }
        .tag(product.id)
        .contextMenu {
            productContextMenu(for: product)
        }
        .accessibilityLabel("\(product.productName), \(product.selectedVariant.displayDescription), \(visibleStatus(for: product).label)")
    }

    @ViewBuilder
    private var sidebarSectionHeader: some View {
        HStack {
            Text("Takip Edilenler")
            Spacer()
            if !trackedProducts.isEmpty {
                Menu {
                    Section("Şuna göre sırala") {
                        ForEach(ProductListSort.allCases) { sort in
                            Toggle(sort.title, isOn: Binding(
                                get: { productListSort == sort },
                                set: { isSelected in
                                    if isSelected {
                                        productListSort = sort
                                    }
                                }
                            ))
                        }
                    }
                } label: {
                    Label("Şuna göre sırala", systemImage: "arrow.up.arrow.down")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .help("Şuna göre sırala")
                .accessibilityLabel("Şuna göre sırala")
            }
            Menu {
                Section("Durum") {
                    ForEach(ProductListFilter.allCases) { filter in
                        Button {
                            productStatusFilter = filter
                        } label: {
                            if productStatusFilter == filter {
                                Label(filter.title, systemImage: "checkmark")
                            } else {
                                Text(filter.title)
                            }
                        }
                    }
                }

                Section("Mağaza") {
                    Button {
                        selectedProviderFilter = nil
                    } label: {
                        if selectedProviderFilter == nil {
                            Label("Tüm Mağazalar", systemImage: "checkmark")
                        } else {
                            Text("Tüm Mağazalar")
                        }
                    }
                    ForEach(StoreProvider.allCases, id: \.self) { provider in
                        Button {
                            selectedProviderFilter = provider
                        } label: {
                            if selectedProviderFilter == provider {
                                Label(provider.displayName, systemImage: "checkmark")
                            } else {
                                Text(provider.displayName)
                            }
                        }
                    }
                }

                if !orgStore.availableGroups.isEmpty {
                    Section("Grup") {
                        Button {
                            selectedGroupFilter = nil
                        } label: {
                            if selectedGroupFilter == nil {
                                Label("Tüm Gruplar", systemImage: "checkmark")
                            } else {
                                Text("Tüm Gruplar")
                            }
                        }
                        ForEach(orgStore.availableGroups, id: \.self) { group in
                            Button {
                                selectedGroupFilter = group
                            } label: {
                                if selectedGroupFilter == group {
                                    Label(group, systemImage: "checkmark")
                                } else {
                                    Text(group)
                                }
                            }
                        }
                    }
                }

                if !orgStore.availableTags.isEmpty {
                    Section("Etiket") {
                        Button {
                            selectedTagFilter = nil
                        } label: {
                            if selectedTagFilter == nil {
                                Label("Tüm Etiketler", systemImage: "checkmark")
                            } else {
                                Text("Tüm Etiketler")
                            }
                        }
                        ForEach(orgStore.availableTags, id: \.self) { tag in
                            Button {
                                selectedTagFilter = tag
                            } label: {
                                if selectedTagFilter == tag {
                                    Label(tag, systemImage: "checkmark")
                                } else {
                                    Text(tag)
                                }
                            }
                        }
                    }
                }

                if isAnyFilterActive {
                    Divider()
                    Button("Filtreleri Temizle", role: .destructive) {
                        clearAllFilters()
                    }
                }
            } label: {
                Label(
                    "Filtrele",
                    systemImage: isAnyFilterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
                )
                .labelStyle(.iconOnly)
                .foregroundStyle(isAnyFilterActive ? Color.accentColor : Color.secondary)
            }
            .menuStyle(.borderlessButton)
            .help(isAnyFilterActive ? "Filtreler etkin (tıkla ve yönet)" : "Ürünleri filtrele")
        }
        .textCase(nil)
    }

    @ViewBuilder
    private func productContextMenu(for product: TrackedProduct) -> some View {
        Button("Şimdi Kontrol Et", systemImage: "arrow.clockwise") {
            startManualCheck(for: product.id)
        }
        .disabled(isCheckSequenceRunning || !networkMonitor.canProceedWithChecks || product.isPaused)

        Button("Tümünü Kontrol Et", systemImage: "arrow.clockwise.circle") {
            startManualCheckAll()
        }
        .disabled(isCheckSequenceRunning || !networkMonitor.canProceedWithChecks)

        Divider()

        Button(
            product.isPaused ? "İzlemeye Devam Et" : "İzlemeyi Duraklat",
            systemImage: product.isPaused ? "play.circle" : "pause.circle"
        ) {
            setPaused(!product.isPaused, for: product.id)
        }
        .disabled(isCheckSequenceRunning)

        Button(
            product.isPriority ? "Önceliği Kaldır" : "Öncelikli Yap",
            systemImage: product.isPriority ? "star.slash" : "star"
        ) {
            togglePriority(for: product.id)
        }

        Divider()

        Button("Ürün Sayfasını Aç", systemImage: "safari") {
            NSWorkspace.shared.open(product.productURL)
        }
        Button("Ürün URL'sini Kopyala", systemImage: "doc.on.doc") {
            copyProductURL(product.productURL)
        }

        Divider()

        Menu("Gruba Taşı", systemImage: "folder") {
            Button("Grupsuz") {
                updateGroup(nil, for: product.id)
            }
            ForEach(orgStore.availableGroups, id: \.self) { group in
                Button(group) {
                    updateGroup(group, for: product.id)
                }
            }
        }

        Menu("Etiketler", systemImage: "tag") {
            ForEach(orgStore.availableTags, id: \.self) { tag in
                let isTagged = product.tags.contains(tag)
                Button {
                    if isTagged {
                        removeTag(tag, for: product.id)
                    } else {
                        addTag(tag, for: product.id)
                    }
                } label: {
                    if isTagged {
                        Label(tag, systemImage: "checkmark")
                    } else {
                        Text(tag)
                    }
                }
            }
        }

        Button("Not Düzenle...", systemImage: "square.and.pencil") {
            selectedProductID = product.id
            noteDraftText = product.note ?? ""
            showingNoteAlert = true
        }

        if productListSort == .defaultOrder && !isAnyFilterActive {
            Divider()
            Button("Yukarı Taşı", systemImage: "arrow.up") {
                moveProductUp(product.id)
            }
            .disabled(trackedProducts.first?.id == product.id)

            Button("Aşağı Taşı", systemImage: "arrow.down") {
                moveProductDown(product.id)
            }
            .disabled(trackedProducts.last?.id == product.id)
        }

        Divider()
        Button("Ürünü Sil", systemImage: "trash", role: .destructive) {
            requestProductDeletion([product.id])
        }
        .disabled(isCheckSequenceRunning)
    }

    @ViewBuilder
    private var selectionToolbarControls: some View {
        if isSelectionMode {
            Button {
                exitSelectionMode()
            } label: {
                Label("Seçim Modunu Kapat", systemImage: "xmark")
            }
            .help("Seçim modunu kapat")

            Menu {
                Button("Tümünü Seç", systemImage: "checkmark.circle") {
                    selectedProductIDs.formUnion(visibleTrackedProducts.map(\.id))
                }
                .disabled(visibleTrackedProducts.isEmpty || isCheckSequenceRunning)
                Button("Tümünün Seçimini Kaldır", systemImage: "circle") {
                    selectedProductIDs.subtract(visibleTrackedProducts.map(\.id))
                }
                .disabled(!visibleTrackedProducts.contains { selectedProductIDs.contains($0.id) } || isCheckSequenceRunning)
            } label: {
                Label("Seçim İşlemleri", systemImage: "ellipsis.circle")
            }
            .help("Seçim işlemleri")

            Button(role: .destructive) {
                requestProductDeletion(Array(selectedProductIDs))
            } label: {
                Label("Seçilenleri Sil", systemImage: "trash")
            }
            .help("Seçilen ürünleri sil")
            .disabled(selectedProductIDs.isEmpty || isCheckSequenceRunning)
        } else {
            Button {
                isSelectionMode = true
                selectedProductIDs = []
            } label: {
                Label("Seç", systemImage: "checkmark.circle")
            }
            .help("Ürünleri seç")
            .disabled(trackedProducts.isEmpty || isCheckSequenceRunning)
        }
    }

    @ViewBuilder
    private var actionToolbarControls: some View {
        Button {
            showingDashboard.toggle()
        } label: {
            Label("Genel Özet", systemImage: showingDashboard ? "gauge.with.dots.needle.bottom.50percent" : "chart.bar.xaxis")
        }
        .help(showingDashboard ? "Ürün görünümüne dön" : "Genel izleme özetini göster")

        Button {
            activeSheet = .addProduct
        } label: {
            Label("Ürün Ekle", systemImage: "plus")
        }
        .help("Ürün Ekle (⌘N)")
        .disabled(isCheckSequenceRunning)
        .keyboardShortcut("n", modifiers: .command)

        Button {
            startManualCheck()
        } label: {
            if isChecking {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            } else {
                Label("Şimdi Kontrol Et", systemImage: "arrow.clockwise")
            }
        }
        .help(networkMonitor.canProceedWithChecks ? "Şimdi Kontrol Et (⌘R)" : "Ağ bağlantısı bekleniyor")
        .disabled(isCheckSequenceRunning || selectedProductIndex == nil || !networkMonitor.canProceedWithChecks || (selectedProductIndex.map { trackedProducts[$0].isPaused } ?? false))
        .keyboardShortcut("r", modifiers: .command)

        Button {
            startManualCheckAll()
        } label: {
            Label("Şimdi Tümünü Kontrol Et", systemImage: "arrow.clockwise.circle")
        }
        .help(networkMonitor.canProceedWithChecks ? "Şimdi Tümünü Kontrol Et (⇧⌘R)" : "Ağ bağlantısı bekleniyor")
        .disabled(isCheckSequenceRunning || !trackedProducts.contains(where: { !$0.isPaused }) || !networkMonitor.canProceedWithChecks)
        .keyboardShortcut("r", modifiers: [.command, .shift])

        Menu {
            Button("Yedek Dışa Aktar...", systemImage: "square.and.arrow.up") {
                exportBackup()
            }
            .disabled(trackedProducts.isEmpty)

            Button("Yedekten İçe Aktar...", systemImage: "square.and.arrow.down") {
                importBackup()
            }
        } label: {
            Label("Yedekle / İçe Aktar", systemImage: "externaldrive")
        }
        .help("Yedekle veya İçe Aktar")

        SettingsLink {
            Label("Ayarlar", systemImage: "gearshape")
        }
        .help("Ayarlar")

        Button {
            showingInspector.toggle()
        } label: {
            Label("Müfettiş", systemImage: "sidebar.trailing")
        }
        .help("Müfettiş Paneli (⌥⌘I)")
        .keyboardShortcut("i", modifiers: [.command, .option])
    }

    private func handleAdaptiveMonitoringChanged(_ isEnabled: Bool) {
        for index in trackedProducts.indices where !trackedProducts[index].isPaused {
            if let last = trackedProducts[index].lastChecked {
                let effectiveMinutes = AdaptiveMonitoringPolicy.effectiveIntervalMinutes(
                    baseMinutes: trackedProducts[index].checkIntervalMinutes,
                    status: trackedProducts[index].status,
                    consecutiveUnchangedChecks: trackedProducts[index].consecutiveUnchangedChecks,
                    consecutiveFailureChecks: trackedProducts[index].consecutiveFailureChecks,
                    isEnabled: isEnabled
                )
                let delay = TimeInterval(effectiveMinutes * 60)
                trackedProducts[index].nextCheckDate = last.addingTimeInterval(delay)
            }
        }
        TrackedProductStore.save(trackedProducts)
        scheduleNextAutomaticCheck()
    }

    private func handleAddedProducts(_ newProducts: [TrackedProduct]) -> (added: Int, duplicates: Int) {
        var addedCount = 0
        var duplicateCount = 0
        var newlyAdded: [TrackedProduct] = []

        for product in newProducts {
            let isDup = trackedProducts.contains { $0.isDuplicate(of: product) }
            if isDup {
                duplicateCount += 1
            } else {
                newlyAdded.append(product)
                addedCount += 1
            }
        }

        if !newlyAdded.isEmpty {
            trackedProducts.append(contentsOf: newlyAdded)
            TrackedProductStore.save(trackedProducts)
            selectedProductID = newlyAdded.last!.id
            refreshMenuBarSummary()
            activeSheet = nil
            scheduleNextAutomaticCheck()
            syncPowerPrevention()
        }

        return (added: addedCount, duplicates: duplicateCount)
    }

    private func handleGlobalPauseChanged(_ paused: Bool) {
        if paused {
            checkSequenceTask?.cancel()
            checkSequenceTask = nil
            automaticCheckTimer?.invalidate()
            automaticCheckTimer = nil
            isChecking = false
            checkingProductID = nil
            isCheckSequenceRunning = false
            refreshMenuBarSummary()
            syncPowerPrevention()
        } else {
            refreshMenuBarSummary()
            configureAutomaticMonitoring(runImmediately: true)
            syncPowerPrevention()
        }
    }

    private func configureAutomaticMonitoring(runImmediately: Bool) {
        stopAutomaticMonitoring()
        guard automaticCheckingEnabled, !isGlobalMonitoringPaused else { return }

        if runImmediately {
            runDueAutomaticChecks()
        } else {
            scheduleNextAutomaticCheck()
        }
    }

    private func stopAutomaticMonitoring() {
        automaticCheckTimer?.invalidate()
        automaticCheckTimer = nil
        checkSequenceTask?.cancel()
        checkSequenceTask = nil
    }

    private func runDueAutomaticChecks() {
        guard automaticCheckingEnabled, !isGlobalMonitoringPaused else { return }
        guard !isCheckSequenceRunning else { return }
        if monitoringScheduleEnabled && !currentMonitoringSchedule.isActive() {
            scheduleNextAutomaticCheck()
            return
        }
        guard networkMonitor.canProceedWithChecks else {
            print("[NetworkGuard] Ağ bağlantısı hazır değil, otomatik kontroller ertelendi.")
            return
        }
        let now = Date()
        let dueIDs = trackedProducts
            .filter { !$0.isPaused && ($0.nextCheckDate == nil || $0.nextCheckDate! <= now) }
            .map(\.id)
        guard !dueIDs.isEmpty else {
            scheduleNextAutomaticCheck()
            return
        }
        startCheckSequence(for: dueIDs)
    }

    private func scheduleNextAutomaticCheck() {
        automaticCheckTimer?.invalidate()
        automaticCheckTimer = nil
        guard automaticCheckingEnabled, !isGlobalMonitoringPaused, !isCheckSequenceRunning else { return }
        guard networkMonitor.canProceedWithChecks else { return }

        let schedule = currentMonitoringSchedule
        if monitoringScheduleEnabled && !schedule.isActive() {
            guard let nextStart = schedule.nextStartDate() else { return }
            let interval = max(1.0, nextStart.timeIntervalSinceNow)
            let timerGeneration = UUID()
            currentTimerGeneration = timerGeneration
            let timer = Timer.scheduledTimer(
                withTimeInterval: interval,
                repeats: false
            ) { _ in
                Task { @MainActor in
                    if self.currentTimerGeneration == timerGeneration {
                        self.automaticCheckTimer = nil
                        self.currentTimerGeneration = nil
                    }
                    self.runDueAutomaticChecks()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            automaticCheckTimer = timer
            return
        }

        let nextDate = trackedProducts
            .filter { !$0.isPaused }
            .compactMap { $0.nextCheckDate ?? Date.distantPast }
            .min()
        guard let nextDate else { return }

        let timerGeneration = UUID()
        currentTimerGeneration = timerGeneration
        let timer = Timer.scheduledTimer(
            withTimeInterval: max(0.2, nextDate.timeIntervalSinceNow),
            repeats: false
        ) { _ in
            Task { @MainActor in
                if self.currentTimerGeneration == timerGeneration {
                    self.automaticCheckTimer = nil
                    self.currentTimerGeneration = nil
                }
                self.runDueAutomaticChecks()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        automaticCheckTimer = timer
    }

    private func startCheckSequence(for productIDs: [UUID]) {
        guard !isCheckSequenceRunning, !productIDs.isEmpty else { return }
        guard networkMonitor.canProceedWithChecks else {
            print("[NetworkGuard] Ağ bağlantısı hazır değil, kontrol sırası başlatılmadı.")
            return
        }
        isCheckSequenceRunning = true
        syncPowerPrevention()
        stopAutomaticMonitoring()

        checkSequenceTask = Task { @MainActor in
            defer {
                checkingProductID = nil
                isChecking = false
                isCheckSequenceRunning = false
                checkSequenceTask = nil
                refreshMenuBarSummary()
                if !isGlobalMonitoringPaused {
                    scheduleNextAutomaticCheck()
                }
                syncPowerPrevention()
            }

            for productID in productIDs {
                guard !Task.isCancelled, !isGlobalMonitoringPaused else { break }
                guard networkMonitor.canProceedWithChecks else {
                    print("[NetworkGuard] Sıra sırasında ağ kesintisi tespit edildi, kalan kontroller ertelendi.")
                    break
                }
                guard let product = trackedProducts.first(where: { $0.id == productID }), !product.isPaused else { continue }
                await performCheck(for: productID)
            }
        }
    }

    private func startManualCheck() {
        startManualCheck(for: selectedProductID)
    }

    private func startManualCheck(for productID: UUID) {
        guard networkMonitor.canProceedWithChecks else { return }
        if let product = trackedProducts.first(where: { $0.id == productID }), product.isPaused {
            return
        }
        startCheckSequence(for: [productID])
    }

    private func startManualCheckAll() {
        guard networkMonitor.canProceedWithChecks else { return }
        let unpausedIDs = trackedProducts.filter { !$0.isPaused }.map(\.id)
        guard !unpausedIDs.isEmpty else { return }
        startCheckSequence(for: unpausedIDs)
    }

    private func deleteProduct(_ productID: UUID) {
        guard !isCheckSequenceRunning else { return }
        trackedProducts.removeAll { $0.id == productID }
        TrackedProductStore.save(trackedProducts)
        refreshMenuBarSummary()
        if selectedProductID == productID {
            selectedProductID = trackedProducts.first?.id ?? UUID()
        }
        syncPowerPrevention()
    }

    private func visibleStatus(for product: TrackedProduct) -> ProductStatus {
        checkingProductID == product.id ? .checking : product.status
    }

    private func performCheck(for productID: UUID) async {
        guard trackedProducts.contains(where: { $0.id == productID }) else { return }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                pendingCheckContinuation = continuation
                selectedProductID = productID
                if let index = trackedProducts.firstIndex(where: { $0.id == productID }) {
                    trackedProducts[index].lastCheckError = nil
                }
                checkingProductID = productID
                isChecking = true
                refreshMenuBarSummary()
                checkRequestID += 1
            }
        } onCancel: { [self] in
            Task { @MainActor [self] in
                cancelPendingCheck(for: productID)
            }
        }
    }

    private func completeCurrentCheck() {
        // Guard against stale callbacks: if no check is in progress
        // (e.g. it was already cancelled/timed-out and the sequence moved on),
        // ignore this completion to prevent resuming the wrong continuation.
        guard checkingProductID != nil else { return }
        TrackedProductStore.save(trackedProducts)
        checkingProductID = nil
        refreshMenuBarSummary()
        let continuation = pendingCheckContinuation
        pendingCheckContinuation = nil
        continuation?.resume()
    }

    private func cancelPendingCheck(for productID: UUID) {
        guard checkingProductID == productID else { return }
        checkingProductID = nil
        isChecking = false
        refreshMenuBarSummary()
        let continuation = pendingCheckContinuation
        pendingCheckContinuation = nil
        continuation?.resume()
    }

    private func refreshMenuBarSummary() {
        menuBarState.productCount = trackedProducts.count
        let statuses = trackedProducts.map(visibleStatus(for:))
        menuBarState.inStockCount = statuses.filter { $0 == .inStock }.count
        menuBarState.outOfStockCount = statuses.filter { $0 == .outOfStock }.count
        menuBarState.unknownStockCount = statuses.filter { $0 == .unchecked || $0 == .checking }.count
        menuBarState.pausedCount = statuses.filter { $0 == .paused }.count
        menuBarState.errorCount = statuses.filter { $0 == .error }.count
        menuBarState.priorityCount = trackedProducts.filter(\.isPriority).count
        menuBarState.isChecking = isCheckSequenceRunning || checkingProductID != nil
        menuBarState.isAllPaused = !trackedProducts.isEmpty && trackedProducts.allSatisfy(\.isPaused)
        menuBarState.isGlobalMonitoringPaused = isGlobalMonitoringPaused

        if isGlobalMonitoringPaused {
            menuBarState.nextCheckCountdownText = "Taramalar duraklatıldı"
        } else if let earliest = earliestNextCheckDate {
            if earliest == Date.distantPast {
                menuBarState.nextCheckCountdownText = "Kontrol sırada"
            } else {
                let seconds = Int(earliest.timeIntervalSinceNow.rounded(.up))
                if seconds <= 0 {
                    menuBarState.nextCheckCountdownText = "Kontrol sırada"
                } else if seconds < 60 {
                    menuBarState.nextCheckCountdownText = "Sonraki kontrol: \(seconds) sn"
                } else {
                    let mins = seconds / 60
                    let secs = seconds % 60
                    menuBarState.nextCheckCountdownText = secs == 0 ? "Sonraki kontrol: \(mins) dk" : "Sonraki kontrol: \(mins) dk \(secs) sn"
                }
            }
        } else {
            menuBarState.nextCheckCountdownText = nil
        }

        let latestCheck = trackedProducts.compactMap(\.lastChecked).max()
        menuBarState.lastCheckedText = latestCheck?.formatted(date: .abbreviated, time: .shortened)
            ?? "Henüz kontrol yapılmadı"

        var movements: [MenuBarStockMovement] = []
        for product in trackedProducts {
            for event in product.events {
                if event.type == .stockArrived || event.type == .stockDepleted {
                    movements.append(MenuBarStockMovement(
                        id: event.id,
                        productID: product.id,
                        productName: product.productName,
                        eventType: event.type,
                        date: event.date
                    ))
                }
            }
        }
        movements.sort { $0.date > $1.date }
        menuBarState.recentStockMovements = Array(movements.prefix(5))

        let providerSummaries = ProviderHealthSummary.allSummaries(for: trackedProducts, isNetworkAvailable: networkMonitor.canProceedWithChecks)
        let warningCount = providerSummaries.filter { $0.health == .warning }.count
        if !networkMonitor.canProceedWithChecks {
            menuBarState.providerHealthText = "Ağ bağlantısı yok"
        } else if warningCount > 0 {
            menuBarState.providerHealthText = "\(warningCount) mağazada uyarı"
        } else {
            menuBarState.providerHealthText = "Tüm mağazalar normal"
        }

        if monitoringScheduleEnabled {
            let sched = currentMonitoringSchedule
            if !sched.isActive() {
                if let nextStart = sched.nextStartDate() {
                    let timeStr = nextStart.formatted(date: .omitted, time: .shortened)
                    menuBarState.scheduleStatusText = "Planlama dışı (Başlangıç: \(timeStr))"
                } else {
                    menuBarState.scheduleStatusText = "Planlama dışı"
                }
            } else {
                menuBarState.scheduleStatusText = nil
            }
        } else {
            menuBarState.scheduleStatusText = nil
        }
    }

    private func setPaused(_ isPaused: Bool, for productID: UUID) {
        guard let index = trackedProducts.firstIndex(where: { $0.id == productID }) else { return }
        trackedProducts[index].record(isPaused ? .trackingPaused : .trackingResumed)
        trackedProducts[index].isPaused = isPaused
        if isPaused {
            trackedProducts[index].nextCheckDate = nil
        } else {
            trackedProducts[index].nextCheckDate = Date()
        }
        TrackedProductStore.save(trackedProducts)
        refreshMenuBarSummary()
        scheduleNextAutomaticCheck()
        syncPowerPrevention()
    }

    private func moveProductUp(_ productID: UUID) {
        guard let index = trackedProducts.firstIndex(where: { $0.id == productID }), index > 0 else { return }
        trackedProducts.swapAt(index, index - 1)
        TrackedProductStore.save(trackedProducts)
    }

    private func moveProductDown(_ productID: UUID) {
        guard let index = trackedProducts.firstIndex(where: { $0.id == productID }), index < trackedProducts.count - 1 else { return }
        trackedProducts.swapAt(index, index + 1)
        TrackedProductStore.save(trackedProducts)
    }

    private func togglePriority(for productID: UUID) {
        guard let index = trackedProducts.firstIndex(where: { $0.id == productID }) else { return }
        trackedProducts[index].isPriority.toggle()
        TrackedProductStore.save(trackedProducts)
        refreshMenuBarSummary()
    }

    private func updateNote(_ note: String?, for productID: UUID) {
        guard let index = trackedProducts.firstIndex(where: { $0.id == productID }) else { return }
        trackedProducts[index].note = note
        TrackedProductStore.save(trackedProducts)
    }

    private func toggleMacOSNotification(for productID: UUID) {
        guard let index = trackedProducts.firstIndex(where: { $0.id == productID }) else { return }
        trackedProducts[index].isMacOSNotificationEnabled.toggle()
        TrackedProductStore.save(trackedProducts)
    }

    private func toggleEmailNotification(for productID: UUID) {
        guard let index = trackedProducts.firstIndex(where: { $0.id == productID }) else { return }
        trackedProducts[index].isEmailNotificationEnabled.toggle()
        TrackedProductStore.save(trackedProducts)
    }

    private func updateNotificationProfile(_ profile: NotificationProfile, for productID: UUID) {
        guard let index = trackedProducts.firstIndex(where: { $0.id == productID }) else { return }
        trackedProducts[index].notificationProfile = profile
        TrackedProductStore.save(trackedProducts)
    }

    private func updateAutoOpenOnRestock(_ autoOpen: Bool?, for productID: UUID) {
        guard let index = trackedProducts.firstIndex(where: { $0.id == productID }) else { return }
        trackedProducts[index].autoOpenOnRestock = autoOpen
        TrackedProductStore.save(trackedProducts)
    }

    private func updateTrackingRule(_ rule: SmartTrackingRule, for productID: UUID) {
        guard let index = trackedProducts.firstIndex(where: { $0.id == productID }) else { return }
        trackedProducts[index].trackingRule = rule
        TrackedProductStore.save(trackedProducts)
    }

    private func updateAlertCondition(_ condition: SmartAlertCondition, for productID: UUID) {
        guard let index = trackedProducts.firstIndex(where: { $0.id == productID }) else { return }
        trackedProducts[index].alertCondition = condition
        TrackedProductStore.save(trackedProducts)
    }

    private func updateVerificationPreference(_ pref: RestockVerificationMode?, for productID: UUID) {
        guard let index = trackedProducts.firstIndex(where: { $0.id == productID }) else { return }
        trackedProducts[index].verificationPreference = pref
        TrackedProductStore.save(trackedProducts)
    }

    private func updateBurstPreference(_ pref: Bool?, for productID: UUID) {
        guard let index = trackedProducts.firstIndex(where: { $0.id == productID }) else { return }
        trackedProducts[index].burstPreference = pref
        TrackedProductStore.save(trackedProducts)
    }

    private func updateCheckInterval(_ minutes: Int, for productID: UUID) {
        guard let index = trackedProducts.firstIndex(where: { $0.id == productID }) else { return }
        trackedProducts[index].checkIntervalMinutes = minutes
        guard !trackedProducts[index].isPaused else {
            TrackedProductStore.save(trackedProducts)
            return
        }
        let effectiveMinutes = AdaptiveMonitoringPolicy.effectiveIntervalMinutes(
            baseMinutes: minutes,
            status: trackedProducts[index].status,
            consecutiveUnchangedChecks: trackedProducts[index].consecutiveUnchangedChecks,
            consecutiveFailureChecks: trackedProducts[index].consecutiveFailureChecks,
            isEnabled: adaptiveMonitoringEnabled,
            burstExpiresAt: trackedProducts[index].burstExpiresAt,
            burstIntervalMinutes: restockBurstIntervalMinutes
        )
        trackedProducts[index].nextCheckDate = trackedProducts[index].lastChecked?
            .addingTimeInterval(TimeInterval(effectiveMinutes * 60)) ?? Date()
        TrackedProductStore.save(trackedProducts)
        scheduleNextAutomaticCheck()
    }

    private func copyProductURL(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    private func exportBackup() {
        ProductBackupService.shared.exportProducts(trackedProducts)
    }

    private func importBackup() {
        ProductBackupService.shared.promptImport(existingProducts: trackedProducts) { newProducts in
            guard !newProducts.isEmpty else { return }
            trackedProducts.append(contentsOf: newProducts)
            TrackedProductStore.save(trackedProducts)
            ProductOrganizationStore.shared.syncFromProducts(trackedProducts)
            scheduleNextAutomaticCheck()
            syncPowerPrevention()
            refreshMenuBarSummary()
        }
    }

    private func updateGroup(_ group: String?, for productID: UUID) {
        guard let index = trackedProducts.firstIndex(where: { $0.id == productID }) else { return }
        trackedProducts[index].group = group
        TrackedProductStore.save(trackedProducts)
        ProductOrganizationStore.shared.syncFromProducts(trackedProducts)
    }

    private func addTag(_ tag: String, for productID: UUID) {
        guard let index = trackedProducts.firstIndex(where: { $0.id == productID }) else { return }
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !trackedProducts[index].tags.contains(trimmed) {
            trackedProducts[index].tags.append(trimmed)
            TrackedProductStore.save(trackedProducts)
            ProductOrganizationStore.shared.syncFromProducts(trackedProducts)
        }
    }

    private func removeTag(_ tag: String, for productID: UUID) {
        guard let index = trackedProducts.firstIndex(where: { $0.id == productID }) else { return }
        trackedProducts[index].tags.removeAll(where: { $0 == tag })
        TrackedProductStore.save(trackedProducts)
        ProductOrganizationStore.shared.syncFromProducts(trackedProducts)
    }

}

private struct ProductSidebarRow: View {
    let product: TrackedProduct
    let status: ProductStatus

    private var cleanVariantDescription: String {
        let desc = product.selectedVariant.displayDescription
        if desc.lowercased().hasPrefix("varyant:") {
            return desc.dropFirst(8).trimmingCharacters(in: .whitespaces)
        }
        return desc
    }

    private var stockIndicatorSymbol: String {
        if status == .checking {
            return "arrow.triangle.2.circlepath"
        }
        switch product.effectiveAvailability {
        case true:
            return "checkmark.circle.fill"
        case false:
            return "circle"
        case nil:
            return "minus.circle"
        }
    }

    private var stockIndicatorColor: Color {
        if status == .checking {
            return .blue
        }
        switch product.effectiveAvailability {
        case true:
            return .green
        case false:
            return .secondary
        case nil:
            return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            // Stock Status Indicator
            Image(systemName: stockIndicatorSymbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(stockIndicatorColor)
                .frame(width: 16)
                .help(product.effectiveAvailability == true ? "Stokta" : (product.effectiveAvailability == false ? "Tükendi" : "Kontrol bekliyor"))

            VStack(alignment: .leading, spacing: 2) {
                // Line 1: Product Name & Badges
                HStack(spacing: 4) {
                    Text(product.productName)
                        .font(.body)
                        .foregroundStyle(product.isPaused ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 2)

                    if product.isPriority {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.yellow)
                            .help("Öncelikli Ürün")
                    }
                    if product.trackingRule != .exactVariant {
                        Image(systemName: product.trackingRule.symbol)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .help(product.trackingRule.title)
                    }
                    if product.isBurstActive {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.orange)
                            .help("Restock Burst Modu Etkin")
                    }
                    if product.isPaused {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .help("İzleme Duraklatıldı")
                    }
                    if product.hasCheckFailure {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                            .help(product.lastCheckError ?? "Son stok kontrolü başarısız")
                    }
                }

                // Line 2: Color · Size
                HStack(spacing: 4) {
                    if let group = product.group, !group.isEmpty {
                        Text(group)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                        Text("·")
                            .foregroundStyle(.tertiary)
                    }
                    Text(cleanVariantDescription)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                // Line 3: Interval · Relative Time
                HStack(spacing: 4) {
                    Text("Her \(ProductCheckInterval.shortTitle(for: product.checkIntervalMinutes))")
                    Text("·")
                        .foregroundStyle(.tertiary)
                    if let lastChecked = product.lastChecked {
                        Text(TurkishRelativeTime.string(from: lastChecked))
                    } else {
                        Text("Henüz kontrol edilmedi")
                    }
                    if product.reliability.level != .unknown && product.reliability.level != .high {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Circle()
                            .fill(product.reliability.level.color)
                            .frame(width: 5, height: 5)
                            .help(product.reliability.level.displayName)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary.opacity(0.85))
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

private struct DisplayEventGroup: Identifiable {
    let id: UUID
    let type: ProductEventType
    let latestDate: Date
    let count: Int
}

private struct TagFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var height: CGFloat = 0
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > width, currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            height = max(height, currentY + lineHeight)
        }

        return CGSize(width: width, height: max(height, lineHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX, currentX > bounds.minX {
                currentX = bounds.minX
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

private struct TagFlowView: View {
    let tags: [String]
    let onRemove: (String) -> Void

    var body: some View {
        TagFlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                HStack(spacing: 4) {
                    Text(tag)
                        .font(.caption.weight(.medium))
                    Button {
                        onRemove(tag)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.12), in: Capsule())
            }
        }
    }
}

private enum HistoryDisplayMode: String, CaseIterable, Identifiable {
    case stockSessions = "Stok Dönemleri"
    case allEvents = "Tüm Olaylar"

    var id: Self { self }
}

private struct ProductDetailView: View {
    @State private var isProductInformationExpanded = true
    @State private var isVariantStockExpanded = true
    @State private var isSmartTrackingExpanded = true
    @State private var isStockStatisticsExpanded = false
    @State private var isChangeHistoryExpanded = false
    @State private var isNotificationAndAutomationExpanded = false
    @State private var isOrganizationAndNotesExpanded = false
    @State private var isReliabilityAndDiagnosticExpanded = false
    @State private var isNotificationAuditExpanded = false
    @State private var copiedDiagnosticFeedback = false

    @State private var showingNewGroupAlert = false
    @State private var newGroupName = ""
    @State private var showingNewTagAlert = false
    @State private var newTagName = ""
    @State private var showingNoteAlert = false
    @State private var noteDraftText = ""
    @State private var historyDisplayMode: HistoryDisplayMode = .stockSessions
    @State private var selectedAnalyticsPeriod: StockAnalyticsPeriod = .sevenDays
    @State private var selectedVariantStateFilter: VariantAvailabilityState? = nil
    @AppStorage("adaptiveMonitoringEnabled") private var adaptiveMonitoringEnabled = false

    @ObservedObject private var orgStore = ProductOrganizationStore.shared
    @ObservedObject private var auditManager = NotificationAuditManager.shared

    let product: TrackedProduct
    let status: ProductStatus
    let storeConnectionStatus: String
    let storeConnectionError: String?
    let automaticCheckingEnabled: Bool
    let canDelete: Bool
    let canChangeInterval: Bool
    let onOpenProduct: () -> Void
    let onDelete: () -> Void
    let onIntervalChange: (Int) -> Void
    let onGroupChange: (String?) -> Void
    let onAddTag: (String) -> Void
    let onRemoveTag: (String) -> Void
    let onTogglePause: () -> Void
    let onTogglePriority: () -> Void
    let onUpdateNote: (String?) -> Void
    let onToggleMacOSNotification: () -> Void
    let onToggleEmailNotification: () -> Void
    let onNotificationProfileChange: (NotificationProfile) -> Void
    let onAutoOpenChange: (Bool?) -> Void
    let onTrackingRuleChange: (SmartTrackingRule) -> Void
    let onAlertConditionChange: (SmartAlertCondition) -> Void
    let onVerificationPreferenceChange: (RestockVerificationMode?) -> Void
    let onBurstPreferenceChange: (Bool?) -> Void

    private var stockAvailabilityLabel: String {
        switch product.effectiveAvailability {
        case true: return "Stokta"
        case false: return "Tükendi"
        case nil: return "Kontrol Bekliyor"
        }
    }

    private var stockAvailabilitySymbol: String {
        switch product.effectiveAvailability {
        case true: return "checkmark.circle.fill"
        case false: return "circle"
        case nil: return "minus.circle"
        }
    }

    private var stockAvailabilityColor: Color {
        switch product.effectiveAvailability {
        case true: return .green
        case false: return .secondary
        case nil: return .secondary
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Header: Product Title & Status
                    VStack(alignment: .leading, spacing: 8) {
                        Text(product.productName)
                            .font(.system(size: 20, weight: .bold))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .id(product.id)

                        HStack(spacing: 8) {
                            HStack(spacing: 5) {
                                Image(systemName: stockAvailabilitySymbol)
                                    .font(.system(size: 11, weight: .semibold))
                                Text(stockAvailabilityLabel)
                                    .font(.subheadline.weight(.semibold))
                            }
                            .foregroundStyle(stockAvailabilityColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(stockAvailabilityColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

                            Text("·")
                                .foregroundStyle(.tertiary)

                            Text(cleanVariantDescription)
                                .font(.callout)
                                .foregroundStyle(.secondary)

                            if let group = product.group, !group.isEmpty {
                                Text("·")
                                    .foregroundStyle(.tertiary)
                                Text(group)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                            }

                            if product.isPaused {
                                Text("·")
                                    .foregroundStyle(.tertiary)
                                Label("Takip duraklatıldı", systemImage: "pause.fill")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    // Action buttons
                    HStack(spacing: 10) {
                        Button(action: onOpenProduct) {
                            Label("Ürün Sayfasını Aç", systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .help("Ürünü varsayılan tarayıcıda aç (Return)")

                        Button(action: onTogglePause) {
                            Label(
                                product.isPaused ? "İzlemeye Devam Et" : "İzlemeyi Duraklat",
                                systemImage: product.isPaused ? "play.circle" : "pause.circle"
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .help(product.isPaused ? "İzlemeye devam et (Boşluk)" : "İzlemeyi duraklat (Boşluk)")

                        Menu {
                            Button(
                                product.isPriority ? "Önceliği Kaldır" : "Öncelikli Yap",
                                systemImage: product.isPriority ? "star.slash" : "star"
                            ) {
                                onTogglePriority()
                            }

                            Button("Ürün URL'sini Kopyala", systemImage: "doc.on.doc") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(product.productURL.absoluteString, forType: .string)
                            }

                            Button("Özel Not Düzenle...", systemImage: "square.and.pencil") {
                                noteDraftText = product.note ?? ""
                                showingNoteAlert = true
                            }

                            Divider()

                            Button("Ürünü Sil", systemImage: "trash", role: .destructive) {
                                onDelete()
                            }
                            .disabled(!canDelete)
                        } label: {
                            Label("Daha Fazla", systemImage: "ellipsis.circle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .help("Daha fazla işlem")
                    }

                    // Check Failure Warning (Clean, user-friendly separation)
                    if product.hasCheckFailure {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.orange)
                                .frame(width: 16, height: 16)
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Son stok kontrolü başarısız")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)

                                HStack(spacing: 6) {
                                    Text("Son bilinen durum: \(product.effectiveAvailability == true ? "Stokta" : (product.effectiveAvailability == false ? "Tükendi" : "Bilinmiyor"))")
                                    Text("·")
                                        .foregroundStyle(.tertiary)
                                    if let lastSuccess = product.lastSuccessfulCheckDate {
                                        Text("Son başarılı kontrol: \(TurkishRelativeTime.string(from: lastSuccess))")
                                    } else if let lastChecked = product.lastChecked {
                                        Text("Son kontrol: \(TurkishRelativeTime.string(from: lastChecked))")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)

                                Text("Şu anda mağazadan yeni veri alınamıyor. Son bilinen stok durumu korunuyor.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                if let error = product.lastCheckError {
                                    Text(error)
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                Button("Tanılama Detaylarını Göster") {
                                    withAnimation {
                                        isReliabilityAndDiagnosticExpanded = true
                                    }
                                }
                                .buttonStyle(.link)
                                .font(.caption)
                                .padding(.top, 2)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.2), lineWidth: 1))
                    }

                    if product.isBurstActive {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.orange)
                                .frame(width: 16, height: 16)
                                .padding(.top, 1)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Restock Burst Modu Etkin")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                if let expires = product.burstExpiresAt {
                                    Text("Yeni stok tespiti sonrası yüksek frekanslı izleme devrede (Kalan süre: \(TurkishRelativeTime.string(from: expires))).")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
                    }

                    Divider()

                    // 1. Temel Bilgiler Özeti
                    basicInfoCard(at: timeline.date)

                    // 2. Gruplanmış Nitelikler (Renk, Beden, SKU, Referans)
                    groupedAttributesCard

                    Divider()

                    // 3. Varyant Stokları (DisclosureSection)
                    DisclosureSection(
                        title: "Varyant Stokları (\(product.variantStockSummary.summaryText))",
                        isExpanded: $isVariantStockExpanded
                    ) {
                        variantStockContent
                    }

                    Divider()

                    // 4. Akıllı Takip ve Alarm Kuralı (DisclosureSection)
                    DisclosureSection(
                        title: "Akıllı Takip ve Alarm Kuralı",
                        isExpanded: $isSmartTrackingExpanded
                    ) {
                        smartTrackingCard
                    }

                    Divider()

                    // 5. Stok İstatistikleri (DisclosureSection)
                    DisclosureSection(
                        title: "Stok İstatistikleri",
                        isExpanded: $isStockStatisticsExpanded
                    ) {
                        stockStatisticsContent
                    }

                    Divider()

                    // 6. Değişiklik Geçmişi (DisclosureSection)
                    DisclosureSection(
                        title: "Değişiklik Geçmişi (\(product.events.count))",
                        isExpanded: $isChangeHistoryExpanded
                    ) {
                        historyContent
                    }

                    Divider()

                    // 7. Bildirimler ve Otomasyon (DisclosureSection)
                    DisclosureSection(
                        title: "Bildirimler ve Otomasyon",
                        isExpanded: $isNotificationAndAutomationExpanded
                    ) {
                        notificationAndAutomationCard
                    }

                    Divider()

                    // 8. Organizasyon ve Notlar (DisclosureSection)
                    DisclosureSection(
                        title: "Organizasyon ve Notlar",
                        isExpanded: $isOrganizationAndNotesExpanded
                    ) {
                        organizationAndNotesCard
                    }

                    Divider()

                    // 9. Kontrol Güvenilirliği ve Tanılama (DisclosureSection)
                    DisclosureSection(
                        title: "Kontrol Güvenilirliği ve Tanılama",
                        isExpanded: $isReliabilityAndDiagnosticExpanded
                    ) {
                        VStack(alignment: .leading, spacing: 14) {
                            reliabilitySummaryCard
                            diagnosticContent
                        }
                    }

                    Divider()

                    // 10. Bildirim Denetim Kayıtları (DisclosureSection)
                    DisclosureSection(
                        title: "Bildirim Denetim Kayıtları (\(auditManager.events(for: product.id).count))",
                        isExpanded: $isNotificationAuditExpanded
                    ) {
                        notificationAuditContent
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
            }
        }
        .onChange(of: product.id) { _, _ in
            isProductInformationExpanded = true
            isVariantStockExpanded = true
            isSmartTrackingExpanded = true
            isStockStatisticsExpanded = false
            isChangeHistoryExpanded = false
            isNotificationAndAutomationExpanded = false
            isOrganizationAndNotesExpanded = false
            isReliabilityAndDiagnosticExpanded = false
            isNotificationAuditExpanded = false
            copiedDiagnosticFeedback = false
            selectedAnalyticsPeriod = .sevenDays
        }
        .alert("Yeni Grup Oluştur", isPresented: $showingNewGroupAlert) {
            TextField("Grup adı", text: $newGroupName)
            Button("Oluştur") {
                let trimmed = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    _ = orgStore.createGroup(trimmed)
                    onGroupChange(trimmed)
                }
                newGroupName = ""
            }
            Button("Vazgeç", role: .cancel) {
                newGroupName = ""
            }
        }
        .alert("Yeni Etiket Ekle", isPresented: $showingNewTagAlert) {
            TextField("Etiket adı", text: $newTagName)
            Button("Ekle") {
                let trimmed = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    _ = orgStore.createTag(trimmed)
                    onAddTag(trimmed)
                }
                newTagName = ""
            }
            Button("Vazgeç", role: .cancel) {
                newTagName = ""
            }
        }
        .alert("Ürün Notu", isPresented: $showingNoteAlert) {
            TextField("Özel not...", text: $noteDraftText)
            Button("Kaydet") {
                let trimmed = noteDraftText.trimmingCharacters(in: .whitespacesAndNewlines)
                onUpdateNote(trimmed.isEmpty ? nil : trimmed)
                noteDraftText = ""
            }
            if product.note != nil {
                Button("Notu Sil", role: .destructive) {
                    onUpdateNote(nil)
                    noteDraftText = ""
                }
            }
            Button("Vazgeç", role: .cancel) {
                noteDraftText = ""
            }
        }
    }

    private var cleanVariantDescription: String {
        let desc = product.selectedVariant.displayDescription
        if desc.lowercased().hasPrefix("varyant:") {
            return desc.dropFirst(8).trimmingCharacters(in: .whitespaces)
        }
        return desc
    }

    private var latestStockChange: ProductEvent? {
        product.events
            .filter { event in
                switch event.type {
                case .stockArrived:
                    event.previousState == false && event.newState == true
                case .stockDepleted:
                    event.previousState == true && event.newState == false
                default:
                    false
                }
            }
            .max { $0.date < $1.date }
    }

    private var groupedEvents: [DisplayEventGroup] {
        let sorted = product.events.sorted { $0.date > $1.date }
        guard !sorted.isEmpty else { return [] }

        var groups: [DisplayEventGroup] = []
        for event in sorted {
            if let last = groups.last, last.type == event.type {
                groups[groups.count - 1] = DisplayEventGroup(
                    id: last.id,
                    type: last.type,
                    latestDate: last.latestDate,
                    count: last.count + 1
                )
            } else {
                groups.append(DisplayEventGroup(
                    id: event.id,
                    type: event.type,
                    latestDate: event.date,
                    count: 1
                ))
            }
        }
        return Array(groups.prefix(10))
    }

    private func nextCheckDescription(at now: Date) -> String {
        if status == .paused { return "Takip duraklatıldı" }
        if status == .checking { return "Kontrol ediliyor..." }
        guard automaticCheckingEnabled else { return "Otomatik kontrol kapalı" }
        guard product.lastChecked != nil, let nextCheckDate = product.nextCheckDate else {
            return "Henüz kontrol planlanmadı"
        }
        let seconds = Int(nextCheckDate.timeIntervalSince(now).rounded(.up))
        guard seconds > 0 else { return "Kontrol sırada" }
        if seconds < 60 { return "\(seconds) sn" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        return remainder == 0 ? "\(minutes) dk" : "\(minutes) dk \(remainder) sn"
    }

    private func basicInfoCard(at now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Temel Bilgiler")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                GridRow {
                    detailLabel("Takip Durumu")
                    HStack(spacing: 6) {
                        StatusBadge(status: status)
                        if product.isPaused {
                            Text("(Duraklatıldı)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                GridRow {
                    detailLabel("Mağaza / Sağlayıcı")
                    Text(storeName(for: product))
                        .font(.callout)
                }

                GridRow {
                    detailLabel("Son Kontrol")
                    if let lastChecked = product.lastChecked {
                        Text(TurkishRelativeTime.string(from: lastChecked))
                            .font(.callout)
                            .help(lastChecked.formatted(date: .long, time: .complete))
                    } else {
                        Text("Henüz kontrol yapılmadı")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                GridRow {
                    detailLabel("Sıradaki Kontrol")
                    Text(nextCheckDescription(at: now))
                        .font(.callout)
                        .foregroundStyle(status == .paused ? .secondary : .primary)
                }

                GridRow {
                    detailLabel("Son Stok Değişimi")
                    if let event = latestStockChange {
                        Text("\(TurkishRelativeTime.string(from: event.date)) · \(event.newState == true ? "Stok Geldi" : "Stok Tükendi")")
                            .font(.callout)
                            .help(event.date.formatted(date: .long, time: .complete))
                    } else {
                        Text("Henüz stok değişikliği yok")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                infoRow("Ürün Bağlantısı", product.productURL.absoluteString, isURL: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private var variantSizeString: String? {
        switch product.provider {
        case .hm:
            return product.hmMetadata?.sizeName ?? product.selectedVariant.options.first(where: { $0.name.localizedCaseInsensitiveContains("beden") || $0.name.localizedCaseInsensitiveContains("size") })?.value
        case .zara:
            return product.selectedVariant.options.first(where: { $0.name == "Beden" })?.value ?? product.selectedVariant.title
        case .bershka:
            return product.bershkaMetadata?.sizeName ?? product.selectedVariant.options.first(where: { $0.name.localizedCaseInsensitiveContains("beden") })?.value
        case .pullAndBear:
            return product.pullAndBearMetadata?.sizeName ?? product.selectedVariant.options.first(where: { $0.name.localizedCaseInsensitiveContains("beden") })?.value
        case .shopify:
            return product.selectedVariant.options.first(where: { $0.name.localizedCaseInsensitiveContains("beden") || $0.name.localizedCaseInsensitiveContains("size") })?.value ?? product.selectedVariant.title
        }
    }

    private var variantColorString: String? {
        switch product.provider {
        case .hm:
            return product.hmMetadata?.colorName ?? product.selectedVariant.options.first(where: { $0.name.localizedCaseInsensitiveContains("renk") || $0.name.localizedCaseInsensitiveContains("color") })?.value
        case .zara:
            return product.zaraMetadata?.colorName ?? product.selectedVariant.options.first(where: { $0.name.localizedCaseInsensitiveContains("renk") })?.value
        case .bershka:
            return product.bershkaMetadata?.colorName ?? product.selectedVariant.options.first(where: { $0.name.localizedCaseInsensitiveContains("renk") })?.value
        case .pullAndBear:
            return product.pullAndBearMetadata?.colorName ?? product.selectedVariant.options.first(where: { $0.name.localizedCaseInsensitiveContains("renk") })?.value
        case .shopify:
            return product.selectedVariant.options.first(where: { $0.name.localizedCaseInsensitiveContains("renk") || $0.name.localizedCaseInsensitiveContains("color") })?.value
        }
    }

    private var variantSKUString: String? {
        switch product.provider {
        case .hm:
            return product.hmMetadata?.articleID ?? product.hmMetadata?.variantID ?? product.selectedVariant.id
        case .zara:
            return product.zaraMetadata?.availabilitySKU ?? product.zaraMetadata?.colorProductID ?? product.selectedVariant.id
        case .bershka:
            return product.bershkaMetadata?.sku ?? product.bershkaMetadata?.partnumber ?? product.selectedVariant.id
        case .pullAndBear:
            return product.pullAndBearMetadata?.sku ?? product.pullAndBearMetadata?.colorReference ?? product.pullAndBearMetadata?.pageProductID ?? product.selectedVariant.id
        case .shopify:
            return product.selectedVariant.id
        }
    }

    private var groupedAttributesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Varyant ve Model Nitelikleri")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                let sizeVal = variantSizeString
                if let sizeVal, !sizeVal.isEmpty {
                    infoRow("Takip Edilen Beden", sizeVal)
                }

                let colorVal = variantColorString
                if let colorVal, !colorVal.isEmpty {
                    infoRow("Takip Edilen Renk", colorVal)
                }

                let skuVal = variantSKUString
                if let skuVal, !skuVal.isEmpty {
                    technicalRow("SKU / Referans", skuVal)
                }

                infoRow("Seçili Varyant", product.selectedVariant.displayDescription)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private var smartTrackingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Akıllı Takip ve Alarm Kuralı")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: product.trackingRule.symbol)
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 6) {
                detailLabel("Takip Modu")
                Picker("Takip Modu", selection: Binding(
                    get: { product.trackingRule },
                    set: { onTrackingRuleChange($0) }
                )) {
                    ForEach(SmartTrackingRule.allCases) { rule in
                        Label(rule.title, systemImage: rule.symbol).tag(rule)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                Text(product.trackingRule.preview(color: product.selectedColorName, size: product.selectedSizeName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                detailLabel("Alarm Koşulu")
                Picker("Alarm Koşulu", selection: Binding(
                    get: {
                        switch product.alertCondition {
                        case .anyMatching: return 0
                        case .minimumCount: return 1
                        }
                    },
                    set: { choice in
                        if choice == 0 {
                            onAlertConditionChange(.anyMatching)
                        } else {
                            onAlertConditionChange(.minimumCount(2))
                        }
                    }
                )) {
                    Text("Herhangi bir eşleşen varyant stokta olduğunda").tag(0)
                    Text("En az belirli sayıda varyant stokta olduğunda").tag(1)
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)

                if case .minimumCount(let count) = product.alertCondition {
                    HStack(spacing: 8) {
                        Text("Gereken minimum varyant adedi:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("", selection: Binding(
                            get: { count },
                            set: { onAlertConditionChange(.minimumCount($0)) }
                        )) {
                            ForEach(2...10, id: \.self) { n in
                                Text("\(n) varyant").tag(n)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                    }
                    .padding(.top, 2)
                }
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                GridRow {
                    detailLabel("Restock Doğrulama")
                    Picker("Doğrulama", selection: Binding(
                        get: { product.verificationPreference },
                        set: { onVerificationPreferenceChange($0) }
                    )) {
                        Text("Varsayılan (Genel Ayar)").tag(nil as RestockVerificationMode?)
                        Text("Kapalı (Anında Bildir)").tag(RestockVerificationMode.off as RestockVerificationMode?)
                        Text("1 kez onayla").tag(RestockVerificationMode.oneConfirmation as RestockVerificationMode?)
                        Text("2 kez onayla").tag(RestockVerificationMode.twoConfirmations as RestockVerificationMode?)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                }

                GridRow {
                    detailLabel("Restock Burst Modu")
                    Picker("Burst", selection: Binding(
                        get: { product.burstPreference },
                        set: { onBurstPreferenceChange($0) }
                    )) {
                        Text("Varsayılan (Genel Ayar)").tag(nil as Bool?)
                        Text("Etkin").tag(true as Bool?)
                        Text("Devre Dışı").tag(false as Bool?)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private var checkMethodDescription: String {
        switch product.provider {
        case .shopify: "Shopify Ürün API (/products.js)"
        case .zara: "Zara Stok API & Oturum"
        case .bershka: "Bershka Nuxt/Pinia Veri Modeli"
        case .pullAndBear: "Pull&Bear DOM & Beden Seçici"
        case .hm: "H&M Online Stok API & SSR Verisi"
        }
    }

    private func reliabilitySymbol(for level: ProductReliabilityLevel) -> String {
        switch level {
        case .high: "checkmark.seal.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private func reliabilityColor(for level: ProductReliabilityLevel) -> Color {
        switch level {
        case .high: .green
        case .warning: .orange
        case .unknown: .secondary
        }
    }

    private var reliabilitySummaryCard: some View {
        let rel = product.reliability
        let past24h = Date().addingTimeInterval(-24 * 3600)
        let events24h = product.events.filter { $0.date >= past24h }
        let checkFailures24h = events24h.filter { $0.type == .checkFailed }.count
        let stockArrivals24h = events24h.filter { $0.type == .stockArrived }.count
        let stockDepletions24h = events24h.filter { $0.type == .stockDepleted }.count

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Kontrol Güvenilirliği")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                HStack(spacing: 5) {
                    Circle()
                        .fill(reliabilityColor(for: rel.level))
                        .frame(width: 8, height: 8)
                    Text(rel.level.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(reliabilityColor(for: rel.level))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(reliabilityColor(for: rel.level).opacity(0.12), in: Capsule())
            }

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                GridRow {
                    detailLabel("Son Kontrol Yöntemi")
                    Text(checkMethodDescription)
                        .font(.callout)
                }

                GridRow {
                    detailLabel("Son Başarılı Kontrol")
                    if let lastSuccess = product.latestDiagnostic?.lastSuccessfulCheckDate ?? (product.lastCheckError == nil ? product.lastChecked : nil) {
                        Text(TurkishRelativeTime.string(from: lastSuccess))
                            .font(.callout)
                            .help(lastSuccess.formatted(date: .long, time: .complete))
                    } else {
                        Text("Henüz başarılı kontrol yok")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMsg = product.lastCheckError ?? (product.status == .error ? product.latestDiagnostic?.userMessage : nil) {
                    GridRow(alignment: .top) {
                        detailLabel("Son Hata")
                        Text(errorMsg)
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                GridRow {
                    detailLabel("Son 24 Saat")
                    if events24h.isEmpty {
                        Text("Kayıtlı olay yok (kontroller stabil)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 6) {
                            if checkFailures24h > 0 {
                                Text("\(checkFailures24h) hata kaydı")
                                    .foregroundStyle(.orange)
                            } else {
                                Text("0 hata")
                                    .foregroundStyle(.green)
                            }
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text("\(stockArrivals24h + stockDepletions24h) stok değişimi")
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }

                GridRow {
                    detailLabel("Ardışık Değişmeyen")
                    Text("\(product.consecutiveUnchangedChecks) kontrol")
                        .font(.callout)
                }

                if product.consecutiveFailureChecks > 0 {
                    GridRow {
                        detailLabel("Ardışık Hatalar")
                        Text("\(product.consecutiveFailureChecks)")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }

                GridRow(alignment: .top) {
                    detailLabel("Değerlendirme")
                    Text(rel.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private var notificationAndAutomationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Bildirimler ve Otomasyon")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                GridRow {
                    detailLabel("macOS Bildirimleri")
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { product.isMacOSNotificationEnabled },
                            set: { _ in onToggleMacOSNotification() }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        Text(product.isMacOSNotificationEnabled ? "Açık" : "Kapalı")
                            .font(.callout)
                            .foregroundStyle(product.isMacOSNotificationEnabled ? .primary : .secondary)
                    }
                }

                GridRow {
                    detailLabel("E-posta Bildirimi")
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { product.isEmailNotificationEnabled },
                            set: { _ in onToggleEmailNotification() }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        Text(product.isEmailNotificationEnabled ? "Açık" : "Kapalı")
                            .font(.callout)
                            .foregroundStyle(product.isEmailNotificationEnabled ? .primary : .secondary)
                    }
                }

                GridRow {
                    detailLabel("Bildirim Profili")
                    Picker("", selection: Binding(
                        get: { product.notificationProfile },
                        set: { onNotificationProfileChange($0) }
                    )) {
                        ForEach(NotificationProfile.allCases, id: \.self) { profile in
                            Text(profile.shortTitle).tag(profile)
                        }
                    }
                    .labelsHidden()
                }

                GridRow {
                    detailLabel("Tarama Aralığı")
                    HStack(spacing: 8) {
                        Menu {
                            ForEach(ProductCheckInterval.minutes, id: \.self) { minutes in
                                Button(ProductCheckInterval.title(for: minutes)) {
                                    onIntervalChange(minutes)
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(ProductCheckInterval.title(for: product.checkIntervalMinutes))
                                    .font(.callout)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .disabled(!canChangeInterval)

                        if adaptiveMonitoringEnabled {
                            let effective = AdaptiveMonitoringPolicy.effectiveIntervalMinutes(
                                baseMinutes: product.checkIntervalMinutes,
                                status: product.status,
                                consecutiveUnchangedChecks: product.consecutiveUnchangedChecks,
                                consecutiveFailureChecks: product.consecutiveFailureChecks,
                                isEnabled: true
                            )
                            if effective != product.checkIntervalMinutes {
                                Text("(Etkin: \(ProductCheckInterval.shortTitle(for: effective)))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .help(AdaptiveMonitoringPolicy.reason(
                                        baseMinutes: product.checkIntervalMinutes,
                                        effectiveMinutes: effective,
                                        status: product.status,
                                        consecutiveUnchangedChecks: product.consecutiveUnchangedChecks,
                                        consecutiveFailureChecks: product.consecutiveFailureChecks,
                                        isEnabled: true
                                    ) ?? "Akıllı kontrol aralığı")
                            }
                        }
                    }
                }

                GridRow {
                    detailLabel("Stokta Otomatik Aç")
                    Picker("", selection: Binding(
                        get: { product.autoOpenOnRestock },
                        set: { onAutoOpenChange($0) }
                    )) {
                        Text("Varsayılan (Genel Ayar)").tag(nil as Bool?)
                        Text("Her Zaman Aç").tag(true as Bool?)
                        Text("Asla Açma").tag(false as Bool?)
                    }
                    .labelsHidden()
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private var organizationAndNotesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Organizasyon ve Notlar")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                GridRow {
                    detailLabel("Grup")
                    HStack(spacing: 8) {
                        Menu {
                            Button("Grup Yok") {
                                onGroupChange(nil)
                            }
                            if !orgStore.availableGroups.isEmpty {
                                Divider()
                                ForEach(orgStore.availableGroups, id: \.self) { group in
                                    Button {
                                        onGroupChange(group)
                                    } label: {
                                        HStack {
                                            Text(group)
                                            if product.group == group {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            }
                            Divider()
                            Button("Yeni Grup Oluştur...") {
                                newGroupName = ""
                                showingNewGroupAlert = true
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(product.group ?? "Grup Yok")
                                    .font(.callout)
                                    .foregroundStyle(product.group == nil ? .secondary : .primary)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }

                GridRow(alignment: .top) {
                    detailLabel("Etiketler")
                    VStack(alignment: .leading, spacing: 6) {
                        if !product.tags.isEmpty {
                            TagFlowView(tags: product.tags) { tag in
                                onRemoveTag(tag)
                            }
                        }
                        HStack(spacing: 6) {
                            if !orgStore.availableTags.filter({ !product.tags.contains($0) }).isEmpty {
                                Menu {
                                    ForEach(orgStore.availableTags.filter({ !product.tags.contains($0) }), id: \.self) { tag in
                                        Button(tag) {
                                            onAddTag(tag)
                                        }
                                    }
                                } label: {
                                    Label("Mevcut Etiket", systemImage: "plus")
                                        .font(.caption)
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                            }
                            Button {
                                newTagName = ""
                                showingNewTagAlert = true
                            } label: {
                                Label("Yeni Etiket", systemImage: "tag")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                GridRow(alignment: .top) {
                    detailLabel("Özel Not")
                    VStack(alignment: .leading, spacing: 6) {
                        if let note = product.note, !note.isEmpty {
                            Text(note)
                                .font(.callout)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

                            HStack(spacing: 8) {
                                Button("Düzenle") {
                                    noteDraftText = note
                                    showingNoteAlert = true
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)

                                Button("Sil", role: .destructive) {
                                    onUpdateNote(nil)
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                            }
                        } else {
                            Button("Not Ekle...") {
                                noteDraftText = ""
                                showingNoteAlert = true
                            }
                            .buttonStyle(.borderless)
                            .font(.callout)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private func variantFilterPill(title: String, count: Int, state: VariantAvailabilityState?) -> some View {
        let isSelected = selectedVariantStateFilter == state
        return Button {
            selectedVariantStateFilter = state
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                Text("(\(count))")
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var variantStockContent: some View {
        let snapshots = product.currentVariantSnapshots
        let summary = product.variantStockSummary

        VStack(alignment: .leading, spacing: 14) {
            // Summary Header Badge Row
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(summary.inStockCount > 0 ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text("\(summary.inStockCount) / \(summary.totalCount) stokta")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                }

                if summary.outOfStockCount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                        Text("\(summary.outOfStockCount) tükendi")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if summary.unknownCount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "questionmark.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(summary.unknownCount) bilinmiyor")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if let lastCheck = summary.lastChecked {
                    Text("Son kontrol: \(TurkishRelativeTime.string(from: lastCheck))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(lastCheck.formatted(date: .long, time: .complete))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

            // Filter Pills Row
            HStack(spacing: 6) {
                variantFilterPill(title: "Tümü", count: snapshots.count, state: nil)
                variantFilterPill(title: "Stokta", count: summary.inStockCount, state: .inStock)
                variantFilterPill(title: "Tükendi", count: summary.outOfStockCount, state: .outOfStock)
                if summary.unknownCount > 0 {
                    variantFilterPill(title: "Bilinmiyor", count: summary.unknownCount, state: .unknown)
                }
            }

            let filteredSnapshots: [VariantStockSnapshot] = {
                guard let filter = selectedVariantStateFilter else { return snapshots }
                return snapshots.filter { $0.state == filter }
            }()

            if filteredSnapshots.isEmpty {
                Text("Seçilen filtreye uygun varyant bulunamadı.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                variantBreakdownView(snapshots: filteredSnapshots)
            }
        }
    }

    private struct DimensionAnalysis {
        let primaryDim: String?
        let primaryValues: [String]
        let isMultiDimensional: Bool
    }

    private func analyzeDimensions(snapshots: [VariantStockSnapshot]) -> DimensionAnalysis {
        var dimensionMap: [String: [String]] = [:]
        var dimensionOrder: [String] = []

        for s in snapshots {
            for opt in s.options {
                let name = opt.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let val = opt.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !val.isEmpty else { continue }
                if dimensionMap[name] == nil {
                    dimensionMap[name] = []
                    dimensionOrder.append(name)
                }
                if let vals = dimensionMap[name], !vals.contains(val) {
                    dimensionMap[name]?.append(val)
                }
            }
        }

        let multiValueDims = dimensionOrder.filter { (dimensionMap[$0]?.count ?? 0) > 1 }
        if multiValueDims.count >= 2 {
            let primaryDim = multiValueDims[0]
            let primaryValues = dimensionMap[primaryDim] ?? []
            return DimensionAnalysis(primaryDim: primaryDim, primaryValues: primaryValues, isMultiDimensional: true)
        } else {
            return DimensionAnalysis(primaryDim: nil, primaryValues: [], isMultiDimensional: false)
        }
    }

    @ViewBuilder
    private func variantBreakdownView(snapshots: [VariantStockSnapshot]) -> some View {
        let analysis = analyzeDimensions(snapshots: snapshots)
        if analysis.isMultiDimensional, let primaryDim = analysis.primaryDim {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(analysis.primaryValues, id: \.self) { pVal in
                    let matchingVariants = snapshots.filter { $0.optionValue(for: primaryDim) == pVal }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(primaryDim): \(pVal)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)

                        TagFlowLayout(spacing: 6) {
                            ForEach(matchingVariants) { variant in
                                variantPill(variant: variant, primaryDimToOmit: primaryDim)
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(snapshots) { variant in
                    variantRow(variant: variant)
                }
            }
        }
    }

    private func isVariantTracked(_ variant: VariantStockSnapshot) -> Bool {
        if variant.id == product.selectedVariant.id { return true }
        if product.provider == .pullAndBear,
           let meta = product.pullAndBearMetadata {
            if let metaSku = meta.sku, metaSku == variant.id { return true }
            let sizeMatch = variant.optionValue(for: "Beden")?.caseInsensitiveCompare(meta.sizeName) == .orderedSame
            let colorMatch = variant.optionValue(for: "Renk")?.caseInsensitiveCompare(meta.colorName) == .orderedSame
            let hasColorOption = !variant.options.filter { $0.name.caseInsensitiveCompare("Renk") == .orderedSame }.isEmpty
            return sizeMatch && (colorMatch || !hasColorOption)
        }
        return false
    }

    private func variantPill(variant: VariantStockSnapshot, primaryDimToOmit: String?) -> some View {
        let isTracked = isVariantTracked(variant)
        let displayLabel: String = {
            if let primaryDimToOmit {
                let remaining = variant.options.filter { $0.name.caseInsensitiveCompare(primaryDimToOmit) != .orderedSame }
                if !remaining.isEmpty {
                    return remaining.map(\.value).joined(separator: " · ")
                }
            }
            return variant.displayTitle
        }()

        return HStack(spacing: 6) {
            Image(systemName: variant.state.symbol)
                .font(.caption2)
                .foregroundStyle(variant.state.color)

            Text(displayLabel)
                .font(.caption.weight(isTracked ? .semibold : .regular))
                .foregroundStyle(.primary)

            Text(variant.state.title)
                .font(.caption2)
                .foregroundStyle(variant.state.color)

            if isTracked {
                Text("Takip Edilen")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 3))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            isTracked ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isTracked ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
    }

    private func variantRow(variant: VariantStockSnapshot) -> some View {
        let isTracked = isVariantTracked(variant)

        return HStack(spacing: 8) {
            Text(variant.displayTitle)
                .font(.callout.weight(isTracked ? .medium : .regular))
                .foregroundStyle(.primary)

            if isTracked {
                Text("Takip Edilen")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            }

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: variant.state.symbol)
                    .font(.caption)
                    .foregroundStyle(variant.state.color)
                Text(variant.state.title)
                    .font(.callout)
                    .foregroundStyle(variant.state.color)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            isTracked ? Color.accentColor.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isTracked ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
    }

    @ViewBuilder
    private var stockStatisticsContent: some View {
        let stats = product.stockStatistics
        let metrics = product.periodMetrics(for: selectedAnalyticsPeriod)

        VStack(alignment: .leading, spacing: 14) {
            Picker("Dönem", selection: $selectedAnalyticsPeriod) {
                ForEach(StockAnalyticsPeriod.allCases) { period in
                    Text(period.title).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if !stats.hasStockHistory || !metrics.hasSufficientData {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Yeterli geçmiş verisi yok")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("Bu ürün için henüz yeterli stok değişikliği kaydedilmedi.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                    GridRow {
                        detailLabel("Mevcut durum")
                        if metrics.isCurrentlyInStock {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 6, height: 6)
                                Text("Stokta")
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(.green)
                            }
                        } else {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(Color.secondary)
                                    .frame(width: 6, height: 6)
                                Text("Stok dışı")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    GridRow {
                        detailLabel("Restock")
                        Text("\(metrics.restockCount)")
                            .font(.callout.weight(.medium))
                    }

                    GridRow {
                        detailLabel("Toplam stokta")
                        Text(metrics.formattedTotalDuration)
                            .font(.callout)
                    }

                    GridRow {
                        detailLabel("Ortalama stokta kalma")
                        if let avg = metrics.formattedAverageDuration {
                            Text(avg)
                                .font(.callout)
                        } else if metrics.isCurrentlyInStock && metrics.ongoingInterval != nil {
                            Text("Devam ediyor")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("—")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    GridRow {
                        detailLabel("Son restock")
                        if let last = metrics.lastRestockDate {
                            Text(TurkishRelativeTime.string(from: last))
                                .font(.callout)
                                .help(last.formatted(date: .long, time: .complete))
                        } else {
                            Text("Bu dönemde restock yok")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    GridRow {
                        detailLabel("Veri aralığı")
                        Text(metrics.dataCoverageDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if metrics.completedIntervals.count >= 2,
                       let minDuration = metrics.completedIntervals.compactMap(\.duration).min(),
                       let maxDuration = metrics.completedIntervals.compactMap(\.duration).max() {
                        GridRow {
                            detailLabel("En uzun stokta kalma")
                            Text(StockDurationFormatter.format(seconds: maxDuration))
                                .font(.callout)
                        }
                        GridRow {
                            detailLabel("En kısa stokta kalma")
                            Text(StockDurationFormatter.format(seconds: minDuration))
                                .font(.callout)
                        }
                    }
                }
            }
        }
    }

    private struct DisplayStockSession: Identifiable {
        let id: UUID
        let startDate: Date
        let endDate: Date?
        let isOngoing: Bool
        let duration: TimeInterval?
    }

    private var stockSessions: [DisplayStockSession] {
        var sessions: [DisplayStockSession] = []
        let stats = product.stockStatistics
        if let ongoing = stats.ongoingInterval {
            sessions.append(DisplayStockSession(
                id: ongoing.id,
                startDate: ongoing.startDate,
                endDate: nil,
                isOngoing: true,
                duration: nil
            ))
        }
        for interval in stats.completedIntervals.reversed() {
            sessions.append(DisplayStockSession(
                id: interval.id,
                startDate: interval.startDate,
                endDate: interval.endDate,
                isOngoing: false,
                duration: interval.duration
            ))
        }
        return sessions
    }

    @ViewBuilder
    private var historyContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $historyDisplayMode) {
                ForEach(HistoryDisplayMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch historyDisplayMode {
            case .stockSessions:
                if stockSessions.isEmpty {
                    Text("Henüz stok dönemi kaydedilmedi.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(stockSessions) { session in
                            HStack(alignment: .top, spacing: 10) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 8, height: 8)
                                    .padding(.top, 5)

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text("Stokta")
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(.green)

                                        if session.isOngoing {
                                            Text("· Devam ediyor")
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(.primary)
                                        } else if let duration = session.duration {
                                            Text("· \(StockDurationFormatter.format(seconds: duration))")
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    HStack(spacing: 4) {
                                        Text(session.startDate.formatted(date: .abbreviated, time: .shortened))
                                        Text("→")
                                        if let end = session.endDate {
                                            Text(end.formatted(date: .omitted, time: .shortened))
                                        } else {
                                            Text("Şimdi")
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .help(session.startDate.formatted(date: .long, time: .complete))
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Stokta, \(session.startDate.formatted(date: .abbreviated, time: .shortened)) ile \(session.endDate?.formatted(date: .omitted, time: .shortened) ?? "devam ediyor")")
                        }
                    }
                }
            case .allEvents:
                if groupedEvents.isEmpty {
                    Text("Henüz bir değişiklik yok")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(groupedEvents) { group in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: group.type.symbol)
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundStyle(group.type.color)
                                    .frame(width: 16, height: 16)
                                    .padding(.top, 1)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 5) {
                                        Text(group.type.title)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(.primary)
                                        if group.count > 1 {
                                            Text("(\(group.count) kez)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Text(TurkishRelativeTime.string(from: group.latestDate))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .help(group.latestDate.formatted(date: .long, time: .complete))
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(group.type.title)\(group.count > 1 ? ", \(group.count) kez" : ""), \(TurkishRelativeTime.string(from: group.latestDate))")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var diagnosticContent: some View {
        if let diag = product.latestDiagnostic {
            VStack(alignment: .leading, spacing: 14) {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                    GridRow {
                        detailLabel("Sağlayıcı")
                        Text(diag.providerName)
                            .font(.callout)
                    }
                    GridRow {
                        detailLabel("Checker")
                        Text(diag.checkerName)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    GridRow {
                        detailLabel("Son kontrol")
                        Text(diag.completedAt.formatted(date: .abbreviated, time: .standard))
                            .font(.callout)
                    }
                    GridRow {
                        detailLabel("Kontrol süresi")
                        Text(diag.formattedDuration)
                            .font(.callout)
                    }
                    GridRow {
                        detailLabel("Sonuç")
                        HStack(spacing: 6) {
                            Image(systemName: diag.outcome.symbol)
                                .foregroundStyle(diag.outcome.color)
                                .font(.callout)
                            Text(diag.outcome.title)
                                .font(.callout.weight(.medium))
                        }
                    }
                    GridRow {
                        detailLabel("Stok durumu")
                        if let stock = diag.stockResult {
                            Text(stock ? "Stokta" : "Stokta değil")
                                .font(.callout)
                                .foregroundStyle(stock ? Color.green : Color.red)
                        } else {
                            Text("Bilinmiyor")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    GridRow {
                        detailLabel("Ağ durumu")
                        Text(diag.networkStatus)
                            .font(.callout)
                    }
                    if let category = diag.errorCategory, category != "Yok" {
                        GridRow {
                            detailLabel("Hata türü")
                            Text(category)
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                    }
                    GridRow {
                        detailLabel("Açıklama")
                        Text(diag.userMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let tech = diag.technicalDetail, !tech.isEmpty {
                        GridRow {
                            detailLabel("Teknik detay")
                            Text(tech)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    GridRow {
                        detailLabel("Son başarılı kontrol")
                        if let lastSuccess = diag.lastSuccessfulCheckDate {
                            Text("\(TurkishRelativeTime.string(from: lastSuccess)) (\(lastSuccess.formatted(date: .abbreviated, time: .shortened)))")
                                .font(.callout)
                        } else {
                            Text("Kayıt yok")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .textSelection(.enabled)

                Button(action: copyDiagnosticReport) {
                    Label(copiedDiagnosticFeedback ? "Kopyalandı" : "Tanılama Bilgilerini Kopyala",
                          systemImage: copiedDiagnosticFeedback ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 2)
            }
        } else {
            Text("Henüz tanılama bilgisi yok. Ürün kontrol edildiğinde burada detaylı tanılama raporu görünecektir.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func copyDiagnosticReport() {
        guard let diag = product.latestDiagnostic else { return }
        var lines = [
            "--- StockPing Tanılama Raporu ---",
            "Ürün: \(product.productName)",
            "Sağlayıcı: \(diag.providerName)",
            "Checker: \(diag.checkerName)",
            "Son Kontrol: \(diag.completedAt.formatted(date: .long, time: .standard))",
            "Kontrol Süresi: \(diag.formattedDuration)",
            "Sonuç: \(diag.outcome.title)",
            "Stok Durumu: \(diag.stockResult == true ? "Stokta" : (diag.stockResult == false ? "Stokta değil" : "Bilinmiyor"))",
            "Ağ Durumu: \(diag.networkStatus)"
        ]
        if let category = diag.errorCategory, category != "Yok" {
            lines.append("Hata Türü: \(category)")
        }
        lines.append("Açıklama: \(diag.userMessage)")
        if let tech = diag.technicalDetail, !tech.isEmpty {
            lines.append("Teknik Detay: \(tech)")
        }
        if let lastSuccess = diag.lastSuccessfulCheckDate {
            lines.append("Son Başarılı Kontrol: \(lastSuccess.formatted(date: .long, time: .standard))")
        } else {
            lines.append("Son Başarılı Kontrol: Kayıt yok")
        }
        lines.append("Ürün URL: \(product.productURL.absoluteString)")

        let report = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        copiedDiagnosticFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copiedDiagnosticFeedback = false
        }
    }

    @ViewBuilder
    private var notificationAuditContent: some View {
        let events = auditManager.events(for: product.id)
        if events.isEmpty {
            Text("Henüz bildirim kaydı bulunmuyor.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(events) { event in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: event.channel.symbol)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.primary)
                            .frame(width: 16, height: 16)
                            .padding(.top, 1)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(event.channel.title)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)

                                HStack(spacing: 4) {
                                    Image(systemName: event.status.symbol)
                                        .font(.caption2)
                                    Text(event.status.title)
                                        .font(.caption.weight(.medium))
                                }
                                .foregroundStyle(event.status.color)
                            }

                            if let message = event.message, !message.isEmpty {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Text(TurkishRelativeTime.string(from: event.date))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .help(event.date.formatted(date: .long, time: .complete))
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(event.channel.title), \(event.status.title), \(event.message ?? ""), \(TurkishRelativeTime.string(from: event.date))")
                }
            }
        }
    }

    @ViewBuilder
    private var productInformation: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
            infoRow("URL", product.productURL.absoluteString, isURL: true)
            infoRow("Varyant", product.selectedVariant.displayDescription)

            switch product.provider {
            case .hm:
                if let metadata = product.hmMetadata {
                    if let color = metadata.colorName, !color.isEmpty {
                        infoRow("Renk", color)
                    }
                    if let size = metadata.sizeName, !size.isEmpty {
                        infoRow("Beden", size)
                    }
                    technicalRow("Article ID", metadata.articleID)
                    if let variantID = metadata.variantID {
                        technicalRow("Variant ID", variantID)
                    }
                }
            case .shopify:
                technicalRow("Variant ID", product.selectedVariant.id)
            case .zara:
                if let metadata = product.zaraMetadata {
                    infoRow("Renk", metadata.colorName)
                    technicalRow("Color ID", metadata.colorID)
                    technicalRow("Color Product ID", metadata.colorProductID)
                    infoRow("Beden", product.selectedVariant.options.first(where: { $0.name == "Beden" })?.value ?? product.selectedVariant.title)
                    technicalRow("Availability SKU", metadata.availabilitySKU)
                    if let sizeID = metadata.equivalentSizeID { technicalRow("Equivalent size", sizeID) }
                }
            case .bershka:
                if let metadata = product.bershkaMetadata {
                    infoRow("Renk", metadata.colorName)
                    technicalRow("Color ID", metadata.colorID)
                    infoRow("Beden", metadata.sizeName)
                    technicalRow("SKU", metadata.sku)
                    if let partnumber = metadata.partnumber { technicalRow("Part number", partnumber) }
                    if let mastersSizeID = metadata.mastersSizeID { technicalRow("Master size ID", mastersSizeID) }
                }
            case .pullAndBear:
                if let metadata = product.pullAndBearMetadata {
                    infoRow("Renk", metadata.colorName)
                    if let colorParameter = metadata.colorParameter { technicalRow("cS", colorParameter) }
                    infoRow("Beden", metadata.sizeName)
                    if let colorReference = metadata.colorReference { technicalRow("Renk referansı", colorReference) }
                    if let pageProductID = metadata.pageProductID { technicalRow("Ürün ID", pageProductID) }
                }
            }
        }
        .textSelection(.enabled)
    }

    private func detailLabel(_ title: String) -> some View {
        Text(title)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(width: 135, alignment: .leading)
            .lineLimit(1)
    }

    private func infoRow(_ title: String, _ value: String, isURL: Bool = false) -> some View {
        GridRow {
            detailLabel(title)
            if isURL {
                HStack(spacing: 6) {
                    Text(value)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(value, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("URL'yi kopyala")
                }
            } else {
                Text(value)
                    .font(.callout)
            }
        }
    }

    private func technicalRow(_ title: String, _ value: String) -> some View {
        GridRow {
            detailLabel(title)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func storeName(for product: TrackedProduct) -> String {
        switch product.provider {
        case .zara: "Zara Türkiye"
        case .bershka: "Bershka Türkiye"
        case .pullAndBear: "Pull&Bear Türkiye"
        case .hm: "H&M Türkiye"
        case .shopify: product.productURL.host() ?? "Shopify mağazası"
        }
    }
}

private struct DisclosureSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content()
            }
        }
    }
}

private struct GlobalMonitoringStatusBar: View {
    let automaticCheckingEnabled: Bool
    let isCheckSequenceRunning: Bool
    let activeProductCount: Int
    let totalProductCount: Int
    let nextCheckDate: Date?
    let powerMode: MonitoringPowerMode
    let networkStatus: NetworkReachabilityMonitor.Status
    let isGlobalMonitoringPaused: Bool
    let onToggleGlobalPause: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            ViewThatFits(in: .horizontal) {
                barContent(at: timeline.date, isCompact: false)
                barContent(at: timeline.date, isCompact: true)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .background(.bar)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilitySummary(at: timeline.date))
        }
    }

    @ViewBuilder
    private func barContent(at now: Date, isCompact: Bool) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                statusIndicator
                statusTitleView(isCompact: isCompact)
            }

            Spacer(minLength: 8)

            HStack(spacing: 10) {
                if networkStatus == .unavailable {
                    HStack(spacing: 5) {
                        Image(systemName: "wifi.slash")
                            .foregroundStyle(.secondary)
                        Text(isCompact ? "Ağ yok" : "Ağ bağlantısı bekleniyor")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .font(.caption)
                } else if networkStatus == .recovering {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.secondary)
                        Text(isCompact ? "Hazırlanıyor…" : "Ağ kontrol ediliyor")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .font(.caption)
                } else if !isGlobalMonitoringPaused && !isCheckSequenceRunning && automaticCheckingEnabled && activeProductCount > 0 {
                    HStack(spacing: 5) {
                        Image(systemName: "clock")
                            .foregroundStyle(.secondary)
                        Text(isCompact ? countdownString(at: now) : "Sonraki kontrol: \(countdownString(at: now))")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .font(.caption)
                }

                Button(action: onToggleGlobalPause) {
                    HStack(spacing: 4) {
                        Image(systemName: isGlobalMonitoringPaused ? "play.fill" : "pause.fill")
                            .font(.caption2)
                        Text(isGlobalMonitoringPaused ? "Devam Ettir" : "Duraklat")
                            .font(.caption.weight(.medium))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(isGlobalMonitoringPaused ? "Otomatik taramaları devam ettir" : "Tüm otomatik taramaları duraklat")

                powerBadge(isCompact: isCompact)
            }
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if networkStatus == .recovering {
            ProgressView()
                .controlSize(.small)
        } else if networkStatus == .unavailable {
            Image(systemName: "wifi.slash")
                .foregroundStyle(.orange)
                .imageScale(.medium)
        } else if isCheckSequenceRunning {
            ProgressView()
                .controlSize(.small)
        } else if isGlobalMonitoringPaused {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.orange)
                .imageScale(.medium)
        } else if !automaticCheckingEnabled {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.orange)
                .imageScale(.medium)
        } else if activeProductCount == 0 {
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.secondary)
                .imageScale(.medium)
        } else {
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
        }
    }

    @ViewBuilder
    private func statusTitleView(isCompact: Bool) -> some View {
        if networkStatus == .recovering {
            HStack(spacing: 6) {
                Text("Bağlantı kuruluyor…")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .fixedSize()
                if !isCompact {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text("Ağ kontrol ediliyor")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        } else if networkStatus == .unavailable {
            HStack(spacing: 6) {
                Text("İzleme beklemede")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .fixedSize()
                Text("·")
                    .foregroundStyle(.secondary)
                Text(isCompact ? "Ağ bekleniyor" : "Ağ bağlantısı bekleniyor")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        } else if isCheckSequenceRunning {
            HStack(spacing: 6) {
                Text("Kontrol ediliyor…")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .fixedSize()
                if activeProductCount > 0 {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(isCompact ? "\(activeProductCount) aktif" : "\(activeProductCount) aktif ürün")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        } else if isGlobalMonitoringPaused {
            HStack(spacing: 6) {
                Text("Taramalar Duraklatıldı")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .fixedSize()
                if !isCompact {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text("Otomatik kontroller durduruldu")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        } else if !automaticCheckingEnabled {
            HStack(spacing: 6) {
                Text("İzleme duraklatıldı")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .fixedSize()
                if !isCompact {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text("Otomatik kontrol kapalı")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        } else if activeProductCount == 0 {
            HStack(spacing: 6) {
                Text(isCompact ? "Aktif ürün yok" : "İzlenecek aktif ürün yok")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .fixedSize()
                if !isCompact && totalProductCount > 0 {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text("Tüm ürünler duraklatıldı")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        } else {
            HStack(spacing: 6) {
                Text("İzleme Aktif")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .fixedSize()
                Text("·")
                    .foregroundStyle(.secondary)
                Text(isCompact ? "\(activeProductCount) ürün" : "\(activeProductCount) ürün takip ediliyor")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    private var isPowerProtectionActive: Bool {
        !isGlobalMonitoringPaused && ((automaticCheckingEnabled && activeProductCount > 0) || isCheckSequenceRunning)
    }

    @ViewBuilder
    private func powerBadge(isCompact: Bool) -> some View {
        if SleepPreventionManager.shared.isClosedDisplayActive {
            HStack(spacing: 5) {
                Image(systemName: "laptopcomputer.and.arrow.down")
                    .foregroundStyle(.purple)
                Text(isCompact ? "Kapak Kapalı" : "Kapak Kapalı Takip")
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.purple.opacity(0.12), in: Capsule())
            .help("Kapak kapalı takip modu devrede (pmset disablesleep)")
        } else if isPowerProtectionActive {
            HStack(spacing: 5) {
                Image(systemName: powerSymbol)
                    .foregroundStyle(powerColor)
                Text(powerText(isCompact: isCompact))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.12), in: Capsule())
            .help(powerHelp)
        } else {
            HStack(spacing: 5) {
                Image(systemName: "powersleep")
                    .foregroundStyle(.secondary)
                Text(isCompact ? "Uyku: pasif" : "Uyku engelleme pasif")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.08), in: Capsule())
            .help("İzleme aktif olmadığında Mac uyku koruması devrede değildir.")
        }
    }

    private var powerSymbol: String {
        switch powerMode {
        case .normal: "leaf"
        case .keepMacAndDisplayAwake: "sun.max.fill"
        case .allowDisplaySleepKeepMacAwake: "display"
        }
    }

    private var powerColor: Color {
        switch powerMode {
        case .normal: .secondary
        case .keepMacAndDisplayAwake: .orange
        case .allowDisplaySleepKeepMacAwake: .accentColor
        }
    }

    private func powerText(isCompact: Bool) -> String {
        switch powerMode {
        case .normal:
            return isCompact ? "Normal uyku" : "macOS uyku yönetimi"
        case .keepMacAndDisplayAwake:
            return isCompact ? "Mac + ekran" : "Mac + ekran uyanık"
        case .allowDisplaySleepKeepMacAwake:
            return isCompact ? "Mac uyanık" : "Mac uyanık · ekran kapanabilir"
        }
    }

    private var powerHelp: String {
        switch powerMode {
        case .normal:
            "macOS ekran ve sistem uykusunu normal şekilde yönetir."
        case .keepMacAndDisplayAwake:
            "İzleme sırasında Mac'in ve ekranın uykuya geçmesi engellenir."
        case .allowDisplaySleepKeepMacAwake:
            "Ekran kapanabilir; Mac uyumaz ve ürün stok takibi devam eder."
        }
    }

    private func countdownString(at now: Date) -> String {
        guard let nextCheckDate else {
            return "Planlanmadı"
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

    private func accessibilitySummary(at now: Date) -> String {
        if networkStatus == .unavailable {
            return "İzleme beklemede. Ağ bağlantısı bekleniyor. Güç koruması: \(powerText(isCompact: false))."
        } else if networkStatus == .recovering {
            return "Ağ bağlantısı kuruluyor. Güç koruması: \(powerText(isCompact: false))."
        } else if isCheckSequenceRunning {
            return "Stok kontrolü yapılıyor. \(activeProductCount) aktif ürün."
        } else if !automaticCheckingEnabled {
            return "İzleme duraklatıldı. Otomatik kontrol kapalı. Uyku koruması pasif."
        } else if activeProductCount == 0 {
            return "İzlenecek aktif ürün yok. Uyku koruması pasif."
        } else {
            return "İzleme aktif. \(activeProductCount) ürün takip ediliyor. Sonraki kontrol \(countdownString(at: now)). Güç koruması: \(powerText(isCompact: false))."
        }
    }
}

private struct StatusBadge: View {
    let status: ProductStatus

    var body: some View {
        Label(status.label, systemImage: status.symbol)
            .font(.callout.weight(.medium))
            .foregroundStyle(status.color)
            .fixedSize()
    }
}

private struct FilterSegmentButton: View {
    let title: String
    let count: Int
    let isSelected: Bool
    var tint: Color = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? Color.secondary.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(isSelected ? tint : .secondary)
        }
        .buttonStyle(.plain)
        .help("\(title) (\(count) ürün)")
        .accessibilityLabel("\(title), \(count) ürün")
    }
}

private struct EmptyProductsView: View {
    let onAddProduct: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Henüz takip edilen ürün yok", systemImage: "shippingbox")
        } description: {
            VStack(spacing: 4) {
                Text("Takip etmek istediğiniz ürünün bağlantısını ekleyin.")
                Text("StockPing stok durumunu sizin için izler.")
            }
        } actions: {
            VStack(spacing: 8) {
                Button(action: onAddProduct) {
                    Label("Ürün Ekle", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Text("veya ⌘N tuşlarına basın ya da bir bağlantıyı buraya sürükleyin")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct InAppRestockBannerView: View {
    let banner: InAppRestockEvent
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("STOK GELDİ!")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(.green)
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(banner.productName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
                Text("\(banner.variantTitle) artık stokta.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("Ürünü Aç", action: onOpen)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Bildirimi Kapat")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.3), lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
    }
}

private struct ProductInspectorView: View {
    let product: TrackedProduct
    let storeName: String
    let onOpenProduct: () -> Void
    let onTogglePause: () -> Void
    let onTogglePriority: () -> Void
    let onIntervalChange: (Int) -> Void
    let onGroupChange: (String?) -> Void
    let onAddTag: (String) -> Void
    let onRemoveTag: (String) -> Void

    @State private var newTagText = ""
    @ObservedObject private var orgStore = ProductOrganizationStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text(product.productName)
                        .font(.headline)
                        .lineLimit(2)
                    Text(storeName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                // Stock & State
                VStack(alignment: .leading, spacing: 8) {
                    Text("DURUM")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("Stok Durumu")
                            .font(.subheadline)
                        Spacer()
                        Text(product.stockAvailabilityStatus.label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(product.stockAvailabilityStatus.color)
                    }

                    HStack {
                        Text("Varyant")
                            .font(.subheadline)
                        Spacer()
                        Text(product.selectedVariant.displayDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    HStack {
                        Text("Takip Kuralı")
                            .font(.subheadline)
                        Spacer()
                        Text(product.trackingRule.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                // Monitoring Controls
                VStack(alignment: .leading, spacing: 8) {
                    Text("İZLEME AYARLARI")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)

                    Toggle("Öncelikli Ürün", isOn: Binding(
                        get: { product.isPriority },
                        set: { _ in onTogglePriority() }
                    ))
                    .font(.subheadline)

                    Toggle("İzlemeyi Duraklat", isOn: Binding(
                        get: { product.isPaused },
                        set: { _ in onTogglePause() }
                    ))
                    .font(.subheadline)

                    Picker("Kontrol Sıklığı", selection: Binding(
                        get: { product.checkIntervalMinutes },
                        set: { onIntervalChange($0) }
                    )) {
                        ForEach(ProductCheckInterval.minutes, id: \.self) { minutes in
                            Text(ProductCheckInterval.title(for: minutes)).tag(minutes)
                        }
                    }
                    .font(.subheadline)
                }

                Divider()

                // Organization
                VStack(alignment: .leading, spacing: 8) {
                    Text("ORGANİZASYON")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)

                    Picker("Grup", selection: Binding(
                        get: { product.group ?? "" },
                        set: { onGroupChange($0.isEmpty ? nil : $0) }
                    )) {
                        Text("Grupsuz").tag("")
                        ForEach(orgStore.availableGroups, id: \.self) { group in
                            Text(group).tag(group)
                        }
                    }
                    .font(.subheadline)

                    if !product.tags.isEmpty {
                        TagFlowView(tags: product.tags, onRemove: onRemoveTag)
                    }

                    HStack {
                        TextField("Yeni etiket...", text: $newTagText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                let trimmed = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty {
                                    onAddTag(trimmed)
                                    newTagText = ""
                                }
                            }
                        Button("Ekle") {
                            let trimmed = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                onAddTag(trimmed)
                                newTagText = ""
                            }
                        }
                        .disabled(newTagText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Divider()

                // Primary Action
                Button(action: onOpenProduct) {
                    Label("Ürün Sayfasını Aç", systemImage: "arrow.up.right.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(14)
        }
        .inspectorColumnWidth(min: 240, ideal: 270, max: 320)
    }
}

private struct MonitoringDashboardView: View {
    let products: [TrackedProduct]
    var isNetworkAvailable: Bool = NetworkReachabilityMonitor.shared.canProceedWithChecks
    let onSelectProduct: (UUID) -> Void
    let onAddProduct: () -> Void

    private var inStockCount: Int {
        products.filter { $0.status == .inStock }.count
    }
    private var outOfStockCount: Int {
        products.filter { $0.status == .outOfStock }.count
    }
    private var pausedCount: Int {
        products.filter { $0.isPaused }.count
    }
    private var priorityCount: Int {
        products.filter { $0.isPriority }.count
    }

    private struct DashboardRecentMovement: Identifiable {
        let id: UUID
        let productID: UUID
        let productName: String
        let variantTitle: String
        let storeName: String
        let isRestock: Bool
        let date: Date
    }

    private var recentMovements: [DashboardRecentMovement] {
        var movements: [DashboardRecentMovement] = []
        for product in products {
            let store = storeName(for: product)
            for event in product.events {
                if event.type == .stockArrived && event.previousState == false && event.newState == true {
                    movements.append(DashboardRecentMovement(
                        id: event.id,
                        productID: product.id,
                        productName: product.productName,
                        variantTitle: product.variantTitle,
                        storeName: store,
                        isRestock: true,
                        date: event.date
                    ))
                } else if event.type == .stockDepleted && event.previousState == true && event.newState == false {
                    movements.append(DashboardRecentMovement(
                        id: event.id,
                        productID: product.id,
                        productName: product.productName,
                        variantTitle: product.variantTitle,
                        storeName: store,
                        isRestock: false,
                        date: event.date
                    ))
                }
            }
        }
        return movements.sorted { $0.date > $1.date }
    }

    private func storeName(for product: TrackedProduct) -> String {
        switch product.provider {
        case .zara: "Zara Türkiye"
        case .bershka: "Bershka Türkiye"
        case .pullAndBear: "Pull&Bear Türkiye"
        case .hm: "H&M Türkiye"
        case .shopify: product.productURL.host() ?? "Shopify mağazası"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("Genel İzleme Özeti")
                        .font(.title2.weight(.bold))
                    Text("Takip edilen mağazalar, ürün sayıları ve anlık durumlar")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                // Summary metric cards
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 12)], spacing: 12) {
                    dashboardCard(title: "Toplam Ürün", value: "\(products.count)", icon: "shippingbox", color: .accentColor)
                    dashboardCard(title: "Stokta", value: "\(inStockCount)", icon: "checkmark.circle.fill", color: .green)
                    dashboardCard(title: "Stokta Değil", value: "\(outOfStockCount)", icon: "xmark.circle.fill", color: .orange)
                    dashboardCard(title: "Duraklatıldı", value: "\(pausedCount)", icon: "pause.circle.fill", color: .secondary)
                    dashboardCard(title: "Öncelikli", value: "\(priorityCount)", icon: "star.fill", color: .yellow)
                }

                Divider()

                // Provider Status Center section
                VStack(alignment: .leading, spacing: 12) {
                    Label("Mağaza Durumu", systemImage: "server.rack")
                        .font(.headline)

                    let summaries = ProviderHealthSummary.allSummaries(for: products, isNetworkAvailable: isNetworkAvailable)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 12)], spacing: 12) {
                        ForEach(summaries) { summary in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: summary.health.symbol)
                                        .foregroundStyle(summary.health.color)
                                    Text(summary.provider.displayName)
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                }
                                Text(summary.health.title)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(summary.health.color)

                                HStack(spacing: 4) {
                                    Text("\(summary.productCount) ürün")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    if summary.activeProductCount != summary.productCount {
                                        Text("(\(summary.activeProductCount) aktif)")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                if let errorMsg = summary.lastErrorMessage {
                                    Text(errorMsg)
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                        .lineLimit(1)
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }

                Divider()

                // Recent stock movements section
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Son Stok Hareketleri", systemImage: "clock.arrow.circlepath")
                            .font(.headline)
                        Spacer()
                        if !recentMovements.isEmpty {
                            Text("\(min(recentMovements.count, 20)) hareket")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if recentMovements.isEmpty {
                        VStack(spacing: 8) {
                            Text("Henüz kaydedilmiş stok hareketi bulunmuyor.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Text("Ürünler takip edildikçe ve stok durumları değiştikçe burada listelenecektir.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 16)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(recentMovements.prefix(20)) { movement in
                                HStack(spacing: 12) {
                                    Image(systemName: movement.isRestock ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(movement.isRestock ? Color.green : Color.orange)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(movement.productName)
                                            .font(.body.weight(.medium))
                                            .lineLimit(1)

                                        HStack(spacing: 6) {
                                            Text(movement.storeName)
                                            Text("·")
                                            Text(movement.variantTitle)
                                            Text("·")
                                            Text(TurkishRelativeTime.string(from: movement.date))
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Button("Ürüne Git") {
                                        onSelectProduct(movement.productID)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func dashboardCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.subheadline)
                Spacer()
            }
            Text(value)
                .font(.title.weight(.bold))
                .foregroundStyle(.primary)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct NoSelectionView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Ürün Seçilmedi", systemImage: "sidebar.left")
        } description: {
            Text("Detayları görüntülemek için kenar çubuğundan bir ürün seçin.")
        }
    }
}

private enum ContentSheet: Identifiable {
    case addProduct(initialURL: String? = nil)

    static var addProduct: ContentSheet { .addProduct(initialURL: nil) }

    var id: String {
        switch self {
        case .addProduct(let url):
            return "addProduct-\(url ?? "")"
        }
    }
}

private struct StorePageWebView: NSViewRepresentable {
    @Binding var product: TrackedProduct
    let checkRequestID: Int
    @Binding var isChecking: Bool
    @Binding var status: String
    @Binding var errorMessage: String?
    let notificationsEnabled: Bool
    let emailNotificationsEnabled: Bool
    let adaptiveMonitoringEnabled: Bool
    let autoOpenOnRestockEnabled: Bool
    var verificationMode: RestockVerificationMode = .off
    var burstModeEnabled: Bool = true
    var burstIntervalMinutes: Int = 2
    var burstDurationMinutes: Int = 30
    let onCheckComplete: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            product: $product,
            initialRequestID: checkRequestID,
            isChecking: $isChecking,
            status: $status,
            errorMessage: $errorMessage,
            notificationsEnabled: notificationsEnabled,
            emailNotificationsEnabled: emailNotificationsEnabled,
            adaptiveMonitoringEnabled: adaptiveMonitoringEnabled,
            autoOpenOnRestockEnabled: autoOpenOnRestockEnabled,
            verificationMode: verificationMode,
            burstModeEnabled: burstModeEnabled,
            burstIntervalMinutes: burstIntervalMinutes,
            burstDurationMinutes: burstDurationMinutes,
            onCheckComplete: onCheckComplete
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: product.productURL))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.receiveCheckRequest(
            checkRequestID,
            product: $product,
            webView: webView,
            notificationsEnabled: notificationsEnabled,
            emailNotificationsEnabled: emailNotificationsEnabled,
            adaptiveMonitoringEnabled: adaptiveMonitoringEnabled,
            autoOpenOnRestockEnabled: autoOpenOnRestockEnabled,
            verificationMode: verificationMode,
            burstModeEnabled: burstModeEnabled,
            burstIntervalMinutes: burstIntervalMinutes,
            burstDurationMinutes: burstDurationMinutes
        )
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private var product: Binding<TrackedProduct>
        private var isChecking: Binding<Bool>
        private var status: Binding<String>
        private var errorMessage: Binding<String?>
        private var notificationsEnabled: Bool
        private var emailNotificationsEnabled: Bool
        private var adaptiveMonitoringEnabled: Bool
        private var autoOpenOnRestockEnabled: Bool
        private var verificationMode: RestockVerificationMode
        private var burstModeEnabled: Bool
        private var burstIntervalMinutes: Int
        private var burstDurationMinutes: Int
        private let onCheckComplete: () -> Void
        private var loadedProductID: UUID
        private var pageIsReady = false
        private var pageLoadFailed = false
        private var lastReceivedRequestID = 0
        private var queuedRequestID: Int?
        private var pageReadinessTimeoutTask: Task<Void, Never>?
        private var providerCheckTimeoutTask: Task<Void, Never>?
        private var providerCheckTask: Task<Void, Never>?
        private var activeProviderCheckRequestID: Int?
        private var checkStartTime: Date?
        private let providerCheckSafetyTimeout: Duration = .seconds(40)
        private var checksCompleted: Int = 0

        init(
            product: Binding<TrackedProduct>,
            initialRequestID: Int,
            isChecking: Binding<Bool>,
            status: Binding<String>,
            errorMessage: Binding<String?>,
            notificationsEnabled: Bool,
            emailNotificationsEnabled: Bool,
            adaptiveMonitoringEnabled: Bool,
            autoOpenOnRestockEnabled: Bool,
            verificationMode: RestockVerificationMode = .off,
            burstModeEnabled: Bool = true,
            burstIntervalMinutes: Int = 2,
            burstDurationMinutes: Int = 30,
            onCheckComplete: @escaping () -> Void
        ) {
            self.product = product
            self.lastReceivedRequestID = initialRequestID
            self.isChecking = isChecking
            self.status = status
            self.errorMessage = errorMessage
            self.notificationsEnabled = notificationsEnabled
            self.emailNotificationsEnabled = emailNotificationsEnabled
            self.adaptiveMonitoringEnabled = adaptiveMonitoringEnabled
            self.autoOpenOnRestockEnabled = autoOpenOnRestockEnabled
            self.verificationMode = verificationMode
            self.burstModeEnabled = burstModeEnabled
            self.burstIntervalMinutes = burstIntervalMinutes
            self.burstDurationMinutes = burstDurationMinutes
            self.onCheckComplete = onCheckComplete
            self.loadedProductID = product.wrappedValue.id
        }

        func receiveCheckRequest(
            _ requestID: Int,
            product: Binding<TrackedProduct>,
            webView: WKWebView,
            notificationsEnabled: Bool,
            emailNotificationsEnabled: Bool,
            adaptiveMonitoringEnabled: Bool,
            autoOpenOnRestockEnabled: Bool,
            verificationMode: RestockVerificationMode = .off,
            burstModeEnabled: Bool = true,
            burstIntervalMinutes: Int = 2,
            burstDurationMinutes: Int = 30
        ) {
            self.product = product
            self.notificationsEnabled = notificationsEnabled
            self.emailNotificationsEnabled = emailNotificationsEnabled
            self.adaptiveMonitoringEnabled = adaptiveMonitoringEnabled
            self.autoOpenOnRestockEnabled = autoOpenOnRestockEnabled
            self.verificationMode = verificationMode
            self.burstModeEnabled = burstModeEnabled
            self.burstIntervalMinutes = burstIntervalMinutes
            self.burstDurationMinutes = burstDurationMinutes
            let currentProduct = product.wrappedValue
            if currentProduct.id != loadedProductID {
                loadedProductID = currentProduct.id
                pageIsReady = false
                pageLoadFailed = false
                queuedRequestID = nil
                pageReadinessTimeoutTask?.cancel()
                pageReadinessTimeoutTask = nil
                webView.load(URLRequest(url: currentProduct.productURL))
            }

            guard requestID > lastReceivedRequestID else { return }
            lastReceivedRequestID = requestID

            guard requestID > 0 else { return }
            checkStartTime = Date()
            if pageIsReady {
                checkAvailability(in: webView, product: product.wrappedValue, requestID: requestID)
            } else if pageLoadFailed {
                let isNetError = !NetworkReachabilityMonitor.shared.isConnected || NetworkReachabilityMonitor.shared.status == .unavailable
                completeFailure(
                    "Store sayfasına bağlanılamadığı için kontrol yapılamadı.",
                    isNetworkError: isNetError,
                    errorDetail: "Store page failed to load prior to check",
                    outcome: isNetError ? .networkUnavailable : .pageLoadFailure
                )
            } else {
                queuedRequestID = requestID
                schedulePageReadinessTimeout(for: requestID, provider: currentProduct.provider)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let evaluatedRequestID = queuedRequestID
            webView.evaluateJavaScript("document.readyState") { [weak self] result, error in
                guard let self else { return }
                if let evaluatedRequestID, self.queuedRequestID != evaluatedRequestID { return }

                if let error {
                    self.showError("Sayfanın hazır olduğu doğrulanamadı: \(error.localizedDescription)")
                    if self.queuedRequestID != nil {
                        self.queuedRequestID = nil
                        self.completeFailure(
                            "Sayfanın hazır olduğu doğrulanamadı: \(error.localizedDescription)",
                            isNetworkError: false,
                            errorDetail: error.localizedDescription,
                            outcome: .pageLoadFailure
                        )
                    }
                    return
                }

                guard let readyState = result as? String, readyState == "complete" else {
                    self.showError("Sayfa yüklemesi tamamlanamadı.")
                    if self.queuedRequestID != nil {
                        self.queuedRequestID = nil
                        self.completeFailure(
                            "Sayfa yüklemesi tamamlanamadı.",
                            isNetworkError: false,
                            errorDetail: "document.readyState did not reach complete",
                            outcome: .pageLoadFailure
                        )
                    }
                    return
                }

                // Let page scripts finish their post-load work before reporting success.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self else { return }
                    if let evaluatedRequestID, self.queuedRequestID != evaluatedRequestID { return }
                    self.pageIsReady = true
                    self.pageLoadFailed = false
                    self.status.wrappedValue = "Bağlandı ✓"
                    self.errorMessage.wrappedValue = nil

                    if let requestID = self.queuedRequestID {
                        self.queuedRequestID = nil
                        self.checkAvailability(in: webView, product: self.product.wrappedValue, requestID: requestID)
                    }
                }
            }
        }

        private func isNetworkConnectivityError(_ error: Error) -> Bool {
            if !NetworkReachabilityMonitor.shared.isConnected || NetworkReachabilityMonitor.shared.status == .unavailable {
                return true
            }
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                switch nsError.code {
                case NSURLErrorNotConnectedToInternet,
                     NSURLErrorNetworkConnectionLost:
                    return true
                default:
                    // Timeouts (NSURLErrorTimedOut), host reachability issues, and other errors
                    // are treated as standard provider/request failures when network is otherwise connected.
                    return false
                }
            }
            return false
        }

        private static func isTimeoutError(_ error: Error) -> Bool {
            if let shopifyError = error as? ShopifyCheckerError {
                if case .requestTimedOut = shopifyError { return true }
            }
            if let bershkaError = error as? BershkaCheckerError {
                if case .pageLoadTimedOut = bershkaError { return true }
            }
            if let pullAndBearError = error as? PullAndBearCheckerError {
                switch pullAndBearError {
                case .pageLoadTimedOut, .javascriptEvaluationTimedOut:
                    return true
                default:
                    break
                }
            }
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
                return true
            }
            return false
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            pageLoadFailed = true
            let isNetError = isNetworkConnectivityError(error)
            showError(isNetError ? "Ağ bağlantısı yok" : error.localizedDescription)
            if queuedRequestID != nil {
                queuedRequestID = nil
                completeFailure(
                    "Store sayfası yüklenemedi: \(error.localizedDescription)",
                    isNetworkError: isNetError,
                    errorDetail: error.localizedDescription,
                    outcome: isNetError ? .networkUnavailable : .pageLoadFailure
                )
            }
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            pageLoadFailed = true
            let isNetError = isNetworkConnectivityError(error)
            showError(isNetError ? "Ağ bağlantısı yok" : error.localizedDescription)
            if queuedRequestID != nil {
                queuedRequestID = nil
                completeFailure(
                    "Store sayfası yüklenemedi: \(error.localizedDescription)",
                    isNetworkError: isNetError,
                    errorDetail: error.localizedDescription,
                    outcome: isNetError ? .networkUnavailable : .pageLoadFailure
                )
            }
        }

        private func checkAvailability(in webView: WKWebView, product: TrackedProduct, requestID: Int) {
            pageReadinessTimeoutTask?.cancel()
            pageReadinessTimeoutTask = nil
            providerCheckTimeoutTask?.cancel()
            providerCheckTask?.cancel()
            activeProviderCheckRequestID = requestID

            providerCheckTask = Task { [self] in
                do {
                    let outcome = try await StoreCheckerRouter.checkWithVariants(in: webView, product: product, activePageURL: webView.url)
                    let exactAvailable = outcome.isAvailable
                    guard self.activeProviderCheckRequestID == requestID,
                          self.product.wrappedValue.id == product.id else { return }

                    let eval = self.product.wrappedValue.evaluateLogicalStock(snapshots: outcome.variants)
                    let logicalAvailable = eval.isAvailable
                    let wasInError = self.product.wrappedValue.lastCheckError != nil
                    let previousLogicalAvailability = self.product.wrappedValue.effectiveAvailability

                    let transition = Self.transition(
                        from: previousLogicalAvailability,
                        to: logicalAvailable
                    )

                    if wasInError {
                        self.product.wrappedValue.record(.checkRecovered, previousState: previousLogicalAvailability, newState: logicalAvailable)
                    }
                    self.product.wrappedValue.consecutiveFailureChecks = 0

                    let effectiveVerificationMode = self.product.wrappedValue.verificationPreference ?? self.verificationMode
                    let requiredConfirmations = effectiveVerificationMode.requiredConfirmations
                    var isConfirmedRestock = false

                    switch transition {
                    case .restocked:
                        if requiredConfirmations > 0 {
                            self.product.wrappedValue.pendingVerificationCount += 1
                            if self.product.wrappedValue.pendingVerificationCount > requiredConfirmations {
                                isConfirmedRestock = true
                                self.product.wrappedValue.pendingVerificationCount = 0
                                self.product.wrappedValue.consecutiveUnchangedChecks = 0
                                self.product.wrappedValue.record(.stockArrived, previousState: false, newState: true)
                            } else {
                                self.product.wrappedValue.consecutiveUnchangedChecks = 0
                            }
                        } else {
                            isConfirmedRestock = true
                            self.product.wrappedValue.pendingVerificationCount = 0
                            self.product.wrappedValue.consecutiveUnchangedChecks = 0
                            self.product.wrappedValue.record(.stockArrived, previousState: false, newState: true)
                        }

                    case .wentOutOfStock:
                        self.product.wrappedValue.pendingVerificationCount = 0
                        self.product.wrappedValue.burstExpiresAt = nil
                        self.product.wrappedValue.consecutiveUnchangedChecks = 0
                        self.product.wrappedValue.record(.stockDepleted, previousState: true, newState: false)

                    case .unchanged(available: false):
                        self.product.wrappedValue.pendingVerificationCount = 0
                        self.product.wrappedValue.consecutiveUnchangedChecks += 1

                    case .unchanged(available: true):
                        if self.product.wrappedValue.pendingVerificationCount > 0 && requiredConfirmations > 0 {
                            self.product.wrappedValue.pendingVerificationCount += 1
                            if self.product.wrappedValue.pendingVerificationCount > requiredConfirmations {
                                isConfirmedRestock = true
                                self.product.wrappedValue.pendingVerificationCount = 0
                                self.product.wrappedValue.consecutiveUnchangedChecks = 0
                                self.product.wrappedValue.record(.stockArrived, previousState: false, newState: true)
                            }
                        } else {
                            self.product.wrappedValue.consecutiveUnchangedChecks = 0
                        }

                    case .initial:
                        self.product.wrappedValue.pendingVerificationCount = 0
                        self.product.wrappedValue.consecutiveUnchangedChecks = 0
                    }

                    self.product.wrappedValue.lastAvailabilityTransition = isConfirmedRestock ? .restocked : transition
                    self.product.wrappedValue.selectedVariant.availability = exactAvailable
                    self.product.wrappedValue.logicalAvailability = logicalAvailable
                    self.product.wrappedValue.variantSnapshots = outcome.variants
                    self.product.wrappedValue.lastCheckError = nil

                    if isConfirmedRestock {
                        if self.burstModeEnabled && self.product.wrappedValue.burstPreference != false {
                            self.product.wrappedValue.burstExpiresAt = Date().addingTimeInterval(TimeInterval(self.burstDurationMinutes * 60))
                        }
                    }

                    let now = Date()
                    let startTime = self.checkStartTime ?? now
                    let duration = max(0, now.timeIntervalSince(startTime))
                    let netStatus: String
                    switch NetworkReachabilityMonitor.shared.status {
                    case .available: netStatus = "Bağlı"
                    case .unavailable: netStatus = "Bağlantı yok"
                    case .recovering: netStatus = "Yeniden bağlanıyor"
                    }
                    let userMsg: String
                    if isConfirmedRestock {
                        userMsg = "Stok kontrolü başarılı. Yeni stok geldiği tespit edildi."
                    } else if transition == .wentOutOfStock {
                        userMsg = "Stok kontrolü başarılı. Stoğun tükendiği tespit edildi."
                    } else {
                        userMsg = "Stok kontrolü başarıyla tamamlandı. Ürün \(logicalAvailable ? "stokta" : "stokta değil")."
                    }
                    self.product.wrappedValue.latestDiagnostic = ProviderDiagnostic(
                        providerName: self.product.wrappedValue.providerDisplayName,
                        checkerName: self.product.wrappedValue.provider.defaultCheckerName,
                        startedAt: startTime,
                        completedAt: now,
                        durationSeconds: duration,
                        outcome: (isConfirmedRestock || transition == .wentOutOfStock) ? .stockChanged : .success,
                        stockResult: logicalAvailable,
                        networkStatus: netStatus,
                        errorCategory: "Yok",
                        userMessage: userMsg,
                        technicalDetail: outcome.diagnosticDetail,
                        lastSuccessfulCheckDate: now
                    )

                    if isConfirmedRestock {
                        let current = self.product.wrappedValue
                        if current.notificationProfile.shouldNotifyOnRestock {
                            let (notifTitle, variantText) = Self.formatRestockNotification(for: current, evaluation: eval)
                            NotificationCenter.default.post(
                                name: .didDetectRestockEvent,
                                object: InAppRestockEvent(
                                    productID: current.id,
                                    productName: current.productName,
                                    variantTitle: variantText,
                                    productURL: current.productURL
                                )
                            )
                            if self.notificationsEnabled && current.isMacOSNotificationEnabled {
                                StockNotificationManager.shared.sendRestockNotification(
                                    productID: current.id,
                                    productName: current.productName,
                                    variantTitle: current.variantTitle,
                                    productURL: current.productURL,
                                    customTitle: notifTitle,
                                    customBody: "\(current.productName) — \(variantText) artık stokta."
                                )
                            } else {
                                let reason = !self.notificationsEnabled
                                    ? "macOS bildirimleri ayarlarda kapalı"
                                    : "Bu ürün için macOS bildirimi kapalı"
                                NotificationAuditManager.shared.record(
                                    productID: current.id,
                                    productName: current.productName,
                                    variantTitle: variantText,
                                    channel: .macOS,
                                    status: .skipped,
                                    message: reason
                                )
                            }
                            if self.emailNotificationsEnabled && current.isEmailNotificationEnabled {
                                EmailNotificationService.shared.sendRestockNotification(
                                    for: current,
                                    customVariantText: variantText
                                )
                            } else {
                                let reason = !self.emailNotificationsEnabled
                                    ? "E-posta bildirimleri ayarlarda kapalı"
                                    : "Bu ürün için e-posta bildirimi kapalı"
                                NotificationAuditManager.shared.record(
                                    productID: current.id,
                                    productName: current.productName,
                                    variantTitle: variantText,
                                    channel: .email,
                                    status: .skipped,
                                    message: reason
                                )
                            }
                        } else {
                            NotificationAuditManager.shared.record(
                                productID: current.id,
                                productName: current.productName,
                                variantTitle: current.variantTitle,
                                channel: .macOS,
                                status: .skipped,
                                message: "Bildirim profili sessiz olarak ayarlanmış"
                            )
                        }

                        AutoOpenManager.shared.handleRestock(
                            for: current,
                            globalEnabled: self.autoOpenOnRestockEnabled
                        )
                    } else if case .wentOutOfStock = transition {
                        let current = self.product.wrappedValue
                        if current.notificationProfile.shouldNotifyOnDepletion {
                            if self.notificationsEnabled && current.isMacOSNotificationEnabled {
                                StockNotificationManager.shared.sendDepletionNotification(
                                    productID: current.id,
                                    productName: current.productName,
                                    variantTitle: current.variantTitle,
                                    productURL: current.productURL
                                )
                            }
                            if self.emailNotificationsEnabled && current.isEmailNotificationEnabled {
                                EmailNotificationService.shared.sendDepletionNotification(
                                    for: current
                                )
                            }
                        }
                    }
                    self.finishCheck()
                } catch {
                    guard self.activeProviderCheckRequestID == requestID,
                          self.product.wrappedValue.id == product.id else { return }
                    let isNetError = self.isNetworkConnectivityError(error)
                    let outcome: DiagnosticOutcome
                    if isNetError {
                        outcome = .networkUnavailable
                    } else if error is CancellationError {
                        outcome = .cancelled
                    } else if Self.isTimeoutError(error) {
                        outcome = .timeout
                    } else {
                        outcome = .providerFailure
                    }
                    self.completeFailure(
                        "Stok kontrolü başarısız: \(error.localizedDescription)",
                        isNetworkError: isNetError,
                        errorDetail: error.localizedDescription,
                        outcome: outcome
                    )
                }
            }

            let timeout = providerCheckSafetyTimeout
            providerCheckTimeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                guard let self, self.activeProviderCheckRequestID == requestID else { return }
                self.activeProviderCheckRequestID = nil
                self.providerCheckTask?.cancel()
                self.providerCheckTask = nil
                let isNetError = !NetworkReachabilityMonitor.shared.isConnected || NetworkReachabilityMonitor.shared.status == .unavailable
                self.completeFailure(
                    "Stok kontrolü güvenlik zaman aşımına uğradı.",
                    isNetworkError: isNetError,
                    errorDetail: "Provider check safety timeout exceeded (40s)",
                    outcome: isNetError ? .networkUnavailable : .timeout
                )
            }
        }

        private func completeFailure(
            _ message: String,
            isNetworkError: Bool = false,
            errorDetail: String? = nil,
            outcome: DiagnosticOutcome = .providerFailure
        ) {
            let now = Date()
            let startTime = checkStartTime ?? now
            let duration = max(0, now.timeIntervalSince(startTime))
            let netStatus: String
            switch NetworkReachabilityMonitor.shared.status {
            case .available: netStatus = "Bağlı"
            case .unavailable: netStatus = "Bağlantı yok"
            case .recovering: netStatus = "Yeniden bağlanıyor"
            }

            let sanitizedDetail = errorDetail.map { TechnicalDetailSanitizer.sanitize($0) }

            let errorCategory: String
            let userMsg: String
            switch outcome {
            case .networkUnavailable:
                errorCategory = "Ağ Bağlantısı"
                userMsg = "İnternet bağlantısı kurulamadığı için mağaza kontrolü gerçekleştirilemedi. Mevcut stok durumu korundu."
            case .timeout:
                errorCategory = "Zaman Aşımı"
                userMsg = "Mağaza sayfası veya stok yanıtı belirlenen sürede tamamlanamadı (zaman aşımı)."
            case .pageLoadFailure:
                errorCategory = "Sayfa Yükleme"
                userMsg = "Mağaza web sayfası yüklenirken hata oluştu."
            case .providerFailure:
                errorCategory = "Mağaza / Sağlayıcı"
                userMsg = "Mağaza stok bilgisi ayrıştırılamadı veya beklenen ürün varyantı bulunamadı."
            case .cancelled:
                errorCategory = "İptal"
                userMsg = "Kontrol işlemi iptal edildi."
            default:
                errorCategory = "Genel Hata"
                userMsg = message
            }

            let previousSuccessfulDate = self.product.wrappedValue.latestDiagnostic?.lastSuccessfulCheckDate
                ?? (self.product.wrappedValue.lastCheckError == nil ? self.product.wrappedValue.lastChecked : nil)

            let diag = ProviderDiagnostic(
                providerName: self.product.wrappedValue.providerDisplayName,
                checkerName: self.product.wrappedValue.provider.defaultCheckerName,
                startedAt: startTime,
                completedAt: now,
                durationSeconds: duration,
                outcome: outcome,
                stockResult: self.product.wrappedValue.lastKnownAvailable,
                networkStatus: netStatus,
                errorCategory: errorCategory,
                userMessage: userMsg,
                technicalDetail: sanitizedDetail,
                lastSuccessfulCheckDate: previousSuccessfulDate
            )
            self.product.wrappedValue.latestDiagnostic = diag

            if isNetworkError {
                print("[NetworkGuard] Ağ bağlantısı sorunu nedeniyle kontrol ertelendi: \(message)")
            } else {
                product.wrappedValue.consecutiveFailureChecks += 1
                if product.wrappedValue.lastCheckError == nil {
                    product.wrappedValue.record(.checkFailed, previousState: product.wrappedValue.lastKnownAvailable)
                }
                product.wrappedValue.lastCheckError = message
            }
            finishCheck(deferNextCheckIfNetworkError: isNetworkError)
        }

        private func finishCheck(deferNextCheckIfNetworkError: Bool = false) {
            pageReadinessTimeoutTask?.cancel()
            pageReadinessTimeoutTask = nil
            providerCheckTimeoutTask?.cancel()
            providerCheckTimeoutTask = nil
            providerCheckTask = nil
            activeProviderCheckRequestID = nil
            if !deferNextCheckIfNetworkError {
                let checkedAt = Date()
                product.wrappedValue.lastChecked = checkedAt
                if product.wrappedValue.isPaused {
                    product.wrappedValue.nextCheckDate = nil
                } else if product.wrappedValue.pendingVerificationCount > 0 {
                    product.wrappedValue.nextCheckDate = checkedAt.addingTimeInterval(2)
                } else {
                    let effectiveMinutes = AdaptiveMonitoringPolicy.effectiveIntervalMinutes(
                        baseMinutes: product.wrappedValue.checkIntervalMinutes,
                        status: product.wrappedValue.status,
                        consecutiveUnchangedChecks: product.wrappedValue.consecutiveUnchangedChecks,
                        consecutiveFailureChecks: product.wrappedValue.consecutiveFailureChecks,
                        isEnabled: adaptiveMonitoringEnabled,
                        burstExpiresAt: product.wrappedValue.burstExpiresAt,
                        burstIntervalMinutes: burstIntervalMinutes
                    )
                    product.wrappedValue.nextCheckDate = checkedAt.addingTimeInterval(
                        TimeInterval(effectiveMinutes * 60)
                    )
                }
            }
            checksCompleted += 1
            // Periodically clear WKWebView caches to prevent memory growth
            // over long-running sessions (hundreds/thousands of navigations).
            if checksCompleted % 50 == 0 {
                WKWebsiteDataStore.default().removeData(
                    ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                    modifiedSince: .distantPast
                ) { }
            }
            isChecking.wrappedValue = false
            onCheckComplete()
        }

        private static func formatRestockNotification(
            for product: TrackedProduct,
            evaluation: TrackedProduct.LogicalStockEvaluation
        ) -> (title: String, variantText: String) {
            let title = "Stok geldi! 🎉"
            switch product.trackingRule {
            case .exactVariant:
                return (title, product.variantTitle)
            case .anySizeInSelectedColor:
                let color = product.selectedColorName ?? "Seçili Renk"
                if evaluation.matchingCount == 1, let first = evaluation.matchingSnapshots.first {
                    let size = first.sizeValue ?? first.displayTitle
                    return (title, "\(color) · \(size)")
                } else {
                    return (title, "\(color) için \(evaluation.matchingCount) beden stokta")
                }
            case .selectedSizeInAnyColor:
                let size = product.selectedSizeName ?? "Seçili Beden"
                if evaluation.matchingCount == 1, let first = evaluation.matchingSnapshots.first {
                    let color = first.colorValue ?? first.displayTitle
                    return (title, "\(color) · \(size)")
                } else {
                    return (title, "\(size) için \(evaluation.matchingCount) renk stokta")
                }
            case .anyVariant:
                if evaluation.matchingCount == 1, let first = evaluation.matchingSnapshots.first {
                    return (title, first.displayTitle)
                } else {
                    return (title, "\(evaluation.matchingCount) varyant stokta")
                }
            }
        }

        private static func transition(from previous: Bool?, to current: Bool) -> AvailabilityTransition {
            guard let previous else { return .initial(available: current) }
            if !previous && current { return .restocked }
            if previous && !current { return .wentOutOfStock }
            return .unchanged(available: current)
        }

        private func showError(_ message: String) {
            status.wrappedValue = "Bağlantı hatası"
            errorMessage.wrappedValue = message
        }

        /// Recover from WebKit content process crashes (jetsam, memory pressure).
        /// Without this, the WebView silently goes blank and all future JS evaluations fail.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            NSLog("[StockPing] WebKit content process terminated — reloading page.")
            pageIsReady = false
            pageLoadFailed = false
            webView.reload()
        }

        private func schedulePageReadinessTimeout(for requestID: Int, provider: StoreProvider) {
            pageReadinessTimeoutTask?.cancel()
            let timeout: Duration
            switch provider {
            case .shopify: timeout = .seconds(15)
            case .bershka: timeout = .seconds(30)
            case .hm: timeout = .seconds(40)
            // These providers do not require page state for their stock request,
            // but their check still waits for the initial WebView readiness.
            // Bound that queued phase too, before the provider safety timer starts.
            case .zara, .pullAndBear: timeout = providerCheckSafetyTimeout
            }

            pageReadinessTimeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                guard let self,
                      self.queuedRequestID == requestID,
                      self.isChecking.wrappedValue else { return }
                self.queuedRequestID = nil
                let isNetError = !NetworkReachabilityMonitor.shared.isConnected || NetworkReachabilityMonitor.shared.status == .unavailable
                self.completeFailure(
                    "Mağaza sayfası zamanında hazır olmadı. Lütfen yeniden deneyin.",
                    isNetworkError: isNetError,
                    errorDetail: "Page readiness timeout exceeded",
                    outcome: isNetError ? .networkUnavailable : .timeout
                )
            }
        }
    }
}

@MainActor
final class AutoOpenManager {
    static let shared = AutoOpenManager()

    private var lastOpenedTimes: [UUID: Date] = [:]
    private var lastGlobalOpenDate: Date?
    private let minimumGlobalInterval: TimeInterval = 2.0
    private let minimumProductInterval: TimeInterval = 60.0

    private init() {}

    func handleRestock(for product: TrackedProduct, globalEnabled: Bool) {
        let shouldOpen: Bool
        if let override = product.autoOpenOnRestock {
            shouldOpen = override
        } else {
            shouldOpen = globalEnabled
        }

        guard shouldOpen else { return }

        let url = product.productURL
        guard let scheme = url.scheme?.lowercased(), (scheme == "http" || scheme == "https") else {
            return
        }

        let now = Date()
        if let lastGlobal = lastGlobalOpenDate, now.timeIntervalSince(lastGlobal) < minimumGlobalInterval {
            return
        }

        if let lastProductTime = lastOpenedTimes[product.id], now.timeIntervalSince(lastProductTime) < minimumProductInterval {
            return
        }

        lastGlobalOpenDate = now
        lastOpenedTimes[product.id] = now
        NSWorkspace.shared.open(url)
    }

    func resetForTesting() {
        lastOpenedTimes.removeAll()
        lastGlobalOpenDate = nil
    }
}

@MainActor
private final class StockNotificationManager {
    static let shared = StockNotificationManager()

    private struct ProductNotice {
        let productID: UUID
        let productName: String
        let variantTitle: String
        let productURL: URL
        let isRestock: Bool
        var customTitle: String? = nil
        var customBody: String? = nil
    }

    private var pendingNotices: [ProductNotice] = []
    private var isProcessingNotices = false

    private init() {}

    func sendRestockNotification(
        productID: UUID,
        productName: String,
        variantTitle: String,
        productURL: URL,
        customTitle: String? = nil,
        customBody: String? = nil
    ) {
        pendingNotices.append(ProductNotice(
            productID: productID,
            productName: productName,
            variantTitle: variantTitle,
            productURL: productURL,
            isRestock: true,
            customTitle: customTitle,
            customBody: customBody
        ))
        guard !isProcessingNotices else { return }

        isProcessingNotices = true
        Task { @MainActor in
            await processPendingNotices()
        }
    }

    func sendDepletionNotification(productID: UUID, productName: String, variantTitle: String, productURL: URL) {
        pendingNotices.append(ProductNotice(productID: productID, productName: productName, variantTitle: variantTitle, productURL: productURL, isRestock: false))
        guard !isProcessingNotices else { return }

        isProcessingNotices = true
        Task { @MainActor in
            await processPendingNotices()
        }
    }

    private func processPendingNotices() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        var canNotify = settings.authorizationStatus == .authorized ||
            settings.authorizationStatus == .provisional

        if settings.authorizationStatus == .notDetermined {
            do {
                canNotify = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                canNotify = false
            }
        }

        if canNotify {
            while !pendingNotices.isEmpty {
                let notices = pendingNotices
                pendingNotices.removeAll()

                for notice in notices {
                    let content = UNMutableNotificationContent()
                    if notice.isRestock {
                        content.title = notice.customTitle ?? "Stok geldi! 🎉"
                        content.body = notice.customBody ?? "\(notice.productName) — \(notice.variantTitle) artık stokta."
                    } else {
                        content.title = "Stok tükendi"
                        content.body = "\(notice.productName) — \(notice.variantTitle) tükendi."
                    }
                    content.sound = .default
                    content.userInfo = [
                        "productID": notice.productID.uuidString,
                        "productURL": notice.productURL.absoluteString
                    ]

                    let request = UNNotificationRequest(
                        identifier: UUID().uuidString,
                        content: content,
                        trigger: nil
                    )
                    do {
                        try await center.add(request)
                        NotificationAuditManager.shared.record(
                            productID: notice.productID,
                            productName: notice.productName,
                            variantTitle: notice.variantTitle,
                            channel: .macOS,
                            status: .sent,
                            message: "macOS bildirimi başarıyla iletildi."
                        )
                    } catch {
                        NotificationAuditManager.shared.record(
                            productID: notice.productID,
                            productName: notice.productName,
                            variantTitle: notice.variantTitle,
                            channel: .macOS,
                            status: .failed,
                            message: error.localizedDescription
                        )
                    }
                }
            }
        } else {
            for notice in pendingNotices {
                NotificationAuditManager.shared.record(
                    productID: notice.productID,
                    productName: notice.productName,
                    variantTitle: notice.variantTitle,
                    channel: .macOS,
                    status: .failed,
                    message: "macOS bildirim izni verilmedi veya reddedildi."
                )
            }
            pendingNotices.removeAll()
        }

        isProcessingNotices = false
    }
}

private extension View {
    /// Consistent layout for every Settings tab form.
    func settingsFormLayout() -> some View {
        self
            .formStyle(.grouped)
            .contentMargins(.horizontal, 24, for: .scrollContent)
            .contentMargins(.top, 10, for: .scrollContent)
            .contentMargins(.bottom, 16, for: .scrollContent)
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SettingsWindowConfigurator())
    }
}

private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowObserverView {
        let view = WindowObserverView()
        view.onWindowAvailable = { window in
            Self.configure(window)
            DispatchQueue.main.async {
                Self.configure(window)
            }
            NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { _ in
                DispatchQueue.main.async {
                    Self.configure(window)
                }
            }
            NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { _ in
                DispatchQueue.main.async {
                    Self.configure(window)
                }
            }
            NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak window] _ in
                DispatchQueue.main.async {
                    if let window, !window.styleMask.contains(.resizable) {
                        Self.configure(window)
                    }
                }
            }
        }
        return view
    }

    private static func configure(_ window: NSWindow) {
        if !window.styleMask.contains(.resizable) {
            window.styleMask.insert(.resizable)
        }
        window.minSize = NSSize(width: 620, height: 520)
        window.maxSize = NSSize(width: 1100, height: 850)
        window.contentMinSize = NSSize(width: 620, height: 520)
        window.contentMaxSize = NSSize(width: 1100, height: 850)
        window.standardWindowButton(.zoomButton)?.isEnabled = true
    }

    func updateNSView(_ view: WindowObserverView, context: Context) {
        if let window = view.window {
            Self.configure(window)
        }
    }
}

private struct SettingsView: View {
    @AppStorage("automaticCheckingEnabled") private var automaticCheckingEnabled = true
    @AppStorage("checkIntervalMinutes") private var checkIntervalMinutes = 1
    @AppStorage("adaptiveMonitoringEnabled") private var adaptiveMonitoringEnabled = false
    @AppStorage("stockNotificationsEnabled") private var stockNotificationsEnabled = true
    @AppStorage("emailNotificationsEnabled") private var emailNotificationsEnabled = false
    @AppStorage("monitoringScheduleEnabled") private var monitoringScheduleEnabled = false
    @AppStorage("monitoringScheduleStartHour") private var monitoringScheduleStartHour = 9
    @AppStorage("monitoringScheduleStartMinute") private var monitoringScheduleStartMinute = 0
    @AppStorage("monitoringScheduleEndHour") private var monitoringScheduleEndHour = 23
    @AppStorage("monitoringScheduleEndMinute") private var monitoringScheduleEndMinute = 0
    @AppStorage("monitoringScheduleWeekdays") private var monitoringScheduleWeekdays = "1,2,3,4,5,6,7"
    @AppStorage("autoOpenOnRestockEnabled") private var autoOpenOnRestockEnabled = false
    @AppStorage("launchAtLoginEnabled") private var launchAtLoginEnabled = false
    @AppStorage("monitoringPowerMode") private var monitoringPowerMode: MonitoringPowerMode = .allowDisplaySleepKeepMacAwake
    @AppStorage("closedDisplayMonitoringEnabled") private var closedDisplayMonitoringEnabled = false
    @AppStorage("closedDisplayRequireACPower") private var closedDisplayRequireACPower = true
    @AppStorage("closedDisplayMinBatteryLevel") private var closedDisplayMinBatteryLevel = 20
    @AppStorage("restockVerificationMode") private var globalVerificationMode: RestockVerificationMode = .off
    @AppStorage("restockBurstModeEnabled") private var restockBurstModeEnabled = true
    @AppStorage("restockBurstIntervalMinutes") private var restockBurstIntervalMinutes = 2
    @AppStorage("restockBurstDurationMinutes") private var restockBurstDurationMinutes = 30
    @ObservedObject private var closedDisplayManager = ClosedDisplayManager.shared
    @State private var isAuthorizingHelper = false
    @State private var helperActionMessage: String?
    @State private var launchAtLoginMessage: String?
    @State private var showingResetConfirmation = false
    @State private var isSendingTestEmail = false
    @State private var testEmailStatusMessage: String?
    @State private var testEmailStatusIsError = false

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("Genel", systemImage: "gearshape") }
            monitoringTab
                .tabItem { Label("İzleme", systemImage: "timer") }
            notificationsTab
                .tabItem { Label("Bildirimler", systemImage: "bell") }
            powerTab
                .tabItem { Label("Güç ve Kapak", systemImage: "bolt.fill") }
            storesTab
                .tabItem { Label("Mağazalar", systemImage: "storefront") }
            advancedTab
                .tabItem { Label("Gelişmiş", systemImage: "wrench.and.screwdriver") }
        }
        .frame(
            minWidth: 620,
            idealWidth: 760,
            maxWidth: 1100,
            minHeight: 520,
            idealHeight: 650,
            maxHeight: 850
        )
        .background(SettingsWindowConfigurator())
        .onAppear {
            synchronizeLaunchAtLoginPreference()
            closedDisplayManager.checkAuthorization()
        }
        .confirmationDialog(
            "Ayarlar varsayılan değerlere dönsün mü?",
            isPresented: $showingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Varsayılanlara Dön", role: .destructive, action: resetSettings)
            Button("İptal", role: .cancel) {}
        } message: {
            Text("Takip edilen ürünler ve ürün bazlı aralıklar korunur.")
        }
    }

    private var generalTab: some View {
        Form {
            Section("Otomatik Kontrol") {
                Toggle(isOn: $automaticCheckingEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Otomatik kontrol")
                        Text("Kontroller, StockPing çalıştığı sürece arka planda gerçekleştirilir.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Picker("Yeni ürünler için varsayılan kontrol aralığı", selection: $checkIntervalMinutes) {
                    ForEach(ProductCheckInterval.minutes, id: \.self) { minutes in
                        Text(ProductCheckInterval.title(for: minutes)).tag(minutes)
                    }
                }
            }

            Section("Başlangıç") {
                Toggle(
                    isOn: Binding(
                        get: { launchAtLoginEnabled },
                        set: setLaunchAtLogin
                    )
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mac açıldığında başlat")
                        if let launchAtLoginMessage {
                            Text(launchAtLoginMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .settingsFormLayout()
    }

    private var monitoringTab: some View {
        Form {
            Section("Akıllı Aralık") {
                Toggle(isOn: $adaptiveMonitoringEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Akıllı kontrol aralığı (Adaptive Monitoring)")
                        Text("Uzun süre değişiklik olmadığında kontrol sıklığını otomatik olarak azaltır ve mağaza sunucularına gereksiz istekleri sınırlar.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section("Zamanlanmış İzleme") {
                Toggle("Zamanlanmış izlemeyi etkinleştir", isOn: $monitoringScheduleEnabled)

                if monitoringScheduleEnabled {
                    HStack {
                        Text("Başlangıç saati:")
                        Spacer()
                        Picker("Saat", selection: $monitoringScheduleStartHour) {
                            ForEach(0..<24, id: \.self) { h in
                                Text(String(format: "%02d:00", h)).tag(h)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 90)
                    }

                    HStack {
                        Text("Bitiş saati:")
                        Spacer()
                        Picker("Saat", selection: $monitoringScheduleEndHour) {
                            ForEach(0..<24, id: \.self) { h in
                                Text(String(format: "%02d:00", h)).tag(h)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 90)
                    }

                    Text("Otomatik kontroller yalnızca belirlenen saatler arasında çalışır. Manuel kontroller her zaman yapılabilir.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Restock Doğrulama ve Burst Modu") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Genel Restock Doğrulama", selection: $globalVerificationMode) {
                        ForEach(RestockVerificationMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Text(globalVerificationMode.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle(isOn: $restockBurstModeEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Restock Burst Modu")
                        Text("Stok tespit edildiğinde geçici olarak yüksek frekanslı izleme yaparak stoğun stabilitesini takip eder.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if restockBurstModeEnabled {
                    Picker("Burst kontrol sıklığı", selection: $restockBurstIntervalMinutes) {
                        Text("1 dakika").tag(1)
                        Text("2 dakika").tag(2)
                    }

                    Picker("Burst süresi", selection: $restockBurstDurationMinutes) {
                        Text("15 dakika").tag(15)
                        Text("30 dakika").tag(30)
                        Text("45 dakika").tag(45)
                        Text("60 dakika").tag(60)
                    }
                }
            }
        }
        .settingsFormLayout()
    }

    private var notificationsTab: some View {
        Form {
            Section("macOS Bildirimleri") {
                Toggle(isOn: $stockNotificationsEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bildirimler")
                        Text("Stok durumu değiştiğinde sistem bildirimi ve sesli uyarı verir.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section("E-posta Bildirimi") {
                Toggle(isOn: $emailNotificationsEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("E-posta bildirimi")
                        Text("Ürün tekrar stokta olduğunda macOS Mail üzerinden e-posta gönderir.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if emailNotificationsEnabled {
                    Button {
                        sendTestEmail()
                    } label: {
                        if isSendingTestEmail {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("E-posta gönderiliyor…")
                            }
                        } else {
                            Text("Test e-postası gönder")
                        }
                    }
                    .disabled(isSendingTestEmail)

                    if let testEmailStatusMessage {
                        Text(testEmailStatusMessage)
                            .font(.caption)
                            .foregroundStyle(testEmailStatusIsError ? .red : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section("Otomasyon") {
                Toggle(isOn: $autoOpenOnRestockEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Stok geldiğinde tarayıcıda otomatik aç")
                        Text("Ürün stoğa girdiğinde ürün sayfasını varsayılan web tarayıcınızda otomatik olarak açar (Doğrulama etkinse onay sonrasında açılır).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .settingsFormLayout()
    }

    private var powerTab: some View {
        Form {
            Section("Mac Güç Yönetimi") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("İzleme sırasında güç modu", selection: $monitoringPowerMode) {
                        ForEach(MonitoringPowerMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .accessibilityLabel("İzleme sırasında güç modu")

                    Text(monitoringPowerMode.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Kapak Kapalı Takip Modu (Closed-Display)") {
                Toggle(isOn: $closedDisplayMonitoringEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Kapak Kapalı Takip Modu")
                        Text("Apple Silicon Mac'lerde ekran kapağı kapatıldığında dahili ekran kapanır, Mac uykuya geçmez ve arka plan stok kontrolleri kesintisiz devam eder.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if closedDisplayMonitoringEnabled {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Ayrıcalıklı Yardımcı:")
                                .font(.callout)
                            Spacer()
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(closedDisplayManager.authorizationStatus == .authorized ? Color.green : Color.orange)
                                    .frame(width: 8, height: 8)
                                Text(closedDisplayManager.authorizationStatus.title)
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(closedDisplayManager.authorizationStatus == .authorized ? .green : .orange)
                            }
                        }

                        if closedDisplayManager.authorizationStatus != .authorized {
                            Button(action: installHelperAuth) {
                                HStack(spacing: 6) {
                                    Image(systemName: "lock.shield")
                                    Text("Kapak Kapalı Modu Yetkilendir (Tek Seferlik)")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(isAuthorizingHelper)

                            Text("Kapak kapalı modun macOS tarafından engellenmemesi için sistem 'pmset disablesleep' komutu için tek seferlik yönetici izni gerektirir.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            HStack(spacing: 12) {
                                Button("Yetkiyi Test Et") {
                                    closedDisplayManager.checkAuthorization()
                                    if closedDisplayManager.authorizationStatus == .authorized {
                                        helperActionMessage = "Yetkilendirme başarıyla doğrulandı."
                                    } else {
                                        helperActionMessage = "Yetkilendirme başarısız."
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button("Yetkiyi Kaldır", role: .destructive) {
                                    let success = closedDisplayManager.removeAuthorization()
                                    if success {
                                        helperActionMessage = "Yetkilendirme kaldırıldı."
                                    } else {
                                        helperActionMessage = "Yetkilendirme kaldırılamadı."
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }

                        if let helperActionMessage {
                            Text(helperActionMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Divider()

                        Toggle("Yalnızca prize takılıyken çalıştır", isOn: $closedDisplayRequireACPower)

                        HStack {
                            Text("Minimum pil seviyesi: %\(closedDisplayMinBatteryLevel)")
                            Spacer()
                            Slider(
                                value: Binding(
                                    get: { Double(closedDisplayMinBatteryLevel) },
                                    set: { closedDisplayMinBatteryLevel = Int($0) }
                                ),
                                in: 10...50,
                                step: 5
                            )
                            .frame(width: 140)
                        }
                        Text("Pil bu seviyenin altına düştüğünde veya pil gücündeyken (ayar seçildiyse) kapak kapalı takip modu otomatik olarak durdurulur.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .settingsFormLayout()
    }

    private var storesTab: some View {
        Form {
            Section("Mağaza Durumu") {
                let savedProducts = TrackedProductStore.load()
                let summaries = ProviderHealthSummary.allSummaries(for: savedProducts, isNetworkAvailable: NetworkReachabilityMonitor.shared.canProceedWithChecks)
                ForEach(summaries) { summary in
                    HStack {
                        Image(systemName: summary.health.symbol)
                            .foregroundStyle(summary.health.color)
                        Text(summary.provider.displayName)
                        Spacer()
                        Text("\(summary.productCount) ürün")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("(\(summary.health.title))")
                            .foregroundStyle(summary.health.color)
                            .font(.caption)
                    }
                }
            }
        }
        .settingsFormLayout()
    }

    private var advancedTab: some View {
        Form {
            Section("Yedekleme ve Geri Yükleme") {
                HStack(spacing: 12) {
                    Button("Yedek Dışa Aktar...") {
                        ProductBackupService.shared.exportProducts(TrackedProductStore.load())
                    }
                    .buttonStyle(.bordered)

                    Button("Yedekten Geri Yükle...") {
                        ProductBackupService.shared.promptImport(existingProducts: TrackedProductStore.load()) { imported in
                            guard !imported.isEmpty else { return }
                            var current = TrackedProductStore.load()
                            current.append(contentsOf: imported)
                            TrackedProductStore.save(current)
                        }
                    }
                    .buttonStyle(.bordered)
                }

                Text("Tüm takip edilen ürünleri, akıllı takip kurallarını ve ayarları JSON formatında yedekleyin veya geri yükleyin.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Sıfırlama") {
                Button("Varsayılanlara Dön", role: .destructive) {
                    showingResetConfirmation = true
                }
                Text("StockPing ayarlarını varsayılan fabrika değerlerine döndürür. Takip edilen ürünleriniz silinmez.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsFormLayout()
    }

    private func synchronizeLaunchAtLoginPreference() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginEnabled = true
            launchAtLoginMessage = "macOS'ta etkin."
        case .requiresApproval:
            launchAtLoginEnabled = true
            launchAtLoginMessage = "macOS onayı gerekiyor. Sistem Ayarları > Genel > Giriş Öğeleri'ni kontrol edin."
        case .notRegistered:
            launchAtLoginEnabled = false
            launchAtLoginMessage = nil
        case .notFound:
            launchAtLoginEnabled = false
            launchAtLoginMessage = "macOS uygulama kaydını bulamadı. Uygulamayı yeniden derleyip açın."
        @unknown default:
            launchAtLoginEnabled = false
            launchAtLoginMessage = "macOS giriş durumu doğrulanamadı."
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        launchAtLoginMessage = nil

        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else if service.status != .notRegistered {
                try service.unregister()
            }

            synchronizeLaunchAtLoginPreference()

            if enabled, service.status == .notRegistered {
                launchAtLoginEnabled = false
                launchAtLoginMessage = "macOS kaydı tamamlamadı. Tekrar deneyin."
            } else if !enabled, service.status == .notRegistered {
                launchAtLoginMessage = "Mac açıldığında başlatma kapalı."
            }
        } catch {
            synchronizeLaunchAtLoginPreference()
            launchAtLoginMessage = "Ayar uygulanamadı: \(error.localizedDescription)"
        }
    }

    private func sendTestEmail() {
        guard !isSendingTestEmail else { return }
        isSendingTestEmail = true
        testEmailStatusMessage = "E-posta gönderiliyor…"
        testEmailStatusIsError = false

        Task { @MainActor in
            do {
                let recipient = try await EmailNotificationService.shared.sendTestEmail()
                testEmailStatusMessage = recipient.isEmpty ? "Test e-postası gönderildi." : "Test e-postası gönderildi (\(recipient))."
                testEmailStatusIsError = false
            } catch {
                let message = (error as? EmailNotificationError)?.localizedDescription ?? error.localizedDescription
                testEmailStatusMessage = "E-posta gönderilemedi: \(message)"
                testEmailStatusIsError = true
            }
            isSendingTestEmail = false
        }
    }

    private func installHelperAuth() {
        guard !isAuthorizingHelper else { return }
        isAuthorizingHelper = true
        helperActionMessage = "Yönetici onayı bekleniyor..."

        Task { @MainActor in
            let success = closedDisplayManager.requestAuthorization()
            if success {
                helperActionMessage = "Yetkilendirme tamamlandı ve doğrulandı."
            } else {
                let err = closedDisplayManager.lastErrorMessage ?? "Yetki dosyası oluşturuldu fakat doğrulanamadı."
                helperActionMessage = "Yetkilendirme hatası: \(err)"
            }
            isAuthorizingHelper = false
        }
    }

    private func resetSettings() {
        automaticCheckingEnabled = true
        checkIntervalMinutes = 1
        adaptiveMonitoringEnabled = false
        stockNotificationsEnabled = true
        emailNotificationsEnabled = false
        monitoringScheduleEnabled = false
        monitoringScheduleStartHour = 9
        monitoringScheduleStartMinute = 0
        monitoringScheduleEndHour = 23
        monitoringScheduleEndMinute = 0
        monitoringScheduleWeekdays = "1,2,3,4,5,6,7"
        autoOpenOnRestockEnabled = false
        monitoringPowerMode = .default
        closedDisplayMonitoringEnabled = false
        closedDisplayRequireACPower = true
        closedDisplayMinBatteryLevel = 20
        globalVerificationMode = .off
        restockBurstModeEnabled = true
        restockBurstIntervalMinutes = 2
        restockBurstDurationMinutes = 30
        helperActionMessage = nil
        testEmailStatusMessage = nil
        testEmailStatusIsError = false
        if launchAtLoginEnabled || SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
            setLaunchAtLogin(false)
        } else {
            launchAtLoginEnabled = false
            launchAtLoginMessage = nil
        }
    }
}

private enum ProductAnalysisFailure: LocalizedError {
    case invalidURL
    case unavailable(String)
    case unreadable
    case notFound
    case noVariants

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "HTTPS kullanan geçerli bir Shopify, Zara Türkiye, Bershka Türkiye veya Pull&Bear Türkiye ürün URL'si girin."
        case .unavailable(let detail):
            "Ürün sayfasına erişilemedi. \(detail)"
        case .unreadable:
            "Ürün bilgisi okunamadı. Lütfen tekrar deneyin."
        case .notFound:
            "Bu URL için ürün bulunamadı."
        case .noVariants:
            "Bu üründe takip edilebilir varyant bulunamadı."
        }
    }
}

private struct AddProductSheet: View {
    let defaultIntervalMinutes: Int
    let existingProducts: [TrackedProduct]
    var initialURL: String? = nil
    let onAddMultiple: ([TrackedProduct]) -> (added: Int, duplicates: Int)

    @Environment(\.dismiss) private var dismiss
    @State private var productURLText = ""
    @State private var autoAnalysisTask: Task<Void, Never>?
    @State private var analysisURL: URL?
    @State private var analysisRequestID = 0
    @State private var isAnalyzing = false
    @State private var productName: String?
    @State private var provider: StoreProvider = .shopify
    @State private var variants: [StoreVariantCandidate] = []
    @State private var optionDimensions: [DiscoveredOptionDimension] = []
    @State private var selectedFilterOptionValue = "all"
    @State private var selectedVariantIDs: Set<String> = []
    @State private var selectedTrackingRule: SmartTrackingRule = .exactVariant
    @State private var analysisError: String?
    @State private var duplicateError: String?
    @FocusState private var isURLFieldFocused: Bool

    private var canAnalyzeURL: Bool {
        Self.validatedProductURL(productURLText) != nil
    }

    private var filterDimension: DiscoveredOptionDimension? {
        optionDimensions.first(where: { $0.values.count > 1 })
    }

    private var visibleVariants: [StoreVariantCandidate] {
        guard let filter = filterDimension, selectedFilterOptionValue != "all" else {
            return variants
        }
        return variants.filter { candidate in
            candidate.variant.options.contains { $0.name == filter.name && $0.value == selectedFilterOptionValue }
        }
    }

    private func isCandidateAlreadyTracked(_ candidate: StoreVariantCandidate) -> Bool {
        guard let analysisURL else { return false }
        return existingProducts.contains { existing in
            existing.matches(candidate: candidate, productURL: analysisURL, provider: provider)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header / introduction
                VStack(alignment: .leading, spacing: 4) {
                    Text("Yeni Ürün Ekle")
                        .font(.title2.weight(.semibold))
                    Text("Takip etmek istediğiniz ürünün bağlantısını yapıştırın.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

                // Scrollable content area
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 14) {
                        GroupBox("Ürün URL'si") {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 8) {
                                    Image(systemName: "link")
                                        .foregroundStyle(.secondary)
                                    TextField("https://shop.example.com/products/...", text: $productURLText)
                                        .textFieldStyle(.plain)
                                        .focused($isURLFieldFocused)
                                        .accessibilityLabel("Ürün URL'si")
                                        .disabled(isAnalyzing)
                                        .onChange(of: productURLText) { _, newText in
                                            let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
                                            if trimmed.isEmpty {
                                                clearAnalysis()
                                                return
                                            }
                                            guard let url = Self.validatedProductURL(trimmed) else {
                                                clearAnalysis()
                                                return
                                            }
                                            if analysisURL != url && !isAnalyzing {
                                                autoAnalysisTask?.cancel()
                                                autoAnalysisTask = Task { @MainActor in
                                                    try? await Task.sleep(nanoseconds: 400_000_000)
                                                    guard !Task.isCancelled, !isAnalyzing, analysisURL != url else { return }
                                                    analyzeProduct()
                                                }
                                            }
                                        }
                                }
                                .padding(.vertical, 7)
                                .padding(.horizontal, 9)
                                .background(.background, in: RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(.quaternary, lineWidth: 1))

                                HStack(spacing: 10) {
                                    Button(action: analyzeProduct) {
                                        if isAnalyzing {
                                            Label("Analiz ediliyor…", systemImage: "hourglass")
                                        } else {
                                            Label("Ürünü Analiz Et", systemImage: "magnifyingglass")
                                        }
                                    }
                                    .disabled(isAnalyzing || !canAnalyzeURL)
                                    .accessibilityLabel("Ürünü Analiz Et")

                                    if isAnalyzing {
                                        ProgressView()
                                            .controlSize(.small)
                                            .accessibilityLabel("Ürün analiz ediliyor")
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                        }

                        if let analysisError {
                            Label(analysisError, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityLabel("Ürün analizi hatası: \(analysisError)")
                        }
                        if let duplicateError {
                            Label(duplicateError, systemImage: "exclamationmark.circle.fill")
                                .font(.callout)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let productName {
                            GroupBox {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(productName)
                                            .font(.headline)
                                            .lineLimit(2)
                                            .truncationMode(.tail)
                                        Spacer(minLength: 8)
                                        Text(provider.displayName)
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(.quaternary, in: Capsule())
                                    }

                                    Divider()

                                    HStack(spacing: 12) {
                                        if let filterDim = filterDimension {
                                            Picker(filterDim.name, selection: $selectedFilterOptionValue) {
                                                Text("Tüm \(filterDim.name)ler (\(variants.count))").tag("all")
                                                ForEach(filterDim.values, id: \.self) { val in
                                                    let count = variants.filter { c in
                                                        c.variant.options.contains { $0.name == filterDim.name && $0.value == val }
                                                    }.count
                                                    Text("\(val) (\(count))").tag(val)
                                                }
                                            }
                                            .pickerStyle(.menu)
                                            .frame(maxWidth: 180)
                                        }

                                        Spacer(minLength: 0)

                                        Button("Tümünü Seç") {
                                            let selectable = visibleVariants.filter { !isCandidateAlreadyTracked($0) }.map(\.id)
                                            selectedVariantIDs.formUnion(selectable)
                                        }
                                        .buttonStyle(.link)
                                        .font(.caption)
                                        .disabled(visibleVariants.allSatisfy { isCandidateAlreadyTracked($0) })

                                        Text("·")
                                            .foregroundStyle(.tertiary)

                                        Button("Seçimi Temizle") {
                                            let visibleIDs = Set(visibleVariants.map(\.id))
                                            selectedVariantIDs.subtract(visibleIDs)
                                        }
                                        .buttonStyle(.link)
                                        .font(.caption)
                                        .disabled(selectedVariantIDs.isEmpty)
                                    }

                                    ScrollView {
                                        VStack(spacing: 2) {
                                            ForEach(visibleVariants) { candidate in
                                                candidateRow(candidate)
                                            }
                                        }
                                        .padding(4)
                                    }
                                    .frame(maxHeight: 180)
                                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.15), lineWidth: 1))

                                    Divider()

                                    smartTrackingSelector
                                }
                                .padding(4)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
                }

                // Fixed bottom action bar
                VStack(spacing: 12) {
                    Divider()
                    HStack {
                        Button("İptal") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                        Spacer()
                        let selectedCount = selectedVariantIDs.count
                        let buttonTitle = selectedCount > 1 ? "\(selectedCount) Varyantı Takibe Ekle" : "Takibe Ekle"
                        Button(buttonTitle, action: addSelectedProducts)
                            .buttonStyle(.borderedProminent)
                            .disabled(selectedVariantIDs.isEmpty || isAnalyzing)
                            .keyboardShortcut(.defaultAction)
                            .accessibilityLabel(buttonTitle)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle("Yeni Ürün Ekle")
            .background {
                if let analysisURL {
                    ProductAnalyzerWebView(
                        productURL: analysisURL,
                        requestID: analysisRequestID,
                        isAnalyzing: $isAnalyzing,
                        onResult: handleAnalysisResult
                    )
                    .id(analysisRequestID)
                    // Pull&Bear only renders its size UI at a real page viewport; keep this analysis WebView hidden but laid out like a desktop page.
                    .frame(
                        width: PullAndBearChecker.canHandle(analysisURL) ? 1200 : 1,
                        height: PullAndBearChecker.canHandle(analysisURL) ? 800 : 1
                    )
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
        }
        .frame(minWidth: 480, idealWidth: 540, maxWidth: 640, minHeight: 480, idealHeight: 560, maxHeight: 720)
        .onAppear {
            isURLFieldFocused = true
            if let initialURL = initialURL?.trimmingCharacters(in: .whitespacesAndNewlines), !initialURL.isEmpty {
                productURLText = initialURL
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    analyzeProduct()
                }
            }
        }
        .onDisappear {
            autoAnalysisTask?.cancel()
        }
    }

    private func analyzeProduct() {
        clearAnalysis()
        guard let parsedURL = Self.validatedProductURL(productURLText) else {
            analysisError = ProductAnalysisFailure.invalidURL.localizedDescription
            return
        }

        analysisURL = parsedURL
        isAnalyzing = true
        analysisRequestID += 1
    }

    private func clearAnalysis() {
        analysisURL = nil
        isAnalyzing = false
        productName = nil
        provider = .shopify
        variants = []
        optionDimensions = []
        selectedFilterOptionValue = "all"
        selectedVariantIDs = []
        selectedTrackingRule = .exactVariant
        analysisError = nil
        duplicateError = nil
    }

    private func handleAnalysisResult(_ result: Result<StoreProductAnalysis, ProductAnalysisFailure>) {
        isAnalyzing = false
        switch result {
        case .success(let analysis):
            productName = analysis.productName
            provider = analysis.provider
            variants = analysis.variants
            optionDimensions = analysis.optionDimensions
            duplicateError = nil
            analysisError = nil

            if let primaryDim = analysis.optionDimensions.first(where: { $0.values.count > 1 }) {
                if provider == .bershka, let url = analysisURL,
                   let colorID = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name.caseInsensitiveCompare("colorId") == .orderedSame })?.value,
                   let matching = variants.first(where: { $0.bershkaMetadata?.colorID == colorID }),
                   let matchingVal = matching.variant.options.first(where: { $0.name == primaryDim.name })?.value {
                    selectedFilterOptionValue = matchingVal
                } else if provider == .pullAndBear, let url = analysisURL,
                          let cs = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name.caseInsensitiveCompare("cS") == .orderedSame })?.value,
                          let matching = variants.first(where: { $0.pullAndBearMetadata?.colorIdentity == cs }),
                          let matchingVal = matching.variant.options.first(where: { $0.name == primaryDim.name })?.value {
                    selectedFilterOptionValue = matchingVal
                } else {
                    selectedFilterOptionValue = "all"
                }
            } else {
                selectedFilterOptionValue = "all"
            }

            // Auto-select first available, untracked variant
            let firstSelectable = variants.first { !isCandidateAlreadyTracked($0) }
            if let firstSelectable {
                selectedVariantIDs = [firstSelectable.id]
            } else {
                selectedVariantIDs = []
            }

        case .failure(let error):
            analysisError = error.localizedDescription
        }
    }

    private func addSelectedProducts() {
        guard let analysisURL, let productName else { return }
        duplicateError = nil

        let candidatesToAdd = variants.filter { selectedVariantIDs.contains($0.id) }
        guard !candidatesToAdd.isEmpty else { return }

        let snapshots = variants.map { VariantStockSnapshot(from: $0, lastChecked: Date()) }
        let products = candidatesToAdd.map { candidate in
            TrackedProduct(
                id: UUID(),
                productName: productName,
                productURL: analysisURL,
                selectedVariant: candidate.variant,
                lastChecked: nil,
                checkIntervalMinutes: defaultIntervalMinutes,
                nextCheckDate: Date(),
                isPaused: false,
                lastCheckError: nil,
                lastAvailabilityTransition: nil,
                provider: provider,
                zaraMetadata: candidate.zaraMetadata,
                bershkaMetadata: candidate.bershkaMetadata,
                pullAndBearMetadata: candidate.pullAndBearMetadata,
                hmMetadata: candidate.hmMetadata,
                events: [],
                variantSnapshots: snapshots,
                trackingRule: selectedTrackingRule
            )
        }

        let result = onAddMultiple(products)
        if result.added > 0 {
            dismiss()
        } else {
            duplicateError = "Seçilen varyantlar zaten takip ediliyor."
        }
    }

    @ViewBuilder
    private func candidateRow(_ candidate: StoreVariantCandidate) -> some View {
        let isTracked = isCandidateAlreadyTracked(candidate)
        let isSelected = selectedVariantIDs.contains(candidate.id)

        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { shouldSelect in
                    if shouldSelect {
                        selectedVariantIDs.insert(candidate.id)
                    } else {
                        selectedVariantIDs.remove(candidate.id)
                    }
                }
            ))
            .labelsHidden()
            .disabled(isTracked)

            Text(candidate.displayTitle)
                .font(.body)
                .foregroundStyle(isTracked ? .secondary : .primary)
                .strikethrough(isTracked)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            candidateAvailabilityBadge(available: candidate.initialAvailability)

            if isTracked {
                Text("Zaten Takipte")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15), in: Capsule())
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isTracked else { return }
            if isSelected {
                selectedVariantIDs.remove(candidate.id)
            } else {
                selectedVariantIDs.insert(candidate.id)
            }
        }
    }

    @ViewBuilder
    private func candidateAvailabilityBadge(available: Bool?) -> some View {
        if let available {
            if available {
                Text("Stokta")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.15), in: Capsule())
                    .foregroundStyle(.green)
            } else {
                Text("Stokta değil")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var smartTrackingSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Akıllı Takip Kuralı")
                .font(.subheadline.weight(.medium))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8)], spacing: 8) {
                ForEach(SmartTrackingRule.allCases) { rule in
                    let isSelected = selectedTrackingRule == rule
                    Button {
                        selectedTrackingRule = rule
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: rule.symbol)
                                .font(.subheadline)
                                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                            Text(rule.title)
                                .font(.callout)
                                .fontWeight(isSelected ? .semibold : .regular)
                                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                                .multilineTextAlignment(.leading)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)

                            Spacer(minLength: 4)

                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor).opacity(0.5))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isSelected ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.15), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(rule.title)
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }

            let firstCandidate = variants.first { selectedVariantIDs.contains($0.id) }
            let colVal = firstCandidate?.variant.options.first(where: { SmartTrackingRule.isColorOptionName($0.name) })?.value
            let szVal = firstCandidate?.variant.options.first(where: { SmartTrackingRule.isSizeOptionName($0.name) })?.value

            Text(selectedTrackingRule.preview(color: colVal, size: szVal))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private static func validatedProductURL(_ value: String) -> URL? {
        StoreCheckerRouter.normalizedProductURL(from: value)
    }
}

private struct ProductAnalyzerWebView: NSViewRepresentable {
    let productURL: URL
    let requestID: Int
    @Binding var isAnalyzing: Bool
    let onResult: (Result<StoreProductAnalysis, ProductAnalysisFailure>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(productURL: productURL, requestID: requestID, isAnalyzing: $isAnalyzing, onResult: onResult)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: productURL))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let productURL: URL
        private let requestID: Int
        private var isAnalyzing: Binding<Bool>
        private let onResult: (Result<StoreProductAnalysis, ProductAnalysisFailure>) -> Void
        private var didStartAnalysis = false

        init(
            productURL: URL,
            requestID: Int,
            isAnalyzing: Binding<Bool>,
            onResult: @escaping (Result<StoreProductAnalysis, ProductAnalysisFailure>) -> Void
        ) {
            self.productURL = productURL
            self.requestID = requestID
            self.isAnalyzing = isAnalyzing
            self.onResult = onResult
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !didStartAnalysis else { return }
            didStartAnalysis = true

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.fetchProductJSON(in: webView)
            }
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            finish(.failure(.unavailable(error.localizedDescription)))
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            finish(.failure(.unavailable(error.localizedDescription)))
        }

        private func fetchProductJSON(in webView: WKWebView) {
            Task { [weak self] in
                guard let self else { return }
                do {
                    let product = try await StoreCheckerRouter.analyze(in: webView, productURL: self.productURL, activePageURL: webView.url)
                    self.finish(.success(product))
                } catch {
                    self.finish(.failure(Self.analysisFailure(for: error)))
                }
            }
        }

        private static func analysisFailure(for error: Error) -> ProductAnalysisFailure {
            if let shopifyError = error as? ShopifyCheckerError {
                return switch shopifyError {
                case .invalidProductURL: .invalidURL
                case .productNotFound: .notFound
                case .noVariants: .noVariants
                case .requestFailed(let detail): .unavailable(detail)
                default: .unreadable
                }
            }
            if let zaraError = error as? ZaraCheckerError {
                return switch zaraError {
                case .invalidURL, .unsupportedMarket: .invalidURL
                case .noColors, .noSizes: .noVariants
                case .availabilityRequestFailed(let detail): .unavailable(detail)
                default: .unreadable
                }
            }
            if let bershkaError = error as? BershkaCheckerError {
                return switch bershkaError {
                case .invalidURL, .unsupportedMarket: .invalidURL
                case .noSizes, .colorNotFound: .noVariants
                case .pageLoadTimedOut: .unavailable(bershkaError.localizedDescription)
                default: .unreadable
                }
            }
            if let pullAndBearError = error as? PullAndBearCheckerError {
                return switch pullAndBearError {
                case .invalidURL, .unsupportedMarket: .invalidURL
                case .productUnavailable, .colorUnavailable, .selectedSizeUnavailable: .noVariants
                case .pageLoadTimedOut: .unavailable(pullAndBearError.localizedDescription)
                case .productCodeMismatch, .ambiguousSizeState, .javascriptEvaluationTimedOut: .unreadable
                }
            }
            return error is StoreCheckerError ? .invalidURL : .unreadable
        }

        private func finish(_ result: Result<StoreProductAnalysis, ProductAnalysisFailure>) {
            isAnalyzing.wrappedValue = false
            onResult(result)
        }
    }
}
