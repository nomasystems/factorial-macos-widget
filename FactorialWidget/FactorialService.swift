import Foundation
import AppKit

struct ProjectWorker: Identifiable, Equatable {
    let id: Int       // project_worker_id (usado en time-records)
    let name: String
    let code: String?

    var displayName: String {
        if let code, !code.isEmpty { return "[\(code)] \(name)" }
        return name
    }
}

struct OpenShift {
    let id: Int
    let clockIn: Date
}

enum FactorialError: LocalizedError {
    case missingTokens
    case apiError(String)
    case authCancelled

    var errorDescription: String? {
        switch self {
        case .missingTokens: return "Token no disponible. Re-autoriza OAuth."
        case .apiError(let msg): return msg
        case .authCancelled: return "Autorización cancelada"
        }
    }
}

@MainActor
class FactorialService: ObservableObject {
    static let baseURL = "https://api.factorialhr.com"

    private let clientId = Bundle.main.infoDictionary?["FactorialClientId"] as? String ?? ""
    private let clientSecret = Bundle.main.infoDictionary?["FactorialClientSecret"] as? String ?? ""

    @Published var status: String = "Comprobando..."
    @Published var isLoading = false
    @Published var needsAuth = false
    @Published var projectWorkers: [ProjectWorker] = []
    @Published var employeeId: Int = 0
    @Published var openShift: OpenShift?
    @Published var todayCompletedDuration: TimeInterval? = nil
    @Published var selectedProjectWorkerId: Int {
        didSet { UserDefaults.standard.set(selectedProjectWorkerId, forKey: "selectedProjectWorkerId") }
    }

    init() {
        let saved = UserDefaults.standard.object(forKey: "selectedProjectWorkerId")
        selectedProjectWorkerId = saved != nil
            ? UserDefaults.standard.integer(forKey: "selectedProjectWorkerId")
            : 0
        Task { await checkStatus() }
    }

    func checkStatus() async {
        isLoading = true
        defer { isLoading = false }

        do {
            print("[Factorial] checkStatus start")
            let token = try await refreshAccessToken()
            print("[Factorial] token ok")

            let fetchedId = try await fetchMyEmployeeId(accessToken: token)
            print("[Factorial] employeeId=\(fetchedId)")
            if fetchedId != employeeId {
                employeeId = fetchedId
                UserDefaults.standard.set(fetchedId, forKey: "cachedEmployeeId")
            }

            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
            let result = try await fetchStatusData(accessToken: token, employeeId: employeeId, yesterday: yesterday)
            print("[Factorial] done: \(result.workers.count) workers, openShift=\(String(describing: result.openShift)), exists=\(result.yesterdayExists)")

            projectWorkers = result.workers
            openShift = result.openShift
            todayCompletedDuration = result.todayCompletedDuration

            let dateStr = isoDate(yesterday)
            status = result.yesterdayExists ? "✅ Fichado (\(dateStr))" : "⏳ Pendiente (\(dateStr))"
            needsAuth = false
        } catch FactorialError.missingTokens {
            needsAuth = true
            status = "🔑 Re-autorización necesaria"
        } catch {
            status = "❌ \(error.localizedDescription)"
        }
    }

    func clockIn(date: Date, startTime: Date, endTime: Date) async throws {
        let token = try await refreshAccessToken()
        let shiftId = try await createShift(date: date, startTime: startTime, endTime: endTime, accessToken: token)
        try await createTimeRecord(shiftId: shiftId, projectWorkerId: selectedProjectWorkerId, accessToken: token)
        status = "✅ Fichado (\(isoDate(date)))"
    }

    // MARK: - Clock In/Out Now

    func clockInNow() async throws {
        let token = try await refreshAccessToken()
        let now = Date()

        let url = URL(string: "\(Self.baseURL)/graphql")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let mutation = """
        mutation ClockIn($locationType: AttendanceShiftLocationTypeEnum, $now: ISO8601DateTime!, $projectWorkerId: Int, $source: AttendanceEnumsShiftSourceEnum) {
          attendanceMutations {
            clockInAttendanceShift(
              locationType: $locationType
              now: $now
              projectWorkerId: $projectWorkerId
              source: $source
            ) {
              errors { ... on SimpleError { message __typename } __typename }
              shift {
                employee {
                  id
                  openShift { id clockIn date }
                }
              }
            }
          }
        }
        """
        let body: [String: Any] = [
            "operationName": "ClockIn",
            "variables": [
                "now": iso8601WithTimezone(now),
                "source": "desktop",
                "locationType": "work_from_home",
                "projectWorkerId": selectedProjectWorkerId
            ],
            "query": mutation
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = root["data"] as? [String: Any],
              let mutations = dataObj["attendanceMutations"] as? [String: Any],
              let result = mutations["clockInAttendanceShift"] as? [String: Any] else {
            let msg = String(data: data, encoding: .utf8) ?? "Error desconocido"
            throw FactorialError.apiError("ClockIn fallido: \(msg)")
        }

        if let errors = result["errors"] as? [[String: Any]], !errors.isEmpty {
            let msg = errors.first?["message"] as? String ?? "Error desconocido"
            throw FactorialError.apiError(msg)
        }

        // Fetch open shift via GraphQL after clocking in
        if let fetchedOpenShift = try? await fetchOpenShift(accessToken: token, employeeId: employeeId) {
            openShift = fetchedOpenShift
        } else {
            openShift = OpenShift(id: 0, clockIn: now)
        }
    }

    func clockOutNow() async throws {
        let token = try await refreshAccessToken()

        let url = URL(string: "\(Self.baseURL)/graphql")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let mutation = """
        mutation ClockOut($now: ISO8601DateTime!, $source: AttendanceEnumsShiftSourceEnum) {
          attendanceMutations {
            clockOutAttendanceShift(now: $now, source: $source) {
              errors { ... on SimpleError { message __typename } __typename }
              shift { id clockOut }
            }
          }
        }
        """
        let body: [String: Any] = [
            "operationName": "ClockOut",
            "variables": [
                "now": iso8601WithTimezone(Date()),
                "source": "desktop"
            ],
            "query": mutation
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)

        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dataObj = root["data"] as? [String: Any],
           let mutations = dataObj["attendanceMutations"] as? [String: Any],
           let result = mutations["clockOutAttendanceShift"] as? [String: Any],
           let errors = result["errors"] as? [[String: Any]], !errors.isEmpty {
            let msg = errors.first?["message"] as? String ?? "Error desconocido"
            throw FactorialError.apiError(msg)
        }

        openShift = nil
        await checkStatus()
    }

    // MARK: - OAuth

    func openAuthorizationURL() {
        let authURLString = "\(Self.baseURL)/oauth/authorize?client_id=\(clientId)&redirect_uri=urn:ietf:wg:oauth:2.0:oob&response_type=code&scope=read%20write"
        guard let authURL = URL(string: authURLString) else { return }
        NSWorkspace.shared.open(authURL)
    }

    func submitAuthorizationCode(_ code: String) async throws {
        try await exchangeCode(code)
        needsAuth = false
        await checkStatus()
    }

    private func exchangeCode(_ code: String) async throws {
        let url = URL(string: "\(Self.baseURL)/oauth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "authorization_code",
            "client_id": clientId,
            "client_secret": clientSecret,
            "redirect_uri": "urn:ietf:wg:oauth:2.0:oob",
            "code": code
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let tokens = try JSONDecoder().decode(OAuthTokens.self, from: data)

        guard tokens.access_token != nil else {
            let msg = String(data: data, encoding: .utf8) ?? "Error desconocido"
            throw FactorialError.apiError("Exchange fallido: \(msg)")
        }
        TokenStore.shared.save(tokens)
    }

    func refreshAccessToken() async throws -> String {
        var tokens = TokenStore.shared.load()
        guard let refreshToken = tokens.refresh_token, !refreshToken.isEmpty else {
            throw FactorialError.missingTokens
        }

        let url = URL(string: "\(Self.baseURL)/oauth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "client_id": clientId,
            "client_secret": clientSecret,
            "refresh_token": refreshToken
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        var newTokens = try JSONDecoder().decode(OAuthTokens.self, from: data)

        guard let accessToken = newTokens.access_token, !accessToken.isEmpty else {
            throw FactorialError.missingTokens
        }

        if newTokens.refresh_token == nil || newTokens.refresh_token!.isEmpty {
            newTokens.refresh_token = refreshToken
        }
        TokenStore.shared.save(newTokens)
        return accessToken
    }

    // MARK: - API

    func createShift(date: Date, startTime: Date, endTime: Date, accessToken: String) async throws -> Int {
        let dateStr = isoDate(date)
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date)
        let isoWeekday = weekday == 1 ? 7 : weekday - 1

        let url = URL(string: "\(Self.baseURL)/api/2025-01-01/resources/attendance/shifts")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "employee_id": employeeId,
            "date": dateStr,
            "workable": true,
            "location_type": "work_from_home",
            "source": "api",
            "clock_in": "\(dateStr)T\(hhmm(startTime)):00Z",
            "clock_out": "\(dateStr)T\(hhmm(endTime)):00Z",
            "day": isoWeekday,
            "reference_date": dateStr
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? Int else {
            let msg = String(data: data, encoding: .utf8) ?? "Error desconocido"
            throw FactorialError.apiError("Error creando turno: \(msg)")
        }
        return id
    }

    func createTimeRecord(shiftId: Int, projectWorkerId: Int, accessToken: String) async throws {
        let url = URL(string: "\(Self.baseURL)/api/2025-01-01/resources/project-management/time-records")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "project_worker_id": projectWorkerId,
            "attendance_shift_id": shiftId,
            "source": "api"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["id"] != nil else {
            let msg = String(data: data, encoding: .utf8) ?? "Error desconocido"
            throw FactorialError.apiError("Error creando time record: \(msg)")
        }
    }

    private func jwtAccessId(_ token: String) -> Int? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
        let rem = b64.count % 4
        if rem > 0 { b64 += String(repeating: "=", count: 4 - rem) }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessId = json["access_id"] as? Int else { return nil }
        return accessId
    }

    func fetchMyEmployeeId(accessToken: String) async throws -> Int {
        guard let accessId = jwtAccessId(accessToken) else {
            throw FactorialError.apiError("No se pudo decodificar el access token")
        }

        let url = URL(string: "\(Self.baseURL)/graphql")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let query = """
        query EmployeeByAccessId($accessIds: [Int!]!) {
          employees {
            employeesConnection(accessIds: $accessIds) {
              nodes { id }
            }
          }
        }
        """
        let body: [String: Any] = [
            "operationName": "EmployeeByAccessId",
            "variables": ["accessIds": [accessId]],
            "query": query
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = root["data"] as? [String: Any],
              let employees = dataObj["employees"] as? [String: Any],
              let conn = employees["employeesConnection"] as? [String: Any],
              let nodes = conn["nodes"] as? [[String: Any]],
              let id = nodes.first?["id"] as? Int, id != 0 else {
            throw FactorialError.apiError("No se pudo obtener el employee ID")
        }
        return id
    }

    private func fetchOpenShift(accessToken: String, employeeId: Int) async throws -> OpenShift? {
        let url = URL(string: "\(Self.baseURL)/graphql")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "variables": ["employeeIds": [employeeId]],
            "query": "query { attendance { openShiftsConnection(employeeIds: $employeeIds) { nodes { id clockIn } } } }"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = root["data"] as? [String: Any],
              let att = dataObj["attendance"] as? [String: Any],
              let conn = att["openShiftsConnection"] as? [String: Any],
              let nodes = conn["nodes"] as? [[String: Any]] else { return nil }

        return nodes.compactMap { node -> OpenShift? in
            guard let id = node["id"] as? Int,
                  let clockInStr = node["clockIn"] as? String,
                  let clockInDate = parseISO8601(clockInStr) else { return nil }
            return OpenShift(id: id, clockIn: clockInDate)
        }.first
    }

    private struct StatusData {
        let workers: [ProjectWorker]
        let openShift: OpenShift?
        let yesterdayExists: Bool
        let todayCompletedDuration: TimeInterval?
    }

    private func fetchStatusData(accessToken: String, employeeId: Int, yesterday: Date) async throws -> StatusData {
        let url = URL(string: "\(Self.baseURL)/graphql")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let query = """
        query CheckStatus($employeeIds: [Int!]!, $yesterday: ISO8601Date!, $today: ISO8601Date!, $assigned: Boolean!, $onlyActiveProjects: Boolean!) {
          projectManagement {
            projectWorkers(assigned: $assigned, projectActive: $onlyActiveProjects, employeeIds: $employeeIds) {
              id
              imputableProject { id code name }
            }
          }
          attendance {
            openShiftsConnection(employeeIds: $employeeIds) {
              nodes { id clockIn }
            }
            yesterdayShifts: shiftsConnection(employeeIds: $employeeIds, startOn: $yesterday, endOn: $yesterday) {
              nodes { id }
            }
            todayShifts: shiftsConnection(employeeIds: $employeeIds, startOn: $today, endOn: $today) {
              nodes { id clockIn clockOut }
            }
          }
        }
        """
        let body: [String: Any] = [
            "operationName": "CheckStatus",
            "variables": [
                "employeeIds": [employeeId],
                "yesterday": isoDate(yesterday),
                "today": isoDate(Date()),
                "assigned": true,
                "onlyActiveProjects": true
            ],
            "query": query
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = root["data"] as? [String: Any] else {
            let msg = String(data: data, encoding: .utf8) ?? "Error desconocido"
            throw FactorialError.apiError("CheckStatus fallido: \(msg)")
        }

        // Parse project workers
        let pm = dataObj["projectManagement"] as? [String: Any]
        let workerDicts = pm?["projectWorkers"] as? [[String: Any]] ?? []
        let workers = workerDicts.compactMap { pw -> ProjectWorker? in
            guard let id = pw["id"] as? Int,
                  let proj = pw["imputableProject"] as? [String: Any],
                  let name = proj["name"] as? String else { return nil }
            return ProjectWorker(id: id, name: name, code: proj["code"] as? String)
        }.sorted { $0.displayName < $1.displayName }

        // Parse open shift
        let att = dataObj["attendance"] as? [String: Any]
        let openNodes = (att?["openShiftsConnection"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        let openShift: OpenShift? = openNodes.compactMap { node -> OpenShift? in
            guard let id = node["id"] as? Int,
                  let clockInStr = node["clockIn"] as? String,
                  let clockInDate = parseISO8601(clockInStr) else { return nil }
            return OpenShift(id: id, clockIn: clockInDate)
        }.first

        // Parse yesterday shift existence
        let yesterdayNodes = (att?["yesterdayShifts"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        let yesterdayExists = !yesterdayNodes.isEmpty

        // Parse today completed shifts duration (sum of completed shifts, excluding open ones)
        let todayNodes = (att?["todayShifts"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        let completedDuration = todayNodes.reduce(0.0) { acc, node -> TimeInterval in
            guard let inStr = node["clockIn"] as? String,
                  let outStr = node["clockOut"] as? String,
                  let clockIn = parseISO8601(inStr),
                  let clockOut = parseISO8601(outStr) else { return acc }
            return acc + clockOut.timeIntervalSince(clockIn)
        }
        let todayCompletedDuration: TimeInterval? = completedDuration > 0 ? completedDuration : nil

        return StatusData(workers: workers, openShift: openShift, yesterdayExists: yesterdayExists, todayCompletedDuration: todayCompletedDuration)
    }

    // MARK: - Helpers

    private func isoDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func hhmm(_ date: Date) -> String {
        let cal = Calendar.current
        let h = cal.component(.hour, from: date)
        let m = cal.component(.minute, from: date)
        return String(format: "%02d:%02d", h, m)
    }

    private func iso8601WithTimezone(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return formatter.string(from: date)
    }

    private func parseISO8601(_ str: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withColonSeparatorInTimeZone]
        if let d = f.date(from: str) { return d }
        f.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return f.date(from: str)
    }
}
