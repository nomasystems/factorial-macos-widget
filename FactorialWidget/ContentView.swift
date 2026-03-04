import SwiftUI

// MARK: - Time persistence

private enum TimePrefs {
    static let startHourKey = "lastClockInStartHour"
    static let startMinuteKey = "lastClockInStartMinute"
    static let endHourKey = "lastClockInEndHour"
    static let endMinuteKey = "lastClockInEndMinute"

    static func saveStart(_ date: Date) {
        let cal = Calendar.current
        UserDefaults.standard.set(cal.component(.hour, from: date), forKey: startHourKey)
        UserDefaults.standard.set(cal.component(.minute, from: date), forKey: startMinuteKey)
    }

    static func saveEnd(_ date: Date) {
        let cal = Calendar.current
        UserDefaults.standard.set(cal.component(.hour, from: date), forKey: endHourKey)
        UserDefaults.standard.set(cal.component(.minute, from: date), forKey: endMinuteKey)
    }

    static func loadStart() -> Date { time(hourKey: startHourKey, minuteKey: startMinuteKey, defaultHour: 8) }
    static func loadEnd() -> Date   { time(hourKey: endHourKey,   minuteKey: endMinuteKey,   defaultHour: 15) }

    private static func time(hourKey: String, minuteKey: String, defaultHour: Int) -> Date {
        let h = UserDefaults.standard.object(forKey: hourKey) != nil
            ? UserDefaults.standard.integer(forKey: hourKey)
            : defaultHour
        let m = UserDefaults.standard.integer(forKey: minuteKey)
        return Calendar.current.date(
            bySettingHour: h, minute: m, second: 0, of: Date()
        ) ?? Date()
    }
}

// MARK: - View

struct ContentView: View {
    @EnvironmentObject var service: FactorialService

    @State private var showPanel = false
    @State private var selectedDate = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
    @State private var startTime = TimePrefs.loadStart()
    @State private var endTime   = TimePrefs.loadEnd()
    @State private var isClockingIn = false
    @State private var errorMessage: String?
    @State private var authCode = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Factorial Clockin")
                    .font(.headline)
                Spacer()
                Image("NomaIcon")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 14)
                Text("🤍")
                    .font(.system(size: 8))
                Image("FactorialIcon")
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 16, height: 16)
                
                if service.isLoading || isClockingIn {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // Status / Error
            if let error = errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.red)
                        .font(.subheadline)
                    Text(error)
                        .font(.subheadline)
                        .foregroundColor(.red)
                    Spacer()
                    Button { errorMessage = nil } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            } else {
                if !service.status.isEmpty {
                    Text(service.status)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                }

                // Day progress bar — includes todayCompletedDuration + live shift
                let workday: TimeInterval = 8 * 3600
                let completed = service.todayCompletedDuration ?? 0
                if let os = service.openShift, !os.isBreak {
                    TimelineView(.periodic(from: .now, by: 1.0)) { tl in
                        let totalWorked = completed + tl.date.timeIntervalSince(os.clockIn)
                        TodayProgressRow(elapsed: min(totalWorked, workday), total: workday, isLive: true)
                    }
                } else if completed > 0 || service.openShift?.isBreak == true {
                    TodayProgressRow(elapsed: min(completed, workday), total: workday, isLive: false)
                }
            }

            // Proyecto (visible siempre, aplica a ambos botones de fichaje)
            if !service.projectWorkers.isEmpty {
                HStack {
                    Text("Proyecto")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("", selection: $service.selectedProjectWorkerId) {
                        ForEach(service.projectWorkers) { pw in
                            Text(pw.displayName).tag(pw.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider()
            }

            // Fichar ahora / Timer en curso / En pausa
            if let os = service.openShift {
                if os.isBreak {
                    // Break state — frozen accumulated work time
                    let completed = service.todayCompletedDuration ?? 0
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Circle().fill(Color.orange).frame(width: 7, height: 7)
                                Text("En pausa desde \(os.clockIn, style: .time)")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Text(formatDuration(completed))
                                .font(.system(.title3, design: .monospaced).bold())
                        }
                        Spacer()
                        Button(action: breakEnd) {
                            Image(systemName: "play.fill")
                                .foregroundColor(.white)
                                .padding(8)
                                .background(Color.green.opacity(0.9))
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        Button(action: clockOut) {
                            Image(systemName: "stop.fill")
                                .foregroundColor(.white)
                                .padding(8)
                                .background(Color.red.opacity(0.9))
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                } else {
                    // Active shift
                    TimelineView(.periodic(from: .now, by: 1.0)) { tl in
                        let elapsed = tl.date.timeIntervalSince(os.clockIn)
                        let totalWorked = (service.todayCompletedDuration ?? 0) + elapsed
                        let remaining = max(0, 8 * 3600 - totalWorked)
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    Circle().fill(Color.green).frame(width: 7, height: 7)
                                    Text("Desde \(os.clockIn, style: .time)")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Text(formatDuration(elapsed))
                                    .font(.system(.title3, design: .monospaced).bold())
                                Text("Restante \(formatDuration(remaining))")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(action: breakStart) {
                                Image(systemName: "pause.fill")
                                    .foregroundColor(.white)
                                    .padding(8)
                                    .background(Color.orange.opacity(0.9))
                                    .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                            Button(action: clockOut) {
                                Image(systemName: "stop.fill")
                                    .foregroundColor(.white)
                                    .padding(8)
                                    .background(Color.red.opacity(0.9))
                                    .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
            } else {
                Button(action: clockInNow) {
                    Label("Fichar ahora", systemImage: "play.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(MenuRowButtonStyle())
                .disabled(service.isLoading)
            }

            Divider()

            // Fichar (fecha manual)
            VStack(spacing: 2) {
                Button {
                    showPanel.toggle()
                    if !showPanel { errorMessage = nil }
                } label: {
                    Label("Fichar fecha/hora", systemImage: showPanel ? "chevron.up" : "calendar")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(MenuRowButtonStyle())
                .disabled(isClockingIn || service.isLoading)

                if showPanel {
                    VStack(spacing: 10) {
                        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                            GridRow {
                                Text("Fecha")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                DatePicker("", selection: $selectedDate, in: ...Date(), displayedComponents: .date)
                                    .labelsHidden()
                                    .datePickerStyle(.compact)
                            }
                            GridRow {
                                Text("Inicio")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                DatePicker("", selection: $startTime, displayedComponents: .hourAndMinute)
                                    .labelsHidden()
                                    .datePickerStyle(.compact)
                            }
                            GridRow {
                                Text("Fin")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                DatePicker("", selection: $endTime, displayedComponents: .hourAndMinute)
                                    .labelsHidden()
                                    .datePickerStyle(.compact)
                            }
                        }

                        Button("Confirmar") {
                            confirm()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .disabled(isClockingIn)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.05))
                }
            }

            Divider()

            // OAuth & settings
            VStack(spacing: 2) {
                Button(action: { service.openAuthorizationURL(); authCode = "" }) {
                    Label("Reautorizar OAuth", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(MenuRowButtonStyle())

                if service.needsAuth {
                    VStack(spacing: 6) {
                        TextField("Pega el código de autorización", text: $authCode)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                        if let error = errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button("Confirmar código") {
                            submitCode()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .disabled(authCode.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Salir", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(MenuRowButtonStyle())
            }
        }
        .frame(width: 260)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await service.checkStatus() }
        }
    }

    // MARK: - Actions

    private func confirm() {
        TimePrefs.saveStart(startTime)
        TimePrefs.saveEnd(endTime)
        isClockingIn = true
        errorMessage = nil
        Task {
            do {
                try await service.clockIn(date: selectedDate, startTime: startTime, endTime: endTime)
                showPanel = false
            } catch {
                errorMessage = error.localizedDescription
            }
            isClockingIn = false
        }
    }

    private func clockInNow() {
        errorMessage = nil
        Task {
            do { try await service.clockInNow() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func breakStart() {
        Task {
            do { try await service.breakStart() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func breakEnd() {
        Task {
            do { try await service.breakEnd() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func clockOut() {
        Task {
            do { try await service.clockOutNow() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    private func submitCode() {
        let code = authCode.trimmingCharacters(in: .whitespaces)
        authCode = ""
        errorMessage = nil
        Task {
            do {
                try await service.submitAuthorizationCode(code)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

}

// MARK: - Today Progress Row

struct TodayProgressRow: View {
    let elapsed: TimeInterval
    let total: TimeInterval
    let isLive: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isLive ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
            ProgressView(value: elapsed, total: total)
                .progressViewStyle(.linear)
                .tint(isLive ? .green : .secondary)
            Text(formatHM(elapsed))
                .font(.caption2)
                .monospacedDigit()
                .foregroundColor(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func formatHM(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        return String(format: "%d:%02d", s / 3600, (s % 3600) / 60)
    }
}

// MARK: - Button Style

struct MenuRowButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                (isHovered || configuration.isPressed)
                    ? Color.accentColor.opacity(0.12)
                    : Color.clear
            )
            .cornerRadius(4)
            .onHover { isHovered = $0 }
    }
}
