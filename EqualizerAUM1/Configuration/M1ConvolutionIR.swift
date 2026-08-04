import Darwin
import Foundation

enum M1ConvolutionIRError: Error, Equatable, Sendable {
    case invalidWAV
    case unsupportedEncoding
    case invalidMetadata
    case sampleRateMismatch(source: Double, target: Double)
    case emptyAudio
    case invalidSample
    case missingResource
    case resourceIO
}

struct M1LoadedConvolutionIR: Equatable, Sendable {
    let source: M1ConvolutionIRReference
    let sourceSampleRate: Double
    let sourceChannelCount: Int
    let sourceFrameCount: Int
    let targetSampleRate: Double
    let channels: [[Float]]
}

protocol M1ConvolutionIRLoading: Sendable {
    func load(
        reference: M1ConvolutionIRReference,
        targetSampleRate: Double
    ) throws -> M1LoadedConvolutionIR
}

struct M1ConvolutionIRStore: M1ConvolutionIRLoading, Sendable {
    static let minimumSampleRate = 8_000.0
    static let maximumSampleRate = 768_000.0
    /// Source duration above which the UI shows a non-blocking performance hint.
    /// 2026-08-04: raised from 8 s after ADR-0019 / M11 Release probes on M1.
    /// Dense ~9 s (432k) × 8 ch stayed under ~33% of a 5.33 ms deadline; 8 s was the
    /// old 2 s product limit ×4, not a measured risk line. 30 s keeps common long IRs
    /// quiet while still flagging multi-minute / multi-million-tap sources.
    static let performanceWarningDurationSeconds = 30.0

    let directoryURL: URL

    init(directoryURL: URL = Self.productionDirectoryURL) {
        self.directoryURL = directoryURL
    }

    static var productionDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/EqualizerAU/IRs", isDirectory: true)
    }

    static func reference(sourceURL: URL) -> M1ConvolutionIRReference {
        M1ConvolutionIRReference(sourcePath: sourceURL.standardizedFileURL.path)
    }

    static func legacyReference(storageID: UUID) -> M1ConvolutionIRReference {
        reference(
            sourceURL: productionDirectoryURL
                .appendingPathComponent("\(storageID.uuidString).wav", isDirectory: false)
        )
    }

    func load(
        reference: M1ConvolutionIRReference,
        targetSampleRate: Double
    ) throws -> M1LoadedConvolutionIR {
        guard targetSampleRate.isFinite,
              targetSampleRate >= Self.minimumSampleRate,
              targetSampleRate <= Self.maximumSampleRate
        else {
            throw M1ConvolutionIRError.invalidMetadata
        }
        let url = URL(fileURLWithPath: reference.sourcePath)
        let data = try readData(at: url)
        let decoded = try M1WAVDecoder.decode(data)
        guard abs(decoded.sampleRate - targetSampleRate) <= 1 else {
            throw M1ConvolutionIRError.sampleRateMismatch(
                source: decoded.sampleRate,
                target: targetSampleRate
            )
        }
        let channels = decoded.channels
        guard let targetFrameCount = channels.first?.count, targetFrameCount > 0 else {
            throw M1ConvolutionIRError.emptyAudio
        }
        for channel in channels {
            guard channel.count == targetFrameCount else { throw M1ConvolutionIRError.invalidSample }
            for (index, sample) in channel.enumerated() {
                if index.isMultiple(of: 4_096) { try Task.checkCancellation() }
                guard sample == 0 || (sample.isFinite && sample.isNormal) else {
                    throw M1ConvolutionIRError.invalidSample
                }
            }
        }
        return M1LoadedConvolutionIR(
            source: reference,
            sourceSampleRate: decoded.sampleRate,
            sourceChannelCount: decoded.channels.count,
            sourceFrameCount: decoded.channels[0].count,
            targetSampleRate: targetSampleRate,
            channels: channels
        )
    }
    private func readData(at url: URL) throws -> Data {
        try Task.checkCancellation()
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            let openError = errno
            try Task.checkCancellation()
            if openError == ENOENT || openError == ENOTDIR {
                throw M1ConvolutionIRError.missingResource
            }
            throw M1ConvolutionIRError.resourceIO
        }
        defer { close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            try Task.checkCancellation()
            throw M1ConvolutionIRError.resourceIO
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            try Task.checkCancellation()
            throw M1ConvolutionIRError.resourceIO
        }
        guard status.st_size >= 0, let fileSize = Int(exactly: status.st_size) else {
            throw M1ConvolutionIRError.resourceIO
        }
        guard fileSize >= 12 else { throw M1ConvolutionIRError.invalidWAV }
        var header = [UInt8](repeating: 0, count: 12)
        var headerOffset = 0
        while headerOffset < header.count {
            try Task.checkCancellation()
            let requestedCount = header.count - headerOffset
            let count = header.withUnsafeMutableBytes { bytes in
                pread(
                    descriptor,
                    bytes.baseAddress!.advanced(by: headerOffset),
                    requestedCount,
                    off_t(headerOffset)
                )
            }
            if count == 0 { throw M1ConvolutionIRError.resourceIO }
            if count < 0 {
                if errno == EINTR { continue }
                throw M1ConvolutionIRError.resourceIO
            }
            headerOffset += count
        }
        let riffSize = Int(UInt32(header[4])
            | (UInt32(header[5]) << 8)
            | (UInt32(header[6]) << 16)
            | (UInt32(header[7]) << 24))
        guard header[0..<4].elementsEqual("RIFF".utf8),
              header[8..<12].elementsEqual("WAVE".utf8),
              riffSize + 8 == fileSize
        else {
            throw M1ConvolutionIRError.invalidWAV
        }

        var data = Data()
        if fileSize <= 64 * 1024 * 1024 {
            data.reserveCapacity(fileSize)
        }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < fileSize {
            try Task.checkCancellation()
            let requestedCount = min(buffer.count, fileSize - data.count)
            let count = read(descriptor, &buffer, requestedCount)
            if count == 0 { throw M1ConvolutionIRError.resourceIO }
            if count < 0 {
                if errno == EINTR { continue }
                try Task.checkCancellation()
                throw M1ConvolutionIRError.resourceIO
            }
            guard count <= Int.max - data.count else {
                throw M1ConvolutionIRError.resourceIO
            }
            data.append(buffer, count: count)
        }
        var finalStatus = stat()
        guard fstat(descriptor, &finalStatus) == 0,
              finalStatus.st_size == status.st_size,
              finalStatus.st_mtimespec.tv_sec == status.st_mtimespec.tv_sec,
              finalStatus.st_mtimespec.tv_nsec == status.st_mtimespec.tv_nsec,
              finalStatus.st_ctimespec.tv_sec == status.st_ctimespec.tv_sec,
              finalStatus.st_ctimespec.tv_nsec == status.st_ctimespec.tv_nsec
        else {
            throw M1ConvolutionIRError.resourceIO
        }
        try Task.checkCancellation()
        return data
    }
}

private struct M1DecodedWAV {
    let sampleRate: Double
    let channels: [[Float]]
}

private enum M1WAVDecoder {
    static func decode(_ data: Data) throws -> M1DecodedWAV {
        guard data.count >= 12,
              data[0..<4].elementsEqual("RIFF".utf8),
              data[8..<12].elementsEqual("WAVE".utf8),
              Int(readUInt32(data, 4)) + 8 == data.count
        else {
            throw M1ConvolutionIRError.invalidWAV
        }

        var format: (encoding: UInt16, channels: Int, sampleRate: Int, blockAlign: Int, bits: Int)?
        var audioRange: Range<Int>?
        var offset = 12
        while offset < data.count {
            guard offset + 8 <= data.count else { throw M1ConvolutionIRError.invalidWAV }
            let size = Int(readUInt32(data, offset + 4))
            let payloadStart = offset + 8
            guard size >= 0, payloadStart <= data.count, size <= data.count - payloadStart else {
                throw M1ConvolutionIRError.invalidWAV
            }
            let payload = payloadStart..<(payloadStart + size)
            let identifier = data[offset..<(offset + 4)]
            if identifier.elementsEqual("fmt ".utf8) {
                guard format == nil else { throw M1ConvolutionIRError.invalidWAV }
                format = try parseFormat(data, payload)
            } else if identifier.elementsEqual("data".utf8) {
                guard audioRange == nil else { throw M1ConvolutionIRError.invalidWAV }
                audioRange = payload
            }
            let paddedSize = size + (size & 1)
            guard paddedSize <= data.count - payloadStart else { throw M1ConvolutionIRError.invalidWAV }
            offset = payloadStart + paddedSize
        }
        guard offset == data.count, let format, let audioRange else {
            throw M1ConvolutionIRError.invalidWAV
        }
        guard !audioRange.isEmpty else { throw M1ConvolutionIRError.emptyAudio }
        guard audioRange.count % format.blockAlign == 0 else { throw M1ConvolutionIRError.invalidWAV }
        let frameCount = audioRange.count / format.blockAlign
        guard frameCount > 0 else { throw M1ConvolutionIRError.emptyAudio }

        let bytesPerSample = format.bits / 8
        var channels = Array(repeating: [Float](), count: format.channels)
        for index in channels.indices { channels[index].reserveCapacity(frameCount) }
        for frame in 0..<frameCount {
            if frame.isMultiple(of: 4_096) { try Task.checkCancellation() }
            let frameOffset = audioRange.lowerBound + frame * format.blockAlign
            for channel in 0..<format.channels {
                let sampleOffset = frameOffset + channel * bytesPerSample
                let sample = try decodeSample(
                    data,
                    offset: sampleOffset,
                    encoding: format.encoding,
                    bits: format.bits
                )
                guard sample.isFinite, sample == 0 || sample.isNormal else {
                    throw M1ConvolutionIRError.invalidSample
                }
                channels[channel].append(sample)
            }
        }
        return M1DecodedWAV(sampleRate: Double(format.sampleRate), channels: channels)
    }

    private static func parseFormat(
        _ data: Data,
        _ range: Range<Int>
    ) throws -> (encoding: UInt16, channels: Int, sampleRate: Int, blockAlign: Int, bits: Int) {
        guard range.count >= 16 else { throw M1ConvolutionIRError.invalidWAV }
        var encoding = readUInt16(data, range.lowerBound)
        let channels = Int(readUInt16(data, range.lowerBound + 2))
        let sampleRate = Int(readUInt32(data, range.lowerBound + 4))
        let byteRate = Int(readUInt32(data, range.lowerBound + 8))
        let blockAlign = Int(readUInt16(data, range.lowerBound + 12))
        let bits = Int(readUInt16(data, range.lowerBound + 14))
        if encoding == 0xFFFE {
            guard range.count >= 40,
                  readUInt16(data, range.lowerBound + 16) >= 22,
                  Int(readUInt16(data, range.lowerBound + 18)) == bits
            else {
                throw M1ConvolutionIRError.invalidWAV
            }
            let subformat = range.lowerBound + 24
            let suffix: [UInt8] = [0, 0, 0x10, 0, 0x80, 0, 0, 0xAA, 0, 0x38, 0x9B, 0x71]
            guard Array(data[(subformat + 4)..<(subformat + 16)]) == suffix else {
                throw M1ConvolutionIRError.unsupportedEncoding
            }
            let subformatEncoding = readUInt32(data, subformat)
            guard subformatEncoding == 1 || subformatEncoding == 3 else {
                throw M1ConvolutionIRError.unsupportedEncoding
            }
            encoding = UInt16(subformatEncoding)
        }
        guard (encoding == 1 && [8, 16, 24, 32].contains(bits)) || (encoding == 3 && bits == 32) else {
            throw M1ConvolutionIRError.unsupportedEncoding
        }
        guard (1...64).contains(channels),
              Double(sampleRate) >= M1ConvolutionIRStore.minimumSampleRate,
              Double(sampleRate) <= M1ConvolutionIRStore.maximumSampleRate,
              bits % 8 == 0
        else {
            throw M1ConvolutionIRError.invalidMetadata
        }
        let expectedBlockAlign = channels * (bits / 8)
        guard blockAlign == expectedBlockAlign,
              byteRate == sampleRate * expectedBlockAlign
        else {
            throw M1ConvolutionIRError.invalidWAV
        }
        return (encoding, channels, sampleRate, blockAlign, bits)
    }

    private static func decodeSample(
        _ data: Data,
        offset: Int,
        encoding: UInt16,
        bits: Int
    ) throws -> Float {
        if encoding == 3 {
            return Float(bitPattern: readUInt32(data, offset))
        }
        switch bits {
        case 8:
            return (Float(data[offset]) - 128) / 128
        case 16:
            return Float(Int16(bitPattern: readUInt16(data, offset))) / 32_768
        case 24:
            var value = Int32(data[offset])
                | (Int32(data[offset + 1]) << 8)
                | (Int32(data[offset + 2]) << 16)
            if value & 0x0080_0000 != 0 { value |= ~0x00FF_FFFF }
            return Float(value) / 8_388_608
        case 32:
            return Float(Int32(bitPattern: readUInt32(data, offset))) / 2_147_483_648
        default:
            throw M1ConvolutionIRError.unsupportedEncoding
        }
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
