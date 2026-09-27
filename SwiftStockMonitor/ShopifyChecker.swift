import CoreFoundation
import Foundation
import WebKit

struct ShopifyVariant: Identifiable, Sendable {
    let id: String
    let title: String
    let available: Bool?
    let options: [VariantOption]

    var displayTitle: String {
        if !options.isEmpty {
            return options.map(\.value).joined(separator: " · ")
        }
        return title.caseInsensitiveCompare("Default Title") == .orderedSame ? "Tek seçenek" : title
    }

    func selectedVariant(availability: Bool? = nil) -> SelectedVariant {
        SelectedVariant(id: id, title: title, options: options, availability: availability)
    }
}

struct ShopifyProduct: Sendable {
    let id: String
    let title: String
    let optionNames: [String]
    let variants: [ShopifyVariant]
}

enum ShopifyCheckerError: LocalizedError {
    case invalidProductURL
    case requestFailed(String)
    case requestTimedOut
    case productNotFound
    case invalidProductJSON
    case noVariants
    case variantNotFound(String)
    case availabilityUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidProductURL:
            "URL geçerli bir Shopify ürün yolu içermiyor."
        case .requestFailed(let detail):
            "Shopify ürün verisine erişilemedi. \(detail)"
        case .requestTimedOut:
            "Shopify ürün isteği zaman aşımına uğradı."
        case .productNotFound:
            "Bu URL için Shopify ürünü bulunamadı."
        case .invalidProductJSON:
            "Yanıt Shopify ürün JSON'u olarak okunamadı."
        case .noVariants:
            "Shopify ürün verisinde varyant bulunamadı."
        case .variantNotFound(let id):
            "Varyant ID \(id) Shopify ürün verisinde bulunamadı."
        case .availabilityUnavailable:
            "Hedef varyantın Shopify available bilgisi okunamadı."
        }
    }
}

enum ShopifyChecker {
    private static let javascriptRequestTimeoutMilliseconds = 10_000
    private static let swiftRequestTimeout: Duration = .seconds(15)

    static func canHandle(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && productPath(in: url.path) != nil
    }

    static func productIdentity(for url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        guard let path = productPath(in: url.path) else { return url.absoluteString.lowercased() }
        return "\(host)/products/\(path.handle.lowercased())"
    }

    static func normalizedProductURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let components = URLComponents(string: trimmed),
            components.scheme?.lowercased() == "https",
            let host = components.host,
            !host.isEmpty,
            components.user == nil,
            components.password == nil,
            productPath(in: components.path) != nil
        else { return nil }

        var normalized = components
        normalized.path = "/" + components.path.split(separator: "/").joined(separator: "/")
        normalized.query = nil
        normalized.fragment = nil
        return normalized.url
    }

    static func productEndpoint(for productURL: URL, activePageURL: URL?) throws -> URL {
        guard
            productURL.scheme?.lowercased() == "https",
            let requestedProductPath = productPath(in: productURL.path)
        else { throw ShopifyCheckerError.invalidProductURL }

        let activePage = activePageURL.flatMap { url -> URL? in
            guard url.scheme?.lowercased() == "https", url.host != nil else { return nil }
            return url
        }
        let activePath = activePage.flatMap { productPath(in: $0.path) }
        let activePathMatches = activePath?.handle == requestedProductPath.handle
        let prefix = activePathMatches ? activePath!.prefix : requestedProductPath.prefix

        var endpoint = URLComponents(url: activePage ?? productURL, resolvingAgainstBaseURL: false)
        endpoint?.path = "/" + (prefix + ["products", "\(requestedProductPath.handle).js"]).joined(separator: "/")
        endpoint?.query = nil
        endpoint?.fragment = nil

        guard let url = endpoint?.url else { throw ShopifyCheckerError.invalidProductURL }
        return url
    }

    @MainActor
    static func fetchProduct(
        in webView: WKWebView,
        productURL: URL,
        activePageURL: URL?
    ) async throws -> ShopifyProduct {
        let endpoint = try productEndpoint(for: productURL, activePageURL: activePageURL)
        let gate = ShopifyRequestGate()
        let result = try await gate.run(timeout: swiftRequestTimeout) {
            try await webView.callAsyncJavaScript(
            """
            return await (async () => {
              const controller = new AbortController();
              const timeout = setTimeout(() => controller.abort(), timeoutMilliseconds);
              try {
                const response = await fetch(endpoint, {
                  cache: 'no-store',
                  credentials: 'same-origin',
                  headers: { 'Accept': 'application/json' },
                  signal: controller.signal
                });
                const body = await response.text();
                return {
                  status: response.status,
                  responseURL: response.url,
                  body
                };
              } catch (error) {
                if (controller.signal.aborted) return { timedOut: true };
                throw error;
              } finally {
                clearTimeout(timeout);
              }
            })();
            """,
            arguments: [
                "endpoint": endpoint.absoluteString,
                "timeoutMilliseconds": Self.javascriptRequestTimeoutMilliseconds
            ],
            in: nil,
            contentWorld: .page
            )
        }

        if (result as? [String: Any])?["timedOut"] as? Bool == true {
            throw ShopifyCheckerError.requestTimedOut
        }

        guard
            let response = result as? [String: Any],
            let status = response["status"] as? Int,
            let body = response["body"] as? String
        else { throw ShopifyCheckerError.invalidProductJSON }

        guard (200..<300).contains(status) else {
            if status == 404 { throw ShopifyCheckerError.productNotFound }
            throw ShopifyCheckerError.requestFailed("HTTP \(status).")
        }

        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let object = json as? [String: Any],
              let productID = stringValue(object["id"]),
              let title = object["title"] as? String,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let rawVariants = object["variants"] as? [[String: Any]]
        else { throw ShopifyCheckerError.invalidProductJSON }

        let optionNames = parseOptionNames(object["options"])
        let variants = rawVariants.compactMap { parseVariant($0, optionNames: optionNames) }
        guard !variants.isEmpty else { throw ShopifyCheckerError.noVariants }

        return ShopifyProduct(
            id: productID,
            title: title,
            optionNames: optionNames,
            variants: variants
        )
    }

    static func variant(withID id: String, in product: ShopifyProduct) throws -> ShopifyVariant {
        guard let variant = product.variants.first(where: { $0.id == id }) else {
            throw ShopifyCheckerError.variantNotFound(id)
        }
        guard variant.available != nil else { throw ShopifyCheckerError.availabilityUnavailable }
        return variant
    }

    private static func productPath(in path: String) -> (prefix: [String], handle: String)? {
        let segments = path.split(separator: "/").map(String.init)
        guard
            let index = segments.lastIndex(of: "products"),
            segments.indices.contains(index + 1),
            !segments[index + 1].isEmpty
        else { return nil }
        return (Array(segments[..<index]), segments[index + 1])
    }

    private static func parseVariant(_ object: [String: Any], optionNames: [String]) -> ShopifyVariant? {
        guard
            let id = stringValue(object["id"]),
            let title = object["title"] as? String
        else { return nil }

        let rawOptionValues = [object["option1"] as? String, object["option2"] as? String, object["option3"] as? String]
        let options = rawOptionValues.enumerated().compactMap { index, value -> VariantOption? in
            guard let value, !value.isEmpty, value.caseInsensitiveCompare("Default Title") != .orderedSame else { return nil }
            let name = optionNames.indices.contains(index) ? optionNames[index] : "Option \(index + 1)"
            return VariantOption(name: name, value: value)
        }

        return ShopifyVariant(
            id: id,
            title: title,
            available: booleanValue(object["available"]),
            options: options
        )
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.stringValue
    }

    private static func booleanValue(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func parseOptionNames(_ value: Any?) -> [String] {
        if let names = value as? [String] { return names }
        if let options = value as? [[String: Any]] {
            return options.compactMap { $0["name"] as? String }
        }
        return []
    }
}

@MainActor
private final class ShopifyRequestGate {
    private var continuation: CheckedContinuation<ShopifyJavaScriptResult, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?

    func run(
        timeout: Duration,
        operation: @escaping @MainActor () async throws -> Any?
    ) async throws -> Any? {
        try Task.checkCancellation()

        let result: ShopifyJavaScriptResult = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ShopifyJavaScriptResult, Error>) in
                self.continuation = continuation
                timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    self?.finish(.failure(ShopifyCheckerError.requestTimedOut))
                }

                operationTask = Task { [weak self] in
                    do {
                        let result = try await operation()
                        self?.finish(.success(ShopifyJavaScriptResult(value: result)))
                    } catch {
                        self?.finish(.failure(error))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(.failure(CancellationError()))
            }
        }
        return result.value
    }

    private func finish(_ result: Result<ShopifyJavaScriptResult, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        operationTask?.cancel()
        operationTask = nil
        continuation.resume(with: result)
    }
}

private struct ShopifyJavaScriptResult: @unchecked Sendable {
    let value: Any?
}
