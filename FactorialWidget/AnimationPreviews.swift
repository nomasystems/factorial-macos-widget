import SwiftUI

// MARK: - Brand colors (local copy for preview isolation)

private extension Color {
    static let factorialTeal    = Color(red: 0.07, green: 0.73, blue: 0.54)
    static let factorialWarning = Color(red: 0.98, green: 0.46, blue: 0.08)
}

// MARK: - Standalone copies for preview isolation

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
            try? await Task.sleep(for: .milliseconds(50))
            waveOpacity = 0.5
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                scale = 2.4
                waveOpacity = 0
            }
        }
    }
}

// MARK: - Completar animation (local copy matching ContentView logic)

private enum QuickClockState { case idle, loading, celebrating, done }

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
                            Capsule()
                                .trim(from: trimStart, to: min(trimStart + arc, 1.0))
                                .stroke(Color.factorialTeal,
                                        style: StrokeStyle(lineWidth: 1, lineCap: .round))
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

private struct CompletarBadge: View {
    let state: QuickClockState
    let onTap: () -> Void

    var body: some View {
        Group {
            switch state {
            case .idle:
                CompletarChip(isLoading: false, onTap: onTap)
            case .loading:
                CompletarChip(isLoading: true, onTap: {})
            case .celebrating:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.factorialTeal)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            case .done:
                Text("7h 00m")
                    .font(.system(size: 10, weight: .semibold).monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.factorialTeal.opacity(0.15))
                    .foregroundStyle(Color.factorialTeal)
                    .clipShape(Capsule())
                    .transition(.opacity)
            }
        }
        .frame(width: 72, alignment: .trailing)
    }
}

private struct CompletarPreviewRow: View {
    @State private var state: QuickClockState = .idle
    @State private var running = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("3 abr")
                    .font(.caption.weight(.medium).monospaced())
                Text(stateLabel)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            CompletarBadge(state: state, onTap: simulate)
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: state == .celebrating)
                .animation(.easeInOut(duration: 0.25), value: state == .loading)
                .animation(.easeInOut(duration: 0.4), value: state == .done)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { if state == .idle { simulate() } }
        .overlay(alignment: .bottom) {
            if state == .idle {
                Text("tap para simular")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, -14)
            } else if state == .done {
                Button("Reiniciar") { state = .idle }
                    .font(.system(size: 8))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, -14)
            }
        }
    }

    private var stateLabel: String {
        switch state {
        case .idle:       "pendiente"
        case .loading:    "registrando..."
        case .celebrating:"✓ fichado"
        case .done:       "completado"
        }
    }

    private func simulate() {
        guard !running else { return }
        running = true
        withAnimation { state = .loading }
        Task {
            try? await Task.sleep(for: .seconds(1))
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { state = .celebrating }
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { state = .done }
            running = false
        }
    }
}

// MARK: - Previews

#Preview("PingDot") {
    VStack(spacing: 40) {
        HStack(spacing: 32) {
            VStack(spacing: 8) {
                PingDot(color: .green, animate: true)
                Text("Activo").font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 8) {
                PingDot(color: .orange, animate: true)
                Text("Pausa").font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 8) {
                PingDot(color: .secondary, animate: false)
                Text("Idle").font(.caption).foregroundStyle(.secondary)
            }
        }

        Divider()

        HStack(spacing: 6) {
            Text("Fichando").font(.title3.bold())
            PingDot(color: .green, animate: true)
        }
    }
    .padding(40)
    .frame(width: 300)
}

#Preview("Completar → Checkmark → Chip") {
    VStack(spacing: 24) {
        Text("Toca la fila para simular")
            .font(.caption)
            .foregroundStyle(.secondary)

        CompletarPreviewRow()
    }
    .padding(32)
    .frame(width: 320)
}
