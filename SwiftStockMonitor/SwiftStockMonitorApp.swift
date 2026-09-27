import SwiftUI
import WebKit
import UserNotifications
import AppKit
import ServiceManagement
import Combine

private enum ProductListFilter: String, CaseIterable, Identifiable {
    case all, inStock, outOfStock, checking, error, paused

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "Tümü"
        case .inStock: "Stokta"
        case .outOfStock: "Stokta değil"
        case .checking: "Kontrol ediliyor"
        case .error: "Kontrol sorunu"
        case .paused: "Duraklatıldı"
        }
    }
}

private enum ProductListSort: String, CaseIterable, Identifiable {
    case defaultOrder, productName, lastChecked, nextCheck

    var id: Self { self }

    var title: String {
        switch self {
        case .defaultOrder: "Varsayılan sıra"
        case .productName: "Ürün adı"
        case .lastChecked: "Son kontrol"
        case .nextCheck: "Sonraki kontrol"
        }
    }
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
        let urlString = response.notification.request.content.userInfo["productURL"] as? String
        completionHandler()
        guard let urlString,
              let url = URL(string: urlString),
              ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        Task { @MainActor in
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
    @Published var errorCount = 0
    @Published var lastCheckedText = "Henüz kontrol yapılmadı"
    @Published private(set) var manualCheckRequestID = 0

    func requestManualCheck() {
        manualCheckRequestID += 1
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
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text("StockPing")
            .font(.headline)
        Text("\(menuBarState.productCount) ürün takip ediliyor")
        Text("\(menuBarState.inStockCount) ürün stokta")
        Text("\(menuBarState.outOfStockCount) ürün stokta değil")
        if menuBarState.unknownStockCount > 0 {
            Text("\(menuBarState.unknownStockCount) ürünün durumu bilinmiyor")
        }
        if menuBarState.pausedCount > 0 {
            Text("\(menuBarState.pausedCount) ürün duraklatıldı")
        }
        if menuBarState.errorCount > 0 {
            Text("\(menuBarState.errorCount) üründe kontrol hatası var")
        }
        Text("Son kontrol: \(menuBarState.lastCheckedText)")
            .font(.caption)

        Divider()

        Button("Uygulamayı Aç", systemImage: "macwindow") {
            if !windowController.showMainWindow() {
                openWindow(id: "main")
            }
        }
        Button("Şimdi Tümünü Kontrol Et", systemImage: "arrow.clockwise") {
            menuBarState.requestManualCheck()
        }
        Button("Ayarlar", systemImage: "gearshape") {
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

struct ContentView: View {
    @EnvironmentObject private var menuBarState: SwiftStockMenuBarState
    @EnvironmentObject private var windowController: MainWindowController
    @AppStorage("automaticCheckingEnabled") private var automaticCheckingEnabled = true
    @AppStorage("checkIntervalMinutes") private var checkIntervalMinutes = 1
    @AppStorage("stockNotificationsEnabled") private var stockNotificationsEnabled = true
    @AppStorage("emailNotificationsEnabled") private var emailNotificationsEnabled = false
    @AppStorage("monitoringPowerMode") private var monitoringPowerMode: MonitoringPowerMode = .allowDisplaySleepKeepMacAwake
    @State private var trackedProducts: [TrackedProduct]
    @State private var selectedProductID: UUID
    @State private var isSelectionMode = false
    @State private var selectedProductIDs: Set<UUID> = []
    @State private var productSearchText = ""
    @State private var productStatusFilter: ProductListFilter = .all
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
    @State private var pendingCheckContinuation: CheckedContinuation<Void, Never>?

    init() {
        let products = TrackedProductStore.load()
        _trackedProducts = State(initialValue: products)
        _selectedProductID = State(initialValue: products.first?.id ?? UUID())
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
            let matchesSearch = query.isEmpty || [product.productName, storeName(for: product), product.variantTitle]
                .contains { $0.localizedCaseInsensitiveContains(query) }
            let status = visibleStatus(for: product)
            let matchesFilter: Bool
            switch productStatusFilter {
            case .all: matchesFilter = true
            case .inStock: matchesFilter = status == .inStock
            case .outOfStock: matchesFilter = status == .outOfStock
            case .checking: matchesFilter = status == .checking
            case .error: matchesFilter = status == .error
            case .paused: matchesFilter = status == .paused
            }
            return matchesSearch && matchesFilter
        }

        guard productListSort != .defaultOrder else { return filteredProducts }
        let locale = Locale(identifier: "tr_TR")
        return filteredProducts.enumerated().sorted { lhs, rhs in
            switch productListSort {
            case .defaultOrder:
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
                                .disabled(isCheckSequenceRunning)
                                Button("Ürün Sayfasını Aç", systemImage: "safari") {
                                    NSWorkspace.shared.open(product.productURL)
                                }
                                Button("Ürün URL'sini Kopyala", systemImage: "doc.on.doc") {
                                    copyProductURL(product.productURL)
                                }
                                Divider()
                                Button(
                                    product.isPaused ? "Takibi Sürdür" : "Takibi Duraklat",
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
                                Picker("Durum", selection: $productStatusFilter) {
                                    ForEach(ProductListFilter.allCases) { filter in
                                        Text(filter.title).tag(filter)
                                    }
                                }
                            } label: {
                                Label(productStatusFilter.title, systemImage: "line.3.horizontal.decrease.circle")
                                    .labelStyle(.iconOnly)
                            }
                            .menuStyle(.borderlessButton)
                            .help("Ürünleri duruma göre filtrele")
                        }
                        .textCase(nil)
                    }
                }
                .listStyle(.sidebar)
                .searchable(text: $productSearchText, placement: .sidebar, prompt: "Ürün veya mağaza ara...")
                .overlay {
                    if visibleTrackedProducts.isEmpty {
                        ContentUnavailableView {
                            Label(productSearchText.isEmpty ? "Takip edilen ürün yok" : "Sonuç bulunamadı", systemImage: "shippingbox")
                        } description: {
                            Text(productSearchText.isEmpty ? "Bir ürün ekleyerek stok takibine başlayın." : "Arama veya filtre ölçütlerini değiştirmeyi deneyin.")
                        } actions: {
                            if !productSearchText.isEmpty || productStatusFilter != .all {
                                Button("Filtreleri Temizle") {
                                    productSearchText = ""
                                    productStatusFilter = .all
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
                    powerMode: monitoringPowerMode
                )
                Divider()
                Group {
                    if let selectedProductIndex {
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
                            onIntervalChange: { updateCheckInterval($0, for: trackedProducts[selectedProductIndex].id) }
                        )
                    } else if trackedProducts.isEmpty {
                        EmptyProductsView {
                            activeSheet = .addProduct
                        }
                    } else {
                        NoSelectionView()
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
                    } else {
                        Label("Şimdi Kontrol Et", systemImage: "arrow.clockwise")
                    }
                }
                .help("Şimdi Kontrol Et (⌘R)")
                .disabled(isCheckSequenceRunning || selectedProductIndex == nil)
                .keyboardShortcut("r", modifiers: .command)

                Button {
                    startManualCheckAll()
                } label: {
                    Label("Şimdi Tümünü Kontrol Et", systemImage: "arrow.clockwise.circle")
                }
                .help("Şimdi Tümünü Kontrol Et (⇧⌘R)")
                .disabled(isCheckSequenceRunning || trackedProducts.isEmpty)
                .keyboardShortcut("r", modifiers: [.command, .shift])

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
        .sheet(item: $activeSheet) { _ in
            AddProductSheet(defaultIntervalMinutes: checkIntervalMinutes) { newProduct in
                let identity = ShopifyChecker.productIdentity(for: newProduct.productURL)
                let alreadyTracked = trackedProducts.contains { existing in
                    if existing.provider != newProduct.provider { return false }
                    if newProduct.provider == .zara,
                       let oldZara = existing.zaraMetadata,
                       let newZara = newProduct.zaraMetadata {
                        return oldZara.productGroupID == newZara.productGroupID &&
                            oldZara.colorProductID == newZara.colorProductID &&
                            oldZara.availabilitySKU == newZara.availabilitySKU
                    }
                    if newProduct.provider == .bershka,
                       let oldBershka = existing.bershkaMetadata,
                       let newBershka = newProduct.bershkaMetadata {
                        return oldBershka.productID == newBershka.productID &&
                            oldBershka.colorID == newBershka.colorID &&
                            oldBershka.sku == newBershka.sku
                    }
                    if newProduct.provider == .pullAndBear,
                       let oldPullAndBear = existing.pullAndBearMetadata,
                       let newPullAndBear = newProduct.pullAndBearMetadata {
                        return oldPullAndBear.productCode == newPullAndBear.productCode &&
                            oldPullAndBear.colorIdentity == newPullAndBear.colorIdentity &&
                            oldPullAndBear.sizeName.caseInsensitiveCompare(newPullAndBear.sizeName) == .orderedSame
                    }
                    return ShopifyChecker.productIdentity(for: existing.productURL) == identity &&
                        existing.variantID == newProduct.variantID
                }
                guard !alreadyTracked else { return false }

                trackedProducts.append(newProduct)
                TrackedProductStore.save(trackedProducts)
                selectedProductID = newProduct.id
                refreshMenuBarSummary()
                activeSheet = nil
                scheduleNextAutomaticCheck()
                syncPowerPrevention()
                return true
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
    }

    private func runDueAutomaticChecks() {
        guard automaticCheckingEnabled else { return }
        guard !isCheckSequenceRunning else { return }
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

        let nextDate = trackedProducts
            .filter { !$0.isPaused }
            .compactMap { $0.nextCheckDate ?? Date.distantPast }
            .min()
        guard let nextDate else { return }

        automaticCheckTimer = Timer.scheduledTimer(
            withTimeInterval: max(0.2, nextDate.timeIntervalSinceNow),
            repeats: false
        ) { _ in
            Task { @MainActor in
                self.automaticCheckTimer = nil
                self.runDueAutomaticChecks()
            }
        }
    }

    private func startCheckSequence(for productIDs: [UUID]) {
        guard !isCheckSequenceRunning, !productIDs.isEmpty else { return }
        isCheckSequenceRunning = true
        syncPowerPrevention()
        stopAutomaticMonitoring()

        Task { @MainActor in
            defer {
                checkingProductID = nil
                isChecking = false
                isCheckSequenceRunning = false
                refreshMenuBarSummary()
                scheduleNextAutomaticCheck()
                syncPowerPrevention()
            }

            for productID in productIDs {
                guard !Task.isCancelled else { break }
                guard trackedProducts.contains(where: { $0.id == productID }) else { continue }
                await performCheck(for: productID)
            }
        }
    }

    private func startManualCheck() {
        startManualCheck(for: selectedProductID)
    }

    private func startManualCheck(for productID: UUID) {
        startCheckSequence(for: [productID])
    }

    private func startManualCheckAll() {
        startCheckSequence(for: trackedProducts.map(\.id))
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

        let latestCheck = trackedProducts.compactMap(\.lastChecked).max()
        menuBarState.lastCheckedText = latestCheck?.formatted(date: .abbreviated, time: .shortened)
            ?? "Henüz kontrol yapılmadı"
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

    private func updateCheckInterval(_ minutes: Int, for productID: UUID) {
        guard let index = trackedProducts.firstIndex(where: { $0.id == productID }) else { return }
        trackedProducts[index].checkIntervalMinutes = minutes
        trackedProducts[index].nextCheckDate = trackedProducts[index].lastChecked?
            .addingTimeInterval(TimeInterval(minutes * 60)) ?? Date()
        TrackedProductStore.save(trackedProducts)
        scheduleNextAutomaticCheck()
    }

    private func copyProductURL(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

}

private struct ProductSidebarRow: View {
    let product: TrackedProduct
    let status: ProductStatus

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: status.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(status.color)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(product.productName)
                    .font(.body)
                    .foregroundStyle(product.isPaused ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    Text(product.selectedVariant.displayDescription)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("Her \(ProductCheckInterval.shortTitle(for: product.checkIntervalMinutes))")
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

private struct ProductDetailView: View {
    @State private var isProductInformationExpanded = false
    @State private var isChangeHistoryExpanded = true

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

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Header: Product Title & Status
                    VStack(alignment: .leading, spacing: 8) {
                        Text(product.productName)
                            .font(.title2.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .id(product.id)

                        HStack(spacing: 8) {
                            StatusBadge(status: status)
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text("Varyant: \(product.selectedVariant.displayDescription)")
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
                            Text(storeName(for: product))
                                .font(.callout)
                        }
                        GridRow {
                            detailLabel("Sonraki kontrol")
                            Text(nextCheckDescription(at: timeline.date))
                                .font(.callout)
                        }
                        GridRow {
                            detailLabel("Kontrol aralığı")
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
                    }

                    Divider()

                    // Collapsible Section 1: Ürün Bilgileri
                    DisclosureSection(
                        title: "Ürün Bilgileri",
                        isExpanded: $isProductInformationExpanded
                    ) {
                        productInformation
                    }

                    Divider()

                    // Collapsible Section 2: Değişiklik Geçmişi
                    DisclosureSection(
                        title: "Değişiklik Geçmişi",
                        isExpanded: $isChangeHistoryExpanded
                    ) {
                        historyContent
                    }

                    // Store connection status at the very bottom
                    HStack(spacing: 6) {
                        if storeConnectionStatus == "Bağlanıyor..." {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Circle()
                                .fill(storeConnectionStatus == "Bağlandı ✓" ? Color.green : Color.orange)
                                .frame(width: 6, height: 6)
                        }
                        Text("Store bağlantısı · \(storeConnectionStatus)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        if let storeConnectionError {
                            Text("(\(storeConnectionError))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
        }
        .onChange(of: product.id) { _, _ in
            isProductInformationExpanded = false
            isChangeHistoryExpanded = true
        }
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
    private var historyContent: some View {
        if product.events.isEmpty {
            Text("Henüz bir değişiklik yok")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(product.events.sorted { $0.date > $1.date }.prefix(10)) { event in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: event.type.symbol)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(event.type.color)
                            .frame(width: 16, height: 16)
                            .padding(.top, 1)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.type.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            Text(TurkishRelativeTime.string(from: event.date))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .help(event.date.formatted(date: .long, time: .complete))
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(event.type.title), \(TurkishRelativeTime.string(from: event.date))")
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
            .frame(width: 130, alignment: .leading)
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

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            barContent(at: timeline.date)
        }
    }

    @ViewBuilder
    private func barContent(at now: Date) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                statusIndicator
                statusTitleView
            }

            Spacer(minLength: 8)

            HStack(spacing: 10) {
                if !isCheckSequenceRunning && automaticCheckingEnabled && activeProductCount > 0 {
                    HStack(spacing: 5) {
                        Image(systemName: "clock")
                            .foregroundStyle(.secondary)
                        Text("Sonraki kontrol: \(countdownString(at: now))")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }

                powerBadge
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary(at: now))
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if isCheckSequenceRunning {
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
    private var statusTitleView: some View {
        if isCheckSequenceRunning {
            HStack(spacing: 6) {
                Text("Kontrol ediliyor…")
                    .font(.callout.weight(.medium))
                if activeProductCount > 0 {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text("\(activeProductCount) aktif ürün")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        } else if !automaticCheckingEnabled {
            HStack(spacing: 6) {
                Text("İzleme duraklatıldı")
                    .font(.callout.weight(.medium))
                Text("·")
                    .foregroundStyle(.secondary)
                Text("Otomatik kontrol kapalı")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if activeProductCount == 0 {
            HStack(spacing: 6) {
                Text("İzlenecek aktif ürün yok")
                    .font(.callout.weight(.medium))
                if totalProductCount > 0 {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text("Tüm ürünler duraklatıldı")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            HStack(spacing: 6) {
                Text("İzleme Aktif")
                    .font(.callout.weight(.medium))
                Text("·")
                    .foregroundStyle(.secondary)
                Text("\(activeProductCount) ürün takip ediliyor")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var isPowerProtectionActive: Bool {
        (automaticCheckingEnabled && activeProductCount > 0) || isCheckSequenceRunning
    }

    @ViewBuilder
    private var powerBadge: some View {
        if isPowerProtectionActive {
            HStack(spacing: 5) {
                Image(systemName: powerSymbol)
                    .foregroundStyle(powerColor)
                Text(powerText)
                    .foregroundStyle(.primary)
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
                Text("Uyku engelleme pasif")
                    .foregroundStyle(.secondary)
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

    private var powerText: String {
        switch powerMode {
        case .normal: "macOS uyku yönetimi"
        case .keepMacAndDisplayAwake: "Mac + ekran uyanık"
        case .allowDisplaySleepKeepMacAwake: "Mac uyanık · ekran kapanabilir"
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
        if isCheckSequenceRunning {
            return "Stok kontrolü yapılıyor. \(activeProductCount) aktif ürün."
        } else if !automaticCheckingEnabled {
            return "İzleme duraklatıldı. Otomatik kontrol kapalı. Uyku koruması pasif."
        } else if activeProductCount == 0 {
            return "İzlenecek aktif ürün yok. Uyku koruması pasif."
        } else {
            return "İzleme aktif. \(activeProductCount) ürün takip ediliyor. Sonraki kontrol \(countdownString(at: now)). Güç koruması: \(powerText)."
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
            emailNotificationsEnabled: emailNotificationsEnabled
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
        private let providerCheckSafetyTimeout: Duration = .seconds(40)

        init(
            product: Binding<TrackedProduct>,
            initialRequestID: Int,
            isChecking: Binding<Bool>,
            status: Binding<String>,
            errorMessage: Binding<String?>,
            notificationsEnabled: Bool,
            emailNotificationsEnabled: Bool,
            onCheckComplete: @escaping () -> Void
        ) {
            self.product = product
            self.lastReceivedRequestID = initialRequestID
            self.isChecking = isChecking
            self.status = status
            self.errorMessage = errorMessage
            self.notificationsEnabled = notificationsEnabled
            self.emailNotificationsEnabled = emailNotificationsEnabled
            self.onCheckComplete = onCheckComplete
            self.loadedProductID = product.wrappedValue.id
        }

        func receiveCheckRequest(
            _ requestID: Int,
            product: Binding<TrackedProduct>,
            webView: WKWebView,
            notificationsEnabled: Bool,
            emailNotificationsEnabled: Bool
        ) {
            self.product = product
            self.notificationsEnabled = notificationsEnabled
            self.emailNotificationsEnabled = emailNotificationsEnabled
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
            if pageIsReady {
                checkAvailability(in: webView, product: product.wrappedValue, requestID: requestID)
            } else if pageLoadFailed {
                completeFailure("Store sayfasına bağlanılamadığı için kontrol yapılamadı.")
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
                        self.completeFailure("Sayfanın hazır olduğu doğrulanamadı: \(error.localizedDescription)")
                    }
                    return
                }

                guard let readyState = result as? String, readyState == "complete" else {
                    self.showError("Sayfa yüklemesi tamamlanamadı.")
                    if self.queuedRequestID != nil {
                        self.queuedRequestID = nil
                        self.completeFailure("Sayfa yüklemesi tamamlanamadı.")
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

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            pageLoadFailed = true
            showError(error.localizedDescription)
            if queuedRequestID != nil {
                queuedRequestID = nil
                completeFailure("Store sayfası yüklenemedi: \(error.localizedDescription)")
            }
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            pageLoadFailed = true
            showError(error.localizedDescription)
            if queuedRequestID != nil {
                queuedRequestID = nil
                completeFailure("Store sayfası yüklenemedi: \(error.localizedDescription)")
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
                    let available = try await StoreCheckerRouter.check(in: webView, product: product, activePageURL: webView.url)
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
                    switch transition {
                    case .restocked:
                        self.product.wrappedValue.record(.stockArrived, previousState: false, newState: true)
                    case .wentOutOfStock:
                        self.product.wrappedValue.record(.stockDepleted, previousState: true, newState: false)
                    case .initial, .unchanged:
                        break
                    }
                    self.product.wrappedValue.lastAvailabilityTransition = transition
                    self.product.wrappedValue.selectedVariant.availability = available
                    self.product.wrappedValue.lastCheckError = nil
                    if case .restocked = transition {
                        if self.notificationsEnabled {
                            StockNotificationManager.shared.sendRestockNotification(
                                productName: self.product.wrappedValue.productName,
                                variantTitle: self.product.wrappedValue.variantTitle,
                                productURL: self.product.wrappedValue.productURL
                            )
                        }
                        if self.emailNotificationsEnabled {
                            EmailNotificationService.shared.sendRestockNotification(
                                for: self.product.wrappedValue
                            )
                        }
                    }
                    self.finishCheck()
                } catch {
                    guard self.activeProviderCheckRequestID == requestID,
                          self.product.wrappedValue.id == product.id else { return }
                    self.completeFailure("Stok kontrolü başarısız: \(error.localizedDescription)")
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
                self.completeFailure("Stok kontrolü güvenlik zaman aşımına uğradı.")
            }
        }

        private func completeFailure(_ message: String) {
            if product.wrappedValue.lastCheckError == nil {
                product.wrappedValue.record(.checkFailed, previousState: product.wrappedValue.lastKnownAvailable)
            }
            product.wrappedValue.lastCheckError = message
            finishCheck()
        }

        private func finishCheck() {
            pageReadinessTimeoutTask?.cancel()
            pageReadinessTimeoutTask = nil
            providerCheckTimeoutTask?.cancel()
            providerCheckTimeoutTask = nil
            providerCheckTask = nil
            activeProviderCheckRequestID = nil
            let checkedAt = Date()
            product.wrappedValue.lastChecked = checkedAt
            product.wrappedValue.nextCheckDate = checkedAt.addingTimeInterval(
                TimeInterval(product.wrappedValue.checkIntervalMinutes * 60)
            )
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
                self.completeFailure("Mağaza sayfası zamanında hazır olmadı. Lütfen yeniden deneyin.")
            }
        }
    }
}

@MainActor
private final class StockNotificationManager {
    static let shared = StockNotificationManager()

    private struct RestockNotice {
        let productName: String
        let variantTitle: String
        let productURL: URL
    }

    private var pendingNotices: [RestockNotice] = []
    private var isProcessingNotices = false

    private init() {}

    func sendRestockNotification(productName: String, variantTitle: String, productURL: URL) {
        pendingNotices.append(RestockNotice(productName: productName, variantTitle: variantTitle, productURL: productURL))
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
                    content.title = "Stok geldi! 🎉"
                    content.body = "\(notice.productName) — \(notice.variantTitle) artık stokta."
                    content.sound = .default
                    content.userInfo = ["productURL": notice.productURL.absoluteString]

                    let request = UNNotificationRequest(
                        identifier: UUID().uuidString,
                        content: content,
                        trigger: nil
                    )
                    try? await center.add(request)
                }
            }
        } else {
            // A denied permission must not affect stock tracking or keep stale notices queued.
            pendingNotices.removeAll()
        }

        isProcessingNotices = false
    }
}

private struct SettingsView: View {
    @AppStorage("automaticCheckingEnabled") private var automaticCheckingEnabled = true
    @AppStorage("checkIntervalMinutes") private var checkIntervalMinutes = 1
    @AppStorage("stockNotificationsEnabled") private var stockNotificationsEnabled = true
    @AppStorage("emailNotificationsEnabled") private var emailNotificationsEnabled = false
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
                Text("Kontroller, StockPing çalıştığı sürece gerçekleştirilir.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Bildirimler") {
                Toggle("Bildirimler", isOn: $stockNotificationsEnabled)

                Toggle("E-posta bildirimi", isOn: $emailNotificationsEnabled)

                Text("Ürün tekrar stokta olduğunda macOS Mail üzerinden e-posta gönderir.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("E-posta gönderimi, Mac'inizde yapılandırılmış Mail hesabı üzerinden gerçekleştirilir.")
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
        stockNotificationsEnabled = true
        emailNotificationsEnabled = false
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
    private struct ColorChoice: Identifiable {
        let id: String
        let name: String
    }

    let defaultIntervalMinutes: Int
    let onAdd: (TrackedProduct) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var productURLText = ""
    @State private var analysisURL: URL?
    @State private var analysisRequestID = 0
    @State private var isAnalyzing = false
    @State private var productName: String?
    @State private var provider: StoreProvider = .shopify
    @State private var variants: [StoreVariantCandidate] = []
    @State private var selectedVariantID = ""
    @State private var selectedColorProductID = ""
    @State private var analysisError: String?
    @State private var duplicateError: String?
    @FocusState private var isURLFieldFocused: Bool

    private var canAnalyzeURL: Bool {
        Self.validatedProductURL(productURLText) != nil
    }

    private var visibleVariants: [StoreVariantCandidate] {
        guard [.zara, .bershka, .pullAndBear].contains(provider), !selectedColorProductID.isEmpty else { return variants }
        return variants.filter { candidate in
            if provider == .zara { return candidate.zaraMetadata?.colorProductID == selectedColorProductID }
            if provider == .bershka { return candidate.bershkaMetadata?.colorID == selectedColorProductID }
            return candidate.pullAndBearMetadata?.colorIdentity == selectedColorProductID
        }
    }

    private var colors: [ColorChoice] {
        var seen = Set<String>()
        return variants.compactMap { candidate in
            if provider == .zara, let metadata = candidate.zaraMetadata,
               seen.insert(metadata.colorProductID).inserted {
                return ColorChoice(id: metadata.colorProductID, name: metadata.colorName)
            }
            if provider == .bershka, let metadata = candidate.bershkaMetadata,
               seen.insert(metadata.colorID).inserted {
                return ColorChoice(id: metadata.colorID, name: metadata.colorName)
            }
            if provider == .pullAndBear, let metadata = candidate.pullAndBearMetadata,
               seen.insert(metadata.colorIdentity).inserted {
                return ColorChoice(id: metadata.colorIdentity, name: metadata.colorName)
            }
            return nil
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
                    GroupBox("Ürün") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(productName)
                                .font(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                            Divider()
                            if [.zara, .bershka, .pullAndBear].contains(provider) {
                                Picker("Renk", selection: $selectedColorProductID) {
                                    Text("Renk seçin").tag("")
                                    ForEach(colors, id: \.id) { color in
                                        Text(color.name).tag(color.id)
                                    }
                                }
                                .pickerStyle(.menu)
                                .accessibilityLabel("Renk")
                                Picker("Beden", selection: $selectedVariantID) {
                                    Text("Beden seçin").tag("")
                                    ForEach(visibleVariants) { variant in
                                        Text(sizePickerTitle(for: variant)).tag(variant.id)
                                    }
                                }
                                .pickerStyle(.menu)
                                .accessibilityLabel("Beden")
                            } else {
                                Picker("Varyant", selection: $selectedVariantID) {
                                    Text("Varyant seçin").tag("")
                                    ForEach(variants) { variant in
                                        Text(variant.displayTitle).tag(variant.id)
                                    }
                                }
                                .pickerStyle(.menu)
                                .accessibilityLabel("Varyant")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Spacer(minLength: 0)

                Divider()
                HStack {
                    Button("İptal") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Takibe Ekle", action: addSelectedProduct)
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedVariantID.isEmpty || isAnalyzing)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityLabel("Takibe Ekle")
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
        .frame(minWidth: 480, idealWidth: 540, minHeight: 300, idealHeight: 420)
        .onAppear {
            isURLFieldFocused = true
        }
        .onChange(of: selectedColorProductID) { _, _ in
            selectedVariantID = ""
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
        selectedVariantID = ""
        selectedColorProductID = ""
        analysisError = nil
    }

    private func handleAnalysisResult(_ result: Result<StoreProductAnalysis, ProductAnalysisFailure>) {
        isAnalyzing = false
        switch result {
        case .success(let analysis):
            productName = analysis.productName
            provider = analysis.provider
            variants = analysis.variants
            if analysis.provider == .zara {
                selectedColorProductID = analysis.variants.compactMap { $0.zaraMetadata?.colorProductID }.first ?? ""
                selectedVariantID = ""
            } else if analysis.provider == .bershka {
                let requestedColor = analysisURL.flatMap { url in
                    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                        .first(where: { $0.name.caseInsensitiveCompare("colorId") == .orderedSame })?.value
                }
                let discoveredColorIDs = Array(Set(analysis.variants.compactMap { $0.bershkaMetadata?.colorID }))
                selectedColorProductID = discoveredColorIDs.count == 1
                    ? discoveredColorIDs[0]
                    : requestedColor.flatMap { requested in discoveredColorIDs.first(where: { $0 == requested }) } ?? ""
                selectedVariantID = ""
            } else if analysis.provider == .pullAndBear {
                let requestedColor = analysisURL.flatMap { url in
                    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                        .first(where: { $0.name.caseInsensitiveCompare("cS") == .orderedSame })?.value
                }
                let discoveredColors = Array(Set(analysis.variants.compactMap { $0.pullAndBearMetadata?.colorIdentity }))
                selectedColorProductID = requestedColor.flatMap { requested in discoveredColors.first(where: { $0 == requested }) }
                    ?? (discoveredColors.count == 1 ? discoveredColors[0] : "")
                selectedVariantID = ""
            } else {
                selectedVariantID = ""
            }
        case .failure(let error):
            analysisError = error.localizedDescription
        }
    }

    private func addSelectedProduct() {
        guard
            let analysisURL,
            let productName,
            let candidate = variants.first(where: { $0.id == selectedVariantID })
        else { return }

        duplicateError = nil

        let added = onAdd(TrackedProduct(
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
            events: []
        ))
        if added {
            dismiss()
        } else {
            duplicateError = "Bu ürünün bu varyantı zaten takip ediliyor."
        }
    }

    private func sizePickerTitle(for candidate: StoreVariantCandidate) -> String {
        let size = candidate.variant.options.last?.value ?? candidate.displayTitle
        if provider == .pullAndBear, let available = candidate.pullAndBearInitialAvailability {
            return "\(size) — \(available ? "Stokta" : "Stokta değil")"
        }
        guard provider == .bershka, let snapshot = candidate.bershkaSnapshot else { return size }
        return "\(size) — \(snapshot.displayLabel)"
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
