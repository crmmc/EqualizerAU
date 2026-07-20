import Foundation
import os

enum AudioDebugSession {
    static let id = UUID().uuidString.lowercased()
}

protocol AudioDebugLogging: Sendable {
    func log(_ event: String, generation: AudioGeneration?, fields: [String: String]) async
}

actor AudioDebugLogger: AudioDebugLogging {
    static let shared = AudioDebugLogger()

    private let fileURL: URL?
    private let sessionID: String
    private let systemLogger = Logger(subsystem: "com.ruimingchen.EqualizerAU", category: "AudioDebug")
    private let encoder: JSONEncoder

    init(
        fileURL: URL? = AudioDebugLogger.defaultFileURL(),
        sessionID: String = AudioDebugSession.id
    ) {
        self.fileURL = fileURL
        self.sessionID = sessionID
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    func log(
        _ event: String,
        generation: AudioGeneration? = nil,
        fields: [String: String] = [:]
    ) {
#if DEBUG
        let record = AudioDebugRecord(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            sessionID: sessionID,
            event: event,
            generation: generation?.rawValue,
            fields: fields
        )
        guard let data = try? encoder.encode(record),
              var line = String(data: data, encoding: .utf8)
        else { return }
        line.append("\n")
        systemLogger.debug("\(line, privacy: .public)")
        guard let fileURL, let bytes = line.data(using: .utf8) else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try bytes.write(to: fileURL, options: .atomic)
            } else {
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: bytes)
                try handle.close()
            }
        } catch {
            systemLogger.error("Unable to write audio debug log: \(error.localizedDescription, privacy: .public)")
        }
#endif
    }

    nonisolated static func defaultFileURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("EqualizerAU/Debug/audio-debug.jsonl")
    }
}

private struct AudioDebugRecord: Codable {
    let timestamp: String
    let sessionID: String
    let event: String
    let generation: UInt64?
    let fields: [String: String]
}

struct NullAudioDebugLogger: AudioDebugLogging {
    func log(_ event: String, generation: AudioGeneration?, fields: [String: String]) async {}
}
