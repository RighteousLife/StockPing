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

import IOKit.ps

public struct SystemPowerSourceState: Sendable, Equatable {
    public let isConnectedToAC: Bool
    public let batteryPercentage: Int?
    public let isCharging: Bool

    public static func current() -> SystemPowerSourceState {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              !sources.isEmpty else {
            return SystemPowerSourceState(isConnectedToAC: true, batteryPercentage: 100, isCharging: false)
        }

        var isAC = false
        var lowestBattery: Int? = nil
        var charging = false

        for source in sources {
            if let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] {
                let state = desc["Power Source State"] as? String ?? ""
                if state == "AC Power" {
                    isAC = true
                }
                if let cap = desc["Current Capacity"] as? Int {
                    if let curLowest = lowestBattery {
                        lowestBattery = min(curLowest, cap)
                    } else {
                        lowestBattery = cap
                    }
                }
                if let isChg = desc["Is Charging"] as? Bool, isChg {
                    charging = true
                }
            }
        }

        return SystemPowerSourceState(
            isConnectedToAC: isAC,
            batteryPercentage: lowestBattery,
            isCharging: charging
        )
    }
}

public enum HelperAuthorizationStatus: String, Sendable {
    case authorized
    case notAuthorized
    case unknown

    public var title: String {
        switch self {
        case .authorized: "Yetkili (Hazır)"
        case .notAuthorized: "Yetki Gerekli"
        case .unknown: "Kontrol Edilmedi"
        }
    }
}

@MainActor
public final class ClosedDisplayManager: ObservableObject {
    public static let shared = ClosedDisplayManager()

    @Published public private(set) var isSleepDisabled: Bool = false
    @Published public private(set) var authorizationStatus: HelperAuthorizationStatus = .unknown
    @Published public private(set) var lastErrorMessage: String? = nil
    @Published public private(set) var batteryStatus: SystemPowerSourceState = .current()

    private let sudoPath = "/usr/bin/sudo"
    private let pmsetPath = "/usr/bin/pmset"
    private let sudoersRulePath = "/private/etc/sudoers.d/stockping-clamshell"

    private init() {
        checkAuthorization()
    }

    public func checkAuthorization() {
        batteryStatus = .current()
        let (exitCode, _) = runSudoPmset(args: ["-n", pmsetPath, "disablesleep", "0"])
        if exitCode == 0 {
            authorizationStatus = .authorized
        } else {
            authorizationStatus = .notAuthorized
        }
    }

    @discardableResult
    public func requestAuthorization() -> Bool {
        let script = "mkdir -p /private/etc/sudoers.d && echo \"ALL ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0\" > \(sudoersRulePath) && chmod 0440 \(sudoersRulePath) && visudo -c -f \(sudoersRulePath)"
        let appleScript = "do shell script \"\(script)\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                checkAuthorization()
                return authorizationStatus == .authorized
            } else {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                lastErrorMessage = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return false
            }
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func removeAuthorization() -> Bool {
        let script = "rm -f \(sudoersRulePath)"
        let appleScript = "do shell script \"\(script)\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        do {
            try process.run()
            process.waitUntilExit()
            checkAuthorization()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    @discardableResult
    public func setDisableSleep(_ disable: Bool) -> Bool {
        let arg = disable ? "1" : "0"
        let (code, output) = runSudoPmset(args: ["-n", pmsetPath, "disablesleep", arg])
        if code == 0 {
            isSleepDisabled = disable
            lastErrorMessage = nil
            return true
        } else {
            lastErrorMessage = output.isEmpty ? "Yetkilendirme hatası (çıkış: \(code))" : output
            return false
        }
    }

    nonisolated public func emergencyRestoreOnTermination() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "/usr/bin/pmset", "disablesleep", "0"]
        try? process.run()
        process.waitUntilExit()
    }

    private func runSudoPmset(args: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sudoPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (process.terminationStatus, output)
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}

@MainActor
final class SleepPreventionManager: ObservableObject {
    static let shared = SleepPreventionManager()

    @Published private(set) var activeMode: MonitoringPowerMode?
    @Published private(set) var isClosedDisplayActive: Bool = false
    @Published private(set) var closedDisplayStatusMessage: String? = nil

    private var currentActivity: (any NSObjectProtocol)?
    private var isMonitoringActive = false
    private var configuredMode: MonitoringPowerMode = .default
    private var configuredClosedDisplay: Bool = false
    private var configuredRequireACPower: Bool = true
    private var configuredMinBatteryLevel: Int = 20

    private init() {}

    var isPreventingSleep: Bool {
        currentActivity != nil || isClosedDisplayActive
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

    func configure(
        isMonitoringActive: Bool,
        mode: MonitoringPowerMode,
        closedDisplayEnabled: Bool = false,
        requireACPower: Bool = true,
        minBatteryLevel: Int = 20
    ) {
        self.isMonitoringActive = isMonitoringActive
        self.configuredMode = mode
        self.configuredClosedDisplay = closedDisplayEnabled
        self.configuredRequireACPower = requireACPower
        self.configuredMinBatteryLevel = minBatteryLevel
        applyCurrentPolicy()
    }

    private func applyCurrentPolicy() {
        guard isMonitoringActive else {
            endActivity()
            disableClosedDisplayIfNeeded()
            return
        }

        // Manage Closed-Display Clamshell Mode
        if configuredClosedDisplay {
            let power = SystemPowerSourceState.current()
            if configuredRequireACPower && !power.isConnectedToAC {
                disableClosedDisplayIfNeeded()
                closedDisplayStatusMessage = "Kapak kapalı takip beklemede (Priz bağlı değil)"
            } else if let battery = power.batteryPercentage, battery <= configuredMinBatteryLevel {
                disableClosedDisplayIfNeeded()
                closedDisplayStatusMessage = "Kapak kapalı takip devre dışı (Düşük pil: %\(battery))"
            } else {
                if ClosedDisplayManager.shared.authorizationStatus == .authorized {
                    let success = ClosedDisplayManager.shared.setDisableSleep(true)
                    isClosedDisplayActive = success
                    closedDisplayStatusMessage = success ? "Kapak kapalı takip modu etkin" : "Yetki hatası"
                } else {
                    disableClosedDisplayIfNeeded()
                    closedDisplayStatusMessage = "Yönetici yetkisi gerekli"
                }
            }
        } else {
            disableClosedDisplayIfNeeded()
            closedDisplayStatusMessage = nil
        }

        // Standard App Activity Assertion
        if configuredMode == .normal {
            endActivity()
            return
        }

        if activeMode == configuredMode, currentActivity != nil {
            return
        }

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

    private func disableClosedDisplayIfNeeded() {
        if isClosedDisplayActive || ClosedDisplayManager.shared.isSleepDisabled {
            ClosedDisplayManager.shared.setDisableSleep(false)
            isClosedDisplayActive = false
        }
    }

    private func endActivity() {
        if let activity = currentActivity {
            ProcessInfo.processInfo.endActivity(activity)
            currentActivity = nil
        }
        activeMode = nil
    }
}
