import Foundation
import AppKit
import os

private let logger = Logger(subsystem: "com.factorial.widget", category: "FactorialService")

struct ProjectWorker: Identifiable, Equatable {
    let id: Int       // project_worker_id (usado en time-records)
    let name: String

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

    private let clientId = ProcessInfo.processInfo.environment["FACTORIAL_CLIENT_ID"] ?? ""
    private let clientSecret = ProcessInfo.processInfo.environment["FACTORIAL_CLIENT_SECRET"] ?? ""

    // MARK: - Constants

    private enum K {
        static let source = "desktop"
        static let locationType = "work_from_home"
        static let apiVersion = "2025-01-01"
        static let projectWorkerKey = "selectedProjectWorkerId"
        static let employeeIdKey = "cachedEmployeeId"
    }

    // MARK: - URLSession with timeout

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    // MARK: - Token cache

    private var cachedAccessToken: String?
    private var tokenExpiresAt: Date?

    // MARK: - Published state

    @Published var status: String = "Comprobando..."
    @Published var isLoading = false
    @Published var needsAuth = false
    @Published var projectWorkers: [ProjectWorker] = []
    @Published var employeeId: Int = 0
    @Published var userEmail: String = ""
    @Published var openShift: OpenShift?
    @Published var todayCompletedDuration: TimeInterval? = nil
    enum ShiftState { case idle, active, paused }
    @Published var menuBarTimer: String = ""
    @Published var shiftState: ShiftState = .idle
    private var menuBarTimerHandle: Timer?

    // Shift segments for arc visualization
    @Published var shiftSegments: [ShiftSegment] = []
    private var workdayStart: Date? = nil

    // 10-day history
    @Published var recentDays: [DaySummary] = []

    // Quick clock-in state
    @Published var quickClockingDates: Set<String> = []   // in-flight API calls
    @Published var celebratingDates: Set<String> = []     // checkmark (~1.5s)

    @Published var quickClockStartHour: Int {
        didSet { UserDefaults.standard.set(quickClockStartHour, forKey: "quickClockStartHour") }
    }
    @Published var quickClockStartMinute: Int {
        didSet { UserDefaults.standard.set(quickClockStartMinute, forKey: "quickClockStartMinute") }
    }
    @Published var quickClockEndHour: Int {
        didSet { UserDefaults.standard.set(quickClockEndHour, forKey: "quickClockEndHour") }
    }
    @Published var quickClockEndMinute: Int {
        didSet { UserDefaults.standard.set(quickClockEndMinute, forKey: "quickClockEndMinute") }
    }

    @Published var selectedProjectWorkerId: Int {
        didSet { UserDefaults.standard.set(selectedProjectWorkerId, forKey: K.projectWorkerKey) }
    }

    init() {
        let saved = UserDefaults.standard.object(forKey: K.projectWorkerKey)
        selectedProjectWorkerId = saved != nil
            ? UserDefaults.standard.integer(forKey: K.projectWorkerKey)
            : 0

        let ud = UserDefaults.standard
        quickClockStartHour = ud.object(forKey: "quickClockStartHour") != nil ? ud.integer(forKey: "quickClockStartHour") : 8
        quickClockStartMinute = ud.integer(forKey: "quickClockStartMinute")
        quickClockEndHour = ud.object(forKey: "quickClockEndHour") != nil ? ud.integer(forKey: "quickClockEndHour") : 15
        quickClockEndMinute = ud.integer(forKey: "quickClockEndMinute")

        Task { await checkStatus() }
    }

    // MARK: - HTTP helper

    private func performRequest(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FactorialError.apiError("Sin respuesta HTTP")
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 { throw FactorialError.missingTokens }
            let body = String(data: data, encoding: .utf8) ?? ""
            throw FactorialError.apiError("HTTP \(http.statusCode): \(body)")
        }
        return data
    }

    // MARK: - Token management

    func getAccessToken() async throws -> String {
        if let token = cachedAccessToken, let exp = tokenExpiresAt, Date() < exp {
            return token
        }
        let token = try await refreshAccessToken()
        cachedAccessToken = token
        let expiresIn = TokenStore.shared.load().expires_in ?? 7200
        tokenExpiresAt = Date().addingTimeInterval(TimeInterval(max(expiresIn - 60, 60)))
        return token
    }

    // MARK: - Check status

    func checkStatus() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            logger.info("checkStatus start")
            let token = try await getAccessToken()
            logger.info("token ok")

            let fetchedId = try await fetchMyEmployeeId(accessToken: token)
            logger.info("employeeId=\(fetchedId)")
            if fetchedId != employeeId {
                employeeId = fetchedId
                UserDefaults.standard.set(fetchedId, forKey: K.employeeIdKey)
            }

            let result = try await fetchStatusData(accessToken: token, employeeId: employeeId)
            logger.info("done: \(result.workers.count) workers, openShift=\(String(describing: result.openShift))")

            projectWorkers = result.workers
            if !result.workers.isEmpty,
               !result.workers.contains(where: { $0.id == selectedProjectWorkerId }) {
                selectedProjectWorkerId = result.workers[0].id
            }
            openShift = result.openShift
            todayCompletedDuration = result.todayCompletedDuration
            shiftSegments = result.segments
            workdayStart = result.workdayStart

            // Fetch holiday map and build 10-day history
            let cal = Calendar.current
            let tenDaysAgoDate = cal.date(byAdding: .day, value: -10, to: cal.startOfDay(for: Date()))!
            let holidayMap = await fetchHolidayMap(accessToken: token, employeeId: employeeId, from: tenDaysAgoDate, to: Date())
            recentDays = buildRecentDays(recentNodes: result.recentNodes, holidayMap: holidayMap)

            updateMenuBarTimer()
            status = ""
            needsAuth = false
        } catch FactorialError.missingTokens {
            cachedAccessToken = nil
            tokenExpiresAt = nil
            let wasAlreadyNeedingAuth = needsAuth
            needsAuth = true
            status = "🔑 Re-autorización necesaria"
            if !wasAlreadyNeedingAuth {
                OTelClient.shared.track("auth_required", [
                    "auth.client_id_set": clientId.isEmpty ? "false" : "true",
                    "auth.has_existing_tokens": TokenStore.shared.load().refresh_token.map { !$0.isEmpty } == true ? "true" : "false"
                ])
            }
        } catch {
            status = "❌ \(error.localizedDescription)"
            OTelClient.shared.track("api_error", [
                "error.operation": "check_status",
                "error.message": error.localizedDescription
            ])
        }
    }

    func clockIn(date: Date, startTime: Date, endTime: Date) async throws {
        let token = try await getAccessToken()
        let shiftId = try await createShift(date: date, startTime: startTime, endTime: endTime, accessToken: token)
        try await createTimeRecord(shiftId: shiftId, projectWorkerId: selectedProjectWorkerId, accessToken: token)
        status = "✅ Fichado (\(isoDate(date)))"
        let isToday = Calendar.current.isDateInToday(date)
        OTelClient.shared.track("manual_clock_in", [
            "project.worker.id": String(selectedProjectWorkerId),
            "entry.is_today": isToday ? "true" : "false"
        ])
    }

    // MARK: - Clock In/Out Now (GraphQL mutations)

    func clockInNow() async throws {
        let token = try await getAccessToken()

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
        let variables: [String: Any] = [
            "now": iso8601WithTimezone(Date()),
            "source": K.source,
            "locationType": K.locationType,
            "projectWorkerId": selectedProjectWorkerId
        ]

        try await executeGraphQLMutation(
            operationName: "ClockIn",
            query: mutation,
            variables: variables,
            resultKey: "clockInAttendanceShift",
            accessToken: token
        )

        OTelClient.shared.track("clock_in_now", [
            "project.worker.id": String(selectedProjectWorkerId)
        ])
        await checkStatus()
    }

    func breakStart() async throws {
        let token = try await getAccessToken()

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
        let variables: [String: Any] = [
            "now": iso8601WithTimezone(Date()),
            "source": K.source
        ]

        try await executeGraphQLMutation(
            operationName: "BreakStart",
            query: mutation,
            variables: variables,
            resultKey: "breakStartAttendanceShift",
            accessToken: token
        )

        OTelClient.shared.track("break_start")
        await checkStatus()
    }

    func breakEnd() async throws {
        let token = try await getAccessToken()

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
            "source": K.source
        ]
        if selectedProjectWorkerId > 0 {
            variables["projectWorkerId"] = selectedProjectWorkerId
        }

        try await executeGraphQLMutation(
            operationName: "BreakEnd",
            query: mutation,
            variables: variables,
            resultKey: "breakEndAttendanceShift",
            accessToken: token
        )

        OTelClient.shared.track("break_end")
        await checkStatus()
    }

    func clockOutNow() async throws {
        let token = try await getAccessToken()

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
        let variables: [String: Any] = [
            "now": iso8601WithTimezone(Date()),
            "source": K.source
        ]

        try await executeGraphQLMutation(
            operationName: "ClockOut",
            query: mutation,
            variables: variables,
            resultKey: "clockOutAttendanceShift",
            accessToken: token
        )

        let workedSeconds = (todayCompletedDuration ?? 0) + (openShift.map { Date().timeIntervalSince($0.clockIn) } ?? 0)
        OTelClient.shared.track("clock_out", [
            "worked.seconds": String(Int(workedSeconds))
        ])
        await checkStatus()
    }

    // MARK: - GraphQL mutation helper

    @discardableResult
    private func executeGraphQLMutation(
        operationName: String,
        query: String,
        variables: [String: Any],
        resultKey: String,
        accessToken: String
    ) async throws -> [String: Any]? {
        let url = URL(string: "\(Self.baseURL)/graphql")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "operationName": operationName,
            "variables": variables,
            "query": query
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await performRequest(request)

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FactorialError.apiError("\(operationName): respuesta inválida")
        }
        if let gqlErrors = root["errors"] as? [[String: Any]], !gqlErrors.isEmpty {
            throw FactorialError.apiError(gqlErrors.first?["message"] as? String ?? "Error de API")
        }
        guard let dataObj = root["data"] as? [String: Any],
              let mutations = dataObj["attendanceMutations"] as? [String: Any],
              let result = mutations[resultKey] as? [String: Any] else {
            throw FactorialError.apiError("\(operationName): respuesta inesperada")
        }
        if let errors = result["errors"] as? [[String: Any]], !errors.isEmpty {
            let msg = extractErrorMessage(errors)
            OTelClient.shared.track("api_error", [
                "error.operation": operationName.lowercased(),
                "error.message": msg
            ])
            throw FactorialError.apiError(msg)
        }

        return result
    }

    // MARK: - OAuth

    func openAuthorizationURL() {
        OTelClient.shared.track("oauth_flow_started", [
            "auth.client_id_set":       clientId.isEmpty     ? "false" : "true",
            "auth.client_secret_set":   clientSecret.isEmpty ? "false" : "true",
            "auth.has_existing_tokens": TokenStore.shared.load().refresh_token.map { !$0.isEmpty } == true ? "true" : "false"
        ])
        let authURLString = "\(Self.baseURL)/oauth/authorize?client_id=\(clientId)&redirect_uri=urn:ietf:wg:oauth:2.0:oob&response_type=code&scope=read%20write"
        guard let authURL = URL(string: authURLString) else { return }
        NSWorkspace.shared.open(authURL)
    }

    func submitAuthorizationCode(_ code: String) async throws {
        let isReauth = TokenStore.shared.load().refresh_token.map { !$0.isEmpty } == true
        try await exchangeCode(code)
        cachedAccessToken = nil
        tokenExpiresAt = nil
        needsAuth = false
        OTelClient.shared.track("oauth_flow_completed", [
            "auth.type": isReauth ? "reauth" : "initial_auth"
        ])
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

        let data = try await performRequest(request)
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

        let data: Data
        do {
            data = try await performRequest(request)
        } catch FactorialError.missingTokens {
            // 401 from the token endpoint (unusual — normally it's 400)
            OTelClient.shared.track("token_refresh_failed", [
                "error.http_status":       "401",
                "error.client_id_set":     clientId.isEmpty     ? "false" : "true",
                "error.client_secret_set": clientSecret.isEmpty ? "false" : "true"
            ], severity: .error)
            throw FactorialError.missingTokens
        } catch FactorialError.apiError(let msg) {
            // Typically HTTP 400 when the refresh token is expired or revoked.
            // msg contains "HTTP 400: <response body>" — truncated to 300 chars.
            OTelClient.shared.track("token_refresh_failed", [
                "error.message":           String(msg.prefix(300)),
                "error.client_id_set":     clientId.isEmpty     ? "false" : "true",
                "error.client_secret_set": clientSecret.isEmpty ? "false" : "true"
            ], severity: .error)
            throw FactorialError.missingTokens
        } catch {
            OTelClient.shared.track("token_refresh_failed", [
                "error.message":       String(error.localizedDescription.prefix(300)),
                "error.client_id_set": clientId.isEmpty ? "false" : "true"
            ], severity: .error)
            throw FactorialError.missingTokens
        }
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

    // MARK: - REST API

    func createShift(date: Date, startTime: Date, endTime: Date, accessToken: String) async throws -> Int {
        let dateStr = isoDate(date)
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date)
        let isoWeekday = weekday == 1 ? 7 : weekday - 1

        let url = URL(string: "\(Self.baseURL)/api/\(K.apiVersion)/resources/attendance/shifts")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "employee_id": employeeId,
            "date": dateStr,
            "workable": true,
            "location_type": K.locationType,
            "source": "api",
            "clock_in": "\(dateStr)T\(hhmm(startTime)):00Z",
            "clock_out": "\(dateStr)T\(hhmm(endTime)):00Z",
            "day": isoWeekday,
            "reference_date": dateStr
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await performRequest(request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? Int else {
            let msg = String(data: data, encoding: .utf8) ?? "Error desconocido"
            throw FactorialError.apiError("Error creando turno: \(msg)")
        }
        return id
    }

    func createTimeRecord(shiftId: Int, projectWorkerId: Int, accessToken: String) async throws {
        let url = URL(string: "\(Self.baseURL)/api/\(K.apiVersion)/resources/project-management/time-records")!
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

        let data = try await performRequest(request)
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

        let data = try await performRequest(request)
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
        let segments: [ShiftSegment]
        let workdayStart: Date?
        let recentNodes: [[String: Any]]
    }

    private func fetchStatusData(accessToken: String, employeeId: Int) async throws -> StatusData {
        let url = URL(string: "\(Self.baseURL)/graphql")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let cal = Calendar.current
        let today = isoDate(Date())
        let yesterday = isoDate(cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date()))!)
        let tenDaysAgo = isoDate(cal.date(byAdding: .day, value: -10, to: cal.startOfDay(for: Date()))!)

        let query = """
        query CheckStatus($employeeIds: [Int!]!, $today: ISO8601Date!, $tenDaysAgo: ISO8601Date!, $yesterday: ISO8601Date!, $assigned: Boolean!, $onlyActiveProjects: Boolean!) {
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
            recentShifts: shiftsConnection(employeeIds: $employeeIds, startOn: $tenDaysAgo, endOn: $yesterday) {
              nodes { date clockIn clockOut workable }
            }
          }
        }
        """
        let body: [String: Any] = [
            "operationName": "CheckStatus",
            "variables": [
                "employeeIds": [employeeId],
                "today": today,
                "tenDaysAgo": tenDaysAgo,
                "yesterday": yesterday,
                "assigned": true,
                "onlyActiveProjects": true
            ],
            "query": query
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await performRequest(request)

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
            return ProjectWorker(id: id, name: name)
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

        // Parse today's shifts into segments
        let todayNodes = (att?["todayShifts"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        let completedSegments: [ShiftSegment] = todayNodes.compactMap { node in
            guard let inStr = node["clockIn"] as? String,
                  let ci = parseTodayTime(inStr),
                  let outStr = node["clockOut"] as? String,
                  let co = parseTodayTime(outStr) else { return nil }
            let isBreak = !(node["workable"] as? Bool ?? true)
            return ShiftSegment(start: ci, end: co, isBreak: isBreak)
        }.sorted { $0.start < $1.start }

        var allSegments = completedSegments
        if let shift = openShift {
            allSegments.append(ShiftSegment(start: shift.clockIn, end: nil, isBreak: shift.isBreak))
        }

        let workdayStart = allSegments.filter { !$0.isBreak }.first?.start

        let completedDuration = completedSegments.filter { !$0.isBreak }.reduce(0.0) { acc, seg in
            guard let end = seg.end else { return acc }
            return acc + end.timeIntervalSince(seg.start)
        }
        let todayCompletedDuration: TimeInterval? = completedDuration > 0 ? completedDuration : nil

        // Recent shifts for 10-day history
        let recentNodes = ((att?["recentShifts"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []

        return StatusData(workers: workers, openShift: openShift, todayCompletedDuration: todayCompletedDuration,
                          segments: allSegments, workdayStart: workdayStart, recentNodes: recentNodes)
    }

    // MARK: - Quick clock-in (full day for past dates)

    func clockInFullDay(date: String) async throws {
        quickClockingDates.insert(date)
        defer { quickClockingDates.remove(date) }

        let token = try await getAccessToken()

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        guard let dayDate = df.date(from: date) else {
            throw FactorialError.apiError("Fecha inválida: \(date)")
        }

        let cal = Calendar.current
        let startDate = cal.date(bySettingHour: quickClockStartHour, minute: quickClockStartMinute, second: 0, of: dayDate)!
        let endDate = cal.date(bySettingHour: quickClockEndHour, minute: quickClockEndMinute, second: 0, of: dayDate)!

        let shiftId = try await createShift(date: dayDate, startTime: startDate, endTime: endDate, accessToken: token)
        try await createTimeRecord(shiftId: shiftId, projectWorkerId: selectedProjectWorkerId, accessToken: token)

        let isToday = Calendar.current.isDateInToday(dayDate)
        OTelClient.shared.track("quick_clock_in", [
            "project.worker.id": String(selectedProjectWorkerId),
            "entry.is_today": isToday ? "true" : "false"
        ])

        celebratingDates.insert(date)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.celebratingDates.remove(date)
        }

        await checkStatus()
    }

    // MARK: - Holiday calendar

    private func fetchHolidayMap(accessToken: String, employeeId: Int, from: Date, to: Date) async -> [Date: String] {
        let startOn = isoDate(from)
        let endOn = isoDate(to)
        guard let url = URL(string: "\(Self.baseURL)/attendance/calendar?start_on=\(startOn)&end_on=\(endOn)&id=\(employeeId)") else { return [:] }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let rawDays = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [:] }

        let cal = Calendar.current
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")

        var map: [Date: String] = [:]
        for day in rawDays {
            let isLeave = day["is_leave"] as? Bool ?? false
            let isLaborable = day["is_laborable"] as? Bool ?? true
            if isLeave || !isLaborable {
                if let dateStr = day["date"] as? String,
                   let date = df.date(from: dateStr) {
                    let leaves = day["leaves"] as? [[String: Any]] ?? []
                    let name = leaves.first?["name"] as? String ?? "Festivo"
                    map[cal.startOfDay(for: date)] = name
                }
            }
        }
        return map
    }

    // MARK: - Recent days computation

    private func buildRecentDays(recentNodes: [[String: Any]], holidayMap: [Date: String]) -> [DaySummary] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")

        var shiftsByDate: [Date: [[String: Any]]] = [:]
        for node in recentNodes {
            guard let dateStr = node["date"] as? String,
                  let date = df.date(from: dateStr) else { continue }
            let key = cal.startOfDay(for: date)
            shiftsByDate[key, default: []].append(node)
        }

        var days: [DaySummary] = []
        for offset in 1...10 {
            guard let day = cal.date(byAdding: .day, value: -offset, to: todayStart) else { continue }
            let weekday = cal.component(.weekday, from: day)
            guard weekday >= 2 && weekday <= 6 else { continue }

            let holidayName = holidayMap[day]
            let nodes = shiftsByDate[day] ?? []

            var workedSeconds: TimeInterval = 0
            var segments: [ShiftSegment] = []
            for node in nodes {
                guard let inStr = node["clockIn"] as? String,
                      let outStr = node["clockOut"] as? String else { continue }
                let isBreak = !(node["workable"] as? Bool ?? true)
                let ciTime = parseTimeOnDate(inStr, on: day)
                let coTime = parseTimeOnDate(outStr, on: day)
                if let ci = ciTime, let co = coTime {
                    segments.append(ShiftSegment(start: ci, end: co, isBreak: isBreak))
                    if !isBreak { workedSeconds += co.timeIntervalSince(ci) }
                }
            }
            segments.sort { $0.start < $1.start }
            days.append(DaySummary(date: day, workedSeconds: workedSeconds, segments: segments, holidayName: holidayName))
        }
        return days.sorted { $0.date < $1.date }
    }

    /// Parse a Factorial time string and pin it to a specific date (not necessarily today).
    private func parseTimeOnDate(_ str: String, on date: Date) -> Date? {
        var s = str
        if let i = s.firstIndex(of: "T") { s = String(s[s.index(after: i)...]) }
        let timeOnly = String(s.prefix(8)).replacingOccurrences(of: "Z", with: "")

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        let cal = Calendar.current
        for fmt in ["HH:mm:ss", "HH:mm"] {
            df.dateFormat = fmt
            if let t = df.date(from: timeOnly) {
                let comps = cal.dateComponents([.hour, .minute, .second], from: t)
                return cal.date(bySettingHour: comps.hour ?? 0,
                                minute: comps.minute ?? 0,
                                second: comps.second ?? 0,
                                of: date)
            }
        }
        return nil
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

        logger.warning("Could not parse '\(str, privacy: .public)'")
        return nil
    }

    private func extractErrorMessage(_ errors: [[String: Any]]) -> String {
        guard let first = errors.first else { return "Error desconocido" }
        if let msg = first["message"] as? String { return msg }
        if let msgs = first["messages"] as? [String], !msgs.isEmpty { return msgs.joined(separator: ", ") }
        return "Error desconocido"
    }

    // MARK: - Menu bar timer

    private func updateMenuBarTimer() {
        menuBarTimerHandle?.invalidate()
        menuBarTimerHandle = nil

        guard let shift = openShift else {
            shiftState = .idle
            menuBarTimer = ""
            return
        }

        if shift.isBreak {
            // Paused: show frozen timer with accumulated time only
            shiftState = .paused
            let s = Int(max(0, todayCompletedDuration ?? 0))
            menuBarTimer = String(format: "%d:%02d", s / 3600, (s % 3600) / 60)
        } else {
            // Active: tick every 60s
            shiftState = .active
            tickMenuBarTimer(clockIn: shift.clockIn)
            menuBarTimerHandle = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let shift = self.openShift, !shift.isBreak else { return }
                    self.tickMenuBarTimer(clockIn: shift.clockIn)
                }
            }
        }
    }

    private func tickMenuBarTimer(clockIn: Date) {
        let elapsed = (todayCompletedDuration ?? 0) + Date().timeIntervalSince(clockIn)
        let s = Int(max(0, elapsed))
        menuBarTimer = String(format: "%d:%02d", s / 3600, (s % 3600) / 60)
    }
}
