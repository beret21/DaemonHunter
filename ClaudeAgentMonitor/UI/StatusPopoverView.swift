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

    @Environment(\.openSettings) private var openSettingsAction
    @Environment(\.openWindow)   private var openWindow

    // Liquid Glass 투명도 (0.0 = 불투명, 1.0 = 완전 투명)
    @AppStorage("glassOpacity") private var glassOpacity: Double = 0.3

    @State private var isCleaningUp   = false
    @State private var cleanupMsg:    String?
    @State private var showTrendChart = false
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
        .background(Color(NSColor.windowBackgroundColor))
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
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(statusColor.opacity(0.15))
        .clipShape(Capsule())
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
            // 예측경보 셀
            statCell(
                predEngine.activeAnomalies.isEmpty ? "✓" : "\(predEngine.activeAnomalies.count)",
                "예측경보",
                color: predEngine.activeAnomalies.contains { $0.absoluteAnomalyLevel == .critical || ($0.residualZScore.map { abs($0) } ?? 0) > 4 } ? .red
                     : predEngine.activeAnomalies.isEmpty ? .green : .orange
            )
            .help(predEngine.activeAnomalies.first?.anomalyDescription ?? "예측 이상 없음")
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
        let info  = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.1"
        let build = info?["CFBundleVersion"] as? String ?? "001"
        return "\(short).\(String(format: "%03d", Int(build) ?? 0))"
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
