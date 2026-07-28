import AudioToolbox
import CoreAudio
import Foundation

struct M1CoreAudioStatusError: Error, Equatable, Sendable {
    let operation: String
    let status: OSStatus
}

private struct M1HALPropertyAddress {
    let selector: AudioObjectPropertySelector
    let scope: AudioObjectPropertyScope

    init(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) {
        self.selector = selector
        self.scope = scope
    }

    var rawValue: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

private struct M1HALPropertyReader {
    func value<T: BitwiseCopyable>(
        objectID: AudioObjectID,
        address: M1HALPropertyAddress,
        initialValue: T,
        operation: String
    ) throws -> T {
        var address = address.rawValue
        var value = initialValue
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr, size == MemoryLayout<T>.size else {
            throw M1CoreAudioStatusError(
                operation: operation,
                status: status == noErr ? kAudio_ParamError : status
            )
        }
        return value
    }

    func qualifiedValue<Q: BitwiseCopyable, T: BitwiseCopyable>(
        objectID: AudioObjectID,
        address: M1HALPropertyAddress,
        qualifier: Q,
        initialValue: T,
        operation: String
    ) throws -> T {
        var address = address.rawValue
        var qualifier = qualifier
        var value = initialValue
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafePointer(to: &qualifier) { qualifierPointer in
            AudioObjectGetPropertyData(
                objectID,
                &address,
                UInt32(MemoryLayout<Q>.size),
                qualifierPointer,
                &size,
                &value
            )
        }
        guard status == noErr, size == MemoryLayout<T>.size else {
            throw M1CoreAudioStatusError(
                operation: operation,
                status: status == noErr ? kAudio_ParamError : status
            )
        }
        return value
    }

    func data(
        objectID: AudioObjectID,
        address: M1HALPropertyAddress,
        operation: String,
        allowEmpty: Bool = false
    ) throws -> Data {
        var address = address.rawValue
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
        guard status == noErr, allowEmpty || size > 0 else {
            throw M1CoreAudioStatusError(
                operation: operation,
                status: status == noErr ? kAudio_ParamError : status
            )
        }
        if size == 0 { return Data() }

        var result = Data(count: Int(size))
        status = result.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, bytes.baseAddress!)
        }
        guard status == noErr, size <= result.count else {
            throw M1CoreAudioStatusError(
                operation: operation,
                status: status == noErr ? kAudio_ParamError : status
            )
        }
        result.count = Int(size)
        return result
    }

    func string(
        objectID: AudioObjectID,
        address: M1HALPropertyAddress,
        operation: String
    ) throws -> String {
        let value: Unmanaged<CFString>? = try value(
            objectID: objectID,
            address: address,
            initialValue: nil,
            operation: operation
        )
        guard let value else {
            throw M1CoreAudioStatusError(operation: operation, status: kAudio_ParamError)
        }
        return value.takeRetainedValue() as String
    }

    func stringArray(
        objectID: AudioObjectID,
        address: M1HALPropertyAddress,
        operation: String
    ) throws -> [String] {
        let value: Unmanaged<CFArray>? = try value(
            objectID: objectID,
            address: address,
            initialValue: nil,
            operation: operation
        )
        guard let value else {
            throw M1CoreAudioStatusError(operation: operation, status: kAudio_ParamError)
        }
        let array = value.takeRetainedValue() as [AnyObject]
        let strings = array.compactMap { $0 as? String }
        guard strings.count == array.count else {
            throw M1CoreAudioStatusError(operation: operation, status: kAudio_ParamError)
        }
        return strings
    }

    func hasProperty(objectID: AudioObjectID, address: M1HALPropertyAddress) -> Bool {
        var address = address.rawValue
        return AudioObjectHasProperty(objectID, &address)
    }
}

enum M1CoreAudioDataParser {
    static func bufferChannelCounts(_ data: Data) throws -> [Int] {
        guard let firstBufferOffset = MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers),
              data.count >= firstBufferOffset
        else {
            throw M1CoreAudioStatusError(operation: "Parse AudioBufferList", status: kAudio_ParamError)
        }
        return try data.withUnsafeBytes { bytes in
            let count = Int(bytes.loadUnaligned(as: UInt32.self))
            let (size, overflow) = count.multipliedReportingOverflow(by: MemoryLayout<AudioBuffer>.stride)
            guard !overflow, size <= bytes.count - firstBufferOffset else {
                throw M1CoreAudioStatusError(operation: "Parse AudioBufferList", status: kAudio_ParamError)
            }
            return (0..<count).map { index in
                Int(bytes.loadUnaligned(
                    fromByteOffset: firstBufferOffset + index * MemoryLayout<AudioBuffer>.stride,
                    as: AudioBuffer.self
                ).mNumberChannels)
            }
        }
    }

    static func semanticPositions(_ data: Data, expectedCount: Int) throws -> [M1SpeakerPosition?] {
        let labels = try channelLabels(data)
        guard labels.count == expectedCount else {
            throw M1CoreAudioStatusError(operation: "Validate channel layout count", status: kAudio_ParamError)
        }
        return labels.map(speakerPosition)
    }

    static func applyingPreferredStereoChannels(
        _ data: Data,
        to positions: [M1SpeakerPosition?]
    ) throws -> [M1SpeakerPosition?] {
        guard data.count == 2 * MemoryLayout<UInt32>.stride else {
            throw M1CoreAudioStatusError(operation: "Parse preferred stereo channels", status: kAudio_ParamError)
        }
        let channels = data.withUnsafeBytes { bytes in
            [
                bytes.loadUnaligned(as: UInt32.self),
                bytes.loadUnaligned(fromByteOffset: MemoryLayout<UInt32>.stride, as: UInt32.self),
            ]
        }
        guard channels[0] > 0,
              channels[1] > 0,
              channels[0] != channels[1],
              channels.allSatisfy({ Int($0) <= positions.count })
        else {
            throw M1CoreAudioStatusError(operation: "Validate preferred stereo channels", status: kAudio_ParamError)
        }

        var result = positions
        let stereoPositions: [M1SpeakerPosition] = [.left, .right]
        for (channel, position) in zip(channels, stereoPositions) {
            let index = Int(channel - 1)
            if result[index] == nil { result[index] = position }
        }
        return result
    }

    private static func channelLabels(_ data: Data) throws -> [AudioChannelLabel] {
        guard let descriptionsOffset = MemoryLayout<AudioChannelLayout>.offset(of: \AudioChannelLayout.mChannelDescriptions),
              data.count >= descriptionsOffset
        else {
            throw M1CoreAudioStatusError(operation: "Parse AudioChannelLayout", status: kAudio_ParamError)
        }
        guard let tagOffset = MemoryLayout<AudioChannelLayout>.offset(of: \AudioChannelLayout.mChannelLayoutTag),
              let bitmapOffset = MemoryLayout<AudioChannelLayout>.offset(of: \AudioChannelLayout.mChannelBitmap)
        else {
            throw M1CoreAudioStatusError(operation: "Parse AudioChannelLayout offsets", status: kAudio_ParamError)
        }
        let (tag, bitmap) = data.withUnsafeBytes { bytes in
            (
                bytes.loadUnaligned(fromByteOffset: tagOffset, as: AudioChannelLayoutTag.self),
                bytes.loadUnaligned(fromByteOffset: bitmapOffset, as: AudioChannelBitmap.self)
            )
        }
        if tag != kAudioChannelLayoutTag_UseChannelDescriptions {
            var property: AudioFormatPropertyID
            var specifier: UInt32
            if tag == kAudioChannelLayoutTag_UseChannelBitmap {
                property = kAudioFormatProperty_ChannelLayoutForBitmap
                specifier = bitmap.rawValue
            } else {
                property = kAudioFormatProperty_ChannelLayoutForTag
                specifier = UInt32(tag)
            }
            var expandedSize: UInt32 = 0
            var status = AudioFormatGetPropertyInfo(
                property,
                UInt32(MemoryLayout<UInt32>.size),
                &specifier,
                &expandedSize
            )
            guard status == noErr, expandedSize > 0 else {
                throw M1CoreAudioStatusError(operation: "Expand channel layout tag", status: status)
            }
            var expanded = Data(count: Int(expandedSize))
            status = expanded.withUnsafeMutableBytes { bytes in
                AudioFormatGetProperty(
                    property,
                    UInt32(MemoryLayout<UInt32>.size),
                    &specifier,
                    &expandedSize,
                    bytes.baseAddress!
                )
            }
            guard status == noErr else {
                throw M1CoreAudioStatusError(operation: "Expand channel layout tag", status: status)
            }
            expanded.count = Int(expandedSize)
            return try descriptionLabels(expanded)
        }

        return try descriptionLabels(data)
    }

    private static func descriptionLabels(_ data: Data) throws -> [AudioChannelLabel] {
        guard let descriptionsOffset = MemoryLayout<AudioChannelLayout>.offset(of: \AudioChannelLayout.mChannelDescriptions),
              let countOffset = MemoryLayout<AudioChannelLayout>.offset(of: \AudioChannelLayout.mNumberChannelDescriptions),
              data.count >= descriptionsOffset
        else {
            throw M1CoreAudioStatusError(operation: "Parse channel descriptions", status: kAudio_ParamError)
        }
        let descriptionCount = data.withUnsafeBytes { bytes in
            bytes.loadUnaligned(fromByteOffset: countOffset, as: UInt32.self)
        }
        let count = Int(descriptionCount)
        let (descriptionsSize, overflow) = count.multipliedReportingOverflow(
            by: MemoryLayout<AudioChannelDescription>.stride
        )
        guard !overflow, descriptionsSize <= data.count - descriptionsOffset else {
            throw M1CoreAudioStatusError(operation: "Parse channel descriptions", status: kAudio_ParamError)
        }
        return data.withUnsafeBytes { bytes in
            (0..<count).map { index in
                bytes.loadUnaligned(
                    fromByteOffset: descriptionsOffset + index * MemoryLayout<AudioChannelDescription>.stride,
                    as: AudioChannelDescription.self
                ).mChannelLabel
            }
        }
    }

    private static func speakerPosition(_ label: AudioChannelLabel) -> M1SpeakerPosition? {
        switch label {
        case kAudioChannelLabel_Left: M1SpeakerPosition(rawValue: "L")
        case kAudioChannelLabel_Right: M1SpeakerPosition(rawValue: "R")
        case kAudioChannelLabel_Center: M1SpeakerPosition(rawValue: "C")
        case kAudioChannelLabel_LFEScreen: M1SpeakerPosition(rawValue: "LFE")
        case kAudioChannelLabel_LeftSurround: M1SpeakerPosition(rawValue: "RL")
        case kAudioChannelLabel_RightSurround: M1SpeakerPosition(rawValue: "RR")
        case kAudioChannelLabel_CenterSurround: M1SpeakerPosition(rawValue: "RC")
        case kAudioChannelLabel_LeftSurroundDirect: M1SpeakerPosition(rawValue: "SL")
        case kAudioChannelLabel_RightSurroundDirect: M1SpeakerPosition(rawValue: "SR")
        default: nil
        }
    }
}

struct M1SystemHALRouteOperations: M1HALRouteOperations, @unchecked Sendable {
    private let reader = M1HALPropertyReader()
    private let processID: pid_t

    init(processID: pid_t = ProcessInfo.processInfo.processIdentifier) {
        self.processID = processID
    }

    func readDefaultOutputDevice() throws -> M1HALOutputDeviceData {
        let systemID = AudioObjectID(kAudioObjectSystemObject)
        let deviceID: AudioObjectID = try reader.value(
            objectID: systemID,
            address: M1HALPropertyAddress(kAudioHardwarePropertyDefaultOutputDevice),
            initialValue: kAudioObjectUnknown,
            operation: "Read default output device"
        )
        guard deviceID != kAudioObjectUnknown else { throw M1AudioRouteError.noOutputDevice }
        let uid = try reader.string(
            objectID: deviceID,
            address: M1HALPropertyAddress(kAudioDevicePropertyDeviceUID),
            operation: "Read output UID"
        )
        let name = try reader.string(
            objectID: deviceID,
            address: M1HALPropertyAddress(kAudioObjectPropertyName),
            operation: "Read output name"
        )
        let alive: UInt32 = try reader.value(
            objectID: deviceID,
            address: M1HALPropertyAddress(kAudioDevicePropertyDeviceIsAlive),
            initialValue: 0,
            operation: "Read output alive state"
        )
        let sampleRate: Double = try reader.value(
            objectID: deviceID,
            address: M1HALPropertyAddress(kAudioDevicePropertyNominalSampleRate),
            initialValue: 0,
            operation: "Read output sample rate"
        )
        let frameRange: AudioValueRange = try reader.value(
            objectID: deviceID,
            address: M1HALPropertyAddress(kAudioDevicePropertyBufferFrameSizeRange),
            initialValue: AudioValueRange(),
            operation: "Read output frame range"
        )
        guard frameRange.mMaximum.isFinite,
              frameRange.mMaximum > 0,
              frameRange.mMaximum <= Double(Int.max)
        else {
            throw M1AudioRouteError.invalidOutputDevice("invalid maximum frame count")
        }
        let topology = try M1CoreAudioDataParser.bufferChannelCounts(reader.data(
            objectID: deviceID,
            address: M1HALPropertyAddress(
                kAudioDevicePropertyStreamConfiguration,
                scope: kAudioObjectPropertyScopeOutput
            ),
            operation: "Read output topology"
        ))
        let channelCount = topology.reduce(0, +)
        guard channelCount > 0 else {
            throw M1AudioRouteError.invalidOutputDevice("output has no channels")
        }
        let layoutAddress = M1HALPropertyAddress(
            kAudioDevicePropertyPreferredChannelLayout,
            scope: kAudioObjectPropertyScopeOutput
        )
        var positions: [M1SpeakerPosition?]
        if reader.hasProperty(objectID: deviceID, address: layoutAddress) {
            positions = try M1CoreAudioDataParser.semanticPositions(
                reader.data(objectID: deviceID, address: layoutAddress, operation: "Read output channel layout"),
                expectedCount: channelCount
            )
        } else {
            positions = Array(repeating: nil, count: channelCount)
        }
        let stereoAddress = M1HALPropertyAddress(
            kAudioDevicePropertyPreferredChannelsForStereo,
            scope: kAudioObjectPropertyScopeOutput
        )
        if reader.hasProperty(objectID: deviceID, address: stereoAddress),
           let enriched = try? M1CoreAudioDataParser.applyingPreferredStereoChannels(
               reader.data(
                   objectID: deviceID,
                   address: stereoAddress,
                   operation: "Read preferred stereo channels"
               ),
               to: positions
           )
        {
            positions = enriched
        }
        return M1HALOutputDeviceData(
            objectID: deviceID,
            uid: uid,
            name: name,
            isAlive: alive != 0,
            sampleRate: sampleRate,
            maximumFrameCount: Int(frameRange.mMaximum.rounded(.up)),
            bufferChannelCounts: topology,
            semanticPositions: positions
        )
    }

    func readCurrentProcessObjectID() throws -> UInt32 {
        let result: AudioObjectID = try reader.qualifiedValue(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: M1HALPropertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject),
            qualifier: processID,
            initialValue: kAudioObjectUnknown,
            operation: "Translate process ID"
        )
        guard result != kAudioObjectUnknown else {
            throw M1AudioRouteError.invalidTap("current process object is unavailable")
        }
        return result
    }

    func createProcessTap(_ request: M1ProcessTapRequest) throws -> UInt32 {
        guard request.isPrivate, !request.outputDeviceUID.isEmpty else {
            throw M1AudioRouteError.invalidTap("process tap contract is incomplete")
        }
        let description = CATapDescription(
            excludingProcesses: [request.excludedProcessObjectID],
            deviceUID: request.outputDeviceUID,
            stream: UInt(request.outputStreamIndex)
        )
        description.name = request.name
        description.isPrivate = true
        description.muteBehavior = request.isMuted ? .muted : .unmuted
        var objectID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &objectID)
        if status == kAudioDevicePermissionsError {
            throw M1AudioRouteError.audioCapturePermissionDenied
        }
        guard status == noErr, objectID != kAudioObjectUnknown else {
            throw M1CoreAudioStatusError(
                operation: "AudioHardwareCreateProcessTap",
                status: status == noErr ? kAudioHardwareBadObjectError : status
            )
        }
        return objectID
    }

    func probeAndMuteProcessTap(_ objectID: UInt32) throws {
        let description = try probeProcessTapDescription(objectID)
        description.muteBehavior = .muted
        try writeProcessTapDescription(
            description,
            objectID: objectID,
            operation: "Mute process tap"
        )
    }

    func verifyProcessTapCapturePermission(_ objectID: UInt32) throws {
        _ = try probeProcessTapDescription(objectID)
    }

    private func probeProcessTapDescription(_ objectID: UInt32) throws -> CATapDescription {
        let description = try readProcessTapDescription(objectID)
        try writeProcessTapDescription(
            description,
            objectID: objectID,
            operation: "Probe process tap capture permission"
        )
        return description
    }

    private func readProcessTapDescription(_ objectID: UInt32) throws -> CATapDescription {
        do {
            let retained: Unmanaged<CATapDescription>? = try reader.value(
                objectID: objectID,
                address: M1HALPropertyAddress(kAudioTapPropertyDescription),
                initialValue: nil,
                operation: "Read process tap description"
            )
            guard let retained else {
                throw M1CoreAudioStatusError(
                    operation: "Read process tap description",
                    status: kAudio_ParamError
                )
            }
            return retained.takeRetainedValue()
        } catch let error as M1CoreAudioStatusError {
            if error.status == kAudioDevicePermissionsError {
                throw M1AudioRouteError.audioCapturePermissionDenied
            }
            throw error
        }
    }

    private func writeProcessTapDescription(
        _ value: CATapDescription,
        objectID: UInt32,
        operation: String
    ) throws {
        var address = M1HALPropertyAddress(kAudioTapPropertyDescription).rawValue
        var value = value
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectSetPropertyData(
                objectID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<CATapDescription>.stride),
                pointer
            )
        }
        if status == kAudioDevicePermissionsError {
            throw M1AudioRouteError.audioCapturePermissionDenied
        }
        guard status == noErr else {
            throw M1CoreAudioStatusError(operation: operation, status: status)
        }
    }

    func readProcessTap(_ objectID: UInt32) throws -> M1HALTapData {
        let uid = try readProcessTapUID(objectID)
        let format: AudioStreamBasicDescription = try reader.value(
            objectID: objectID,
            address: M1HALPropertyAddress(kAudioTapPropertyFormat),
            initialValue: AudioStreamBasicDescription(),
            operation: "Read tap format"
        )
        return M1HALTapData(uid: uid, format: pcmFormat(format))
    }

    func readProcessTapUID(_ objectID: UInt32) throws -> String {
        try reader.string(
            objectID: objectID,
            address: M1HALPropertyAddress(kAudioTapPropertyUID),
            operation: "Read tap UID"
        )
    }

    func destroyProcessTap(_ objectID: UInt32) throws {
        let status = AudioHardwareDestroyProcessTap(objectID)
        guard status == noErr else {
            throw M1CoreAudioStatusError(operation: "AudioHardwareDestroyProcessTap", status: status)
        }
    }

    func createAggregateDevice(_ request: M1AggregateRequest) throws -> UInt32 {
        guard request.isPrivate, !request.isStacked, !request.tapAutoStart,
              request.tapDriftCompensation, !request.tapUID.isEmpty
        else {
            throw M1AudioRouteError.invalidAggregate("aggregate contract is incomplete")
        }
        let subTap: [String: Any] = [
            kAudioSubTapUIDKey: request.tapUID,
            kAudioSubTapDriftCompensationKey: true,
        ]
        let description: CFDictionary = [
            kAudioAggregateDeviceUIDKey: request.uid,
            kAudioAggregateDeviceNameKey: request.name,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapListKey: [subTap],
            kAudioAggregateDeviceTapAutoStartKey: false,
        ] as CFDictionary
        var objectID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description, &objectID)
        guard status == noErr, objectID != kAudioObjectUnknown else {
            throw M1CoreAudioStatusError(
                operation: "AudioHardwareCreateAggregateDevice",
                status: status == noErr ? kAudioHardwareBadObjectError : status
            )
        }
        return objectID
    }

    func readAggregateDevice(_ objectID: UInt32) throws -> M1HALAggregateData {
        let uid = try readAggregateDeviceUID(objectID)
        let tapUIDs = try reader.stringArray(
            objectID: objectID,
            address: M1HALPropertyAddress(kAudioAggregateDevicePropertyTapList),
            operation: "Read aggregate tap list"
        )
        let format: AudioStreamBasicDescription = try reader.value(
            objectID: objectID,
            address: M1HALPropertyAddress(
                kAudioDevicePropertyStreamFormat,
                scope: kAudioObjectPropertyScopeInput
            ),
            initialValue: AudioStreamBasicDescription(),
            operation: "Read aggregate input format"
        )
        let topology = try M1CoreAudioDataParser.bufferChannelCounts(reader.data(
            objectID: objectID,
            address: M1HALPropertyAddress(
                kAudioDevicePropertyStreamConfiguration,
                scope: kAudioObjectPropertyScopeInput
            ),
            operation: "Read aggregate input topology"
        ))
        let frameRange: AudioValueRange = try reader.value(
            objectID: objectID,
            address: M1HALPropertyAddress(kAudioDevicePropertyBufferFrameSizeRange),
            initialValue: AudioValueRange(),
            operation: "Read aggregate frame range"
        )
        guard frameRange.mMaximum.isFinite,
              frameRange.mMaximum > 0,
              frameRange.mMaximum <= Double(Int.max)
        else {
            throw M1AudioRouteError.invalidAggregate("invalid maximum frame count")
        }
        return M1HALAggregateData(
            uid: uid,
            tapUIDs: tapUIDs,
            format: pcmFormat(format),
            maximumFrameCount: Int(frameRange.mMaximum.rounded(.up)),
            bufferChannelCounts: topology
        )
    }

    func readAggregateDeviceUID(_ objectID: UInt32) throws -> String {
        try reader.string(
            objectID: objectID,
            address: M1HALPropertyAddress(kAudioDevicePropertyDeviceUID),
            operation: "Read aggregate UID"
        )
    }

    func destroyAggregateDevice(_ objectID: UInt32) throws {
        let status = AudioHardwareDestroyAggregateDevice(objectID)
        guard status == noErr else {
            throw M1CoreAudioStatusError(operation: "AudioHardwareDestroyAggregateDevice", status: status)
        }
    }

    private func pcmFormat(_ value: AudioStreamBasicDescription) -> M1HALPCMFormat {
        let nativeEndian: Bool
        #if _endian(little)
        nativeEndian = value.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
        #else
        nativeEndian = value.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        #endif
        return M1HALPCMFormat(
            sampleRate: value.mSampleRate,
            channelCount: value.mChannelsPerFrame,
            isNativeFloat32: value.mFormatID == kAudioFormatLinearPCM
                && value.mBitsPerChannel == 32
                && value.mFormatFlags & kAudioFormatFlagIsFloat != 0
                && nativeEndian,
            isPacked: value.mFormatFlags & kAudioFormatFlagIsPacked != 0,
            isNonInterleaved: value.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0,
            framesPerPacket: value.mFramesPerPacket,
            bytesPerFrame: value.mBytesPerFrame,
            bytesPerPacket: value.mBytesPerPacket
        )
    }
}
