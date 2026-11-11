import Foundation
import Synchronization
import Testing
@testable import ReaderCore

/// Test-only transport. All shared state is protected; no network connection is made.
private final class CompanionFixtureProtocol: URLProtocol, @unchecked Sendable {
    struct Plan: Sendable { let lines: [String]; var delay: Int = 0; var status: Int = 200 }
    struct State { var plans: [URL: Plan] = [:]; var stopped = Set<URL>(); var bodies: [URL: Data] = [:] }
    static let state = Mutex(State())
    private let worker = Mutex<Task<Void, Never>?>(nil)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let plan = Self.state.withLock { value in value.bodies[url] = request.httpBody; return value.plans[url] }
        guard let plan else { client?.urlProtocol(self, didFailWithError: CompanionError.configuration); return }
        let task = Task { @Sendable [self] in
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: plan.status, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            do {
                for line in plan.lines {
                    if plan.delay > 0 { try await Task.sleep(for: .milliseconds(plan.delay)) }
                    try Task.checkCancellation(); client?.urlProtocol(self, didLoad: Data((line + "\n").utf8))
                }
                client?.urlProtocolDidFinishLoading(self)
            } catch { }
        }
        worker.withLock { $0 = task }
    }
    override func stopLoading() {
        worker.withLock { $0?.cancel(); $0 = nil }
        if let url = request.url { _ = Self.state.withLock { $0.stopped.insert(url) } }
    }
}

private func transport(_ plan: CompanionFixtureProtocol.Plan, cloud: Bool = false) -> (CompanionHTTPProvider, URL) {
    var settings = CompanionSettings(); settings.mode = cloud ? .cloud : .local; settings.model = "fixture"
    settings.endpoint = "\(cloud ? "https://fixture.example" : "http://127.0.0.1:11434")/\(UUID().uuidString)"
    settings.consentDestination = cloud ? settings.destination : nil
    let url = URL(string: settings.endpoint)!
    CompanionFixtureProtocol.state.withLock { $0.plans[url] = plan }
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CompanionFixtureProtocol.self]
    return (CompanionHTTPProvider(settings: settings, apiKey: cloud ? "fixture-key" : "", configuration: config), url)
}
private let request = CompanionRequest(question: "Explain", title: "Fixture", page: 1, sources: [])

@Test func actualTransportDecodesBothProtocolsAndBoundsOutboundContext() async throws {
    let (local, _) = transport(.init(lines: [#"{"message":{"content":"first"},"done":false}"#, #"{"message":{"content":"second"},"done":true}"#]))
    var text = ""; for try await chunk in local.response(to: request) { text += chunk }; #expect(text == "firstsecond")
    let (cloud, _) = transport(.init(lines: [#"data: {"choices":[{"delta":{"content":"result"},"finish_reason":null}]}"#, #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#, "data: [DONE]"]), cloud: true)
    text = ""; for try await chunk in cloud.response(to: request) { text += chunk }; #expect(text == "result")
    let huge = CompanionRequest(question: String(repeating: "x", count: 4001), title: "", page: 1, sources: [])
    await #expect(throws: CompanionError.limitExceeded) { for try await _ in local.response(to: huge) {} }
}

@Test func transportRejectsIncompleteOversizeAndHttpFailure() async throws {
    let (incomplete, _) = transport(.init(lines: [#"{"message":{"content":"partial"},"done":false}"#]))
    await #expect(throws: CompanionError.invalidResponse) { for try await _ in incomplete.response(to: request) {} }
    let (failed, _) = transport(.init(lines: [], status: 401))
    await #expect(throws: CompanionError.http(401)) { for try await _ in failed.response(to: request) {} }
    let (oversize, _) = transport(.init(lines: [String(repeating: "x", count: 65537)]))
    await #expect(throws: CompanionError.limitExceeded) { for try await _ in oversize.response(to: request) {} }
}

@Test func cancellationStopsUnderlyingUrlLoading() async throws {
    let (provider, url) = transport(.init(lines: [#"{"message":{"content":"wait"},"done":false}"#], delay: 10000))
    let task = Task { for try await _ in provider.response(to: request) {} }
    try await Task.sleep(for: .milliseconds(80)); task.cancel()
    _ = try? await task.value
    for _ in 0..<30 {
        if CompanionFixtureProtocol.state.withLock({ $0.stopped.contains(url) }) { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("Cancelling the response must stop URL loading")
}
