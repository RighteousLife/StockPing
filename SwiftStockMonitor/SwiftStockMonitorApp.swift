import SwiftUI
import WebKit
import UserNotifications
import AppKit
import ServiceManagement
import Combine
import Network

private enum ProductListFilter: String, CaseIterable, Identifiable {
    case all, inStock, outOfStock, checking, error, paused, priority, noGroup

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
}

@main
struct SwiftStockMonitorApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: SwiftStockAppDelegate
    @StateObject private var menuBarState = SwiftStockMenuBarState()
    @StateObject private var windowController = MainWindowController()

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
                .frame(width: 480, height: 540)
        }
    }
}

@MainActor
private final class SwiftStockAppDelegate: NSObject, NSApplicationDelegate {
    static var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.isTerminating = true
        SleepPreventionManager.shared.configure(isMonitoringActive: false, mode: .normal)
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
private final class SwiftStockMenuBarState: ObservableObject {
    @Published var productCount = 0
    @Published var inStockCount = 0
    @Published var outOfStockCount = 0
    @Published var unknownStockCount = 0
    @Published var pausedCount = 0
    @Published var priorityCount = 0
    @Published var errorCount = 0
    @Published var isChecking = false
    @Published var isAllPaused = false
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
private final class MainWindowController: ObservableObject {
    private weak var mainWindow: NSWindow?
    private var closeDelegateProxy: CloseToHideWindowDelegate?

    func attach(to window: NSWindow) {
        if mainWindow === window {
            if let closeDelegateProxy,
               (window.delegate as AnyObject?) !== closeDelegateProxy {
                window.delegate = closeDelegateProxy
            }
            return
        }

        let proxy = CloseToHideWindowDelegate(forwarding: window.delegate)
        closeDelegateProxy = proxy
        mainWindow = window
        window.delegate = proxy
    }

    @discardableResult
    func showMainWindow() -> Bool {
        guard let mainWindow else { return false }
        mainWindow.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        return true
    }
}

private final class CloseToHideWindowDelegate: NSObject, NSWindowDelegate {
    private weak var downstreamDelegate: (any NSWindowDelegate)?

    init(forwarding delegate: (any NSWindowDelegate)?) {
        downstreamDelegate = delegate
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !SwiftStockAppDelegate.isTerminating else { return true }
        sender.orderOut(nil)
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
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text("StockPing")
            .font(.headline)

        if networkMonitor.status == .unavailable {
            Text("⚠️ Ağ bağlantısı yok (Kontroller duraklatıldı)")
        } else if networkMonitor.status == .recovering {
            Text("🔄 Ağ bağlantısı bekleniyor...")
        } else if menuBarState.isChecking {
            Text("⏳ Kontroller yapılıyor...")
        } else if menuBarState.isAllPaused {
            Text("⏸️ Tüm takipler duraklatıldı")
        } else {
            Text("● \(menuBarState.productCount) ürün izleniyor")
        }

        Divider()

        Text("Stokta: \(menuBarState.inStockCount)")
        Text("Stok dışı: \(menuBarState.outOfStockCount)")
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
        if let schedText = menuBarState.scheduleStatusText {
            Text("⏰ \(schedText)")
                .font(.caption)
        }
        Text("🏪 \(menuBarState.providerHealthText)")
            .font(.caption)

        Divider()

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

        Button("StockPing'i Aç", systemImage: "macwindow") {
            NSApp.activate(ignoringOtherApps: true)
            if !windowController.showMainWindow() {
                openWindow(id: "main")
            }
        }

        Button("Şimdi Tümünü Kontrol Et", systemImage: "arrow.clockwise") {
            menuBarState.requestManualCheck()
        }
        .disabled(!networkMonitor.canProceedWithChecks || menuBarState.isChecking)

        Button("Ayarlar…", systemImage: "gearshape") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }

        Divider()

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

    private var isMonitoringActive: Bool {
        (automaticCheckingEnabled && trackedProducts.contains(where: { !$0.isPaused })) || isCheckSequenceRunning
    }

    private func syncPowerPrevention() {
        SleepPreventionManager.shared.configure(
            isMonitoringActive: isMonitoringActive,
            mode: monitoringPowerMode
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
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: listSelection) {
                    Section {
                        ForEach(visibleTrackedProducts) { product in
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
                                Button("Şimdi Kontrol Et", systemImage: "arrow.clockwise") {
                                    startManualCheck(for: product.id)
                                }
                                .disabled(isCheckSequenceRunning || !networkMonitor.canProceedWithChecks || product.isPaused)

                                Button(
                                    product.isPriority ? "Önceliği Kaldır" : "Öncelikli Yap",
                                    systemImage: product.isPriority ? "star.slash" : "star"
                                ) {
                                    togglePriority(for: product.id)
                                }

                                Button("Ürün Sayfasını Aç", systemImage: "safari") {
                                    NSWorkspace.shared.open(product.productURL)
                                }
                                Button("Ürün URL'sini Kopyala", systemImage: "doc.on.doc") {
                                    copyProductURL(product.productURL)
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
                                Button(
                                    product.isPaused ? "İzlemeye Devam Et" : "İzlemeyi Duraklat",
                                    systemImage: product.isPaused ? "play.circle" : "pause.circle"
                                ) {
                                    setPaused(!product.isPaused, for: product.id)
                                }
                                .disabled(isCheckSequenceRunning)

                                Divider()
                                Button("Ürünü Sil", systemImage: "trash", role: .destructive) {
                                    requestProductDeletion([product.id])
                                }
                                .disabled(isCheckSequenceRunning)
                            }
                            .accessibilityLabel("\(product.productName), \(product.selectedVariant.displayDescription), \(visibleStatus(for: product).label)")
                        }
                    } header: {
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
                                            HStack {
                                                Text(filter.title)
                                                if productStatusFilter == filter {
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }
                                    }
                                }

                                Section("Mağaza") {
                                    Button {
                                        selectedProviderFilter = nil
                                    } label: {
                                        HStack {
                                            Text("Tüm Mağazalar")
                                            if selectedProviderFilter == nil {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                    ForEach(StoreProvider.allCases, id: \.self) { provider in
                                        Button {
                                            selectedProviderFilter = provider
                                        } label: {
                                            HStack {
                                                Text(provider.displayName)
                                                if selectedProviderFilter == provider {
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }
                                    }
                                }

                                if !orgStore.availableGroups.isEmpty {
                                    Section("Grup") {
                                        Button {
                                            selectedGroupFilter = nil
                                        } label: {
                                            HStack {
                                                Text("Tüm Gruplar")
                                                if selectedGroupFilter == nil {
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }
                                        ForEach(orgStore.availableGroups, id: \.self) { group in
                                            Button {
                                                selectedGroupFilter = group
                                            } label: {
                                                HStack {
                                                    Text(group)
                                                    if selectedGroupFilter == group {
                                                        Image(systemName: "checkmark")
                                                    }
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
                                            HStack {
                                                Text("Tüm Etiketler")
                                                if selectedTagFilter == nil {
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }
                                        ForEach(orgStore.availableTags, id: \.self) { tag in
                                            Button {
                                                selectedTagFilter = tag
                                            } label: {
                                                HStack {
                                                    Text(tag)
                                                    if selectedTagFilter == tag {
                                                        Image(systemName: "checkmark")
                                                    }
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
                                Label("Filtrele", systemImage: isAnyFilterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                                    .labelStyle(.iconOnly)
                                    .foregroundStyle(isAnyFilterActive ? Color.accentColor : Color.secondary)
                            }
                            .menuStyle(.borderlessButton)
                            .help(isAnyFilterActive ? "Filtreler etkin (tıkla ve yönet)" : "Ürünleri filtrele")
                        }
                        .textCase(nil)
                    }
                }
                .listStyle(.sidebar)
                .searchable(text: $productSearchText, placement: .sidebar, prompt: "Ürün, mağaza, grup veya etiket ara...")
                .overlay {
                    if visibleTrackedProducts.isEmpty {
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
                                Button("Ürün Ekle", systemImage: "plus") { activeSheet = .addProduct }
                            }
                        }
                    }
                }
                .onDeleteCommand {
                    guard isSelectionMode, !selectedProductIDs.isEmpty else { return }
                    requestProductDeletion(Array(selectedProductIDs))
                }

                Divider()

                HStack(spacing: 8) {
                    Label("\(visibleTrackedProducts.count) / \(trackedProducts.count) ürün", systemImage: "shippingbox")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        activeSheet = .addProduct
                    } label: {
                        Label("Ürün Ekle", systemImage: "plus")
                    }
                    .labelStyle(.iconOnly)
                    .help("Ürün Ekle")
                    .disabled(isCheckSequenceRunning)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            VStack(spacing: 0) {
                GlobalMonitoringStatusBar(
                    automaticCheckingEnabled: automaticCheckingEnabled,
                    isCheckSequenceRunning: isCheckSequenceRunning,
                    activeProductCount: activeMonitoredProductsCount,
                    totalProductCount: trackedProducts.count,
                    nextCheckDate: earliestNextCheckDate,
                    powerMode: monitoringPowerMode,
                    networkStatus: networkMonitor.status
                )
                Divider()
                Group {
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
                        ProductDetailView(
                            product: trackedProducts[selectedProductIndex],
                            status: visibleStatus(for: trackedProducts[selectedProductIndex]),
                            storeConnectionStatus: storeConnectionStatus,
                            storeConnectionError: storeConnectionError,
                            automaticCheckingEnabled: automaticCheckingEnabled,
                            canDelete: !isCheckSequenceRunning,
                            canChangeInterval: !isCheckSequenceRunning,
                            onOpenProduct: { NSWorkspace.shared.open(trackedProducts[selectedProductIndex].productURL) },
                            onDelete: { requestProductDeletion([trackedProducts[selectedProductIndex].id]) },
                            onIntervalChange: { updateCheckInterval($0, for: trackedProducts[selectedProductIndex].id) },
                            onGroupChange: { updateGroup($0, for: trackedProducts[selectedProductIndex].id) },
                            onAddTag: { addTag($0, for: trackedProducts[selectedProductIndex].id) },
                            onRemoveTag: { removeTag($0, for: trackedProducts[selectedProductIndex].id) },
                            onTogglePause: { setPaused(!trackedProducts[selectedProductIndex].isPaused, for: trackedProducts[selectedProductIndex].id) },
                            onTogglePriority: { togglePriority(for: trackedProducts[selectedProductIndex].id) },
                            onUpdateNote: { updateNote($0, for: trackedProducts[selectedProductIndex].id) },
                            onToggleMacOSNotification: { toggleMacOSNotification(for: trackedProducts[selectedProductIndex].id) },
                            onToggleEmailNotification: { toggleEmailNotification(for: trackedProducts[selectedProductIndex].id) },
                            onNotificationProfileChange: { updateNotificationProfile($0, for: trackedProducts[selectedProductIndex].id) },
                            onAutoOpenChange: { updateAutoOpenOnRestock($0, for: trackedProducts[selectedProductIndex].id) }
                        )
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
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

            }
        }
        .frame(minWidth: 760, minHeight: 500)
        .background {
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
        .background {
            WindowCloseBehaviorInstaller(controller: windowController)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onAppear {
            refreshMenuBarSummary()
            configureAutomaticMonitoring(runImmediately: true)
            syncPowerPrevention()
        }
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
            for index in trackedProducts.indices where !trackedProducts[index].isPaused {
                if let last = trackedProducts[index].lastChecked {
                    let effectiveMinutes = AdaptiveMonitoringPolicy.effectiveIntervalMinutes(
                        baseMinutes: trackedProducts[index].checkIntervalMinutes,
                        status: trackedProducts[index].status,
                        consecutiveUnchangedChecks: trackedProducts[index].consecutiveUnchangedChecks,
                        consecutiveFailureChecks: trackedProducts[index].consecutiveFailureChecks,
                        isEnabled: isEnabled
                    )
                    trackedProducts[index].nextCheckDate = last.addingTimeInterval(TimeInterval(effectiveMinutes * 60))
                }
            }
            TrackedProductStore.save(trackedProducts)
            scheduleNextAutomaticCheck()
        }
        .onChange(of: monitoringPowerMode) { _, _ in
            syncPowerPrevention()
        }
        .onChange(of: isCheckSequenceRunning) { _, _ in
            syncPowerPrevention()
        }
        .onChange(of: trackedProducts.map { "\($0.id):\($0.isPaused)" }) { _, _ in
            syncPowerPrevention()
        }
        .onChange(of: menuBarState.manualCheckRequestID) { _, _ in
            startManualCheckAll()
        }
        .onChange(of: menuBarState.selectedProductToOpen) { _, productID in
            guard let productID else { return }
            if trackedProducts.contains(where: { $0.id == productID }) {
                selectedProductID = productID
            }
        }
        .onChange(of: networkMonitor.status) { oldStatus, newStatus in
            if newStatus == .available && oldStatus != .available {
                print("[NetworkGuard] Ağ bağlantısı hazır ve stabilize oldu. Bekleyen kontroller yürütülüyor.")
                runDueAutomaticChecks()
                scheduleNextAutomaticCheck()
            }
        }
        .sheet(item: $activeSheet) { _ in
            AddProductSheet(
                defaultIntervalMinutes: checkIntervalMinutes,
                existingProducts: trackedProducts
            ) { newProducts in
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
        }
        .confirmationDialog(
            productIDsPendingDeletion.count == 1 ? "Ürünü Sil?" : "\(productIDsPendingDeletion.count) Ürünü Sil?",
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
    }

    private func configureAutomaticMonitoring(runImmediately: Bool) {
        stopAutomaticMonitoring()
        guard automaticCheckingEnabled else { return }

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
        guard automaticCheckingEnabled else { return }
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
        guard automaticCheckingEnabled, !isCheckSequenceRunning else { return }
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
                // Only clear the reference if it's still the same timer generation.
                // A rapid re-schedule could have replaced it already.
                if self.currentTimerGeneration == timerGeneration {
                    self.automaticCheckTimer = nil
                    self.currentTimerGeneration = nil
                }
                self.runDueAutomaticChecks()
            }
        }
        // Run in .common mode so the timer fires even during menu tracking.
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
                scheduleNextAutomaticCheck()
                syncPowerPrevention()
            }

            for productID in productIDs {
                guard !Task.isCancelled else { break }
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
            isEnabled: adaptiveMonitoringEnabled
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

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: status.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(status.color)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(product.productName)
                        .font(.body)
                        .foregroundStyle(product.isPaused ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if product.isPriority {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.yellow)
                    }
                }
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
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("Her \(ProductCheckInterval.shortTitle(for: product.checkIntervalMinutes))")
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
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
    @State private var isStockStatisticsExpanded = true
    @State private var isChangeHistoryExpanded = false
    @State private var isDiagnosticExpanded = false
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

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header: Product Title & Status
                    VStack(alignment: .leading, spacing: 8) {
                        Text(product.productName)
                            .font(.system(size: 18, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .id(product.id)

                        HStack(spacing: 8) {
                            StatusBadge(status: status)
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
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(cleanVariantDescription)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Action buttons
                    HStack(spacing: 10) {
                        Button(action: onOpenProduct) {
                            Label("Ürün Sayfasını Aç", systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.bordered)

                        Button(action: onTogglePause) {
                            Label(
                                product.isPaused ? "İzlemeye Devam Et" : "İzlemeyi Duraklat",
                                systemImage: product.isPaused ? "play.circle" : "pause.circle"
                            )
                        }
                        .buttonStyle(.bordered)

                        Button(action: onTogglePriority) {
                            Label(
                                product.isPriority ? "Önceliği Kaldır" : "Öncelikli Yap",
                                systemImage: product.isPriority ? "star.slash" : "star"
                            )
                        }
                        .buttonStyle(.bordered)

                        Button(role: .destructive, action: onDelete) {
                            Label("Ürünü Sil", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!canDelete)
                    }

                    // Inline Error Warning (if present)
                    if status == .error || product.lastCheckError != nil {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.orange)
                                .frame(width: 16, height: 16)
                                .padding(.top, 1)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Kontrol uyarısı")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                if let error = product.lastCheckError {
                                    Text(error)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    }

                    Divider()

                    // Primary Monitoring Grid
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                        GridRow {
                            detailLabel("Mağaza")
                            HStack(spacing: 8) {
                                Text(storeName(for: product))
                                    .font(.callout)

                                HStack(spacing: 5) {
                                    if storeConnectionStatus == "Bağlanıyor..." {
                                        ProgressView()
                                            .controlSize(.mini)
                                    } else {
                                        Circle()
                                            .fill(storeConnectionStatus == "Bağlandı ✓" ? Color.green : Color.orange)
                                            .frame(width: 5, height: 5)
                                    }
                                    Text(storeConnectionStatus)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let storeConnectionError {
                                    Text("(\(storeConnectionError))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                        GridRow {
                            detailLabel("Sonraki kontrol")
                            Text(nextCheckDescription(at: timeline.date))
                                .font(.callout)
                        }
                        GridRow {
                            detailLabel("Kontrol aralığı")
                            HStack(spacing: 8) {
                                Picker("", selection: Binding(
                                    get: { product.checkIntervalMinutes },
                                    set: onIntervalChange
                                )) {
                                    ForEach(ProductCheckInterval.minutes, id: \.self) { minutes in
                                        Text(ProductCheckInterval.title(for: minutes)).tag(minutes)
                                    }
                                }
                                .labelsHidden()
                                .disabled(!canChangeInterval)
                                .help(canChangeInterval ? "Kontrol aralığını değiştir" : "Kontrol tamamlanınca kullanılabilir")

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
                            detailLabel("Son kontrol")
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
                            detailLabel("Son stok değişimi")
                            if let event = latestStockChange {
                                Text("\(TurkishRelativeTime.string(from: event.date)) · \(event.newState == true ? "Stokta" : "Stokta değil")")
                                    .font(.callout)
                                    .help(event.date.formatted(date: .long, time: .complete))
                            } else {
                                Text("Henüz stok değişikliği yok")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        GridRow {
                            detailLabel("Otomatik kontrol")
                            Text(automaticCheckingEnabled ? "Uygulama açıkken etkin" : "Kapalı")
                                .font(.callout)
                                .foregroundStyle(automaticCheckingEnabled ? .primary : .secondary)
                        }
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

                                Menu {
                                    let unassignedTags = orgStore.availableTags.filter { !product.tags.contains($0) }
                                    if !unassignedTags.isEmpty {
                                        ForEach(unassignedTags, id: \.self) { tag in
                                            Button(tag) {
                                                onAddTag(tag)
                                            }
                                        }
                                        Divider()
                                    }
                                    Button("Yeni Etiket Ekle...") {
                                        newTagName = ""
                                        showingNewTagAlert = true
                                    }
                                } label: {
                                    Label(product.tags.isEmpty ? "Etiket Ekle" : "Yeni Etiket", systemImage: "plus")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        GridRow {
                            detailLabel("Öncelik")
                            HStack(spacing: 8) {
                                Toggle("", isOn: Binding(
                                    get: { product.isPriority },
                                    set: { _ in onTogglePriority() }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                Text(product.isPriority ? "Öncelikli ürün" : "Normal")
                                    .font(.callout)
                                    .foregroundStyle(product.isPriority ? .primary : .secondary)
                            }
                        }
                        GridRow(alignment: .top) {
                            detailLabel("Not")
                            HStack(alignment: .top, spacing: 8) {
                                if let note = product.note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(note)
                                        .font(.callout)
                                        .foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                } else {
                                    Text("Not eklenmedi")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                                Button {
                                    noteDraftText = product.note ?? ""
                                    showingNoteAlert = true
                                } label: {
                                    Image(systemName: "pencil")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help("Notu Düzenle")
                            }
                        }
                        GridRow {
                            detailLabel("macOS Bildirimi")
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
                                set: onNotificationProfileChange
                            )) {
                                ForEach(NotificationProfile.allCases, id: \.self) { profile in
                                    Text(profile.shortTitle).tag(profile)
                                }
                            }
                            .labelsHidden()
                        }
                        GridRow {
                            detailLabel("Stokta Otomatik Aç")
                            Picker("", selection: Binding(
                                get: { product.autoOpenOnRestock },
                                set: onAutoOpenChange
                            )) {
                                Text("Varsayılan (Genel Ayar)").tag(nil as Bool?)
                                Text("Her Zaman Aç").tag(true as Bool?)
                                Text("Asla Açma").tag(false as Bool?)
                            }
                            .labelsHidden()
                        }
                    }

                    Divider()

                    // Collapsible Section 1: Ürün Bilgileri (Expanded by default)
                    DisclosureSection(
                        title: "Ürün Bilgileri",
                        isExpanded: $isProductInformationExpanded
                    ) {
                        productInformation
                    }

                    Divider()

                    // Collapsible Section: Varyant Stokları
                    DisclosureSection(
                        title: "Varyant Stokları (\(product.variantStockSummary.summaryText))",
                        isExpanded: $isVariantStockExpanded
                    ) {
                        variantStockContent
                    }

                    Divider()

                    // Collapsible Section: Stok İstatistikleri
                    DisclosureSection(
                        title: "Stok İstatistikleri",
                        isExpanded: $isStockStatisticsExpanded
                    ) {
                        stockStatisticsContent
                    }

                    Divider()

                    // Collapsible Section 2: Değişiklik Geçmişi
                    DisclosureSection(
                        title: "Değişiklik Geçmişi (\(product.events.count))",
                        isExpanded: $isChangeHistoryExpanded
                    ) {
                        historyContent
                    }

                    Divider()

                    // Collapsible Section 3: Kontrol Tanılama
                    DisclosureSection(
                        title: "Kontrol Tanılama",
                        isExpanded: $isDiagnosticExpanded
                    ) {
                        diagnosticContent
                    }

                    Divider()

                    // Collapsible Section 4: Bildirim Geçmişi
                    DisclosureSection(
                        title: "Bildirim Geçmişi (\(auditManager.events(for: product.id).count))",
                        isExpanded: $isNotificationAuditExpanded
                    ) {
                        notificationAuditContent
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
            }
        }
        .onChange(of: product.id) { _, _ in
            isProductInformationExpanded = true
            isVariantStockExpanded = true
            isStockStatisticsExpanded = true
            isChangeHistoryExpanded = false
            isDiagnosticExpanded = false
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

            // Adaptive content layout based on option dimensions
            variantBreakdownView(snapshots: snapshots)
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
            isTracked ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(isTracked ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
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
            isTracked ? Color.accentColor.opacity(0.06) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
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
                } else if !isCheckSequenceRunning && automaticCheckingEnabled && activeProductCount > 0 {
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
        (automaticCheckingEnabled && activeProductCount > 0) || isCheckSequenceRunning
    }

    @ViewBuilder
    private func powerBadge(isCompact: Bool) -> some View {
        if isPowerProtectionActive {
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

private struct EmptyProductsView: View {
    let onAddProduct: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Henüz takip edilen ürün yok", systemImage: "shippingbox")
        } description: {
            Text("Bir ürün URL'si ekleyerek stok takibine başlayın.")
        } actions: {
            Button("Ürün Ekle", systemImage: "plus", action: onAddProduct)
                .buttonStyle(.borderedProminent)
        }
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
    case addProduct

    var id: Self { self }
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
            autoOpenOnRestockEnabled: autoOpenOnRestockEnabled
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
            autoOpenOnRestockEnabled: Bool
        ) {
            self.product = product
            self.notificationsEnabled = notificationsEnabled
            self.emailNotificationsEnabled = emailNotificationsEnabled
            self.adaptiveMonitoringEnabled = adaptiveMonitoringEnabled
            self.autoOpenOnRestockEnabled = autoOpenOnRestockEnabled
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
                    let available = outcome.isAvailable
                    guard self.activeProviderCheckRequestID == requestID,
                          self.product.wrappedValue.id == product.id else { return }
                    let wasInError = self.product.wrappedValue.lastCheckError != nil
                    let previousAvailability = self.product.wrappedValue.lastKnownAvailable
                    let transition = Self.transition(
                        from: previousAvailability,
                        to: available
                    )
                    if wasInError {
                        self.product.wrappedValue.record(.checkRecovered, previousState: previousAvailability, newState: available)
                    }
                    self.product.wrappedValue.consecutiveFailureChecks = 0
                    switch transition {
                    case .restocked:
                        self.product.wrappedValue.consecutiveUnchangedChecks = 0
                        self.product.wrappedValue.record(.stockArrived, previousState: false, newState: true)
                    case .wentOutOfStock:
                        self.product.wrappedValue.consecutiveUnchangedChecks = 0
                        self.product.wrappedValue.record(.stockDepleted, previousState: true, newState: false)
                    case .unchanged(available: false):
                        self.product.wrappedValue.consecutiveUnchangedChecks += 1
                    case .unchanged(available: true):
                        self.product.wrappedValue.consecutiveUnchangedChecks = 0
                    case .initial:
                        self.product.wrappedValue.consecutiveUnchangedChecks = 0
                    }
                    self.product.wrappedValue.lastAvailabilityTransition = transition
                    self.product.wrappedValue.selectedVariant.availability = available
                    self.product.wrappedValue.variantSnapshots = outcome.variants
                    self.product.wrappedValue.lastCheckError = nil

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
                    switch transition {
                    case .restocked:
                        userMsg = "Stok kontrolü başarılı. Yeni stok geldiği tespit edildi."
                    case .wentOutOfStock:
                        userMsg = "Stok kontrolü başarılı. Stoğun tükendiği tespit edildi."
                    default:
                        userMsg = "Stok kontrolü başarıyla tamamlandı. Ürün \(available ? "stokta" : "stokta değil")."
                    }
                    self.product.wrappedValue.latestDiagnostic = ProviderDiagnostic(
                        providerName: self.product.wrappedValue.providerDisplayName,
                        checkerName: self.product.wrappedValue.provider.defaultCheckerName,
                        startedAt: startTime,
                        completedAt: now,
                        durationSeconds: duration,
                        outcome: (transition == .restocked || transition == .wentOutOfStock) ? .stockChanged : .success,
                        stockResult: available,
                        networkStatus: netStatus,
                        errorCategory: "Yok",
                        userMessage: userMsg,
                        technicalDetail: outcome.diagnosticDetail,
                        lastSuccessfulCheckDate: now
                    )

                    if case .restocked = transition {
                        let current = self.product.wrappedValue
                        if current.notificationProfile.shouldNotifyOnRestock {
                            if self.notificationsEnabled && current.isMacOSNotificationEnabled {
                                StockNotificationManager.shared.sendRestockNotification(
                                    productID: current.id,
                                    productName: current.productName,
                                    variantTitle: current.variantTitle,
                                    productURL: current.productURL
                                )
                            } else {
                                let reason = !self.notificationsEnabled
                                    ? "macOS bildirimleri ayarlarda kapalı"
                                    : "Bu ürün için macOS bildirimi kapalı"
                                NotificationAuditManager.shared.record(
                                    productID: current.id,
                                    productName: current.productName,
                                    variantTitle: current.variantTitle,
                                    channel: .macOS,
                                    status: .skipped,
                                    message: reason
                                )
                            }
                            if self.emailNotificationsEnabled && current.isEmailNotificationEnabled {
                                EmailNotificationService.shared.sendRestockNotification(
                                    for: current
                                )
                            } else {
                                let reason = !self.emailNotificationsEnabled
                                    ? "E-posta bildirimleri ayarlarda kapalı"
                                    : "Bu ürün için e-posta bildirimi kapalı"
                                NotificationAuditManager.shared.record(
                                    productID: current.id,
                                    productName: current.productName,
                                    variantTitle: current.variantTitle,
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
                } else {
                    let effectiveMinutes = AdaptiveMonitoringPolicy.effectiveIntervalMinutes(
                        baseMinutes: product.wrappedValue.checkIntervalMinutes,
                        status: product.wrappedValue.status,
                        consecutiveUnchangedChecks: product.wrappedValue.consecutiveUnchangedChecks,
                        consecutiveFailureChecks: product.wrappedValue.consecutiveFailureChecks,
                        isEnabled: adaptiveMonitoringEnabled
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
    }

    private var pendingNotices: [ProductNotice] = []
    private var isProcessingNotices = false

    private init() {}

    func sendRestockNotification(productID: UUID, productName: String, variantTitle: String, productURL: URL) {
        pendingNotices.append(ProductNotice(productID: productID, productName: productName, variantTitle: variantTitle, productURL: productURL, isRestock: true))
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
                        content.title = "Stok geldi! 🎉"
                        content.body = "\(notice.productName) — \(notice.variantTitle) artık stokta."
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
    @State private var launchAtLoginMessage: String?
    @State private var showingResetConfirmation = false
    @State private var isSendingTestEmail = false
    @State private var testEmailStatusMessage: String?
    @State private var testEmailStatusIsError = false

    var body: some View {
        Form {
            Section("Genel") {
                Toggle("Otomatik kontrol", isOn: $automaticCheckingEnabled)

                Picker("Yeni ürünler için varsayılan kontrol aralığı", selection: $checkIntervalMinutes) {
                    ForEach(ProductCheckInterval.minutes, id: \.self) { minutes in
                        Text(ProductCheckInterval.title(for: minutes)).tag(minutes)
                    }
                }

                Toggle("Akıllı kontrol aralığı", isOn: $adaptiveMonitoringEnabled)
                Text("Uzun süre değişiklik olmadığında kontrol sıklığını otomatik olarak azaltır ve gereksiz istekleri sınırlar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Kontroller, StockPing çalıştığı sürece gerçekleştirilir.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                }
            }

            Section("Bildirimler ve Otomasyon") {
                Toggle("Bildirimler", isOn: $stockNotificationsEnabled)

                Toggle("E-posta bildirimi", isOn: $emailNotificationsEnabled)

                Text("Ürün tekrar stokta olduğunda macOS Mail üzerinden e-posta gönderir.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("E-posta gönderimi, Mac'inizde yapılandırılmış Mail hesabı üzerinden gerçekleştirilir.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Stok geldiğinde tarayıcıda otomatik aç", isOn: $autoOpenOnRestockEnabled)

                Text("Ürün stoğa girdiğinde ürün sayfasını varsayılan web tarayıcınızda otomatik olarak açar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
                        Text("(\(summary.health.title))")
                            .foregroundStyle(summary.health.color)
                            .font(.caption)
                    }
                }
            }

            Section("Mac Uyku Davranışı") {
                Picker("İzleme sırasında güç modu", selection: $monitoringPowerMode) {
                    ForEach(MonitoringPowerMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .accessibilityLabel("Mac Uyku Davranışı")

                Text(monitoringPowerMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Bu ayar yalnızca StockPing aktif olarak ürünleri izlerken uygulanır.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Başlangıç") {
                Toggle(
                    "Mac açıldığında başlat",
                    isOn: Binding(
                        get: { launchAtLoginEnabled },
                        set: setLaunchAtLogin
                    )
                )

                if let launchAtLoginMessage {
                    Text(launchAtLoginMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                Button("Varsayılanlara Dön", role: .destructive) {
                    showingResetConfirmation = true
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: synchronizeLaunchAtLoginPreference)
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
    let onAddMultiple: ([TrackedProduct]) -> (added: Int, duplicates: Int)

    @Environment(\.dismiss) private var dismiss
    @State private var productURLText = ""
    @State private var analysisURL: URL?
    @State private var analysisRequestID = 0
    @State private var isAnalyzing = false
    @State private var productName: String?
    @State private var provider: StoreProvider = .shopify
    @State private var variants: [StoreVariantCandidate] = []
    @State private var optionDimensions: [DiscoveredOptionDimension] = []
    @State private var selectedFilterOptionValue = "all"
    @State private var selectedVariantIDs: Set<String> = []
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
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Yeni Ürün Ekle")
                        .font(.title2.weight(.semibold))
                    Text("Takip etmek istediğiniz ürünün bağlantısını yapıştırın.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

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
                                .onChange(of: productURLText) {
                                    clearAnalysis()
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
                }

                if let productName {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(productName)
                                    .font(.headline)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
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
                                    .frame(maxWidth: 220)
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

                                            Spacer()

                                            if let available = candidate.initialAvailability {
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
                                }
                                .padding(4)
                            }
                            .frame(maxHeight: 180)
                            .background(Color(nsColor: .controlBackgroundColor).opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
                        }
                        .padding(4)
                    }
                }

                Spacer(minLength: 0)

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
            .padding(20)
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
        .frame(minWidth: 520, idealWidth: 580, minHeight: 400, idealHeight: 520)
        .onAppear {
            isURLFieldFocused = true
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
                events: [],
                variantSnapshots: snapshots
            )
        }

        let result = onAddMultiple(products)
        if result.added > 0 {
            dismiss()
        } else {
            duplicateError = "Seçilen varyantlar zaten takip ediliyor."
        }
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
