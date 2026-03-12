import Foundation
import AppKit

struct ProjectWorker: Identifiable, Equatable {
    let id: Int       // project_worker_id (usado en time-records)
    let name: String
    let code: String?

    var displayName: String { name }
}

struct OpenShift {
    let id: Int
    let clockIn: Date
    let isBreak: Bool
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
    @Published var userEmail: String = ""
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
        guard !isLoading else { return }
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

            let result = try await fetchStatusData(accessToken: token, employeeId: employeeId)
            print("[Factorial] done: \(result.workers.count) workers, openShift=\(String(describing: result.openShift))")

            projectWorkers = result.workers
            // Auto-select first project if nothing valid is selected
            if !result.workers.isEmpty,
               !result.workers.contains(where: { $0.id == selectedProjectWorkerId }) {
                selectedProjectWorkerId = result.workers[0].id
            }
            openShift = result.openShift
            todayCompletedDuration = result.todayCompletedDuration
            status = ""
            needsAuth = false
        } catch FactorialError.missingTokens {
            needsAuth = true
            status = "🔑 Re-autorización necesaria"
            OTelClient.shared.track("auth_error", ["error.message": "missing_tokens"])
        } catch {
            status = "❌ \(error.localizedDescription)"
            OTelClient.shared.track("api_error", [
                "error.operation": "check_status",
                "error.message": error.localizedDescription
            ])
        }
    }

    func clockIn(date: Date, startTime: Date, endTime: Date) async throws {
        let token = try await refreshAccessToken()
        let shiftId = try await createShift(date: date, startTime: startTime, endTime: endTime, accessToken: token)
        try await createTimeRecord(shiftId: shiftId, projectWorkerId: selectedProjectWorkerId, accessToken: token)
        status = "✅ Fichado (\(isoDate(date)))"
        let isToday = Calendar.current.isDateInToday(date)
        OTelClient.shared.track("manual_clock_in", [
            "project.worker.id": String(selectedProjectWorkerId),
            "entry.is_today": isToday ? "true" : "false"
        ])
    }

    // MARK: - Clock In/Out Now

    func clockInNow() async throws {
        let token = try await refreshAccessToken()

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
                "now": iso8601WithTimezone(Date()),
                "source": "desktop",
                "locationType": "work_from_home",
                "projectWorkerId": selectedProjectWorkerId
            ],
            "query": mutation
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FactorialError.apiError("ClockIn: respuesta inválida")
        }
        if let gqlErrors = root["errors"] as? [[String: Any]], !gqlErrors.isEmpty {
            throw FactorialError.apiError(gqlErrors.first?["message"] as? String ?? "Error de API")
        }
        guard let dataObj = root["data"] as? [String: Any],
              let mutations = dataObj["attendanceMutations"] as? [String: Any],
              let result = mutations["clockInAttendanceShift"] as? [String: Any] else {
            throw FactorialError.apiError("ClockIn: respuesta inesperada")
        }
        if let errors = result["errors"] as? [[String: Any]], !errors.isEmpty {
            let msg = extractErrorMessage(errors)
            OTelClient.shared.track("api_error", ["error.operation": "clock_in_now", "error.message": msg])
            throw FactorialError.apiError(msg)
        }

        OTelClient.shared.track("clock_in_now", [
            "project.worker.id": String(selectedProjectWorkerId)
        ])
        await checkStatus()
    }

    func breakStart() async throws {
        let token = try await refreshAccessToken()

        let url = URL(string: "\(Self.baseURL)/graphql")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let mutation = """
        mutation BreakStart($now: ISO8601DateTime!, $source: AttendanceEnumsShiftSourceEnum) {
          attendanceMutations {
            breakStartAttendanceShift(now: $now, source: $source, systemCreated: false) {
              errors { ... on SimpleError { message __typename } __typename }
              shift { id }
            }
          }
        }
        """
        let body: [String: Any] = [
            "operationName": "BreakStart",
            "variables": [
                "now": iso8601WithTimezone(Date()),
                "source": "desktop"
            ],
            "query": mutation
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FactorialError.apiError("BreakStart: respuesta inválida")
        }
        if let gqlErrors = root["errors"] as? [[String: Any]], !gqlErrors.isEmpty {
            let msg = gqlErrors.first?["message"] as? String ?? "Error de API"
            throw FactorialError.apiError(msg)
        }
        if let dataObj = root["data"] as? [String: Any],
           let mutations = dataObj["attendanceMutations"] as? [String: Any],
           let result = mutations["breakStartAttendanceShift"] as? [String: Any],
           let errors = result["errors"] as? [[String: Any]], !errors.isEmpty {
            let msg = extractErrorMessage(errors)
            OTelClient.shared.track("api_error", ["error.operation": "break_start", "error.message": msg])
            throw FactorialError.apiError(msg)
        }

        OTelClient.shared.track("break_start")
        await checkStatus()
    }

    func breakEnd() async throws {
        let token = try await refreshAccessToken()

        let url = URL(string: "\(Self.baseURL)/graphql")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let mutation = """
        mutation BreakEnd($now: ISO8601DateTime!, $source: AttendanceEnumsShiftSourceEnum) {
          attendanceMutations {
            breakEndAttendanceShift(now: $now, source: $source, systemCreated: false) {
              errors { ... on SimpleError { message __typename } __typename }
              shift { id }
            }
          }
        }
        """
        var variables: [String: Any] = [
            "now": iso8601WithTimezone(Date()),
            "source": "desktop"
        ]
        if selectedProjectWorkerId > 0 {
            variables["projectWorkerId"] = selectedProjectWorkerId
        }
        let body: [String: Any] = [
            "operationName": "BreakEnd",
            "variables": variables,
            "query": mutation
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FactorialError.apiError("BreakEnd: respuesta inválida")
        }
        if let gqlErrors = root["errors"] as? [[String: Any]], !gqlErrors.isEmpty {
            let msg = gqlErrors.first?["message"] as? String ?? "Error de API"
            throw FactorialError.apiError(msg)
        }
        if let dataObj = root["data"] as? [String: Any],
           let mutations = dataObj["attendanceMutations"] as? [String: Any],
           let result = mutations["breakEndAttendanceShift"] as? [String: Any],
           let errors = result["errors"] as? [[String: Any]], !errors.isEmpty {
            let msg = extractErrorMessage(errors)
            OTelClient.shared.track("api_error", ["error.operation": "break_end", "error.message": msg])
            throw FactorialError.apiError(msg)
        }

        OTelClient.shared.track("break_end")
        await checkStatus()
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

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FactorialError.apiError("ClockOut: respuesta inválida")
        }
        if let gqlErrors = root["errors"] as? [[String: Any]], !gqlErrors.isEmpty {
            throw FactorialError.apiError(gqlErrors.first?["message"] as? String ?? "Error de API")
        }
        if let dataObj = root["data"] as? [String: Any],
           let mutations = dataObj["attendanceMutations"] as? [String: Any],
           let result = mutations["clockOutAttendanceShift"] as? [String: Any],
           let errors = result["errors"] as? [[String: Any]], !errors.isEmpty {
            let msg = extractErrorMessage(errors)
            OTelClient.shared.track("api_error", ["error.operation": "clock_out", "error.message": msg])
            throw FactorialError.apiError(msg)
        }

        let workedSeconds = (todayCompletedDuration ?? 0) + (openShift.map { Date().timeIntervalSince($0.clockIn) } ?? 0)
        OTelClient.shared.track("clock_out", [
            "worked.seconds": String(Int(workedSeconds))
        ])
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
              nodes { id email }
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
              let node = nodes.first,
              let id = node["id"] as? Int, id != 0 else {
            throw FactorialError.apiError("No se pudo obtener el employee ID")
        }
        if let email = node["email"] as? String, !email.isEmpty {
            userEmail = email
            OTelClient.shared.userEmail = email
        }
        return id
    }

    private struct StatusData {
        let workers: [ProjectWorker]
        let openShift: OpenShift?
        let todayCompletedDuration: TimeInterval?
    }

    private func fetchStatusData(accessToken: String, employeeId: Int) async throws -> StatusData {
        let url = URL(string: "\(Self.baseURL)/graphql")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let query = """
        query CheckStatus($employeeIds: [Int!]!, $today: ISO8601Date!, $assigned: Boolean!, $onlyActiveProjects: Boolean!) {
          projectManagement {
            projectWorkers(assigned: $assigned, projectActive: $onlyActiveProjects, employeeIds: $employeeIds) {
              id
              imputableProject { id code name }
            }
          }
          attendance {
            openShiftsConnection(employeeIds: $employeeIds) {
              nodes { id clockIn workable }
            }
            todayShifts: shiftsConnection(employeeIds: $employeeIds, startOn: $today, endOn: $today) {
              nodes { id clockIn clockOut workable }
            }
          }
        }
        """
        let body: [String: Any] = [
            "operationName": "CheckStatus",
            "variables": [
                "employeeIds": [employeeId],
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
            guard let id = (node["id"] as? Int) ?? (node["id"] as? String).flatMap(Int.init),
                  let clockInStr = node["clockIn"] as? String,
                  let clockInDate = parseTodayTime(clockInStr) else { return nil }
            let isBreak = !(node["workable"] as? Bool ?? true)
            return OpenShift(id: id, clockIn: clockInDate, isBreak: isBreak)
        }.first

        // Parse today completed shifts duration (sum of completed shifts, excluding open ones)
        let todayNodes = (att?["todayShifts"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        let completedDuration = todayNodes.reduce(0.0) { acc, node -> TimeInterval in
            guard node["workable"] as? Bool != false,
                  let inStr = node["clockIn"] as? String,
                  let outStr = node["clockOut"] as? String,
                  let clockIn = parseTodayTime(inStr),
                  let clockOut = parseTodayTime(outStr) else { return acc }
            return acc + clockOut.timeIntervalSince(clockIn)
        }
        let todayCompletedDuration: TimeInterval? = completedDuration > 0 ? completedDuration : nil

        return StatusData(workers: workers, openShift: openShift, todayCompletedDuration: todayCompletedDuration)
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
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    /// Parse a Factorial time string and pin it to today's date.
    /// Factorial stores times as face-value local time regardless of any timezone
    /// suffix it may include in responses. We extract the HH:mm:ss digits directly
    /// and treat them as local time, ignoring any Z / +HH:mm offset entirely.
    private func parseTodayTime(_ str: String) -> Date? {
        // If there's a 'T', take what's after it; otherwise use the whole string
        var s = str
        if let i = s.firstIndex(of: "T") { s = String(s[s.index(after: i)...]) }

        // Take the first 8 characters (covers "HH:mm:ss"); strip any trailing Z
        let timeOnly = String(s.prefix(8)).replacingOccurrences(of: "Z", with: "")

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        // No explicit timeZone → defaults to TimeZone.current; face value = local time
        let cal = Calendar.current
        for fmt in ["HH:mm:ss", "HH:mm"] {
            df.dateFormat = fmt
            if let t = df.date(from: timeOnly) {
                let comps = cal.dateComponents([.hour, .minute, .second], from: t)
                return cal.date(bySettingHour: comps.hour ?? 0,
                                minute: comps.minute ?? 0,
                                second: comps.second ?? 0,
                                of: Date())
            }
        }

        print("[Factorial] WARNING: could not parse '\(str)'")
        return nil
    }

    private func extractErrorMessage(_ errors: [[String: Any]]) -> String {
        guard let first = errors.first else { return "Error desconocido" }
        if let msg = first["message"] as? String { return msg }
        if let msgs = first["messages"] as? [String], !msgs.isEmpty { return msgs.joined(separator: ", ") }
        return "Error desconocido"
    }
}
