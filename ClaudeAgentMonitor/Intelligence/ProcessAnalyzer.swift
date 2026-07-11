import Foundation
import os

// Apple Intelligence — FoundationModels conditional import
#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
final class ProcessAnalyzer: ObservableObject {
    @Published private(set) var lastAnalysis: AnalysisResult?
    @Published private(set) var isAnalyzing = false
    @Published private(set) var isAIAvailable = false

    private var cachedAt: Date?
    private let cacheSeconds: TimeInterval = 300  // 5분 캐시
    private let logger = Logger(subsystem: "com.beret21.DaemonHunter", category: "ProcessAnalyzer")

    static let shared = ProcessAnalyzer()
    private init() {
        checkAIAvailability()
    }

    // MARK: - Public API

    struct AnalysisResult: Sendable {
        let timestamp: Date
        let severity: String               // "normal" / "warning" / "critical"
        let summary: String                // 상황 요약 (한국어, 2문장 이내)
        let recommendation: String         // 권고 행동 (한국어, 1문장)
        let shouldNotify: Bool
        let notificationMessage: String    // 20자 이내
        let isAIGenerated: Bool
    }

    /// Force = 캐시 무시하고 재분석.
    /// 규칙 기반 결과를 즉시 설정한 뒤 AI 결과로 업데이트 (최대 15초 대기).
    func analyze(
        snapshot: ProcessSnapshot,
        delta: SnapshotDelta? = nil,
        trend: TrendAnalysis? = nil,
        metrics: SystemMetrics? = nil,
        force: Bool = false
    ) async -> AnalysisResult {
        // Cache check
        if !force, let cached = lastAnalysis, let at = cachedAt,
           Date().timeIntervalSince(at) < cacheSeconds {
            return cached
        }

        // Step 1: 즉시 규칙 기반 결과 → 패널이 바로 내용을 표시
        let ruleResult = analyzeWithRules(snapshot: snapshot, delta: delta)
        lastAnalysis = ruleResult
        cachedAt = Date()

        // Step 2: Apple Intelligence로 15초 내 개선 시도
        if #available(macOS 26.0, *) {
            isAnalyzing = true
            defer { isAnalyzing = false }
            if let ai = await analyzeWithTimeout(snapshot: snapshot, delta: delta, trend: trend, metrics: metrics) {
                lastAnalysis = ai
                cachedAt = Date()
                return ai
            }
        }
        return ruleResult
    }

    @available(macOS 26.0, *)
    private func analyzeWithTimeout(
        snapshot: ProcessSnapshot,
        delta: SnapshotDelta?,
        trend: TrendAnalysis?,
        metrics: SystemMetrics?
    ) async -> AnalysisResult? {
        await withTaskGroup(of: AnalysisResult?.self) { group in
            group.addTask { [self] in
                await analyzeWithFoundationModels(snapshot: snapshot, delta: delta, trend: trend, metrics: metrics)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(15))
                return nil
            }
            // First task to complete wins; cancel the other
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: - Apple Intelligence (FoundationModels)

    @available(macOS 26.0, *)
    private func analyzeWithFoundationModels(
        snapshot: ProcessSnapshot,
        delta: SnapshotDelta?,
        trend: TrendAnalysis?,
        metrics: SystemMetrics?
    ) async -> AnalysisResult? {
#if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else {
            logger.warning("Apple Intelligence not available on this device")
            return nil
        }

        let prompt = buildPrompt(snapshot: snapshot, delta: delta, trend: trend, metrics: metrics)

        do {
            let session = LanguageModelSession()
            let response = try await session.respond(
                to: prompt,
                generating: AIProcessAnalysis.self
            )
            let output = response.content
            logger.info("AI analysis complete: \(output.severity)")
            return AnalysisResult(
                timestamp: Date(),
                severity: output.severity,
                summary: output.summary,
                recommendation: output.recommendation,
                shouldNotify: output.shouldNotify,
                notificationMessage: output.notificationMessage,
                isAIGenerated: true
            )
        } catch {
            logger.error("FoundationModels error: \(error.localizedDescription)")
            return nil
        }
#else
        return nil
#endif
    }

    // MARK: - Prompt builder

    private func buildPrompt(
        snapshot: ProcessSnapshot,
        delta: SnapshotDelta?,
        trend: TrendAnalysis?,
        metrics: SystemMetrics?
    ) -> String {
        let leaked = snapshot.processes.filter(\.isLeaked)
        let oldest = snapshot.processes.first

        let leakTopList = leaked.prefix(5).map {
            "• PID \($0.pid): \($0.ageFormatted) 경과, \(Int($0.memMB))MB, 원인: \($0.leakReason)"
        }.joined(separator: "\n")

        // 상태 전환 섹션
        var deltaSection = ""
        if let d = delta, d.statusChanged {
            deltaSection = """

## 이전 상태 대비 변화
- 상태 전환: \(d.previousStatus.rawValue) → \(snapshot.status.rawValue)
- 프로세스 수: \(d.processCountDelta > 0 ? "+" : "")\(d.processCountDelta)개
- 메모리: \(d.memDeltaGB > 0 ? "+" : "")\(String(format: "%.1f", d.memDeltaGB))GB
- 누수: \(d.leakDelta > 0 ? "+" : "")\(d.leakDelta)개
"""
        }

        // 트렌드 섹션
        var trendSection = ""
        if let t = trend {
            let groups = t.processGroups.prefix(3).map {
                "  • \($0.type): \($0.count)개 (\($0.deltaFromPrev > 0 ? "+" : "")\($0.deltaFromPrev))"
            }.joined(separator: "\n")
            let chronic = t.chronicLeakers.prefix(2).map {
                "  • PID \($0.pid): 큐 \(Int($0.queueDwellMinutes))분 대기, \(Int($0.avgMemMB))MB"
            }.joined(separator: "\n")

            trendSection = """

## 프로세스 트렌드 분석
- 패턴: \(t.pattern.rawValue) (기울기 \(String(format: "%.2f", t.slopePerMinute))/분)
- 급증 가능성: \(Int(t.spikeProbability * 100))% (일시적 vs 지속적 판단에 활용)
- 프로세스 그룹:
\(groups.isEmpty ? "  데이터 수집 중" : groups)
- 장기 큐 대기 (미종료):
\(chronic.isEmpty ? "  없음" : chronic)
"""
        }

        // 시스템 헬스 섹션
        var metricsSection = ""
        if let m = metrics {
            let fan = m.fanSpeedRPM.map { "\($0)rpm" } ?? "N/A"
            metricsSection = """

## 시스템 헬스
- CPU: \(String(format: "%.1f", m.cpuUsagePercent))%  |  부하(1m/5m): \(String(format: "%.2f", m.loadAvg1min))/\(String(format: "%.2f", m.loadAvg5min))
- 메모리: \(String(format: "%.1f", m.memUsedGB))GB / \(String(format: "%.1f", m.memTotalGB))GB  [\(m.memPressure.rawValue)]
- 발열: \(m.thermalState.rawValue) \(m.thermalState.emoji)
- 팬: \(fan)
"""
        }

        // 칼만 예측 이상 섹션
        let anomalies = PredictionEngine.shared.activeAnomalies
        var anomalySection = ""
        if !anomalies.isEmpty {
            let lines = anomalies.prefix(4).map { p -> String in
                let absTag = p.absoluteAnomalyLevel == .critical ? "🔴" : p.absoluteAnomalyLevel == .warning ? "🟡" : "  "
                return "\(absTag) \(p.anomalyDescription ?? p.metric)"
            }.joined(separator: "\n")
            anomalySection = """

## 칼만 예측 이상 (\(anomalies.count)건)
\(lines)
"""
        }

        // 시스템 레인 (앱 외부 · Claude 무관) 섹션
        let sysReport = SystemHealthEvaluator.shared.report
        var systemLaneSection = ""
        if sysReport.state != .normal {
            let cands = sysReport.candidates.prefix(4).map { c -> String in
                let tag = c.isChronic ? "만성" : "일시"
                return "  • \(c.name) [\(tag) · \(c.resource.rawValue)] — \(c.suggestion)"
            }.joined(separator: "\n")
            systemLaneSection = """

## 시스템 레인 (앱 외부 · Claude 무관) [\(sysReport.state == .critical ? "위험" : "경고")]
- 요약: \(sysReport.summary)
- 스왑: \(String(format: "%.0f%%", sysReport.swapRatio * 100))  |  메모리 압박 레벨: \(sysReport.memPressureLevel) (0정상/1경고/2위험)
- 오버헤드 후보:
\(cands.isEmpty ? "  없음" : cands)
- ⚠️ 이 섹션은 시스템 데몬·타 앱이 유발한 앱 밖 문제다. Claude Code 누수와 절대 섞지 말고, 요약에서 "이건 시스템 문제"로 별개 항목으로 명확히 구분해 안내하라.
"""
        }

        // 유휴 서브에이전트 섹션
        let idleProcs = snapshot.processes.filter(\.isIdle)
        var idleSection = ""
        if !idleProcs.isEmpty {
            let lines = idleProcs.prefix(3).map {
                "• PID \($0.pid): 유휴 \($0.idleSnapshots)회, \(Int($0.memMB))MB 점유"
            }.joined(separator: "\n")
            idleSection = """

## CPU 유휴 서브에이전트 (\(idleProcs.count)개)
\(lines)
"""
        }

        // claude-mem 관찰자 섹션
        let memObservers = snapshot.processes.filter(\.isClaudeMemObserver)
        var memObserverSection = ""
        if !memObservers.isEmpty {
            let leaked = memObservers.filter(\.isLeaked).count
            let totalMB = Int(memObservers.reduce(0.0) { $0 + $1.memMB })
            memObserverSection = """

## claude-mem 메모리 관찰자 (\(memObservers.count)개, \(totalMB)MB)
- 미종료(누수): \(leaked)개
- 가장 오래된: \(memObservers.first.map { "\($0.ageFormatted) (PID \($0.pid))" } ?? "없음")
- bun worker-service 데몬이 생성하는 메모리 저장용 관찰자 에이전트 (정상 종료 후에도 잔존)
"""
        }

        return """
당신은 macOS 시스템 전문가입니다. Claude Code sub-agent 프로세스 상태와 시스템 헬스를 종합 분석해 한국어로 안내해주세요.

## 현재 프로세스 상태 [\(snapshot.status.rawValue)]
- 총 프로세스: \(snapshot.processes.count)개  |  총 메모리: \(String(format: "%.1f", snapshot.totalMemGB))GB
- 누수 의심: \(snapshot.leakedCount)개 (\(String(format: "%.1f", leaked.reduce(0){$0+$1.memMB}/1024))GB)
- 최장 생존: \(oldest.map { "\($0.ageFormatted) (PID \($0.pid))" } ?? "없음")\(deltaSection)\(trendSection)\(metricsSection)\(systemLaneSection)\(anomalySection)\(idleSection)\(memObserverSection)

## 누수 의심 상위 5개
\(leakTopList.isEmpty ? "없음" : leakTopList)

## 분석 요청
1. 심각도를 판단하세요 (normal/warning/critical)
2. 현재 상황을 2문장 이내로 요약하세요. 트렌드(일시 급증 vs 지속 누적)와 시스템 영향(발열·CPU 부하)을 구체적으로 포함.
   유휴 서브에이전트와 예측 이상이 있으면 언급하세요.
   ⚠️ "시스템 레인" 섹션이 있으면 그건 Claude가 아니라 앱 밖 시스템 문제이므로, Claude 누수 문제와 섞지 말고 별개로 분명히 구분해 안내하세요.
3. 지금 당장 해야 할 행동을 1문장으로 권고하세요.
4. 사용자에게 알림이 필요한지 판단하세요. 중복 알림을 최소화하고, 상태 전환·즉각 조치 필요 시만 true.
5. shouldNotify=true 시 20자 이내 알림 메시지를 작성하세요.
"""
    }

    // MARK: - Rule-based fallback

    private func analyzeWithRules(snapshot: ProcessSnapshot, delta: SnapshotDelta?) -> AnalysisResult {
        let total = snapshot.processes.count
        let leaked = snapshot.leakedCount
        let memGB = snapshot.totalMemGB
        let statusChanged = delta?.statusChanged ?? false
        // 시스템 레인(앱 외부) 문제는 Claude 누수와 별개로 덧붙인다.
        let sysNote = systemHealthNote()

        switch snapshot.status {
        case .critical:
            return AnalysisResult(
                timestamp: Date(),
                severity: "critical",
                summary: "서브 에이전트 \(total)개가 실행 중이며 \(leaked)개가 누수 상태입니다. 총 \(String(format: "%.1f", memGB))GB를 점유해 시스템 자원이 심각하게 낭비되고 있습니다.\(sysNote)",
                recommendation: "누수된 \(leaked)개의 프로세스를 즉시 정리하세요.",
                shouldNotify: statusChanged || leaked > 10,
                notificationMessage: "심각: \(leaked)개 누수·\(String(format: "%.1f", memGB))GB",
                isAIGenerated: false
            )
        case .warning:
            return AnalysisResult(
                timestamp: Date(),
                severity: "warning",
                summary: "서브 에이전트 \(total)개 중 \(leaked)개가 장기 유휴 상태입니다. \(String(format: "%.1f", memGB))GB의 메모리가 사용되고 있습니다.\(sysNote)",
                recommendation: "\(leaked)개의 유휴 프로세스 정리를 고려하세요.",
                shouldNotify: statusChanged,
                notificationMessage: "경고: 유휴 프로세스 \(leaked)개",
                isAIGenerated: false
            )
        case .normal:
            return AnalysisResult(
                timestamp: Date(),
                severity: "normal",
                summary: "서브 에이전트 \(total)개가 정상 동작 중입니다. 메모리 사용량은 \(String(format: "%.1f", memGB))GB입니다.\(sysNote)",
                recommendation: sysNote.isEmpty ? "현 상태를 유지하세요." : "Claude 프로세스는 정상입니다. 시스템 과부하는 앱 밖 원인을 확인하세요.",
                shouldNotify: false,
                notificationMessage: "",
                isAIGenerated: false
            )
        }
    }

    /// 시스템 레인(앱 외부)이 경고/위험이면 Claude 누수와 분명히 구분한 안내 문구를 반환.
    /// 정상이면 빈 문자열.
    private func systemHealthNote() -> String {
        let r = SystemHealthEvaluator.shared.report
        guard r.state != .normal else { return "" }
        let culprit = r.candidates.first { $0.isChronic } ?? r.candidates.first
        let who = culprit.map { " (\($0.name) 등)" } ?? ""
        let level = r.state == .critical ? "위험" : "경고"
        return " ⚠️ 이와 별개로, 시스템 자체가 \(level) 상태입니다 — 이건 Claude가 아니라 앱 밖 시스템 문제(시스템 데몬 폭주·메모리 부족\(who))입니다."
    }

    // MARK: - AI availability check

    private func checkAIAvailability() {
        if #available(macOS 26.0, *) {
#if canImport(FoundationModels)
            isAIAvailable = (SystemLanguageModel.default.availability == .available)
#endif
        }
    }
}

// MARK: - FoundationModels @Generable struct (Apple Intelligence)

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct AIProcessAnalysis: Sendable {
    @Guide(description: "심각도 수준: 'normal', 'warning', 'critical' 중 정확히 하나")
    var severity: String

    @Guide(description: "현재 상황을 2문장 이내 한국어로 요약. 프로세스 수·메모리 수치를 반드시 포함.")
    var summary: String

    @Guide(description: "사용자가 즉시 해야 할 행동 1문장 (한국어). 조치가 불필요하면 '현 상태를 유지하세요.'")
    var recommendation: String

    @Guide(description: "알림 표시 필요 여부. 상태 전환이나 즉각 조치가 필요할 때만 true. 중복 알림 최소화.")
    var shouldNotify: Bool

    @Guide(description: "shouldNotify=true일 때만 작성. 20자 이내 한국어 알림 메시지. false면 빈 문자열.")
    var notificationMessage: String
}
#endif
