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
        let suggestedAction: String         // "kill" / "monitor" / "none"
        let suggestedTargetApp: String      // suggestedAction=="kill"일 때 대상 앱 이름
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
                isAIGenerated: true,
                suggestedAction: output.suggestedAction,
                suggestedTargetApp: output.suggestedTargetApp
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

        // 관찰된 이상 신호 섹션 (절대임계·지속·급증 등 기계적 신호 — 미래 예측 아님)
        let anomalies = PredictionEngine.shared.activeAnomalies
        var anomalySection = ""
        if !anomalies.isEmpty {
            let lines = anomalies.prefix(4).map { p -> String in
                let absTag = p.absoluteAnomalyLevel == .critical ? "🔴" : p.absoluteAnomalyLevel == .warning ? "🟡" : "  "
                return "\(absTag) \(p.anomalyDescription ?? p.metric)"
            }.joined(separator: "\n")
            anomalySection = """

## 관찰된 이상 신호 (\(anomalies.count)건)
\(lines)
"""
        }

        // 시스템 레인 (앱 외부 · Claude 무관) 섹션
        let sysReport = SystemHealthEvaluator.shared.report
        var systemLaneSection = ""
        if sysReport.state != .normal {
            // 후보 = "소비 중일 뿐", 인과는 결론 아님 → "확인:" 엣지 포인터만 덧붙인다.
            let cands = sysReport.candidates.prefix(4).map { c -> String in
                let mode = c.isConsuming ? "소비 중" : "회수 후보(parked)"
                let edge = c.causalPointer.map { " — \($0)" } ?? ""
                return "  • \(c.name) [\(c.resource.rawValue) · \(mode)] \(c.suggestion)\(edge)"
            }.joined(separator: "\n")
            // 계층1 확정 사실(입증된 압박)만. 없는 예측은 안 만든다.
            var pressureFacts = "메모리 압박 레벨 \(sysReport.memPressureLevel)(0정상/1경고/2위험)"
                + " · CPU 부하 \(String(format: "%.1f", sysReport.cpuLoadRatio))×코어"
                + " · 스왑 IO \(String(format: "%.0f", sysReport.swapIOPagesPerSec)) p/s"
            if let mt = sysReport.memTimeToExhaustionSeconds {
                pressureFacts += " · 메모리 소진 추정 ~\(SystemHealthEvaluator.humanDuration(mt))"
            }
            if let st = sysReport.swapTimeToExhaustionSeconds {
                pressureFacts += " · 스왑 소진 추정 ~\(SystemHealthEvaluator.humanDuration(st))"
            }
            systemLaneSection = """

## 시스템 레인 (앱 외부 · Claude 무관) [백엔드 판정: \(sysReport.state == .critical ? "위험" : "경고")]
- 압박(입증된 사실): \(pressureFacts)
- 후보(소비 중일 뿐 — 원인 아님):
\(cands.isEmpty ? "  없음" : cands)
- 규칙(반드시 준수):
  · 심각도는 위 '백엔드 판정'을 그대로 쓰라. 백엔드가 판정하지 않은 '위험'을 문장으로 지어내지 말라.
  · 후보는 'X 소비 중'으로만 서술하고 원인으로 단정하지 말라(예: "과부하/폭주" 금지).
  · 근본원인은 가설 금지 — 오직 위 '확인:' 엣지(부모 pid·상위 자원)로만 언급하고, 엣지가 없으면 원인 언급을 삭제하라.
  · 이 섹션은 특정 앱이 아니라 시스템 전체의 압박 신호다. 위 "앱별 리소스 현황"(개별 앱 소비)과 섞지 말고 별개 항목으로 구분하라.
"""
        }

        // 앱별 리소스 현황 (ResourceTracker.shared 직접 참조 — FR1/FR4)
        let rt = ResourceTracker.shared
        let appStatusSection = """
## 앱별 리소스 현황 [\(snapshot.status.rawValue)]
- 추적 중인 앱: \(rt.topApps.count)개  |  상위 총 메모리: \(String(format: "%.1f", rt.latestReport?.totalMemGB ?? 0))GB
- 메모리 압박: \(rt.memoryInfo.pressureLevel.rawValue)  |  스왑: \(String(format: "%.1f", rt.memoryInfo.swapUsedGB))GB
- 누수 의심 앱: \(rt.leakSuspects.count)개
"""

        // 누수 의심 앱 상위 5 (leak-suspect 여부는 ResourceTracker가 이미 임계 판정 완료)
        let leakAppList = rt.leakSuspects.prefix(5).map {
            "• \($0.appName) [\($0.category)] — 연속 증가 임계 초과, 현재 \(Int($0.totalMemMB))MB, PID \($0.pids.count)개"
        }.joined(separator: "\n")

        // 상세 평가(드릴다운) — 부하 임계 초과 앱만 (drilldownApps가 비어있지 않을 때만 등장)
        var drilldownSection = ""
        if !rt.drilldownApps.isEmpty {
            let blocks = rt.drilldownApps.map { app -> String in
                let details = rt.detailedProcesses(for: app)
                let orphanCount = details.filter(\.isOrphan).count
                let idleCount = details.filter(\.isIdle).count
                return """

## 상세 평가 — \(app) (부하 임계 초과)
- PID \(details.count)개: 고아 \(orphanCount)개, 유휴 \(idleCount)개
"""
            }.joined()
            drilldownSection = blocks
        }

        return """
당신은 macOS 시스템 리소스 분석 전문가입니다. 아래 제공된 확정 관측 사실(추적 중인 앱의 리소스 사용량과 시스템 압박 상태)만 근거로 진단하고, 구체적 처방을 한국어로 제시하세요.

\(appStatusSection)\(deltaSection)\(trendSection)\(metricsSection)\(systemLaneSection)\(anomalySection)

## 누수 의심 앱 상위 5
\(leakAppList.isEmpty ? "없음" : leakAppList)\(drilldownSection)

## 케이징 규칙 (반드시 준수 — facts→judgment 울타리)
- 제공된 상태·백엔드 판정을 넘어서는 심각도를 만들지 말라. 위에 없는 수치를 지어내지 말라.
- 근본원인은 가설 금지 — 오직 제공된 '확인:' 엣지(부모 pid·상위 자원)로만 언급하라. 엣지를 못 대면 원인 언급을 삭제하라("X 소비 중"까지만).
- "위험/critical"은 백엔드가 판정했을 때만 쓰라. 문장으로 위험을 지어내지 말라.
- 미래를 예측하거나 전망하지 말라. 오직 지금까지 관찰된 사실과 현재 변화율(추세)만 요약하라. 단, 위에 제공된 "소진 추정" 수치(현재 속도가 유지될 때의 기계적 함의)는 예외로 그대로 인용할 수 있다.
- 종료(kill) 제안은 제공된 사실에 기계적 근거(고아 확인됨, 누수 의심 + 압박 지속 등)가 있을 때만 하라. 근거를 요약에 명시하라.

## 분석 요청
1. 심각도를 판단하세요 (normal/warning/critical). 단, 위 케이징 규칙을 넘지 마세요.
2. 현재 상황을 2문장 이내로 요약하세요. 트렌드(일시 급증 vs 지속 누적)와 시스템 영향(발열·CPU 부하)을 구체적으로 포함.
   상세 평가 대상과 관찰된 이상 신호가 있으면 언급하세요.
   ⚠️ "시스템 레인" 섹션이 있으면 그건 특정 앱이 아니라 시스템 전체 신호이므로, 앱별 리소스 문제와 섞지 말고 별개로 분명히 구분해 안내하세요.
3. 지금 해야 할 행동을 1문장으로 처방하세요 — 근거가 있으면 대상 앱을 지목하고 종료 권장 여부를 분명히 하세요(모호한 표현 금지).
4. 사용자에게 알림이 필요한지 판단하세요. 중복 알림을 최소화하고, 상태 전환·즉각 조치 필요 시만 true.
5. shouldNotify=true 시 20자 이내 알림 메시지를 작성하세요.
"""
    }

    // MARK: - Rule-based fallback

    private func analyzeWithRules(snapshot: ProcessSnapshot, delta: SnapshotDelta?) -> AnalysisResult {
        let rt = ResourceTracker.shared
        let total = rt.topApps.count
        let suspectCount = rt.leakSuspects.count
        let memGB = rt.latestReport?.totalMemGB ?? 0
        let statusChanged = delta?.statusChanged ?? false
        // 시스템 레인(앱 외부) 문제는 특정 앱 문제와 별개로 덧붙인다.
        let sysNote = systemHealthNote()
        // 고아 프로세스 확인된 앱 탐색 (drilldownApps 대상만 — FR3 온디맨드 판정 결과 소비)
        let orphanApp = rt.drilldownApps.first { app in
            rt.detailedProcesses(for: app).contains { $0.isOrphan }
        }
        let action    = orphanApp != nil ? "kill" : "none"
        let targetApp = orphanApp ?? ""

        switch snapshot.status {
        case .critical:
            return AnalysisResult(
                timestamp: Date(),
                severity: "critical",
                summary: "추적 중인 앱 \(total)개 중 \(suspectCount)개가 누수 의심 상태입니다. 상위 앱 총 \(String(format: "%.1f", memGB))GB를 점유해 시스템 자원이 심각하게 소모되고 있습니다.\(sysNote)",
                recommendation: orphanApp.map { "\($0)이(가) 고아 프로세스로 확인되어 종료를 권장합니다." } ?? "누수 의심 앱을 즉시 정리하세요.",
                shouldNotify: statusChanged || suspectCount > 10,
                notificationMessage: "심각: 누수의심 \(suspectCount)개·\(String(format: "%.1f", memGB))GB",
                isAIGenerated: false,
                suggestedAction: action,
                suggestedTargetApp: targetApp
            )
        case .warning:
            return AnalysisResult(
                timestamp: Date(),
                severity: "warning",
                summary: "추적 중인 앱 \(total)개 중 \(suspectCount)개가 누수 의심 상태입니다. \(String(format: "%.1f", memGB))GB의 메모리가 사용되고 있습니다.\(sysNote)",
                recommendation: orphanApp.map { "\($0)이(가) 고아 프로세스로 확인되어 종료를 권장합니다." } ?? "누수 의심 앱 정리를 고려하세요.",
                shouldNotify: statusChanged,
                notificationMessage: "경고: 누수의심 앱 \(suspectCount)개",
                isAIGenerated: false,
                suggestedAction: action,
                suggestedTargetApp: targetApp
            )
        case .normal:
            return AnalysisResult(
                timestamp: Date(),
                severity: "normal",
                summary: "추적 중인 앱 \(total)개 중 \(suspectCount)개가 누수 의심 상태입니다. 메모리 사용량은 \(String(format: "%.1f", memGB))GB입니다.\(sysNote)",
                recommendation: sysNote.isEmpty ? "현 상태를 유지하세요." : "특정 앱이 아니라 시스템 과부하는 앱 밖 원인을 확인하세요.",
                shouldNotify: false,
                notificationMessage: "",
                isAIGenerated: false,
                suggestedAction: action,
                suggestedTargetApp: targetApp
            )
        }
    }

    /// 시스템 레인(앱 외부)이 경고/위험이면 특정 앱 문제와 분명히 구분한 안내 문구를 반환.
    /// 정상이면 빈 문자열.
    private func systemHealthNote() -> String {
        let r = SystemHealthEvaluator.shared.report
        guard r.state != .normal else { return "" }
        // 소비(flow) 후보 우선. 원인 단정 없이 "소비 중" + 확인 엣지만.
        let c = r.candidates.first { $0.isConsuming } ?? r.candidates.first
        let who = c.map { " (\($0.name) \($0.resource.rawValue) 소비 중)" } ?? ""
        let edge: String
        if let cp = c?.causalPointer { edge = " — \(cp)" } else { edge = "" }
        let level = r.state == .critical ? "위험" : "경고"
        return " ⚠️ 이와 별개로, 시스템 자체가 \(level) 압박 상태입니다 — 이건 특정 앱이 아니라 앱 밖 신호입니다\(who)\(edge)."
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
    @Guide(description: "심각도 수준: 'normal', 'warning', 'critical' 중 정확히 하나. 제공된 상태·백엔드 판정을 넘지 말 것 — 근거 없는 'critical'을 지어내지 말 것.")
    var severity: String

    @Guide(description: "현재 상황을 2문장 이내 한국어로 요약. 제공된 프로세스 수·메모리 수치만 사용(없는 수치 생성 금지). 근본원인은 제공된 '확인:' 엣지로만 언급하고, 엣지가 없으면 원인 언급 금지('X 소비 중'까지만).")
    var summary: String

    @Guide(description: "즉시 해야 할 행동 1문장. 근거가 있으면 대상 앱을 지목한 구체적 처방(예: 'OO이 메모리를 지속 증가시키고 있어 종료를 권장합니다'). 불필요 시 '현 상태를 유지하세요.'")
    var recommendation: String

    @Guide(description: "알림 표시 필요 여부. 상태 전환이나 즉각 조치가 필요할 때만 true. 중복 알림 최소화.")
    var shouldNotify: Bool

    @Guide(description: "shouldNotify=true일 때만 작성. 20자 이내 한국어 알림 메시지. false면 빈 문자열.")
    var notificationMessage: String

    @Guide(description: "권장 조치: 'kill'(특정 앱 종료 권장)/'monitor'(관찰 지속)/'none'. 'kill'은 고아 확인·누수의심+압박 지속 등 제공된 사실에 기계적 근거가 있을 때만.")
    var suggestedAction: String

    @Guide(description: "suggestedAction='kill'일 때 대상 앱 이름(제공된 현황의 이름 그대로). 그 외 빈 문자열.")
    var suggestedTargetApp: String
}
#endif
