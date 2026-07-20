import XCTest
@testable import EqualizerAU

final class AudioDebugLoggerTests: XCTestCase {
    func testWritesOneStructuredJSONRecordPerLine() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EqualizerAU-log-\(UUID().uuidString)/audio.jsonl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let logger = AudioDebugLogger(fileURL: url, sessionID: "test-session")

        await logger.log(
            "pipeline.start",
            generation: AudioGeneration(rawValue: 7),
            fields: ["sampleRate": "48000", "device": "test-output"]
        )

#if DEBUG
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["event"] as? String, "pipeline.start")
        XCTAssertEqual(object["sessionID"] as? String, "test-session")
        XCTAssertEqual(object["generation"] as? UInt64, 7)
        XCTAssertEqual((object["fields"] as? [String: String])?["sampleRate"], "48000")
#endif
    }
}
