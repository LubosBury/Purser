import Foundation

public enum BridgeFileError: Error, Equatable, Sendable, CustomStringConvertible {
    case both(String, String)
    case wrongExtension(String)
    case unreadable(String)
    case tooLarge(String, limit: Int)
    case notText(String)

    public var description: String {
        switch self {
        case let .both(path, text): return "Give “\(path)” or “\(text)”, not both."
        case let .wrongExtension(path): return "Only a .csv file can be sent: \(path)"
        case let .unreadable(path): return "The file cannot be read: \(path)"
        case let .tooLarge(path, limit): return "The file is larger than \(limit / 1024) KB: \(path)"
        case let .notText(path): return "The file is not UTF-8 text: \(path)"
        }
    }
}

extension BridgeRequest {
    /// The file the helper read, so the tool's answer and the audit can name it.
    public static let csvSourceKey = "csv_source"

    /// Replaces a path argument with the file's text. The sandboxed app cannot open a path nobody picked in an open
    /// panel, so the helper reads the file and sends its content. Only `.csv` files: the tool must not become a way
    /// to read any file on the Mac.
    public func inliningCSV(pathKey: String, textKey: String, maxBytes: Int = 4 << 20) throws -> BridgeRequest {
        guard case var .object(members) = arguments, let raw = members[pathKey]?.stringValue, !raw.isEmpty else { return self }
        if let text = members[textKey]?.stringValue, !text.isEmpty { throw BridgeFileError.both(pathKey, textKey) }
        let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        guard url.pathExtension.lowercased() == "csv" else { throw BridgeFileError.wrongExtension(raw) }
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, let data = try? Data(contentsOf: url) else {
            throw BridgeFileError.unreadable(raw)
        }
        guard size <= maxBytes, data.count <= maxBytes else { throw BridgeFileError.tooLarge(raw, limit: maxBytes) }
        guard let text = String(data: data, encoding: .utf8) else { throw BridgeFileError.notText(raw) }
        members[pathKey] = nil
        members[textKey] = .string(text)
        members[BridgeRequest.csvSourceKey] = .string(url.standardizedFileURL.path)
        return BridgeRequest(tool: tool, arguments: .object(members))
    }
}
