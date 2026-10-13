import Foundation
import Domain

public protocol TableSource: Sendable {
    /// Raw cell strings, row-major, as unformatted values (Sheets: valueRenderOption=UNFORMATTED_VALUE).
    func fetchRows() async throws -> [[String]]
}

public enum ImportColumns {
    /// "A" -> 0, "Z" -> 25, "AA" -> 26. Case-insensitive; nil for anything that is not 1-3 letters.
    public static func index(of letters: String) -> Int? {
        let trimmed = letters.trimmingCharacters(in: .whitespaces).uppercased()
        guard !trimmed.isEmpty, trimmed.count <= 3 else { return nil }
        var result = 0
        for scalar in trimmed.unicodeScalars {
            guard scalar.value >= 65, scalar.value <= 90 else { return nil }
            result = result * 26 + Int(scalar.value - 64)
        }
        return result - 1
    }

    /// Inverse of `index(of:)`: 0 -> "A", 26 -> "AA".
    public static func letters(for index: Int) -> String {
        var n = index + 1
        var result = ""
        while n > 0 {
            let remainder = (n - 1) % 26
            result = String(UnicodeScalar(UInt8(65 + remainder))) + result
            n = (n - 1) / 26
        }
        return result
    }
}
