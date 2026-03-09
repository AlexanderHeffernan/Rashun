import Foundation

enum JSONOutput {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static func print<T: Encodable>(_ value: T) throws {
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw JSONOutputError.invalidUTF8
        }
        Swift.print(string)
    }
}

enum JSONOutputError: Error {
    case invalidUTF8
}
