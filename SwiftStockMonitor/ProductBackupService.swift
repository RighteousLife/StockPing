import Foundation
import AppKit
import UniformTypeIdentifiers

struct StockPingExportPayload: Codable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var exportedAt: Date
    var appVersion: String
    var products: [StockPingExportProduct]
}

struct StockPingExportProduct: Codable {
    var id: UUID
    var productName: String
    var productURL: URL
    var selectedVariant: SelectedVariant
    var checkIntervalMinutes: Int
    var isPaused: Bool
    var provider: StoreProvider
    var zaraMetadata: ZaraVariantMetadata?
    var bershkaMetadata: BershkaVariantMetadata?
    var pullAndBearMetadata: PullAndBearVariantMetadata?
    var group: String?
    var tags: [String]
    var isPriority: Bool?
    var note: String?
    var isMacOSNotificationEnabled: Bool?
    var isEmailNotificationEnabled: Bool?
    var notificationProfile: NotificationProfile?
    var autoOpenOnRestock: Bool?

    init(from product: TrackedProduct) {
        self.id = product.id
        self.productName = product.productName
        self.productURL = product.productURL
        self.selectedVariant = product.selectedVariant
        self.checkIntervalMinutes = product.checkIntervalMinutes
        self.isPaused = product.isPaused
        self.provider = product.provider
        self.zaraMetadata = product.zaraMetadata
        self.bershkaMetadata = product.bershkaMetadata
        self.pullAndBearMetadata = product.pullAndBearMetadata
        self.group = product.group
        self.tags = product.tags
        self.isPriority = product.isPriority ? true : nil
        self.note = product.note
        self.isMacOSNotificationEnabled = product.isMacOSNotificationEnabled ? nil : false
        self.isEmailNotificationEnabled = product.isEmailNotificationEnabled ? nil : false
        self.notificationProfile = product.notificationProfile == .standard ? nil : product.notificationProfile
        self.autoOpenOnRestock = product.autoOpenOnRestock
    }

    var trackedProduct: TrackedProduct {
        TrackedProduct(
            id: UUID(), // Generate new unique ID upon import to prevent any ID collision
            productName: productName,
            productURL: productURL,
            selectedVariant: selectedVariant,
            lastChecked: nil,
            checkIntervalMinutes: checkIntervalMinutes,
            nextCheckDate: Date(),
            isPaused: isPaused,
            lastCheckError: nil,
            lastAvailabilityTransition: nil,
            provider: provider,
            zaraMetadata: zaraMetadata,
            bershkaMetadata: bershkaMetadata,
            pullAndBearMetadata: pullAndBearMetadata,
            events: [],
            latestDiagnostic: nil,
            group: group,
            tags: tags,
            consecutiveUnchangedChecks: 0,
            consecutiveFailureChecks: 0,
            isPriority: isPriority ?? false,
            note: note,
            isMacOSNotificationEnabled: isMacOSNotificationEnabled ?? true,
            isEmailNotificationEnabled: isEmailNotificationEnabled ?? true,
            notificationProfile: notificationProfile ?? .standard,
            autoOpenOnRestock: autoOpenOnRestock
        )
    }
}

struct ImportAnalysisResult {
    let totalInFile: Int
    let newProducts: [TrackedProduct]
    let duplicateCount: Int
}

enum BackupError: LocalizedError {
    case invalidData
    case unsupportedSchemaVersion(Int)
    case writeFailed(String)
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "Seçilen dosya geçerli bir StockPing yedek dosyası değil veya içeriği bozuk."
        case .unsupportedSchemaVersion(let v):
            return "Bu yedek dosyası daha yeni bir StockPing sürümü (v\(v)) tarafından oluşturulmuş. Lütfen uygulamanızı güncelleyin."
        case .writeFailed(let msg):
            return "Yedek dosyası yazılamadı: \(msg)"
        case .readFailed(let msg):
            return "Yedek dosyası okunamadı: \(msg)"
        }
    }
}

@MainActor
final class ProductBackupService {
    static let shared = ProductBackupService()

    private init() {}

    func exportProducts(_ products: [TrackedProduct]) {
        let payload = StockPingExportPayload(
            schemaVersion: StockPingExportPayload.currentSchemaVersion,
            exportedAt: Date(),
            appVersion: "StockPing 1.0",
            products: products.map(StockPingExportProduct.init)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(payload) else {
            showAlert(title: "Dışa Aktarma Hatası", message: "Yedek verisi oluşturulamadı.")
            return
        }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd-HHmm"
        savePanel.nameFieldStringValue = "StockPing-Yedek-\(dateFormatter.string(from: Date())).json"
        savePanel.title = "Ürünleri Dışa Aktar"
        savePanel.prompt = "Dışa Aktar"

        if savePanel.runModal() == .OK, let url = savePanel.url {
            do {
                try data.write(to: url, options: .atomic)
                showAlert(title: "Başarılı", message: "\(products.count) ürün başarıyla dışa aktarıldı.")
            } catch {
                showAlert(title: "Hata", message: "Dosya kaydedilemedi: \(error.localizedDescription)")
            }
        }
    }

    func promptImport(existingProducts: [TrackedProduct], onConfirm: @escaping ([TrackedProduct]) -> Void) {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.json]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.title = "Yedekten İçe Aktar"
        openPanel.prompt = "Seç"

        guard openPanel.runModal() == .OK, let url = openPanel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let result = try analyzeImportData(data, existingProducts: existingProducts)

            if result.newProducts.isEmpty {
                showAlert(
                    title: "İçe Aktarılacak Yeni Ürün Yok",
                    message: "Dosyadaki \(result.totalInFile) ürünün tümü zaten takip ediliyor."
                )
                return
            }

            let alert = NSAlert()
            alert.messageText = "Ürünleri İçe Aktar"
            var message = "\(result.newProducts.count) yeni ürün içeri aktarılacak."
            if result.duplicateCount > 0 {
                message += "\n\(result.duplicateCount) ürün zaten mevcut olduğu için atlanacak."
            }
            alert.informativeText = message
            alert.alertStyle = .informational
            alert.addButton(withTitle: "İçe Aktar")
            alert.addButton(withTitle: "İptal")

            if alert.runModal() == .alertFirstButtonReturn {
                onConfirm(result.newProducts)
                showAlert(
                    title: "Başarılı",
                    message: "\(result.newProducts.count) ürün başarıyla eklendi."
                )
            }
        } catch {
            showAlert(title: "İçe Aktarma Başarısız", message: error.localizedDescription)
        }
    }

    func analyzeImportData(_ data: Data, existingProducts: [TrackedProduct]) throws -> ImportAnalysisResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let exportProducts: [StockPingExportProduct]

        if let payload = try? decoder.decode(StockPingExportPayload.self, from: data) {
            guard payload.schemaVersion <= StockPingExportPayload.currentSchemaVersion else {
                throw BackupError.unsupportedSchemaVersion(payload.schemaVersion)
            }
            exportProducts = payload.products
        } else if let directList = try? decoder.decode([StockPingExportProduct].self, from: data) {
            exportProducts = directList
        } else {
            throw BackupError.invalidData
        }

        var newProducts: [TrackedProduct] = []
        var duplicateCount = 0

        for exportProduct in exportProducts {
            // Duplicate definition: same productURL and same variant ID
            let isDuplicate = existingProducts.contains { existing in
                existing.productURL == exportProduct.productURL &&
                existing.selectedVariant.id == exportProduct.selectedVariant.id
            }

            if isDuplicate {
                duplicateCount += 1
            } else {
                newProducts.append(exportProduct.trackedProduct)
            }
        }

        return ImportAnalysisResult(
            totalInFile: exportProducts.count,
            newProducts: newProducts,
            duplicateCount: duplicateCount
        )
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Tamam")
        alert.runModal()
    }
}
