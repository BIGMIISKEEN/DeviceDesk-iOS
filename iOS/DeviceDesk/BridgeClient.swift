import Foundation
import Security

struct TokenVault {
    static let service = "DeviceDesk.BridgeToken"
    static func save(_ token: String, endpoint: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: endpoint]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw AppFailure(message: "Could not save the access token to Keychain (\(status)).") }
    }
    static func read(endpoint: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: endpoint, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func delete(endpoint: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: endpoint] as CFDictionary)
    }
}
final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
final class BridgeClient: @unchecked Sendable {
    let endpoint: URL
    private let token: String
    private let session: URLSession
    static func normalizedEndpoint(_ input: String) throws -> URL {
        guard let parts = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)), parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/", let url = parts.url else {
            throw AppFailure(message: "Enter the bridge HTTPS origin, for example https://devicedesk.company.example:9443. No path, username or query is allowed.")
        }
        return url
    }
    init(endpoint: URL, token: String) {
        self.endpoint = endpoint; self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 45
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func request<T: Decodable & Sendable>(_ path: String, body: Data? = nil) async throws -> T {
        let url = endpoint.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppFailure(message: "No valid bridge response.") }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(JSONValue.self, from: data)["detail"].text) ?? ""
            throw BridgeHTTPFailure(status: http.statusCode, message: message.isEmpty ? "Bridge returned HTTP \(http.statusCode)." : message)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func capabilities() async throws -> Capabilities { try await request("v1/capabilities") }
    func submit(_ submission: JobSubmission) async throws -> JobTicket { try await request("v1/jobs", body: JSONEncoder().encode(submission)) }
    func lookup(_ requestID: UUID) async throws -> JobTicket { try await request("v1/requests/\(requestID.uuidString.lowercased())") }
    func job(_ id: String) async throws -> JobStatus { try await request("v1/jobs/\(id)") }
}
