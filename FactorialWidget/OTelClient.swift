import Foundation
import os

private let logger = Logger(subsystem: "com.factorial.widget", category: "OTelClient")

/// Fire-and-forget OTLP HTTP/JSON telemetry client.
/// Reads configuration from standard OTEL env vars:
///   OTEL_EXPORTER_OTLP_ENDPOINT  — base URL (e.g. http://host:4318), /v1/logs appended automatically
///   OTEL_EXPORTER_OTLP_HEADERS   — comma-separated key=value pairs (e.g. Authorization=Bearer xxx)
/// All sends are async and silent — telemetry failures never affect the widget.
class OTelClient {
    static let shared = OTelClient()

    enum Severity {
        case info, warn, error
        var number: Int { switch self { case .info: return 9; case .warn: return 13; case .error: return 17 } }
        var text: String { switch self { case .info: return "INFO"; case .warn: return "WARN"; case .error: return "ERROR" } }
    }

    var userEmail: String = ""

    private let endpoint: URL?
    private let headers: [String: String]
    private let appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    private let deviceUser: String = NSUserName()

    private init() {
        let env = ProcessInfo.processInfo.environment

        if let base = env["OTEL_EXPORTER_OTLP_ENDPOINT"]?.trimmingCharacters(in: .whitespaces) {
            endpoint = URL(string: base.hasSuffix("/") ? "\(base)v1/logs" : "\(base)/v1/logs")
        } else {
            endpoint = nil
        }

        // Parse "Key1=Value1,Key2=Value2" — values may contain '=' (e.g. Bearer tokens)
        if let raw = env["OTEL_EXPORTER_OTLP_HEADERS"] {
            var parsed: [String: String] = [:]
            for pair in raw.split(separator: ",") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    parsed[String(parts[0]).trimmingCharacters(in: .whitespaces)] =
                        String(parts[1]).trimmingCharacters(in: .whitespaces)
                }
            }
            headers = parsed
        } else {
            headers = [:]
        }

    }

    /// Send a named event with optional extra attributes. Fire-and-forget.
    func track(_ event: String, _ extra: [String: String] = [:], severity: Severity = .info) {
        guard let endpoint, !headers.isEmpty else { return }

        var attrs: [[String: Any]] = [
            otlpStr("event.name", event),
            otlpStr("user.email", userEmail.isEmpty ? "unknown" : userEmail),
            otlpStr("app.version", appVersion),
        ]
        for (k, v) in extra {
            attrs.append(otlpStr(k, v))
        }

        let payload = buildPayload(event, attrs, severity: severity)
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        let req = buildRequest(url: endpoint, body: body)
        Task.detached {
            do {
                _ = try await URLSession.shared.data(for: req)
            } catch {
                logger.debug("Telemetry send failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func buildRequest(url: URL, body: Data) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.httpBody = body
        return req
    }

    private func buildPayload(_ event: String, _ attrs: [[String: Any]], severity: Severity) -> [String: Any] {
        let nowNs = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        return [
            "resourceLogs": [[
                "resource": ["attributes": [
                    otlpStr("service.name", "factorial-widget"),
                    otlpStr("service.version", appVersion),
                    otlpStr("job", "factorial-widget"),
                    otlpStr("device.user", deviceUser),
                ]],
                "scopeLogs": [[
                    "scope": ["name": "factorial-widget"],
                    "logRecords": [[
                        "timeUnixNano": String(nowNs),
                        "severityNumber": severity.number,
                        "severityText": severity.text,
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
