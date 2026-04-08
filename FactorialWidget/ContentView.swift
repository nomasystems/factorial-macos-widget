import SwiftUI

// MARK: - Brand colors

private extension Color {
    static let factorialRed     = Color(red: 0.88, green: 0.16, blue: 0.28)
    static let factorialTeal    = Color(red: 0.07, green: 0.73, blue: 0.54)
    static let factorialWarning = Color(red: 0.98, green: 0.46, blue: 0.08)
    static let arcTrack         = Color.primary.opacity(0.20)
}

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

// MARK: - Formatters

private func formatHHMM(_ interval: TimeInterval) -> String {
    let t = Int(max(0, interval))
    return String(format: "%d:%02d", t / 3600, (t % 3600) / 60)
}

private func formatHHMMSS(_ interval: TimeInterval) -> String {
    let s = Int(max(0, interval))
    return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
}

// MARK: - Arc Data (adapter from FactorialService → ArcView)

private struct ArcData {
    let shiftState: FactorialService.ShiftState
    let segments: [ShiftSegment]
    let now: Date
    let shiftStartDate: Date?
    let shiftEndDate: Date?

    var completedWorkSeconds: TimeInterval {
        segments.filter { !$0.isBreak && $0.end != nil }.reduce(0) {
            $0 + $1.end!.timeIntervalSince($1.start)
        }
    }

    var elapsedWorkSeconds: TimeInterval {
        switch shiftState {
        case .active:
            let ongoingStart = segments.last(where: { !$0.isBreak && $0.end == nil })?.start
            if let start = ongoingStart {
                return completedWorkSeconds + max(0, now.timeIntervalSince(start))
            }
            return completedWorkSeconds
        case .paused, .idle:
            return completedWorkSeconds
        }
    }

    var remainingSeconds: TimeInterval { max(0, 8 * 3600 - elapsedWorkSeconds) }
    var overtimeSeconds: TimeInterval  { max(0, elapsedWorkSeconds - 8 * 3600) }
    var isOvertime: Bool               { elapsedWorkSeconds > 8 * 3600 }

    @MainActor static func from(service: FactorialService, at now: Date) -> ArcData {
        let endDate = service.shiftSegments.compactMap { $0.end }.max()
        let startDate = service.shiftSegments.filter { !$0.isBreak }.first?.start
        return ArcData(
            shiftState: service.shiftState,
            segments: service.shiftSegments,
            now: now,
            shiftStartDate: startDate,
            shiftEndDate: endDate
        )
    }
}

// MARK: - Arc View

private struct ArcView: View {
    let data: ArcData
    let lineWidth: CGFloat
    let size: CGFloat

    private let workdaySeconds: TimeInterval = 8 * 3600
    private let arcSpan: CGFloat = 0.75
    private let arcStartAngle: Double = 135

    var body: some View {
        ZStack {
            segmentsLayer

            // Center timer
            Text(formatHHMM(data.elapsedWorkSeconds))
                .font(.system(size: size * 0.23, weight: .bold, design: .monospaced))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .frame(width: size * 0.65)

            // Bottom: start / end times
            VStack {
                Spacer()
                HStack {
                    timeLabel(data.shiftStartDate)
                    Spacer()
                    timeLabel(data.shiftState == .active ? data.now : data.shiftEndDate)
                }
                .font(.system(size: size * 0.10))
                .padding(.horizontal, size * 0.04)
                .offset(y: size * 0.10)
            }
        }
        .frame(width: size, height: size)
    }

    // Pill types
    private enum PillKind { case work, brk, overtime, remaining }
    private struct ArcItem { let duration: TimeInterval; let kind: PillKind }

    private func pillColor(_ kind: PillKind) -> Color {
        switch kind {
        case .work:      return .factorialTeal
        case .brk:       return .orange
        case .overtime:  return .factorialWarning
        case .remaining: return .arcTrack
        }
    }

    @ViewBuilder
    private var segmentsLayer: some View {
        let segs = data.segments
        let now = data.now
        let workDone = data.elapsedWorkSeconds
        let overtime = data.isOvertime

        let usedArc = overtime
            ? Double(arcSpan)
            : min(workDone / workdaySeconds, 1) * Double(arcSpan)

        let items: [ArcItem] = {
            var list: [ArcItem] = []
            for (i, seg) in segs.enumerated() {
                if i > 0, let prevEnd = segs[i - 1].end {
                    let gap = seg.start.timeIntervalSince(prevEnd)
                    if gap > 60 { list.append(ArcItem(duration: gap, kind: .remaining)) }
                }
                let dur = (seg.end ?? now).timeIntervalSince(seg.start)
                list.append(ArcItem(duration: dur, kind: seg.isBreak ? .brk : .work))
            }
            return list
        }()

        let totalElapsed = items.reduce(0.0) { $0 + $1.duration }
        let gap = CGFloat(lineWidth * 1.5) / (CGFloat.pi * (size - lineWidth))

        let specs: [(duration: TimeInterval, kind: PillKind)] = {
            guard !items.isEmpty, totalElapsed > 0, usedArc > 0 else {
                var r: [(TimeInterval, PillKind)] = []
                if usedArc > 0 { r.append((workDone, data.shiftState == .paused ? .brk : .work)) }
                if !overtime   { r.append((max(0, workdaySeconds - workDone), .remaining)) }
                return r
            }

            var result: [(TimeInterval, PillKind)] = []
            var cumWork: TimeInterval = 0

            for item in items {
                if item.kind == .remaining || item.kind == .brk {
                    result.append((item.duration, item.kind))
                } else if overtime && cumWork < workdaySeconds && cumWork + item.duration > workdaySeconds {
                    let normal = workdaySeconds - cumWork
                    let extra  = item.duration - normal
                    if normal > 0 { result.append((normal, .work)) }
                    if extra > 0  { result.append((extra, .overtime)) }
                    cumWork += item.duration
                } else if overtime && cumWork >= workdaySeconds {
                    result.append((item.duration, .overtime))
                    cumWork += item.duration
                } else {
                    result.append((item.duration, .work))
                    cumWork += item.duration
                }
            }

            if !overtime { result.append((max(0, workdaySeconds - workDone), .remaining)) }
            return result
        }()

        let numGaps = CGFloat(max(0, specs.count - 1))
        let availableArc = CGFloat(arcSpan) - numGaps * gap
        let durationTotal = specs.reduce(0.0) { $0 + $1.duration }

        let pills: [(from: CGFloat, to: CGFloat, kind: PillKind)] = {
            guard durationTotal > 0, availableArc > 0 else { return [] }
            var result: [(CGFloat, CGFloat, PillKind)] = []
            var cursor: CGFloat = 0
            for (i, spec) in specs.enumerated() {
                let width = CGFloat(spec.duration / durationTotal) * availableArc
                result.append((cursor, cursor + width, spec.kind))
                cursor += width + (i < specs.count - 1 ? gap : 0)
            }
            return result
        }()

        ForEach(Array(pills.enumerated()), id: \.offset) { _, pill in
            if pill.to > pill.from {
                Circle()
                    .trim(from: pill.from, to: pill.to)
                    .stroke(pillColor(pill.kind),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(arcStartAngle))
            }
        }
    }

    @ViewBuilder
    private func timeLabel(_ date: Date?) -> some View {
        if let d = date {
            Text(d, style: .time).foregroundStyle(.secondary)
        } else {
            Text("--:--").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Completar Chip

private struct CompletarChip: View {
    let isLoading: Bool
    let onTap: () -> Void

    @State private var trimStart: CGFloat = 0
    private let arc: CGFloat = 0.25
    private let cycle: Double = 0.9

    var body: some View {
        Button(action: onTap) {
            Text("Completar")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.factorialTeal.opacity(isLoading ? 0.45 : 1))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .overlay(
                    ZStack {
                        Capsule()
                            .stroke(Color.factorialTeal.opacity(isLoading ? 0.15 : 1), lineWidth: 1)
                        if isLoading {
                            // Main arc — stops at 1.0
                            Capsule()
                                .trim(from: trimStart, to: min(trimStart + arc, 1.0))
                                .stroke(Color.factorialTeal,
                                        style: StrokeStyle(lineWidth: 1, lineCap: .round))
                            // Wrap-around arc — appears when arc crosses the 0/1 seam
                            Capsule()
                                .trim(from: 0, to: max(0, trimStart + arc - 1.0))
                                .stroke(Color.factorialTeal,
                                        style: StrokeStyle(lineWidth: 1, lineCap: .round))
                        }
                    }
                )
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .task(id: isLoading) {
            guard isLoading else { trimStart = 0; return }
            while !Task.isCancelled {
                trimStart = 0
                withAnimation(.linear(duration: cycle)) { trimStart = 1.0 }
                try? await Task.sleep(for: .seconds(cycle))
            }
        }
    }
}

// MARK: - Ping Dot

private struct PingDot: View {
    let color: Color
    let animate: Bool

    @State private var scale: CGFloat = 1.0
    @State private var waveOpacity: Double = 0.0

    var body: some View {
        ZStack {
            if animate {
                Circle()
                    .fill(color)
                    .scaleEffect(scale)
                    .opacity(waveOpacity)
            }
            Circle()
                .fill(color)
        }
        .frame(width: 10, height: 10)
        .task {
            guard animate else { return }
            // Yield one frame so the view renders invisible before animation starts
            try? await Task.sleep(for: .milliseconds(50))
            waveOpacity = 0.5
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                scale = 2.4
                waveOpacity = 0
            }
        }
    }
}

// MARK: - View

struct ContentView: View {
    @EnvironmentObject var service: FactorialService

    @State private var selectedDate = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
    @State private var startTime = TimePrefs.loadStart()
    @State private var endTime   = TimePrefs.loadEnd()
    @State private var manualTimesInitialized = false
    @State private var isClockingIn = false
    @State private var errorMessage: String?
    @State private var authCode = ""

    // Template editing
    @State private var isEditingTemplate = false
    @State private var editTemplateStartHour: Int = 8
    @State private var editTemplateStartMinute: Int = 0
    @State private var editTemplateEndHour: Int = 15
    @State private var editTemplateEndMinute: Int = 0

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.dateFormat = "d MMM"
        return f
    }()

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header + Project ──
            headerView

            if !service.projectWorkers.isEmpty {
                projectPicker
            }

            Divider()

            // ── Error / Status ──
            if let error = errorMessage {
                errorView(error)
            } else if !service.status.isEmpty {
                Text(service.status)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }

            // ── PRIMARY: Today Status Block ──
            todayPanel
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            Divider()

            // ── SECONDARY: 10-Day Quick Summary ──
            if !service.recentDays.isEmpty {
                recentDaysSection
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                Divider()
            }

            // ── TERTIARY: Manual Clock-in ──
            manualClockInSection
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            Divider()

            // ── Settings ──
            settingsSection
        }
        .frame(width: 360)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await service.checkStatus() }
        }
    }

    // MARK: - Header

    private var headerView: some View {
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
    }

    // MARK: - Error

    private func errorView(_ error: String) -> some View {
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
    }

    // MARK: - Today Panel (Arc + Status + Actions)

    @ViewBuilder
    private var todayPanel: some View {
        if let os = service.openShift {
            if os.isBreak {
                pausedPanel(os)
            } else {
                TimelineView(.periodic(from: .now, by: 1.0)) { tl in
                    activePanel(os, now: tl.date)
                }
            }
        } else {
            idlePanel
        }
    }

    /// Status block replicating the medium widget layout: left text column + right arc
    private func statusBlock(arcData: ArcData) -> some View {
        let statusTitle: String
        let statusColor: Color
        switch service.shiftState {
        case .active: statusTitle = "Fichando"; statusColor = .green
        case .paused: statusTitle = "En pausa"; statusColor = .orange
        case .idle:   statusTitle = "Salida";   statusColor = .secondary
        }

        return HStack(alignment: .center, spacing: 0) {
            // Left column: status + time + buttons
            VStack(alignment: .leading, spacing: 0) {
                Text("Fichaje")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)

                HStack(spacing: 6) {
                    Text(statusTitle)
                        .font(.title3.bold())
                    PingDot(color: statusColor, animate: service.shiftState == .active)
                }

                Text(arcData.isOvertime
                     ? "Tiempo adicional \(formatHHMM(arcData.overtimeSeconds))"
                     : "Tiempo restante \(formatHHMM(arcData.remainingSeconds))")
                    .font(.caption)
                    .foregroundStyle(arcData.isOvertime ? .orange : .secondary)
                    .padding(.top, 2)
                    .padding(.bottom, 12)

                // Action buttons
                actionButtons

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Right column: arc
            ArcView(data: arcData, lineWidth: 8, size: 104)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch service.shiftState {
        case .idle:
            Button(action: clockInNow) {
                Label("Fichar", systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.factorialRed)
            .disabled(service.isLoading)
        case .active:
            HStack(spacing: 8) {
                Button(action: breakStart) {
                    Image(systemName: "pause.fill")
                        .font(.subheadline.weight(.medium))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                Button(action: clockOut) {
                    Label("Salida", systemImage: "stop.fill")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
            }
        case .paused:
            HStack(spacing: 8) {
                Button(action: clockOut) {
                    Image(systemName: "stop.fill")
                        .font(.subheadline.weight(.medium))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                Button(action: breakEnd) {
                    Label("Reanudar", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.factorialRed)
            }
        }
    }

    private func activePanel(_ os: OpenShift, now: Date) -> some View {
        statusBlock(arcData: ArcData.from(service: service, at: now))
    }

    private func pausedPanel(_ os: OpenShift) -> some View {
        statusBlock(arcData: ArcData.from(service: service, at: Date()))
    }

    private var idlePanel: some View {
        statusBlock(arcData: ArcData.from(service: service, at: Date()))
    }

    // MARK: - Project Picker

    private var projectPicker: some View {
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
    }

    // MARK: - 10-Day History

    private var pendingDaysCount: Int {
        service.recentDays.filter { !$0.isHoliday && $0.workedSeconds < 60
            && !service.celebratingDates.contains(Self.dateFmt.string(from: $0.date)) }.count
    }

    private var recentDaysSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Group {
                if isEditingTemplate {
                    // EDIT MODE: editable form
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Fichaje rápido")
                                .font(.subheadline.bold())
                            Spacer()
                            Button(action: saveTemplateChanges) {
                                Text("Guardar")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(.factorialTeal)
                        }
                        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                            GridRow {
                                Text("Inicio").font(.caption).foregroundColor(.secondary)
                                HStack(spacing: 0) {
                                    Stepper(value: $editTemplateStartHour, in: 0...23) {
                                        Text("\(editTemplateStartHour, format: .number.grouping(.never))")
                                            .font(.caption.monospaced()).frame(width: 20)
                                    }
                                    Text(":").font(.caption)
                                    Stepper(value: $editTemplateStartMinute, in: 0...59, step: 5) {
                                        Text("\(editTemplateStartMinute, format: .number.grouping(.never))")
                                            .font(.caption.monospaced()).frame(width: 20)
                                    }
                                }
                            }
                            GridRow {
                                Text("Fin").font(.caption).foregroundColor(.secondary)
                                HStack(spacing: 0) {
                                    Stepper(value: $editTemplateEndHour, in: 0...23) {
                                        Text("\(editTemplateEndHour, format: .number.grouping(.never))")
                                            .font(.caption.monospaced()).frame(width: 20)
                                    }
                                    Text(":").font(.caption)
                                    Stepper(value: $editTemplateEndMinute, in: 0...59, step: 5) {
                                        Text("\(editTemplateEndMinute, format: .number.grouping(.never))")
                                            .font(.caption.monospaced()).frame(width: 20)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    // LOCKED MODE: display-only with lock button
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Fichaje rápido")
                                .font(.subheadline.bold())
                            Spacer()
                            if pendingDaysCount == 0 {
                                Label("Todo al día", systemImage: "checkmark.circle.fill")
                                    .font(.caption.bold())
                                    .foregroundStyle(.green)
                            } else {
                                Label(pendingDaysCount == 1 ? "Te falta 1 día" : "Te faltan \(pendingDaysCount) días",
                                      systemImage: "exclamationmark.circle.fill")
                                    .font(.caption.bold())
                                    .foregroundStyle(.orange)
                            }
                        }
                        HStack {
                            let timeRange = String(format: "%02d:%02d–%02d:%02d",
                                                   service.quickClockStartHour, service.quickClockStartMinute,
                                                   service.quickClockEndHour, service.quickClockEndMinute)
                            Text("Plantilla: \(timeRange)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(action: {
                                editTemplateStartHour = service.quickClockStartHour
                                editTemplateStartMinute = service.quickClockStartMinute
                                editTemplateEndHour = service.quickClockEndHour
                                editTemplateEndMinute = service.quickClockEndMinute
                                isEditingTemplate = true
                            }) {
                                Image(systemName: "lock.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
            }
            .padding(.bottom, 10)

            // Day rows
            let days = service.recentDays.reversed()
            VStack(spacing: 16) {
                ForEach(Array(days), id: \.id) { day in
                    dayRow(day)
                }
            }
        }
    }

    private func dayRow(_ day: DaySummary) -> some View {
        let dateStr = Self.dateFmt.string(from: day.date)
        return VStack(spacing: 4) {
            HStack {
                Text(Self.dayFmt.string(from: day.date))
                    .font(.caption.weight(.medium).monospaced())
                Spacer()
                dayBadge(day)
                    .animation(.spring(response: 0.35, dampingFraction: 0.7),
                               value: service.celebratingDates.contains(dateStr))
            }
            linearBar(day)
                .frame(height: 5)
        }
    }

    @ViewBuilder
    private func dayBadge(_ day: DaySummary) -> some View {
        let dateStr = Self.dateFmt.string(from: day.date)

        if day.isHoliday {
            Label(day.holidayName ?? "Festivo", systemImage: "moon.fill")
                .font(.system(size: 9, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.12))
                .foregroundStyle(.primary.opacity(0.6))
                .clipShape(Capsule())
                .frame(width: 72, alignment: .trailing)
        } else if service.celebratingDates.contains(dateStr) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.factorialTeal)
                .frame(width: 72, alignment: .trailing)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        } else if day.workedSeconds < 60 {
            CompletarChip(isLoading: service.quickClockingDates.contains(dateStr)) {
                Task {
                    do { try await service.clockInFullDay(date: dateStr) }
                    catch { errorMessage = error.localizedDescription }
                }
            }
            .frame(width: 72, alignment: .trailing)
        } else {
            hoursChip(day.workedSeconds)
                .frame(width: 72, alignment: .trailing)
        }
    }

    // MARK: - Linear progress bar

    private let workdaySeconds: TimeInterval = 8 * 3600

    private func linearBar(_ day: DaySummary) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height

            if day.isHoliday || day.segments.isEmpty {
                Capsule().fill(Color.primary.opacity(0.05))
            } else {
                let totalRef = max(workdaySeconds, day.workedSeconds)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    ForEach(Array(day.segments.enumerated()), id: \.offset) { _, seg in
                        if let end = seg.end {
                            let duration = end.timeIntervalSince(seg.start)
                            let segStart = segmentOffset(seg, in: day.segments)
                            let x = CGFloat(segStart / totalRef) * width
                            let w = max(2, CGFloat(duration / totalRef) * width)
                            let color: Color = seg.isBreak ? .orange : .factorialTeal
                            Capsule()
                                .fill(color)
                                .frame(width: w, height: height)
                                .offset(x: x)
                        }
                    }
                }
            }
        }
    }

    private func segmentOffset(_ seg: ShiftSegment, in segments: [ShiftSegment]) -> TimeInterval {
        guard let first = segments.first else { return 0 }
        return seg.start.timeIntervalSince(first.start)
    }

    private func hoursChip(_ seconds: TimeInterval) -> some View {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let text = String(format: "%d:%02d", h, m)
        let color: Color = seconds < 60 ? .secondary
            : seconds < 7 * 3600 ? .factorialWarning
            : .factorialTeal

        return Text(text)
            .font(.system(size: 10, weight: .semibold).monospaced())
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    // MARK: - Manual Clock-in

    private var manualClockInSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fichaje manual")
                .font(.subheadline.bold())

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("Fecha").font(.caption).foregroundColor(.secondary)
                    DatePicker("", selection: $selectedDate, in: ...Date(), displayedComponents: .date)
                        .labelsHidden().datePickerStyle(.compact)
                }
                GridRow {
                    Text("Inicio").font(.caption).foregroundColor(.secondary)
                    DatePicker("", selection: $startTime, displayedComponents: .hourAndMinute)
                        .labelsHidden().datePickerStyle(.compact)
                }
                GridRow {
                    Text("Fin").font(.caption).foregroundColor(.secondary)
                    DatePicker("", selection: $endTime, displayedComponents: .hourAndMinute)
                        .labelsHidden().datePickerStyle(.compact)
                }
            }

            HStack {
                Spacer()
                Button(action: confirm) {
                    if isClockingIn {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 16, height: 16)
                    } else {
                        Label("Registrar fichaje", systemImage: "calendar.badge.checkmark")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 4)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.factorialRed)
                .disabled(isClockingIn || service.isLoading)
            }
        }
        .onAppear { syncManualTimesFromTemplate() }
    }

    /// Sync manual clock-in times from the shared template (once on first appear)
    private func syncManualTimesFromTemplate() {
        guard !manualTimesInitialized else { return }
        manualTimesInitialized = true
        let cal = Calendar.current
        if let s = cal.date(bySettingHour: service.quickClockStartHour, minute: service.quickClockStartMinute, second: 0, of: Date()) {
            startTime = s
        }
        if let e = cal.date(bySettingHour: service.quickClockEndHour, minute: service.quickClockEndMinute, second: 0, of: Date()) {
            endTime = e
        }
    }

    // MARK: - Settings

    private var settingsSection: some View {
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
                    Button("Confirmar código") { submitCode() }
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

    // MARK: - Actions

    private func saveTemplateChanges() {
        service.quickClockStartHour = editTemplateStartHour
        service.quickClockStartMinute = editTemplateStartMinute
        service.quickClockEndHour = editTemplateEndHour
        service.quickClockEndMinute = editTemplateEndMinute

        // Sync manual form with new template values
        let cal = Calendar.current
        if let s = cal.date(bySettingHour: editTemplateStartHour, minute: editTemplateStartMinute, second: 0, of: Date()) {
            startTime = s
        }
        if let e = cal.date(bySettingHour: editTemplateEndHour, minute: editTemplateEndMinute, second: 0, of: Date()) {
            endTime = e
        }

        isEditingTemplate = false
    }

    private func confirm() {
        TimePrefs.saveStart(startTime)
        TimePrefs.saveEnd(endTime)
        isClockingIn = true
        errorMessage = nil
        Task {
            do {
                try await service.clockIn(date: selectedDate, startTime: startTime, endTime: endTime)
                // Reset manual form to template values after successful clock-in
                let cal = Calendar.current
                if let s = cal.date(bySettingHour: service.quickClockStartHour, minute: service.quickClockStartMinute, second: 0, of: Date()) {
                    await MainActor.run { startTime = s }
                }
                if let e = cal.date(bySettingHour: service.quickClockEndHour, minute: service.quickClockEndMinute, second: 0, of: Date()) {
                    await MainActor.run { endTime = e }
                }
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

    private func submitCode() {
        let code = authCode.trimmingCharacters(in: .whitespaces)
        authCode = ""
        errorMessage = nil
        Task {
            do { try await service.submitAuthorizationCode(code) }
            catch { errorMessage = error.localizedDescription }
        }
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
