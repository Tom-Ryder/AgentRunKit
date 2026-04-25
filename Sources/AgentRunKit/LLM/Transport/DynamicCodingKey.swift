import Foundation

struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? {
        nil
    }

    init(_ key: String) {
        stringValue = key
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue _: Int) {
        nil
    }
}
