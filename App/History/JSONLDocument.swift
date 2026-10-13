import SwiftUI
import UniformTypeIdentifiers

/// The audit export handed to `fileExporter`.
struct JSONLDocument: FileDocument {
    static let contentType = UTType(filenameExtension: "jsonl", conformingTo: .plainText) ?? .plainText
    static var readableContentTypes: [UTType] { [contentType] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
