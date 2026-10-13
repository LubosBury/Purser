#!/usr/bin/env swift
// Offline check of a Purser audit export (Historie -> Export JSONL; one ChainLine per line, contract K3).
// Same checks as AuditLog.verifyExport(at:): every line decodes, seq runs 1, 2, 3, ... without gaps, seq 1 starts
// from the genesis prevHash (64 x "0"), every prevHash equals the previous line's hash and every hash equals
// sha256hex(prevHash|seq|ts|type|actor|refs|payload) over the exported strings. Optional --check <seq>:<hash>
// pairs (e.g. the daily chain head posted to Slack) must match the export.
// Usage: swift Tools/verify-audit-export.swift <export.jsonl> [--check <seq>:<hash>]...
// Exit status: 0 = chain intact and all checks match, 1 = broken chain or check mismatch, 2 = usage or read error.
import CryptoKit
import Foundation

/// One exported audit row; `refs` and `payload` are the JSON strings exactly as stored (contract K3).
struct ChainLine: Decodable {
    let seq: Int64
    let ts: String
    let type: String
    let actor: String
    let refs: String
    let payload: String
    let prevHash: String
    let hash: String

    var computedHash: String {
        let input = [prevHash, String(seq), ts, type, actor, refs, payload].joined(separator: "|")
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(code)
}

func isHash(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy(\.isHexDigit)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let path = arguments.first, !path.hasPrefix("--") else {
    fail("usage: swift Tools/verify-audit-export.swift <export.jsonl> [--check <seq>:<hash>]...", code: 2)
}
arguments.removeFirst()

var checks: [Int64: String] = [:]
while !arguments.isEmpty {
    let flag = arguments.removeFirst()
    guard flag == "--check", let value = arguments.first else { fail("unexpected argument \(flag)", code: 2) }
    arguments.removeFirst()
    let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2, let seq = Int64(parts[0]), isHash(parts[1]) else {
        fail("--check expects <seq>:<64 hex characters>, got \(value)", code: 2)
    }
    checks[seq] = parts[1].lowercased()
}

let text: String
do {
    text = try String(contentsOfFile: path, encoding: .utf8)
} catch {
    fail("cannot read \(path): \(error.localizedDescription)", code: 2)
}

let genesis = String(repeating: "0", count: 64)
let decoder = JSONDecoder()
var previous: ChainLine?
var count = 0
var seen: [Int64: String] = [:]

for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
    let lineNumber = index + 1
    let line: ChainLine
    do {
        line = try decoder.decode(ChainLine.self, from: Data(rawLine.utf8))
    } catch {
        fail("line \(lineNumber): not an audit export line (\(error))")
    }
    let expectedSeq = (previous?.seq ?? 0) + 1
    guard line.seq == expectedSeq else {
        fail("line \(lineNumber): seq \(line.seq), expected \(expectedSeq)")
    }
    guard line.prevHash == (previous?.hash ?? genesis) else {
        if previous == nil { fail("line 1: seq 1 must start from the genesis prevHash") }
        fail("line \(lineNumber): prevHash does not match the hash of seq \(expectedSeq - 1)")
    }
    guard line.hash == line.computedHash else {
        fail("line \(lineNumber): hash does not match the content of seq \(line.seq)")
    }
    if checks[line.seq] != nil { seen[line.seq] = line.hash }
    previous = line
    count += 1
}

guard let head = previous else { fail("export is empty") }
print("OK chain: \(count) events, seq 1...\(head.seq), content hashes recomputed")
print("head: \(head.seq):\(head.hash)")

var mismatch = false
for (seq, expected) in checks.sorted(by: { $0.key < $1.key }) {
    switch seen[seq] {
    case nil:
        print("check \(seq): NOT IN EXPORT")
        mismatch = true
    case expected?:
        print("check \(seq): OK")
    case let actual?:
        print("check \(seq): hash differs (export has \(actual))")
        mismatch = true
    }
}
exit(mismatch ? 1 : 0)
