import Foundation

package func encodeDeterministicJSON(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}
