import CryptoKit
import Darwin
import Foundation

enum M1ConvolutionIRError: Error, Equatable, Sendable {
    case fileTooLarge
    case invalidWAV
    case unsupportedEncoding
    case invalidMetadata
    case emptyAudio
    case durationExceeded
    case invalidSample
    case storageAlreadyExists
    case missingResource
    case hashMismatch
    case metadataMismatch
    case resourceIO
}

struct M1LoadedConvolutionIR: Equatable, Sendable {
    let source: M1ConvolutionIRReference
    let targetSampleRate: Double
    let channels: [[Float]]
}

protocol M1ConvolutionIRLoading: Sendable {
    func validate(reference: M1ConvolutionIRReference) throws
    func load(
        reference: M1ConvolutionIRReference,
        targetSampleRate: Double
    ) throws -> M1LoadedConvolutionIR
}

extension M1ConvolutionIRLoading {
    func validate(reference: M1ConvolutionIRReference) throws {
        _ = try load(reference: reference, targetSampleRate: reference.sampleRate)
    }
}

struct M1ConvolutionIRStore: M1ConvolutionIRLoading, Sendable {
    static let maximumFileSize = 32 * 1024 * 1024
    static let maximumDurationSeconds = 2.0
    static let minimumSampleRate = 8_000.0
    static let maximumSampleRate = 768_000.0

    let directoryURL: URL

    init(directoryURL: URL = Self.productionDirectoryURL) {
        self.directoryURL = directoryURL
    }

    static var productionDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/EqualizerAU/IRs", isDirectory: true)
    }

    func importWAV(at sourceURL: URL, storageID: UUID = UUID()) throws -> M1ConvolutionIRReference {
        try Task.checkCancellation()
        let data: Data
        do {
            data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        } catch {
            throw M1ConvolutionIRError.resourceIO
        }
        guard data.count <= Self.maximumFileSize else { throw M1ConvolutionIRError.fileTooLarge }
        let decoded = try M1WAVDecoder.decode(data)
        try Task.checkCancellation()

        let reference = M1ConvolutionIRReference(
            storageID: storageID,
            originalFileName: sourceURL.lastPathComponent,
            sha256: Self.sha256(data),
            sampleRate: decoded.sampleRate,
            channelCount: decoded.channels.count,
            frameCount: decoded.channels[0].count
        )
        do {
            var isDirectory = ObjCBool(false)
            if FileManager.default.fileExists(
                atPath: directoryURL.path,
                isDirectory: &isDirectory
            ) {
                guard isDirectory.boolValue else { throw M1ConvolutionIRError.resourceIO }
            } else {
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: false
                )
            }
            try synchronizeDirectory(at: directoryURL.deletingLastPathComponent())
        } catch {
            throw M1ConvolutionIRError.resourceIO
        }
        let destination = resourceURL(storageID: storageID)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw M1ConvolutionIRError.storageAlreadyExists
        }
        let temporary = directoryURL.appendingPathComponent(".\(storageID.uuidString).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
            try synchronizeFile(at: temporary)
        } catch {
            throw M1ConvolutionIRError.resourceIO
        }
        try Task.checkCancellation()
        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            if FileManager.default.fileExists(atPath: destination.path) {
                throw M1ConvolutionIRError.storageAlreadyExists
            }
            throw M1ConvolutionIRError.resourceIO
        }
        try synchronizeDirectory(at: directoryURL)
        return reference
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
        let url = resourceURL(storageID: reference.storageID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw M1ConvolutionIRError.missingResource
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw M1ConvolutionIRError.resourceIO
        }
        guard data.count <= Self.maximumFileSize else { throw M1ConvolutionIRError.fileTooLarge }
        try Task.checkCancellation()
        guard Self.sha256(data) == reference.sha256 else { throw M1ConvolutionIRError.hashMismatch }
        try Task.checkCancellation()
        let decoded = try M1WAVDecoder.decode(data)
        guard decoded.sampleRate == reference.sampleRate,
              decoded.channels.count == reference.channelCount,
              decoded.channels.first?.count == reference.frameCount
        else {
            throw M1ConvolutionIRError.metadataMismatch
        }
        let channels = try decoded.sampleRate == targetSampleRate
            ? decoded.channels
            : decoded.channels.map {
                try M1WindowedSincResampler.convert(
                    $0,
                    sourceRate: decoded.sampleRate,
                    targetRate: targetSampleRate
                )
            }
        guard let targetFrameCount = channels.first?.count, targetFrameCount > 0 else {
            throw M1ConvolutionIRError.emptyAudio
        }
        guard targetFrameCount <= Int(targetSampleRate * Self.maximumDurationSeconds) else {
            throw M1ConvolutionIRError.durationExceeded
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
            targetSampleRate: targetSampleRate,
            channels: channels
        )
    }

    private func resourceURL(storageID: UUID) -> URL {
        directoryURL.appendingPathComponent("\(storageID.uuidString).wav", isDirectory: false)
    }

    private func synchronizeFile(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw M1ConvolutionIRError.resourceIO }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw M1ConvolutionIRError.resourceIO }
    }

    private func synchronizeDirectory(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw M1ConvolutionIRError.resourceIO }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw M1ConvolutionIRError.resourceIO }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
        guard Double(frameCount) / Double(format.sampleRate) <= M1ConvolutionIRStore.maximumDurationSeconds else {
            throw M1ConvolutionIRError.durationExceeded
        }

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

private enum M1WindowedSincResampler {
    private static let radius = 16

    static func convert(_ source: [Float], sourceRate: Double, targetRate: Double) throws -> [Float] {
        let outputCount = max(
            1,
            min(
                Int((Double(source.count) * targetRate / sourceRate).rounded()),
                Int(targetRate * M1ConvolutionIRStore.maximumDurationSeconds)
            )
        )
        let cutoff = min(1, targetRate / sourceRate)
        let impulseResponseGain = sourceRate / targetRate
        let sourceRadius = Int(ceil(Double(radius) / cutoff))
        var output = Array(repeating: Float.zero, count: outputCount)
        for outputIndex in output.indices {
            if outputIndex.isMultiple(of: 64) { try Task.checkCancellation() }
            let position = Double(outputIndex) * sourceRate / targetRate
            let center = Int(floor(position))
            var value = 0.0
            let lowerBound = max(source.startIndex, center - sourceRadius + 1)
            let upperBound = min(source.endIndex - 1, center + sourceRadius)
            guard lowerBound <= upperBound else { continue }
            for sourceIndex in lowerBound...upperBound {
                let distance = position - Double(sourceIndex)
                let normalized = distance * cutoff / Double(radius)
                let window = 0.5 + 0.5 * cos(Double.pi * normalized)
                let argument = Double.pi * distance * cutoff
                let sinc = argument == 0 ? 1 : sin(argument) / argument
                let weight = cutoff * sinc * window
                value += Double(source[sourceIndex]) * weight
            }
            output[outputIndex] = Float(value * impulseResponseGain)
        }
        return output
    }
}
