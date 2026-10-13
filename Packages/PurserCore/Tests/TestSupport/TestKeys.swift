import CryptoKit
import Foundation

/// Freshly generated P-256 keys in the PKCS#8 PEM shape of an ASC .p8 file. Never a real key.
public enum TestKeys {
    public static func makeKey() -> (pem: String, publicKey: P256.Signing.PublicKey) {
        let key = P256.Signing.PrivateKey()
        return (key.pemRepresentation, key.publicKey)
    }

    /// Decodes one base64url JWT segment.
    public static func decodeSegment(_ segment: Substring) -> Data? {
        var text = segment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        return Data(base64Encoded: text)
    }

    /// The JSON object in the payload segment of a JWT.
    public static func claims(of token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3, let data = decodeSegment(parts[1]) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
