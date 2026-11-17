import XCTest
@testable import DeviceDesk

final class DeviceDeskTests: XCTestCase {
    func testPreservesProcessTimestamp() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data("{\"StartTicks\":638987654321987654}".utf8))
        XCTAssertEqual(value["StartTicks"].text, "638987654321987654")
        let again = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(again, value)
    }
    func testRequiresHTTPSOrigin() throws {
        for bad in ["http://bridge.test", "https://name:secret@bridge.test", "https://bridge.test/path", "https://bridge.test?q=x", "https://bridge.test/#fragment"] {
            XCTAssertThrowsError(try BridgeClient.normalizedEndpoint(bad))
        }
        XCTAssertEqual(try BridgeClient.normalizedEndpoint("https://bridge.test:9443").host, "bridge.test")
    }
    func testDecodesSingleAndMultipleRows() throws {
        let single = try JSONDecoder().decode(JSONValue.self, from: Data("{\"Name\":\"Tester\"}".utf8))
        XCTAssertEqual(single.rows.count, 1)
        XCTAssertEqual(JSONValue.array([single, single]).rows.count, 2)
        XCTAssertEqual(JSONValue.null.rows.count, 0)
    }
    func testJobEnvelope() throws {
        let data = Data("{\"id\":\"123\",\"action\":\"Inventory\",\"target\":\"PC001\",\"state\":\"unknown\",\"result\":null,\"error\":\"Verify before retrying\"}".utf8)
        let job = try JSONDecoder().decode(JobStatus.self, from: data)
        XCTAssertEqual(job.state, "unknown")
        XCTAssertEqual(job.error, "Verify before retrying")
    }
}
