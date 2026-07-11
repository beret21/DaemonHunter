import SwiftUI
import AppKit

// MARK: - Glass background

// NSVisualEffectView 서브클래스: viewDidMoveToWindow() 에서 창 투명화
private final class GlassView: NSVisualEffectView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let w = window else { return }
        w.isOpaque        = false
        w.backgroundColor = .clear
    }
}

private struct GlassPanel: NSViewRepresentable {
    let opacity: Double   // 0.0 = 완전 불투명, 1.0 = 완전 투명

    func makeNSView(context: Context) -> GlassView {
        let v = GlassView()
        v.material     = .hudWindow   // hudWindow는 menu 보다 더 투명한 느낌
        v.blendingMode = .behindWindow
        v.state        = .active
        v.alphaValue   = CGFloat(1.0 - opacity)
        return v
    }

    func updateNSView(_ v: GlassView, context: Context) {
        v.alphaValue = CGFloat(1.0 - opacity)
        v.needsDisplay = true
        // 창이 이미 연결된 경우에도 재확인
        if let w = v.window {
            w.isOpaque        = false
            w.backgroundColor = .clear
        }
    }
}

// MARK: - Main View

struct StatusPopoverView: View {
    @EnvironmentObject var monitor:  ProcessMonitor
    @EnvironmentObject var analyzer: ProcessAnalyzer
    @ObservedObject  var tracker:    ProcessHistoryTracker = .shared
    @ObservedObject  var metrics:    SystemMetricsCollector = .shared
    @ObservedObject  var predEngine: PredictionEngine = .shared
    @ObservedObject  var health:     SystemHealthEvaluator = .shared

    @Environment(\.openSettings) private var openSettingsAction
    @Environment(\.openWindow)   private var openWindow

    // Liquid Glass 투명도 (0.0 = 불투명, 1.0 = 완전 투명)
    @AppStorage("glassOpacity") private var glassOpacity: Double = 0.3

    @State private var isCleaningUp   = false
    @State private var cleanupMsg:    String?
    @State private var showTrendChart = false
    @State private var showSystemDetail = true
    @State private var dbSnapshots:   [SnapshotRecord] = []
    @State private var autoRefreshTimer: Timer?
    private let autoRefreshInterval: TimeInterval = 60

    var snapshot: ProcessSnapshot { monitor.snapshot }
    var trend:    TrendAnalysis   { tracker.analysis }

    private var mainSessionCount: Int { snapshot.processes.filter { $0.cmdArgs == "메인세션" }.count }
    private var memObserverLeakCount: Int { snapshot.processes.filter { $0.isClaudeMemObserver && $0.isLeaked }.count }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            Divider()
            aiSection
            Divider()
            statsRow
            Divider()
            systemRow
            Divider()
            systemHealthSection
            if showTrendChart {
                Divider()
                TrendChartView(trend: trend, dbSnapshots: dbSnapshots)
            }
            if snapshot.leakedCount > 0 || cleanupMsg != nil {
                Divider()
                actionsSection
            }
            Divider()
            footerRow
        }
        .background(.regularMaterial)
        .frame(width: 360)
        .onAppear {
            triggerAnalysis(force: false)
            loadDbSnapshots()
            startAutoRefresh()
        }
        .onDisappear {
            stopAutoRefresh()
        }
    }

    // MARK: - Auto-refresh

    private func startAutoRefresh() {
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = Timer.scheduledTimer(withTimeInterval: autoRefreshInterval, repeats: true) { _ in
            Task { @MainActor in
                triggerAnalysis(force: true)
                loadDbSnapshots()
            }
        }
    }

    private func stopAutoRefresh() {
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text("Daemon Hunter")
                .font(.headline)
            Spacer()
            statusBadge
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            if metrics.current.thermalState == .serious || metrics.current.thermalState == .critical {
                Image(systemName: "thermometer.high")
                    .foregroundStyle(.red).font(.caption)
            }
            Text(snapshot.status.rawValue)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusColor)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .glassEffect(.regular.tint(statusColor.opacity(0.22)), in: .capsule)
    }

    // MARK: - AI Analysis

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "brain.head.profile")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("AI 분석")
                    .font(.subheadline.weight(.semibold))
                if analyzer.isAIAvailable {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.purple).font(.caption)
                }
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                    Text("\(Int(autoRefreshInterval))s")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                if analyzer.isAnalyzing {
                    ProgressView().scaleEffect(0.6)
                } else {
                    Button { triggerAnalysis(force: true) } label: {
                        Image(systemName: "arrow.clockwise").font(.caption)
                    }
                    .buttonStyle(.plain).help("재분석")
                }
            }

            if let a = analyzer.lastAnalysis {
                Text(a.summary)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)

                if !a.recommendation.isEmpty {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "lightbulb.fill")
                            .foregroundStyle(.orange).font(.caption)
                        Text(a.recommendation)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 4) {
                    Image(systemName: a.isAIGenerated ? "sparkles" : "ruler")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Text(a.isAIGenerated ? "Apple Intelligence" : "규칙 기반")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Text(relativeTime(a.timestamp))
                        .font(.caption2).foregroundStyle(.quaternary)
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text("분석 중...")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Stats

    private var statsRow: some View {
        HStack(spacing: 0) {
            statCell(
                "\(snapshot.processes.count)",
                "에이전트",
                sub: mainSessionCount > 0 ? "+\(mainSessionCount) 세션" : nil,
                color: snapshot.processes.count >= AppSettings.criticalProcessCount ? .red
                     : snapshot.processes.count >= AppSettings.warningProcessCount  ? .orange : nil
            )
            Divider().frame(height: 36).opacity(0.4)
            statCell(
                String(format: "%.1f", snapshot.totalMemGB) + "GB",
                "메모리",
                color: snapshot.totalMemGB >= AppSettings.criticalMemoryGB ? .red
                     : snapshot.totalMemGB >= AppSettings.criticalMemoryGB * 0.5 ? .orange : nil
            )
            Divider().frame(height: 36).opacity(0.4)
            statCell(
                "\(snapshot.leakedCount)",
                "누수",
                color: snapshot.leakedCount > 0 ? .orange : .green
            )
            Divider().frame(height: 36).opacity(0.4)
            // 트렌드 탭 → 차트 토글
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showTrendChart.toggle() }
                if showTrendChart { loadDbSnapshots() }
            } label: {
                statCell(
                    trend.patternEmoji,
                    "추세",
                    color: trend.pattern == .fastGrowing ? .red
                         : trend.pattern == .slowGrowing ? .orange : nil
                )
            }
            .buttonStyle(.plain)
            .help(showTrendChart ? "차트 숨기기" : "트렌드 차트 표시")
            Divider().frame(height: 36).opacity(0.4)
            // 이상 신호 셀 (관찰된 현재 상태 — 미래 예측 아님)
            statCell(
                predEngine.activeAnomalies.isEmpty ? "✓" : "\(predEngine.activeAnomalies.count)",
                "이상 신호",
                color: predEngine.activeAnomalies.contains { $0.absoluteAnomalyLevel == .critical || ($0.residualZScore.map { abs($0) } ?? 0) > 4 } ? .red
                     : predEngine.activeAnomalies.isEmpty ? .green : .orange
            )
            .help(predEngine.activeAnomalies.first?.anomalyDescription ?? "관찰된 이상 없음")
            Divider().frame(height: 36).opacity(0.4)
            // claude-mem 관찰자 셀
            let memObsCnt  = snapshot.processes.filter(\.isClaudeMemObserver).count
            let memObsLeak = snapshot.processes.filter { $0.isClaudeMemObserver && $0.isLeaked }.count
            statCell(
                "\(memObsCnt)",
                "mem관찰",
                sub: memObsLeak > 0 ? "누수 \(memObsLeak)" : nil,
                color: memObsLeak > 0 ? .purple : memObsCnt > 0 ? .secondary : nil
            )
            .help("claude-mem 메모리 관찰자 프로세스 (\(memObsLeak)개 미종료)")
        }
        .padding(.vertical, 8)
    }

    private func statCell(_ value: String, _ label: String,
                          sub: String? = nil, color: Color? = nil) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(color ?? .primary)
            Text(label)
                .font(.caption2).foregroundStyle(.secondary)
            if let sub {
                Text(sub).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - System row

    private var systemRow: some View {
        let m = metrics.current
        return HStack(spacing: 0) {
            Image(systemName: "cpu").font(.caption).foregroundStyle(.secondary)
                .padding(.leading, 14)
            Text(String(format: " %.0f%%", m.cpuUsagePercent))
                .font(.caption).foregroundStyle(.secondary)
            Text("  ·  ").foregroundStyle(.quaternary).font(.caption)
            Text(String(format: "%.0f%%", (m.memUsedGB / max(m.memTotalGB, 1)) * 100) + " 메모리")
                .font(.caption).foregroundStyle(.secondary)
            Text("  ·  ").foregroundStyle(.quaternary).font(.caption)
            Text(m.thermalState.emoji + " " + m.thermalState.rawValue)
                .font(.caption).foregroundStyle(.secondary)
            if let fan = m.fanSpeedRPM {
                Text("  ·  ").foregroundStyle(.quaternary).font(.caption)
                Text("\(fan)rpm").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            // 프로세스 목록 → 별도 Window
            Button {
                openWindow(id: WindowID.processDetail)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "list.bullet").font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).help("프로세스 목록")
            .padding(.trailing, 14)
        }
        .padding(.vertical, 8)
    }

    // MARK: - System health / overhead

    private var systemHealthSection: some View {
        let r = health.report
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "waveform.path.ecg")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("시스템 건강 / 오버헤드")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !r.candidates.isEmpty {
                    Text("\(r.candidates.count)건")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showSystemDetail.toggle() }
                    } label: {
                        Image(systemName: showSystemDetail ? "chevron.up" : "chevron.down")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(showSystemDetail ? "회수 리포트 접기" : "회수 리포트 펼치기")
                }
            }

            // 요약 줄 (report.summary는 상태 이모지를 이미 포함)
            Text(r.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // 입증분: 측정된 압박(경합) 신호 — 심각도는 여기서 나온다. 강한 색은 이 입증분에만.
            HStack(spacing: 6) {
                metricChip("CPU 부하", String(format: "%.1f×", r.cpuLoadRatio), cpuLoadColor(r.cpuLoadRatio))
                metricChip("메모리 압박", memPressureText(r.memPressureLevel), memPressureColor(r.memPressureLevel))
                if r.swapIOPagesPerSec > 0 {
                    metricChip("스왑 IO", String(format: "%.0f p/s", r.swapIOPagesPerSec), swapIOColor(r.swapIOPagesPerSec))
                }
            }

            // 추론분: 정직한 선형 외삽(rate 안정 시에만 non-nil). 있을 때만 부차적으로, 단정 색 없이.
            if let t = r.memTimeToExhaustionSeconds {
                exhaustionLine("메모리", t)
            }
            if let t = r.swapTimeToExhaustionSeconds {
                exhaustionLine("스왑", t)
            }

            // 오버헤드 회수 리포트 (리포트 전용 — 프로세스 종료 버튼 없음)
            if r.candidates.isEmpty {
                Text("회수 대상 없음 — 시스템 정상")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else if showSystemDetail {
                ScrollView {
                    GlassEffectContainer(spacing: 6) {
                        VStack(spacing: 6) {
                            ForEach(r.candidates.prefix(6)) { c in
                                candidateRow(c)
                            }
                        }
                    }
                    .padding(.vertical, 1)
                }
                .frame(maxHeight: 176)
                .clipped()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func candidateRow(_ c: OverheadCandidate) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(c.name)
                    .font(.caption.weight(.medium)).lineLimit(1)
                consumptionBadge(c.isConsuming)
                Spacer()
                Text(candidateValueText(c))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 5) {
                Text(c.resource.rawValue)
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                Text("·").font(.system(size: 9)).foregroundStyle(.quaternary)
                Text(SystemHealthEvaluator.humanDuration(c.durationSeconds) + " 관측")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            Text(c.suggestion)
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            // 인과는 결론이 아니라 "다음 확인 대상" — 부차적 스타일로만.
            if let edge = c.causalPointer {
                Text(edge)
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 8))
    }

    // 후보는 per-process "소비 상태"일 뿐 심각도가 아니다 → 강한 색 금지, 중립 뱃지.
    private func consumptionBadge(_ isConsuming: Bool) -> some View {
        Text(isConsuming ? "소비 중" : "회수 후보")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.gray.opacity(0.16))
            .clipShape(Capsule())
    }

    private func metricChip(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .glassEffect(.regular, in: .capsule)
    }

    private func candidateValueText(_ c: OverheadCandidate) -> String {
        switch c.resource {
        case .cpu:    return String(format: "%.0f%%", c.value)
        case .memory: return String(format: "%.1fGB", c.value / 1024)
        case .swap:   return String(format: "%.1fGB", c.value / 1024)
        }
    }

    // 압박 색은 백엔드의 경합 임계와 동일하게(입증분에만 단정).
    private func cpuLoadColor(_ ratio: Double) -> Color {
        // 백엔드: cpuLoadRatio>1 경고, load>코어×2(=ratio>2) 위험.
        ratio > 2.0 ? .red : ratio > 1.0 ? .orange : .secondary
    }

    private func swapIOColor(_ pagesPerSec: Double) -> Color {
        // 백엔드 SystemHealthEvaluator 임계와 동일: warn 50 · crit 500 pages/s.
        pagesPerSec >= 500 ? .red : pagesPerSec >= 50 ? .orange : .secondary
    }

    // time-to-exhaustion 표시(추론분): 있을 때만, 단정 색 없이.
    private func exhaustionLine(_ label: String, _ seconds: Double) -> some View {
        let t = seconds < 60 ? "\(Int(max(0, seconds)))초"
                             : SystemHealthEvaluator.humanDuration(seconds)
        return HStack(spacing: 4) {
            Image(systemName: "hourglass")
                .font(.system(size: 8)).foregroundStyle(.tertiary)
            Text("추정: \(label) 약 \(t) 뒤 소진")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }

    private func memPressureText(_ level: Int) -> String {
        switch level {
        case 2:  return "위험"
        case 1:  return "경고"
        default: return "정상"
        }
    }

    private func memPressureColor(_ level: Int) -> Color {
        switch level {
        case 2:  return .red
        case 1:  return .orange
        default: return .secondary
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(spacing: 6) {
            if snapshot.leakedCount > 0 {
                Button(action: cleanupLeaked) {
                    Label(
                        isCleaningUp ? "정리 중..." : "누수 정리 (\(snapshot.leakedCount)개 · \(leakMemText))",
                        systemImage: isCleaningUp ? "hourglass" : "trash.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red.opacity(0.85))
                .disabled(isCleaningUp)
                .padding(.horizontal, 14)
            }
            if let msg = cleanupMsg {
                HStack(spacing: 6) {
                    Label(msg, systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                    Spacer()
                    Button("로그 보기") {
                        openWindow(id: WindowID.activityLog)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    .buttonStyle(.link).font(.caption)
                }
                .padding(.horizontal, 14)
            }
        }
        .padding(.vertical, 8)
    }

    private var leakMemText: String {
        let gb = snapshot.processes.filter(\.isLeaked).reduce(0.0) { $0 + $1.memMB } / 1024
        return String(format: "%.1fGB", gb)
    }

    // MARK: - Footer

    private var footerRow: some View {
        VStack(spacing: 4) {
            // 자가치유 상태 뱃지 (문제 있을 때만 표시)
            SelfHealingBadge(healer: .shared)
                .padding(.horizontal, 14)

            HStack(spacing: 4) {
                Text("v\(appVersion)")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("로그") {
                    openWindow(id: WindowID.activityLog)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.link).font(.caption2)

                Text("·").foregroundStyle(.tertiary).font(.caption2)

                Button("업데이트") { UpdateManager.shared.checkForUpdates() }
                    .buttonStyle(.link).font(.caption2)

                Text("·").foregroundStyle(.tertiary).font(.caption2)

                Button("설정") {
                    openSettingsAction()
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.link).font(.caption2)

                Text("·").foregroundStyle(.tertiary).font(.caption2)

                Button("종료") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.link).font(.caption2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch snapshot.status {
        case .normal:   return .green
        case .warning:  return .orange
        case .critical: return .red
        }
    }

    private var appVersion: String {
        // CFBundleShortVersionString(MARKETING_VERSION)이 이미 전체 버전(예: 0.1.007).
        // 빌드번호를 다시 붙이면 "0.1.007.007"처럼 중복되므로 그대로 사용한다.
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
    }

    private func relativeTime(_ date: Date) -> String {
        let s = -date.timeIntervalSinceNow
        if s < 60   { return "방금" }
        if s < 3600 { return "\(Int(s / 60))분 전" }
        return "\(Int(s / 3600))시간 전"
    }

    private func triggerAnalysis(force: Bool) {
        Task {
            _ = await analyzer.analyze(
                snapshot: snapshot,
                delta: snapshot.delta(from: monitor.previousSnapshot),
                trend: trend,
                metrics: metrics.current,
                force: force
            )
        }
    }

    private func loadDbSnapshots() {
        Task.detached {
            let records = DatabaseManager.shared.fetchRecentSnapshots(hours: 6)
            await MainActor.run { dbSnapshots = records }
        }
    }

    private func cleanupLeaked() {
        let countBefore  = snapshot.processes.count
        let statusBefore = snapshot.status.rawValue
        isCleaningUp = true; cleanupMsg = nil
        Task {
            let r          = await monitor.killLeaked()
            let gb         = r.reclaimedMB / 1024.0
            let countAfter = monitor.snapshot.processes.count

            let killedRecords = r.killedProcesses.map {
                ProcessEventRecord(pid: $0.pid, ppid: $0.ppid,
                                   ageMinutes: $0.ageMinutes, memMB: $0.memMB,
                                   cmdArgs: $0.cmdArgs, leakReason: $0.leakReason,
                                   killSuccess: true)
            }
            let failedRecords = r.failedProcesses.map {
                ProcessEventRecord(pid: $0.pid, ppid: $0.ppid,
                                   ageMinutes: $0.ageMinutes, memMB: $0.memMB,
                                   cmdArgs: $0.cmdArgs, leakReason: $0.leakReason,
                                   killSuccess: false)
            }
            let allRecords = killedRecords + failedRecords

            let logId = DatabaseManager.shared.insertCleanupLog(
                killedCount: r.killed, failedCount: r.failed,
                reclaimedMB: r.reclaimedMB,
                processCountBefore: countBefore, processCountAfter: countAfter,
                status: statusBefore, trigger: "manual",
                processes: allRecords
            )
            var events: [(record: ProcessEventRecord, type: String, status: String, refId: Int64?)] = []
            events += killedRecords.map { (record: $0, type: "cleanup_success", status: statusBefore, refId: logId) }
            events += failedRecords.map { (record: $0, type: "cleanup_failed",  status: statusBefore, refId: logId) }
            if !events.isEmpty { DatabaseManager.shared.insertProcessEvents(events) }

            await MainActor.run {
                isCleaningUp = false
                cleanupMsg   = "\(r.killed)개 종료 · \(String(format: "%.1f", gb))GB 회수"
                NotificationCoordinator.shared.notifyCleanupDone(killed: r.killed, reclaimedGB: gb)
            }
            _ = await analyzer.analyze(
                snapshot: monitor.snapshot, trend: tracker.analysis,
                metrics: SystemMetricsCollector.shared.current, force: true
            )
        }
    }
}
