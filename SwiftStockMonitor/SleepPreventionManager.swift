import Foundation

enum MonitoringPowerMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case normal = "normal"
    case keepMacAndDisplayAwake = "keepMacAndDisplayAwake"
    case allowDisplaySleepKeepMacAwake = "allowDisplaySleepKeepMacAwake"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal:
            return "Normal"
        case .keepMacAndDisplayAwake:
            return "Mac ve ekran uyanık kalsın"
        case .allowDisplaySleepKeepMacAwake:
            return "Ekran kapanabilsin, Mac uyumasın"
        }
    }

    var description: String {
        switch self {
        case .normal:
            return "macOS ekran ve sistem uykusunu normal şekilde yönetir."
        case .keepMacAndDisplayAwake:
            return "İzleme sırasında Mac'in ve ekranın uykuya geçmesini engeller."
        case .allowDisplaySleepKeepMacAwake:
            return "Ekran kapanabilir; Mac uyumaz ve izleme devam eder."
        }
    }

    static let `default`: MonitoringPowerMode = .allowDisplaySleepKeepMacAwake
}

@MainActor
final class SleepPreventionManager: ObservableObject {
    static let shared = SleepPreventionManager()

    @Published private(set) var activeMode: MonitoringPowerMode?

    private var currentActivity: (any NSObjectProtocol)?
    private var isMonitoringActive = false
    private var configuredMode: MonitoringPowerMode = .default

    private init() {}

    var isPreventingSleep: Bool {
        currentActivity != nil
    }

    func updateMonitoringState(isActive: Bool) {
        guard isMonitoringActive != isActive else { return }
        isMonitoringActive = isActive
        applyCurrentPolicy()
    }

    func updatePowerMode(_ mode: MonitoringPowerMode) {
        guard configuredMode != mode else { return }
        configuredMode = mode
        applyCurrentPolicy()
    }

    func configure(isMonitoringActive: Bool, mode: MonitoringPowerMode) {
        self.isMonitoringActive = isMonitoringActive
        self.configuredMode = mode
        applyCurrentPolicy()
    }

    private func applyCurrentPolicy() {
        guard isMonitoringActive, configuredMode != .normal else {
            endActivity()
            return
        }

        // If activity is already active in the requested mode, preserve it without churn.
        if activeMode == configuredMode, currentActivity != nil {
            return
        }

        // Mode changed or new activity requested: release previous activity first.
        endActivity()

        let options: ProcessInfo.ActivityOptions
        switch configuredMode {
        case .normal:
            return
        case .keepMacAndDisplayAwake:
            options = [.idleSystemSleepDisabled, .idleDisplaySleepDisabled]
        case .allowDisplaySleepKeepMacAwake:
            options = [.idleSystemSleepDisabled]
        }

        currentActivity = ProcessInfo.processInfo.beginActivity(
            options: options,
            reason: "StockPing aktif ürün stok takibi"
        )
        activeMode = configuredMode
    }

    private func endActivity() {
        if let activity = currentActivity {
            ProcessInfo.processInfo.endActivity(activity)
            currentActivity = nil
        }
        activeMode = nil
    }
}
