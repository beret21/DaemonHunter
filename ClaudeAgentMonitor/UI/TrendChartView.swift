import SwiftUI
import Charts

struct TrendChartView: View {
    let trend: TrendAnalysis
    let dbSnapshots: [SnapshotRecord]

    // DB 기록이 있으면 DB 데이터, 없으면 인메모리 히스토리 사용
    private var chartPoints: [ChartPoint] {
        if dbSnapshots.count > 2 {
            return dbSnapshots.map {
                ChartPoint(time: $0.timestamp, total: $0.totalCount, leaked: $0.leakedCount)
            }
        }
        // 인메모리: 각 스냅샷 인덱스 → 상대 시각 (30s 간격 가정)
        let interval = AppSettings.monitorIntervalSeconds
        let now = Date()
        let totalPts = trend.countHistory.count
        return trend.countHistory.indices.map { i in
            let offset = Double(totalPts - 1 - i) * interval
            return ChartPoint(
                time: now.addingTimeInterval(-offset),
                total: trend.countHistory[i],
                leaked: i < trend.leakHistory.count ? trend.leakHistory[i] : 0
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label("트렌드", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                patternBadge
            }

            if chartPoints.isEmpty {
                Text("데이터 수집 중...")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(height: 60, alignment: .center)
                    .frame(maxWidth: .infinity)
            } else {
                Chart {
                    ForEach(chartPoints) { pt in
                        LineMark(
                            x: .value("시간", pt.time),
                            y: .value("에이전트", pt.total)
                        )
                        .foregroundStyle(.blue)
                        .interpolationMethod(.monotone)

                        AreaMark(
                            x: .value("시간", pt.time),
                            y: .value("에이전트", pt.total)
                        )
                        .foregroundStyle(.blue.opacity(0.08))
                        .interpolationMethod(.monotone)
                    }
                    // 누수 오버레이
                    ForEach(chartPoints.filter { $0.leaked > 0 }) { pt in
                        LineMark(
                            x: .value("시간", pt.time),
                            y: .value("누수", pt.leaked)
                        )
                        .foregroundStyle(.red.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        .interpolationMethod(.monotone)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .minute, count: xAxisStride)) { v in
                        AxisValueLabel(format: .dateTime.hour().minute())
                            .font(.system(size: 8))
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { v in
                        AxisValueLabel().font(.system(size: 8))
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                    }
                }
                .frame(height: 80)
                .chartLegend(.hidden)

                // 범례
                HStack(spacing: 10) {
                    legendDot(.blue, "에이전트")
                    legendDashLine(.red, "누수")
                    Spacer()
                    if trend.slopePerMinute != 0 {
                        let sign = trend.slopePerMinute > 0 ? "+" : ""
                        Text("\(sign)\(String(format: "%.1f", trend.slopePerMinute))/분")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private var patternBadge: some View {
        HStack(spacing: 3) {
            Text(trend.patternEmoji)
            Text(trend.pattern.rawValue)
                .font(.caption2)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(patternColor.opacity(0.12))
        .foregroundStyle(patternColor)
        .clipShape(Capsule())
    }

    private var patternColor: Color {
        switch trend.pattern {
        case .stable:      return .green
        case .slowGrowing: return .orange
        case .fastGrowing: return .red
        case .spike:       return .purple
        case .shrinking:   return .blue
        }
    }

    private var xAxisStride: Int {
        let rangeMinutes = (chartPoints.last?.time.timeIntervalSince(chartPoints.first?.time ?? Date()) ?? 60) / 60
        if rangeMinutes < 10 { return 2 }
        if rangeMinutes < 60 { return 10 }
        return 30
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    private func legendDashLine(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            Rectangle().fill(color).frame(width: 12, height: 1.5)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - ChartPoint

private struct ChartPoint: Identifiable {
    let id = UUID()
    let time: Date
    let total: Int
    let leaked: Int
}
