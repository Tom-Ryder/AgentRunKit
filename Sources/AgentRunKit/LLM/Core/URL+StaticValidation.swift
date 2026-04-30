import Foundation

extension URL {
    init(validStaticString string: String) {
        guard let url = URL(string: string) else {
            preconditionFailure("Invalid static URL: \(string)")
        }
        self = url
    }
}
