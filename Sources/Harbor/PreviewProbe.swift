import Foundation

enum PreviewHealth: String, Sendable {
    case checking = "Checking preview…"
    case available = "Preview available"
    case missingPage = "Preview connected · no page yet"
    case unavailable = "Preview unavailable"
    case unknown = "Preview status unknown"
}

enum PreviewProbe {
    static func check(port: Int, runID: String) async -> PreviewHealth {
        guard (1024...65535).contains(port), let url = URL(string: "http://127.0.0.1:\(port)/") else { return .unavailable }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2; configuration.timeoutIntervalForResource = 3
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.httpMethod = "HEAD"
        do {
            let (_, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, response.value(forHTTPHeaderField: "X-Harbor-Preview") == runID else { return .unknown }
            return response.statusCode == 200 ? .available : response.statusCode == 404 ? .missingPage : .unavailable
        } catch { return .unavailable }
    }
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
}
