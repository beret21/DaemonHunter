import SwiftUI

struct TrendSummaryView: View {
    let analysis: TrendAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            headerRow
            if !analysis.processGroups.isEmpty { groupList }
            if !analysis.chronicLeakers.isEmpty { chronicList }
            if analysis.countHistory.count > 2 { sparklineRow }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 6) {
            Label("프로세스 추세", systemImage: "chart.xyaxis.line")
                .font(.subheadline.weight(.semibold))
            Spacer()
            patternBadge
        }
    }

    private var patternBadge: some View {
        HStack(spacing: 3) {
            Text(analysis.patternEmoji)
            Text(analysis.pattern.rawValue)
                .font(.caption.weight(.semibold))
                .foregroundStyle(patternColor)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(patternColor.opacity(0.1))
        .clipShape(Capsule())
    }

    private var patternColor: Color {
        switch analysis.pattern {
        case .stable:      return .green
        case .slowGrowing: return .yellow
        case .fastGrowing: return .red
        case .spike:       return .orange
        case .shrinking:   return .blue
        }
    }

    // MARK: - Process groups

    private var groupList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(analysis.processGroups.prefix(4)) { group in
                HStack(spacing: 6) {
                    Text(group.type)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    if group.deltaFromPrev != 0 {
                        Text(group.deltaFromPrev > 0 ? "+\(group.deltaFromPrev)" : "\(group.deltaFromPrev)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(group.deltaFromPrev > 0 ? .orange : .green)
                    }
                    Text("\(group.count)개")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Chronic leakers

    private var chronicList: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("장기 미종료 프로세스")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(analysis.chronicLeakers.prefix(3)) { leaker in
                HStack(spacing: 4) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("PID \(leaker.pid)")
                        .font(.caption2.monospacedDigit())
                    Text(leaker.ageFormatted)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.0fMB", leaker.avgMemMB))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("큐 \(Int(leaker.queueDwellMinutes))분")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Sparkline

    private var sparklineRow: some View {
        HStack(alignment: .center, spacing: 6) {
            Text("5분 추이")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Sparkline(
                values: analysis.countHistory.suffix(10).map { Double($0) }[...],
                color: patternColor
            )
            .frame(height: 20)

            if analysis.spikeProbability > 0.5 {
                Label("일시적", systemImage: "bolt.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - Mini sparkline

private struct Sparkline: View {
    let values: ArraySlice<Double>
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let mn = values.min() ?? 0
            let mx = values.max() ?? 1
            let range = max(1, mx - mn)
            let pts: [CGPoint] = values.enumerated().map { i, v in
                CGPoint(
                    x: w * Double(i) / Double(max(1, values.count - 1)),
                    y: h - h * (v - mn) / range
                )
            }

            Path { path in
                guard let first = pts.first else { return }
                path.move(to: first)
                for pt in pts.dropFirst() { path.addLine(to: pt) }
            }
            .stroke(color, lineWidth: 1.5)
        }
    }
}
