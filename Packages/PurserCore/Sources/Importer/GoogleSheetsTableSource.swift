import Foundation
import ASCClient

public enum GoogleSheetsError: Error, Equatable {
    case unauthorized
    case http(status: Int, message: String)
    case malformedResponse
}

/// Reads one range through spreadsheets.values.get with valueRenderOption=UNFORMATTED_VALUE.
/// Numbers are rendered from the JSON text without any locale formatting ("1234.5", never "1 234,50").
public struct GoogleSheetsTableSource: TableSource {
    private let spreadsheetId: String
    private let range: String
    private let transport: any HTTPTransport
    private let accessToken: @Sendable () async throws -> String

    public init(spreadsheetId: String, range: String, transport: any HTTPTransport,
                accessToken: @escaping @Sendable () async throws -> String) {
        self.spreadsheetId = spreadsheetId; self.range = range; self.transport = transport; self.accessToken = accessToken
    }

    public func fetchRows() async throws -> [[String]] {
        var request = URLRequest(url: Self.valuesURL(spreadsheetId: spreadsheetId, range: range))
        request.httpMethod = "GET"
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.send(request)
        if response.statusCode == 401 { throw GoogleSheetsError.unauthorized }
        guard (200..<300).contains(response.statusCode) else {
            throw GoogleSheetsError.http(status: response.statusCode, message: String(decoding: data.prefix(500), as: UTF8.self))
        }
        return try Self.parseValues(data)
    }

    static func valuesURL(spreadsheetId: String, range: String) -> URL {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!:")
        let id = spreadsheetId.addingPercentEncoding(withAllowedCharacters: allowed) ?? spreadsheetId
        let encodedRange = range.addingPercentEncoding(withAllowedCharacters: allowed) ?? range
        var components = URLComponents(string: "https://sheets.googleapis.com/v4/spreadsheets/\(id)/values/\(encodedRange)")!
        components.queryItems = [
            URLQueryItem(name: "valueRenderOption", value: "UNFORMATTED_VALUE"),
            URLQueryItem(name: "majorDimension", value: "ROWS"),
        ]
        return components.url!
    }

    enum Cell: Decodable {
        case text(String)
        case number(Decimal)
        case bool(Bool)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .text(s); return }
            if let b = try? c.decode(Bool.self) { self = .bool(b); return }
            self = .number(try c.decode(Decimal.self))
        }

        var rendered: String {
            switch self {
            case let .text(s): return s
            case let .bool(b): return b ? "TRUE" : "FALSE"
            case let .number(d): return "\(d)"
            }
        }
    }

    static func parseValues(_ data: Data) throws -> [[String]] {
        struct Body: Decodable { var values: [[Cell]]? }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { throw GoogleSheetsError.malformedResponse }
        return (body.values ?? []).map { $0.map(\.rendered) }
    }
}
