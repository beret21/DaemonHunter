import SwiftUI

struct SystemMetricsView: View {
    @ObservedObject var collector: SystemMetricsCollector = .shared
    private var m: SystemMetrics { collector.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("시스템 상태", systemImage: "thermometer.medium")
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 12) {
                cpuGauge
                memGauge
                thermalBadge
                fanBadge
            }

            loadRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - CPU gauge

    private var cpuGauge: some View {
        MetricGauge(
            label: "CPU",
            value: m.cpuUsagePercent / 100,
            display: String(format: "%.0f%%", m.cpuUsagePercent),
            color: cpuColor
        )
    }

    private var cpuColor: Color {
        if m.cpuUsagePercent > 80 { return .red }
        if m.cpuUsagePercent > 50 { return .orange }
        return .green
    }

    // MARK: - Memory gauge

    private var memGauge: some View {
        let ratio = m.memTotalGB > 0 ? m.memUsedGB / m.memTotalGB : 0
        return MetricGauge(
            label: "메모리",
            value: ratio,
            display: String(format: "%.1fG", m.memUsedGB),
            color: memColor
        )
    }

    private var memColor: Color {
        switch m.memPressure {
        case .normal:   return .green
        case .warning:  return .orange
        case .critical: return .red
        }
    }

    // MARK: - Thermal badge

    private var thermalBadge: some View {
        VStack(spacing: 3) {
            Text(m.thermalState.emoji)
                .font(.title3)
            Text("발열")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(m.thermalState.rawValue)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(thermalColor)
        }
        .frame(minWidth: 44)
    }

    private var thermalColor: Color {
        switch m.thermalState {
        case .nominal:  return .green
        case .fair:     return .yellow
        case .serious:  return .orange
        case .critical: return .red
        }
    }

    // MARK: - Fan badge

    private var fanBadge: some View {
        VStack(spacing: 3) {
            Image(systemName: "fan.fill")
                .font(.title3)
                .foregroundStyle(fanColor)
                .symbolEffect(.rotate, isActive: isFanActive)
            Text("팬")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let rpm = m.fanSpeedRPM {
                Text("\(rpm)rpm")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(fanColor)
                    .monospacedDigit()
            } else {
                Text("N/A")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minWidth: 44)
    }

    private var isFanActive: Bool { (m.fanSpeedRPM ?? 0) > 1000 }
    private var fanColor: Color {
        guard let rpm = m.fanSpeedRPM else { return .secondary }
        if rpm > 5000 { return .red }
        if rpm > 3000 { return .orange }
        return .primary
    }

    // MARK: - Load average row

    private var loadRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.bar.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("부하:")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(String(format: "%.2f", m.loadAvg1min))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(loadColor(m.loadAvg1min))
            Text("/")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(String(format: "%.2f", m.loadAvg5min))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(loadColor(m.loadAvg5min))
            Text("(1m/5m)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }

    private func loadColor(_ load: Double) -> Color {
        let cores = Double(ProcessInfo.processInfo.processorCount)
        let ratio = load / max(1, cores)
        if ratio > 1.5 { return .red }
        if ratio > 1.0 { return .orange }
        return .primary
    }
}

// MARK: - Mini gauge widget

private struct MetricGauge: View {
    let label: String
    let value: Double  // 0–1
    let display: String
    let color: Color

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .stroke(color.opacity(0.15), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: CGFloat(min(1, max(0, value))))
                    .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.4), value: value)
                Text(display)
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color)
            }
            .frame(width: 40, height: 40)

            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
