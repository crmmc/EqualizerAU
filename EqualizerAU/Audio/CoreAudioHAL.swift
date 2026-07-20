import CoreAudio
import Foundation

struct HALPropertyAddress: Equatable, Sendable {
    let selector: AudioObjectPropertySelector
    let scope: AudioObjectPropertyScope
    let element: AudioObjectPropertyElement

    init(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) {
        self.selector = selector
        self.scope = scope
        self.element = element
    }

    var rawValue: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
    }

    var diagnosticDescription: String {
        "selector=\(fourCC(selector)), scope=\(fourCC(scope)), element=\(element)"
    }
}

struct HALStatusError: Error, Equatable, LocalizedError, Sendable {
    let operation: String
    let objectID: AudioObjectID
    let address: HALPropertyAddress
    let status: OSStatus

    var errorDescription: String? {
        "\(operation) failed for object \(objectID) "
            + "(\(address.diagnosticDescription)): OSStatus \(status) "
            + "(\(fourCC(UInt32(bitPattern: status))))"
    }
}

protocol HALPropertyOperations: Sendable {
    func propertyDataSize(
        objectID: AudioObjectID,
        address: HALPropertyAddress
    ) -> (status: OSStatus, size: UInt32)

    func propertyData(
        objectID: AudioObjectID,
        address: HALPropertyAddress,
        dataSize: inout UInt32,
        data: UnsafeMutableRawPointer
    ) -> OSStatus

    func qualifiedPropertyData(
        objectID: AudioObjectID,
        address: HALPropertyAddress,
        qualifierDataSize: UInt32,
        qualifierData: UnsafeRawPointer,
        dataSize: inout UInt32,
        data: UnsafeMutableRawPointer
    ) -> OSStatus

    func setPropertyData(
        objectID: AudioObjectID,
        address: HALPropertyAddress,
        dataSize: UInt32,
        data: UnsafeRawPointer
    ) -> OSStatus
}

extension HALPropertyOperations {
    func qualifiedPropertyData(
        objectID: AudioObjectID,
        address: HALPropertyAddress,
        qualifierDataSize: UInt32,
        qualifierData: UnsafeRawPointer,
        dataSize: inout UInt32,
        data: UnsafeMutableRawPointer
    ) -> OSStatus {
        kAudio_ParamError
    }

    func setPropertyData(
        objectID: AudioObjectID,
        address: HALPropertyAddress,
        dataSize: UInt32,
        data: UnsafeRawPointer
    ) -> OSStatus {
        kAudioHardwareUnsupportedOperationError
    }
}

struct SystemHALPropertyOperations: HALPropertyOperations {
    func propertyDataSize(
        objectID: AudioObjectID,
        address: HALPropertyAddress
    ) -> (status: OSStatus, size: UInt32) {
        var rawAddress = address.rawValue
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            objectID,
            &rawAddress,
            0,
            nil,
            &size
        )
        return (status, size)
    }

    func propertyData(
        objectID: AudioObjectID,
        address: HALPropertyAddress,
        dataSize: inout UInt32,
        data: UnsafeMutableRawPointer
    ) -> OSStatus {
        var rawAddress = address.rawValue
        return AudioObjectGetPropertyData(
            objectID,
            &rawAddress,
            0,
            nil,
            &dataSize,
            data
        )
    }

    func qualifiedPropertyData(
        objectID: AudioObjectID,
        address: HALPropertyAddress,
        qualifierDataSize: UInt32,
        qualifierData: UnsafeRawPointer,
        dataSize: inout UInt32,
        data: UnsafeMutableRawPointer
    ) -> OSStatus {
        var rawAddress = address.rawValue
        return AudioObjectGetPropertyData(
            objectID,
            &rawAddress,
            qualifierDataSize,
            qualifierData,
            &dataSize,
            data
        )
    }

    func setPropertyData(
        objectID: AudioObjectID,
        address: HALPropertyAddress,
        dataSize: UInt32,
        data: UnsafeRawPointer
    ) -> OSStatus {
        var rawAddress = address.rawValue
        return AudioObjectSetPropertyData(
            objectID,
            &rawAddress,
            0,
            nil,
            dataSize,
            data
        )
    }
}

struct HALPropertyReader: Sendable {
    private let operations: any HALPropertyOperations

    init(operations: any HALPropertyOperations = SystemHALPropertyOperations()) {
        self.operations = operations
    }

    func readValue<Value>(
        _ type: Value.Type = Value.self,
        objectID: AudioObjectID,
        address: HALPropertyAddress,
        operation: String,
        initialValue: Value
    ) throws -> Value {
        var value = initialValue
        var dataSize = UInt32(MemoryLayout<Value>.size)
        let status = withUnsafeMutablePointer(to: &value) { output in
            operations.propertyData(
                objectID: objectID,
                address: address,
                dataSize: &dataSize,
                data: output
            )
        }

        try validate(
            status: status,
            operation: operation,
            objectID: objectID,
            address: address
        )
        guard dataSize == MemoryLayout<Value>.size else {
            throw HALStatusError(
                operation: "\(operation): validate data size",
                objectID: objectID,
                address: address,
                status: kAudio_ParamError
            )
        }
        return value
    }

    func readRetainedString(
        objectID: AudioObjectID,
        address: HALPropertyAddress,
        operation: String
    ) throws -> String {
        let value: Unmanaged<CFString>? = try readValue(
            objectID: objectID,
            address: address,
            operation: operation,
            initialValue: nil
        )
        guard let value else {
            throw HALStatusError(
                operation: "\(operation): validate retained CFString",
                objectID: objectID,
                address: address,
                status: kAudio_ParamError
            )
        }
        return value.takeRetainedValue() as String
    }

    func readRetainedStringArray(
        objectID: AudioObjectID,
        address: HALPropertyAddress,
        operation: String
    ) throws -> [String] {
        let value: Unmanaged<CFArray>? = try readValue(
            objectID: objectID,
            address: address,
            operation: operation,
            initialValue: nil
        )
        guard let value else {
            throw HALStatusError(
                operation: "\(operation): validate retained CFArray",
                objectID: objectID,
                address: address,
                status: kAudio_ParamError
            )
        }
        let array = value.takeRetainedValue() as [AnyObject]
        let strings = array.compactMap { $0 as? String }
        guard strings.count == array.count else {
            throw HALStatusError(
                operation: "\(operation): validate CFString elements",
                objectID: objectID,
                address: address,
                status: kAudio_ParamError
            )
        }
        return strings
    }

    func readQualifiedValue<Qualifier, Value>(
        objectID: AudioObjectID,
        address: HALPropertyAddress,
        operation: String,
        qualifier: Qualifier,
        initialValue: Value
    ) throws -> Value {
        var qualifier = qualifier
        var value = initialValue
        var dataSize = UInt32(MemoryLayout<Value>.size)
        let status = withUnsafePointer(to: &qualifier) { qualifierPointer in
            withUnsafeMutablePointer(to: &value) { output in
                operations.qualifiedPropertyData(
                    objectID: objectID,
                    address: address,
                    qualifierDataSize: UInt32(MemoryLayout<Qualifier>.size),
                    qualifierData: qualifierPointer,
                    dataSize: &dataSize,
                    data: output
                )
            }
        }

        try validate(
            status: status,
            operation: operation,
            objectID: objectID,
            address: address
        )
        guard dataSize == MemoryLayout<Value>.size else {
            throw HALStatusError(
                operation: "\(operation): validate data size",
                objectID: objectID,
                address: address,
                status: kAudio_ParamError
            )
        }
        return value
    }

    func readData(
        objectID: AudioObjectID,
        address: HALPropertyAddress,
        operation: String,
        allowEmpty: Bool = false
    ) throws -> Data {
        let sizeResult = operations.propertyDataSize(objectID: objectID, address: address)
        try validate(
            status: sizeResult.status,
            operation: "\(operation): get data size",
            objectID: objectID,
            address: address
        )
        if allowEmpty, sizeResult.size == 0 {
            return Data()
        }
        guard sizeResult.size > 0 else {
            throw HALStatusError(
                operation: "\(operation): validate data size",
                objectID: objectID,
                address: address,
                status: kAudio_ParamError
            )
        }

        var data = Data(count: Int(sizeResult.size))
        var actualSize = sizeResult.size
        let status = data.withUnsafeMutableBytes { bytes in
            operations.propertyData(
                objectID: objectID,
                address: address,
                dataSize: &actualSize,
                data: bytes.baseAddress!
            )
        }
        try validate(
            status: status,
            operation: operation,
            objectID: objectID,
            address: address
        )
        guard actualSize <= sizeResult.size else {
            throw HALStatusError(
                operation: "\(operation): validate returned data size",
                objectID: objectID,
                address: address,
                status: kAudio_ParamError
            )
        }
        data.count = Int(actualSize)
        return data
    }

    private func validate(
        status: OSStatus,
        operation: String,
        objectID: AudioObjectID,
        address: HALPropertyAddress
    ) throws {
        guard status == noErr else {
            throw HALStatusError(
                operation: operation,
                objectID: objectID,
                address: address,
                status: status
            )
        }
    }
}

struct HALPropertyWriter: Sendable {
    private let operations: any HALPropertyOperations

    init(operations: any HALPropertyOperations = SystemHALPropertyOperations()) {
        self.operations = operations
    }

    func writeValue<Value>(
        _ value: Value,
        objectID: AudioObjectID,
        address: HALPropertyAddress,
        operation: String
    ) throws {
        var value = value
        let status = withUnsafePointer(to: &value) { pointer in
            operations.setPropertyData(
                objectID: objectID,
                address: address,
                dataSize: UInt32(MemoryLayout<Value>.size),
                data: pointer
            )
        }
        guard status == noErr else {
            throw HALStatusError(
                operation: operation,
                objectID: objectID,
                address: address,
                status: status
            )
        }
    }
}

struct AudioGeneration: Hashable, Sendable {
    let rawValue: UInt64
}

struct AudioResourceDescriptor: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case processTap
        case aggregateDevice
        case ioProc
        case propertyListener
    }

    let ownershipToken: UUID
    let generation: AudioGeneration
    let kind: Kind
    let objectID: AudioObjectID
    let persistentUID: String?

    init(
        ownershipToken: UUID = UUID(),
        generation: AudioGeneration,
        kind: Kind,
        objectID: AudioObjectID,
        persistentUID: String?
    ) {
        self.ownershipToken = ownershipToken
        self.generation = generation
        self.kind = kind
        self.objectID = objectID
        self.persistentUID = persistentUID
    }
}

final class HALListenerToken: @unchecked Sendable {
    private let lock = NSLock()
    private var removal: (@Sendable () -> OSStatus)?
    private let objectID: AudioObjectID
    private let address: HALPropertyAddress

    init(
        objectID: AudioObjectID,
        address: HALPropertyAddress,
        removal: @escaping @Sendable () -> OSStatus
    ) {
        self.objectID = objectID
        self.address = address
        self.removal = removal
    }

    func cancel() throws {
        let action = lock.withLock {
            defer { removal = nil }
            return removal
        }
        guard let action else { return }

        let status = action()
        guard status == noErr else {
            throw HALStatusError(
                operation: "AudioObjectRemovePropertyListener",
                objectID: objectID,
                address: address,
                status: status
            )
        }
    }

    deinit {
        try? cancel()
    }
}

func fourCC(_ value: UInt32) -> String {
    let bytes: [UInt8] = [
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff),
    ]

    guard bytes.allSatisfy({ (32...126).contains($0) }) else {
        return "0x\(String(value, radix: 16, uppercase: true))"
    }
    return "'\(String(decoding: bytes, as: UTF8.self))'"
}
