import Foundation

struct MultipartFormData: Sendable {
    enum Body: Sendable {
        case data(Data)
        case file(URL)
    }

    struct Part: Sendable {
        let headers: [(String, String)]
        let body: Body
    }

    let boundary: String
    private var parts: [Part] = []

    init(boundary: String) {
        self.boundary = boundary
    }

    var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    mutating func addField(name: String, value: String) {
        let headers = [("Content-Disposition", "form-data; name=\"\(name)\"")]
        parts.append(Part(headers: headers, body: .data(Data(value.utf8))))
    }

    mutating func addFile(name: String, filename: String, mimeType: String, data: Data) {
        let headers = [
            ("Content-Disposition", "form-data; name=\"\(name)\"; filename=\"\(filename)\""),
            ("Content-Type", mimeType)
        ]
        parts.append(Part(headers: headers, body: .data(data)))
    }

    mutating func addFile(name: String, filename: String, mimeType: String, fileURL: URL) {
        let headers = [
            ("Content-Disposition", "form-data; name=\"\(name)\"; filename=\"\(filename)\""),
            ("Content-Type", mimeType)
        ]
        parts.append(Part(headers: headers, body: .file(fileURL)))
    }

    func encoded() -> Data {
        var data = Data()
        for part in parts {
            data.appendString("--\(boundary)\r\n")
            for (name, value) in part.headers {
                data.appendString("\(name): \(value)\r\n")
            }
            data.appendString("\r\n")
            switch part.body {
            case let .data(bodyData):
                data.append(bodyData)
            case .file:
                preconditionFailure("MultipartFormData.encoded requires data-backed parts")
            }
            data.appendString("\r\n")
        }
        data.appendString("--\(boundary)--\r\n")
        return data
    }

    func contentLength() throws -> Int {
        let boundaryPrefix = "--\(boundary)\r\n"
        let boundarySuffix = "--\(boundary)--\r\n"
        var length = 0

        for part in parts {
            length += boundaryPrefix.utf8.count
            for (name, value) in part.headers {
                length += "\(name): \(value)\r\n".utf8.count
            }
            length += "\r\n".utf8.count
            length += try bodyLength(for: part.body)
            length += "\r\n".utf8.count
        }

        length += boundarySuffix.utf8.count
        return length
    }

    func write(to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        for part in parts {
            try handle.write(contentsOf: Data("--\(boundary)\r\n".utf8))
            for (name, value) in part.headers {
                try handle.write(contentsOf: Data("\(name): \(value)\r\n".utf8))
            }
            try handle.write(contentsOf: Data("\r\n".utf8))
            try writeBody(part.body, to: handle)
            try handle.write(contentsOf: Data("\r\n".utf8))
        }

        try handle.write(contentsOf: Data("--\(boundary)--\r\n".utf8))
    }

    private func bodyLength(for body: Body) throws -> Int {
        switch body {
        case let .data(data):
            return data.count
        case let .file(url):
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = attributes[.size] as? NSNumber
            return size?.intValue ?? 0
        }
    }

    private func writeBody(_ body: Body, to handle: FileHandle) throws {
        switch body {
        case let .data(data):
            try handle.write(contentsOf: data)
        case let .file(url):
            let reader = try FileHandle(forReadingFrom: url)
            defer { try? reader.close() }
            while let chunk = try reader.read(upToCount: 65536), !chunk.isEmpty {
                try handle.write(contentsOf: chunk)
            }
        }
    }
}

private extension Data {
    mutating func appendString(_ value: String) {
        append(Data(value.utf8))
    }
}
