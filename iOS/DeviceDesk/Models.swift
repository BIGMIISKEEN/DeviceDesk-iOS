import Foundation

// Preserve 64-bit process timestamps instead of rounding them through Double.
indirect enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), integer(Int64), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> JSONValue { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    var rows: [JSONValue] { if case .array(let v) = self { return v }; if case .object = self { return [self] }; return [] }
    var fields: [(String, JSONValue)] { if case .object(let v) = self { return v.filter { !["PSComputerName", "RunspaceId", "PSShowComputerName"].contains($0.key) }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) } }; return [] }
    var text: String {
        switch self {
        case .string(let v): return v
        case .integer(let v): return String(v)
        case .number(let v): return String(v)
        case .bool(let v): return v ? "Yes" : "No"
        case .null: return ""
        case .array(let v): return v.map(\.text).joined(separator: ", ")
        case .object: return fields.map { "\($0.0): \($0.1.text)" }.joined(separator: "\n")
        }
    }
}
struct Capabilities: Decodable, Sendable {
    let apiVersion: Int
    let `operator`: String
    let targets: [String]
    let actions: [String]
    let directoryServer: String
}
struct JobTicket: Decodable, Sendable { let id: String }
struct JobStatus: Decodable, Sendable {
    let id: String
    let action: String
    let target: String
    let state: String
    let result: JSONValue?
    let error: String?
}
struct JobSubmission: Encodable, Sendable {
    let requestId: UUID
    let action: String
    let target: String
    let payload: [String: JSONValue]
    let confirmed: Bool
}
struct PendingOperation: Codable, Sendable {
    let requestId: UUID
    let action: String
    let target: String
    let endpoint: String
}
enum Page: String, CaseIterable, Identifiable, Hashable {
    case overview = "Overview", devices = "Devices & drivers", directory = "Active Directory", actions = "Remote actions", connection = "Connection"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .devices: return "cpu"
        case .directory: return "person.2.badge.key"
        case .actions: return "bolt.horizontal.circle"
        case .connection: return "network"
        }
    }
}
struct AppFailure: LocalizedError { let message: String; var errorDescription: String? { message } }

struct BridgeHTTPFailure: LocalizedError { let status: Int; let message: String; var errorDescription: String? { message } }
