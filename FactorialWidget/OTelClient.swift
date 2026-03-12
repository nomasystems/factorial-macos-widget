import Foundation

/// Fire-and-forget OTLP HTTP/JSON telemetry client.
/// All sends are async and silent — telemetry failures never affect the widget.
class OTelClient {
    static let shared = OTelClient()

    var userEmail: String = ""

    private let endpoint = URL(string: "https://telemetry.nomasystems.com/v1/logs")!
    private let token: String = Bundle.main.infoDictionary?["OtelToken"] as? String ?? ""
    private let appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"

    private init() {}

    /// Send a test event and return a human-readable result. For diagnostics only.
    func testConnection() async -> String {
        guard !token.isEmpty else { return "❌ Token vacío — revisa OTEL_TOKEN en Secrets.xcconfig" }
        let payload = buildPayload("test_connection", [otlpStr("source", "manual")])
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return "❌ Error serializando payload"
        }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            return code == 200 ? "✅ OK (\(code))" : "❌ HTTP \(code): \(body)"
        } catch {
            return "❌ \(error.localizedDescription)"
        }
    }

    /// Send a named event with optional extra attributes. Fire-and-forget.
    func track(_ event: String, _ extra: [String: String] = [:]) {
        guard !token.isEmpty else { return }

        var attrs: [[String: Any]] = [
            otlpStr("event.name", event),
            otlpStr("user.email", userEmail.isEmpty ? "unknown" : userEmail),
            otlpStr("app.version", appVersion),
        ]
        for (k, v) in extra {
            attrs.append(otlpStr(k, v))
        }

        let payload = buildPayload(event, attrs)
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        Task.detached {
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    private func buildPayload(_ event: String, _ attrs: [[String: Any]]) -> [String: Any] {
        let nowNs = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        return [
            "resourceLogs": [[
                "resource": ["attributes": [
                    otlpStr("service.name", "factorial-widget"),
                    otlpStr("service.version", appVersion),
                ]],
                "scopeLogs": [[
                    "scope": ["name": "factorial-widget"],
                    "logRecords": [[
                        "timeUnixNano": String(nowNs),
                        "severityNumber": 9,
                        "severityText": "INFO",
                        "body": ["stringValue": event],
                        "attributes": attrs
                    ]]
                ]]
            ]]
        ]
    }

    private func otlpStr(_ key: String, _ value: String) -> [String: Any] {
        ["key": key, "value": ["stringValue": value]]
    }
}
