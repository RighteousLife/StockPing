import Foundation

enum EmailNotificationError: LocalizedError, Equatable {
    case mailUnavailable
    case permissionDenied
    case noConfiguredAccount
    case scriptExecutionFailed(String)
    case messageCreationFailed
    case sendFailed(String)
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .mailUnavailable:
            return "Mail uygulaması bulunamadı veya açılamıyor."
        case .permissionDenied:
            return "Mail uygulamasına erişim izni gerekiyor. Sistem Ayarları > Gizlilik ve Güvenlik > Otomasyon bölümünden StockPing için Mail erişimine izin verin."
        case .noConfiguredAccount:
            return "Mail uygulamasında etkin bir e-posta hesabı bulunamadı. Lütfen Mail uygulamasında bir hesap yapılandırın."
        case .scriptExecutionFailed(let message):
            return "Mail betiği çalıştırılamadı: \(message)"
        case .messageCreationFailed:
            return "E-posta iletisi oluşturulamadı."
        case .sendFailed(let message):
            return "E-posta gönderilemedi: \(message)"
        case .unexpected(let message):
            return "Beklenmeyen e-posta hatası: \(message)"
        }
    }
}

@MainActor
final class EmailNotificationService: ObservableObject {
    static let shared = EmailNotificationService()

    @Published private(set) var isSendingTestEmail = false
    @Published private(set) var lastErrorMessage: String?

    private struct PendingEmail {
        let productID: UUID
        let productName: String
        let variantTitle: String
        let subject: String
        let content: String
    }

    private var pendingEmails: [PendingEmail] = []
    private var isProcessingQueue = false

    private init() {}

    func sendRestockNotification(for product: TrackedProduct) {
        let store: String
        switch product.provider {
        case .zara: store = "Zara Türkiye"
        case .bershka: store = "Bershka Türkiye"
        case .pullAndBear: store = "Pull&Bear Türkiye"
        case .shopify: store = product.productURL.host() ?? "Shopify Mağazası"
        }

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "tr_TR")
        timeFormatter.dateStyle = .medium
        timeFormatter.timeStyle = .short
        let timeString = timeFormatter.string(from: Date())

        var bodyLines = [
            "StockPing bir ürünün tekrar stokta olduğunu tespit etti.",
            "",
            "Ürün: \(product.productName)",
            "Mağaza: \(store)"
        ]
        if !product.variantTitle.isEmpty && product.variantTitle != "Default Title" {
            bodyLines.append("Varyant: \(product.variantTitle)")
        }
        bodyLines.append("Kontrol zamanı: \(timeString)")
        bodyLines.append("")
        bodyLines.append("Ürün bağlantısı:")
        bodyLines.append(product.productURL.absoluteString)

        let subject = "StockPing — Ürün Stokta!"
        let content = bodyLines.joined(separator: "\n")

        pendingEmails.append(PendingEmail(
            productID: product.id,
            productName: product.productName,
            variantTitle: product.variantTitle,
            subject: subject,
            content: content
        ))
        guard !isProcessingQueue else { return }

        isProcessingQueue = true
        Task { @MainActor in
            await processPendingEmails()
        }
    }

    func sendDepletionNotification(for product: TrackedProduct) {
        let store: String
        switch product.provider {
        case .zara: store = "Zara Türkiye"
        case .bershka: store = "Bershka Türkiye"
        case .pullAndBear: store = "Pull&Bear Türkiye"
        case .shopify: store = product.productURL.host() ?? "Shopify Mağazası"
        }

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "tr_TR")
        timeFormatter.dateStyle = .medium
        timeFormatter.timeStyle = .short
        let timeString = timeFormatter.string(from: Date())

        var bodyLines = [
            "StockPing bir ürünün stoğunun tükendiğini tespit etti.",
            "",
            "Ürün: \(product.productName)",
            "Mağaza: \(store)"
        ]
        if !product.variantTitle.isEmpty && product.variantTitle != "Default Title" {
            bodyLines.append("Varyant: \(product.variantTitle)")
        }
        bodyLines.append("Kontrol zamanı: \(timeString)")
        bodyLines.append("")
        bodyLines.append("Ürün bağlantısı:")
        bodyLines.append(product.productURL.absoluteString)

        let subject = "StockPing — Ürün Stoğu Tükendi"
        let content = bodyLines.joined(separator: "\n")

        pendingEmails.append(PendingEmail(
            productID: product.id,
            productName: product.productName,
            variantTitle: product.variantTitle,
            subject: subject,
            content: content
        ))
        guard !isProcessingQueue else { return }

        isProcessingQueue = true
        Task { @MainActor in
            await processPendingEmails()
        }
    }

    func sendTestEmail() async throws -> String {
        guard !isSendingTestEmail else {
            throw EmailNotificationError.unexpected("Halen devam eden bir test e-postası gönderimi var.")
        }
        isSendingTestEmail = true
        lastErrorMessage = nil
        defer { isSendingTestEmail = false }

        let subject = "StockPing — Test E-postası"
        let content = "Bu, StockPing e-posta bildirimlerinin çalıştığını doğrulamak için gönderilen test e-postasıdır."

        do {
            let recipient = try await Self.dispatchMail(subject: subject, content: content)
            return recipient
        } catch {
            let localized = (error as? EmailNotificationError)?.localizedDescription ?? error.localizedDescription
            lastErrorMessage = localized
            throw error
        }
    }

    private func processPendingEmails() async {
        while !pendingEmails.isEmpty {
            let email = pendingEmails.removeFirst()
            do {
                let recipient = try await Self.dispatchMail(subject: email.subject, content: email.content)
                NotificationAuditManager.shared.record(
                    productID: email.productID,
                    productName: email.productName,
                    variantTitle: email.variantTitle,
                    channel: .email,
                    status: .sent,
                    message: "E-posta gönderildi: \(recipient)"
                )
            } catch {
                NSLog("[StockPing Email] Restock email failed: %@", error.localizedDescription)
                let errorDesc = (error as? EmailNotificationError)?.localizedDescription ?? error.localizedDescription
                NotificationAuditManager.shared.record(
                    productID: email.productID,
                    productName: email.productName,
                    variantTitle: email.variantTitle,
                    channel: .email,
                    status: .failed,
                    message: errorDesc
                )
            }
        }
        isProcessingQueue = false
    }

    private static func dispatchMail(subject: String, content: String) async throws -> String {
        // Race the AppleScript execution against a 30-second timeout to prevent
        // a hung Mail app from blocking the email queue indefinitely.
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await Task.detached {
                    try executeAppleScript(subject: subject, content: content)
                }.value
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw EmailNotificationError.sendFailed("Mail uygulaması 30 saniye içinde yanıt vermedi.")
            }
            // Return the first successful result (the AppleScript completion).
            // If the timeout wins, it throws and cancels the other task.
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private static nonisolated func executeAppleScript(subject: String, content: String) throws -> String {
        let escapedSubject = escapeForAppleScript(subject)
        let escapedContent = escapeForAppleScript(content)

        let scriptSource = """
        set theSubject to "\(escapedSubject)"
        set theContent to "\(escapedContent)"

        tell application "Mail"
            set accList to every account
            set targetAddress to ""
            repeat with acc in accList
                if enabled of acc is true then
                    set addrList to email addresses of acc
                    if (count of addrList) > 0 then
                        set targetAddress to (item 1 of addrList) as text
                        exit repeat
                    end if
                end if
            end repeat
            if targetAddress is "" then
                error "Mail uygulamasında etkin bir e-posta hesabı bulunamadı." number 1001
            end if
            set msg to make new outgoing message with properties {subject:theSubject, content:theContent, visible:false}
            tell msg
                make new to recipient at end of to recipients with properties {address:targetAddress}
                send
            end tell
            return targetAddress
        end tell
        """

        var errorDict: NSDictionary?
        guard let script = NSAppleScript(source: scriptSource) else {
            throw EmailNotificationError.messageCreationFailed
        }

        let result = script.executeAndReturnError(&errorDict)
        if let errorDict = errorDict {
            let errorNumber = errorDict[NSAppleScript.errorNumber] as? Int ?? 0
            let errorMessage = errorDict[NSAppleScript.errorMessage] as? String ?? "Bilinmeyen hata"

            if errorNumber == -1743 || errorMessage.localizedCaseInsensitiveContains("not permitted") || errorMessage.localizedCaseInsensitiveContains("authorized") {
                throw EmailNotificationError.permissionDenied
            } else if errorNumber == -600 || errorMessage.localizedCaseInsensitiveContains("procNotFound") {
                throw EmailNotificationError.mailUnavailable
            } else if errorNumber == 1001 || errorMessage.localizedCaseInsensitiveContains("etkin bir e-posta hesabı bulunamadı") {
                throw EmailNotificationError.noConfiguredAccount
            } else {
                throw EmailNotificationError.sendFailed(errorMessage)
            }
        }

        return result.stringValue ?? ""
    }

    private static nonisolated func escapeForAppleScript(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
