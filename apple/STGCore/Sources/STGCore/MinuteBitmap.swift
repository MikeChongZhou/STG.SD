import Foundation

public struct MinuteBitmap: Equatable, Sendable {
    public static let minuteCount = 1_440
    public static let byteCount = 180
    public private(set) var data: Data

    public init() { data = Data(repeating: 0, count: Self.byteCount) }

    public init(data: Data) throws {
        guard data.count == Self.byteCount else { throw STGError.invalidBitmapLength(data.count) }
        self.data = data
    }

    public subscript(minute: Int) -> Bool {
        get {
            guard (0..<Self.minuteCount).contains(minute) else { return false }
            return data[minute / 8] & UInt8(1 << (minute % 8)) != 0
        }
        set {
            guard (0..<Self.minuteCount).contains(minute) else { return }
            let index = minute / 8
            let mask = UInt8(1 << (minute % 8))
            data[index] = newValue ? data[index] | mask : data[index] & ~mask
        }
    }

    @discardableResult
    public mutating func mark(_ minute: Int) -> Bool {
        let wasSet = self[minute]
        self[minute] = true
        return !wasSet
    }

    public var count: Int { data.reduce(0) { $0 + $1.nonzeroBitCount } }

    public mutating func formUnion(_ other: MinuteBitmap) {
        for index in data.indices { data[index] |= other.data[index] }
    }

    public func union(_ other: MinuteBitmap) -> MinuteBitmap {
        var result = self
        result.formUnion(other)
        return result
    }
}

public enum STGError: Error, Equatable, LocalizedError {
    case invalidBitmapLength(Int)
    case invalidUTCDate(String)
    case database(String)
    case invalidDocument(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidBitmapLength(length):
            return "Invalid bitmap length: \(length) bytes"
        case let .invalidUTCDate(value):
            return "Invalid UTC date: \(value)"
        case let .database(message):
            return "Database error: \(message)"
        case let .invalidDocument(message):
            return message
        }
    }
}
