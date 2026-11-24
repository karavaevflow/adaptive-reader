import Foundation

private final class NoCompanionRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Ollama NDJSON and OpenAI-compatible Chat Completions SSE. No SDK, telemetry or background requests.
public struct CompanionHTTPProvider: CompanionProvider {
    public let settings: CompanionSettings
    private let apiKey: String
    private let configuration: URLSessionConfiguration
    public init(settings: CompanionSettings, apiKey: String = "", configuration: URLSessionConfiguration = .ephemeral) {
        self.settings = settings; self.apiKey = apiKey; self.configuration = configuration
    }
    public func response(to request: CompanionRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let worker = Task {
                let config = configuration.copy() as! URLSessionConfiguration
                config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
                if settings.mode == .local { config.connectionProxyDictionary = [:] }
                config.timeoutIntervalForRequest = 120; config.timeoutIntervalForResource = 180
                let session = URLSession(configuration: config, delegate: NoCompanionRedirects(), delegateQueue: nil)
                defer { session.invalidateAndCancel() }
                do {
                    let url = try settings.validatedURL()
                    var outbound = URLRequest(url: url)
                    outbound.httpMethod = "POST"; outbound.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if settings.mode == .cloud && !apiKey.isEmpty { outbound.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
                    var body: [String: Any] = ["model": settings.model, "messages": try request.messages, "stream": true]
                    if settings.mode == .local { body["format"] = "json"; body["options"] = ["num_predict": 4096]; body["keep_alive"] = "5m" }
                    else { body["response_format"] = ["type": "json_object"]; body["max_completion_tokens"] = 4096; body["store"] = false }
                    outbound.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (bytes, response) = try await session.bytes(for: outbound)
                    guard let http = response as? HTTPURLResponse else { throw CompanionError.invalidResponse }
                    guard (200..<300).contains(http.statusCode) else { throw CompanionError.http(http.statusCode) }
                    var line = Data(), received = 0, textCount = 0, finished = false
                    for try await byte in bytes {
                        try Task.checkCancellation(); received += 1
                        guard received <= 512 * 1024, line.count < 64 * 1024 else { throw CompanionError.limitExceeded }
                        if byte != 10 { line.append(byte); continue }
                        let event = try Self.decodeLine(line, mode: settings.mode); line.removeAll(keepingCapacity: true)
                        if let text = event.text {
                            textCount += text.count; guard textCount <= 64000 else { throw CompanionError.limitExceeded }
                            continuation.yield(text)
                        }
                        if event.done { finished = true; break }
                    }
                    if !finished && !line.isEmpty {
                        let event = try Self.decodeLine(line, mode: settings.mode)
                        if let text = event.text { textCount += text.count; guard textCount <= 64000 else { throw CompanionError.limitExceeded }; continuation.yield(text) }
                        finished = event.done
                    }
                    guard finished, textCount > 0 else { throw CompanionError.invalidResponse }
                    try Task.checkCancellation(); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in worker.cancel() }
        }
    }

    static func decodeLine(_ data: Data, mode: CompanionMode) throws -> (text: String?, done: Bool) {
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return (nil, false) }
        var payload = value
        if mode == .cloud {
            guard value.hasPrefix("data:") else { return (nil, false) }
            payload = String(value.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { return (nil, true) }
        }
        guard let object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any], object["error"] == nil else { throw CompanionError.invalidResponse }
        if mode == .local {
            return ((object["message"] as? [String: Any])?["content"] as? String, object["done"] as? Bool == true)
        }
        let choice = (object["choices"] as? [[String: Any]])?.first
        if let reason = choice?["finish_reason"] as? String, reason != "stop" { throw CompanionError.invalidResponse }
        return ((choice?["delta"] as? [String: Any])?["content"] as? String, false)
    }
}
