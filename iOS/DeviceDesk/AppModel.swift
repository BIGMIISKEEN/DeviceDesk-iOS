import SwiftUI
import Combine

@MainActor final class AppModel: ObservableObject {
    @Published var capabilities: Capabilities?
    @Published var target = ""
    @Published var inventory: JSONValue = .null
    @Published var driverReport: JSONValue = .null
    @Published var directoryRows: [JSONValue] = []
    @Published var cleanupPreview: JSONValue = .null
    @Published var busy = false
    @Published var status = "Connect to your Windows bridge to begin."
    @Published var message: String?
    @Published var pending: PendingOperation?
    @Published var selectedPage: Page? = .overview
    @Published var demo = false
    @Published var collectedAt: Date?
    @Published var endpoint: String
    private var client: BridgeClient?
    init() {
        endpoint = UserDefaults.standard.string(forKey: "bridgeEndpoint") ?? ""
        if let bytes = UserDefaults.standard.data(forKey: "pendingOperation") { pending = try? JSONDecoder().decode(PendingOperation.self, from: bytes) }
    }
    var connected: Bool { capabilities != nil && !demo }
    func permits(_ action: String) -> Bool { connected && capabilities?.actions.contains(action) == true && !busy && pending == nil }
    func persistPending(_ operation: PendingOperation?) {
        pending = operation
        if let operation, let bytes = try? JSONEncoder().encode(operation) { UserDefaults.standard.set(bytes, forKey: "pendingOperation") }
        else { UserDefaults.standard.removeObject(forKey: "pendingOperation") }
    }
    func connect(address: String, enteredToken: String) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            let url = try BridgeClient.normalizedEndpoint(address)
            let key = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let token = enteredToken.isEmpty ? (TokenVault.read(endpoint: key) ?? "") : enteredToken
            guard token.count >= 40 else { throw AppFailure(message: "Enter the access token created by your bridge administrator.") }
            let api = BridgeClient(endpoint: url, token: token)
            let cap = try await api.capabilities()
            guard cap.apiVersion == 1 else { throw AppFailure(message: "This bridge uses an unsupported API version.") }
            try TokenVault.save(token, endpoint: key)
            client = api; endpoint = key; capabilities = cap; demo = false
            UserDefaults.standard.set(key, forKey: "bridgeEndpoint")
            target = cap.targets.first ?? ""
            clearResults()
            status = "Connected as \(cap.operator)."
        } catch { message = error.localizedDescription }
    }
    func disconnect() {
        guard !busy else { return }
        client = nil; capabilities = nil; demo = false; target = ""; clearResults()
        status = "Disconnected. Pending operation references are retained for reconciliation."
    }
    func forgetToken() { disconnect(); TokenVault.delete(endpoint: endpoint) }
    func clearResults() { inventory = .null; driverReport = .null; directoryRows = []; cleanupPreview = .null; collectedAt = nil }
    func changeTarget(_ value: String) { guard !busy else { return }; target = value; clearResults() }
    func run(_ action: String, payload: [String: JSONValue] = [:], confirmed: Bool = false) async {
        guard permits(action), let client else { return }
        let destination = action.hasPrefix("Directory") ? (capabilities?.directoryServer ?? "") : target
        guard !destination.isEmpty else { message = "No permitted target is configured."; return }
        if action == "DirectorySearch" { directoryRows = [] }
        if action == "DriverUpdates" { driverReport = .null }
        if action == "TempPreview" { cleanupPreview = .null }
        let operation = PendingOperation(requestId: UUID(), action: action, target: destination, endpoint: endpoint)
        persistPending(operation) // Before POST, so a lost response can be reconciled without repeating a write.
        busy = true; status = "Submitting \(action) for \(destination)…"
        defer { busy = false }
        var accepted = false
        do {
            let ticket = try await client.submit(JobSubmission(requestId: operation.requestId, action: action, target: destination, payload: payload, confirmed: confirmed))
            accepted = true
            try await poll(ticket.id, client: client)
        } catch {
            if !accepted, let http = error as? BridgeHTTPFailure, [400, 401, 403, 409, 413, 415, 422, 429].contains(http.status) {
                persistPending(nil); status = "Request rejected; no operation was started."
                message = http.localizedDescription; return
            }
            status = "Connection interrupted. Operation outcome needs checking."
            message = error.localizedDescription + "\nUse Check pending operation to retrieve the result. Do not repeat a change until its outcome is known."
        }
    }
    func resume() async {
        guard !busy, let pending, let client else { return }
        guard endpoint == pending.endpoint else { message = "Connect to the original bridge: \(pending.endpoint)"; return }
        busy = true; defer { busy = false }
        do { let ticket = try await client.lookup(pending.requestId); try await poll(ticket.id, client: client) }
        catch { message = error.localizedDescription + "\nIf the bridge has no record, verify the target before clearing this pending reference." }
    }
    private func poll(_ id: String, client: BridgeClient) async throws {
        for _ in 0..<480 {
            let job = try await client.job(id)
            status = "\(job.action) · \(job.target) · \(job.state)"
            switch job.state {
            case "queued", "running": try await Task.sleep(for: .seconds(2))
            case "succeeded":
                apply(job); persistPending(nil); return
            case "failed":
                message = job.error ?? "Operation failed."; persistPending(nil); return
            default:
                message = job.error ?? "Outcome unknown. Verify on the target before repeating."
                // Unknown/expired operations require an explicit acknowledgement to clear.
                return
            }
        }
        throw AppFailure(message: "Polling timed out; use Check pending operation later.")
    }
    private func apply(_ job: JobStatus) {
        if !job.action.hasPrefix("Directory"), target != job.target {
            clearResults(); target = job.target
        }
        let result = job.result ?? .null
        switch job.action {
        case "Inventory": inventory = result; collectedAt = Date()
        case "DriverUpdates": driverReport = result; collectedAt = Date(); message = result["Note"].text
        case "DirectorySearch": directoryRows = result["Rows"].rows; message = result["Note"].text
        case "TempPreview": cleanupPreview = result
        case "DirectoryUnlock", "DirectoryResetPassword": directoryRows = []; message = result["Note"].text
        case "TempDelete", "TempDiscard": cleanupPreview = .null; message = result.text
        default: message = result.text
        }
    }
    func loadDemo() {
        guard !busy, pending == nil else { return }
        client = nil; capabilities = nil; demo = true; clearResults(); target = "DEMO-PC-001"
        inventory = .object([
            "Summary": .array([.object(["Item": .string("Computer"), "Value": .string(target)]), .object(["Item": .string("Windows"), "Value": .string("Windows 11 — sample")]), .object(["Item": .string("RAM total GB"), "Value": .string("32")]), .object(["Item": .string("RAM available GB"), "Value": .string("18.4")])]),
            "Connected": .array([.object(["Device": .string("USB-C display — sample"), "Class": .string("Monitor"), "Status": .string("OK"), "DriverVersion": .string("Sample only"), "UpdateStatus": .string("Not checked")])])
        ])
        status = "DEMO · Sample data only. All remote actions are disabled."
    }
}
