#if DEBUG
import Foundation
import ASCClient
import Executor

/// Spike S8 drills, DEBUG builds only, driven by environment variables of the Xcode scheme:
/// PURSER_DRILL_KILL_AT=afterItemCommitted:7 kills the process with SIGKILL at that executor step;
/// PURSER_DRILL_429_AFTER=10 answers the 10th write of the apply session with a synthetic 429 that never leaves the Mac.
enum DrillSupport {
    static func install(on executor: Executor) async {
        guard let raw = ProcessInfo.processInfo.environment["PURSER_DRILL_KILL_AT"], let target = ExecutorStep(raw) else { return }
        await executor.setStepHook { step in
            if step == target { kill(getpid(), SIGKILL) }
        }
    }

    static func wrap(_ inner: any HTTPTransport) -> any HTTPTransport {
        guard let raw = ProcessInfo.processInfo.environment["PURSER_DRILL_429_AFTER"], let count = Int(raw), count > 0 else { return inner }
        return Forced429Transport(inner: inner, failAt: count)
    }
}

actor Forced429Transport: HTTPTransport {
    let inner: any HTTPTransport
    let failAt: Int
    private var writes = 0

    init(inner: any HTTPTransport, failAt: Int) {
        self.inner = inner
        self.failAt = failAt
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.httpMethod != "GET" {
            writes += 1
            if writes == failAt {
                let body = #"{"errors":[{"id":"drill","status":"429","code":"RATE_LIMIT_EXCEEDED","title":"Drill","detail":"Synthetic 429 (S8 drill)"}]}"#
                let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: "HTTP/1.1",
                                               headerFields: ["Content-Type": "application/json"])!
                return (Data(body.utf8), response)
            }
        }
        return try await inner.send(request)
    }
}
#endif
