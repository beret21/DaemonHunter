import Foundation
import Combine

// MARK: - Overhead finder types

enum SystemHealthState: Int, Comparable, Sendable {
    case normal   = 0
    case warning  = 1
    case critical = 2
    static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }

    var emoji: String {
        switch self {
        case .normal:   return "🟢"
        case .warning:  return "🟡"
        case .critical: return "🔴"
        }
    }
}

enum OverheadResource: String, Sendable {
    case cpu    = "CPU"
    case memory = "메모리"
    case swap   = "스왑"
}

/// 오버헤드 회수 후보 1건. 실제로 죽이지 않고 리포트만 한다.
struct OverheadCandidate: Identifiable, Sendable, Hashable {
    let pid: Int
    let name: String
    let resource: OverheadResource
    let value: Double            // CPU% · 메모리MB · 스왑MB
    let durationSeconds: Double  // 고부하/점유 지속시간(만성이면 생존시간 반영)
    let uptimeMinutes: Double
    let isChronic: Bool          // true=만성(장시간), false=양성 일시부하
    let suggestion: String
    var id: String { "\(pid)-\(resource.rawValue)" }   // 같은 pid가 CPU·메모리 후보로 중복돼도 고유
}

/// 시스템 건강 + 오버헤드 파인더 결과.
struct SystemHealthReport: Sendable {
    let state: SystemHealthState
    let swapUsedGB: Double
    let swapRatio: Double
    let memPressureLevel: Int          // 0=정상 1=경고 2=위험 (kern.memorystatus_level)
    let candidates: [OverheadCandidate]
    let summary: String
    let updatedAt: Date

    static let empty = SystemHealthReport(
        state: .normal, swapUsedGB: 0, swapRatio: 0, memPressureLevel: 0,
        candidates: [], summary: "관측 대기 중", updatedAt: Date()
    )
}

// MARK: - SystemHealthEvaluator

/// 절대 임계값으로 시스템 건강을 판정하고 오버헤드 회수 후보를 만든다.
///
/// ## 만성(chronic) vs 양성 일시부하(benign) 구분
/// - **만성**: (앱이 관측한 연속 고부하 ≥ 10분) **또는** (생존시간이 길고 생애평균 CPU가 높음).
///   두 번째 조건 덕에 앱 기동 직후에도 이미 폭주 중인 데몬(예: cloudd 13일째 198%)을 즉시 잡는다.
/// - **양성 일시부하**: 최근에 뜬 프로세스(생존시간 짧음)의 고CPU — 부팅 후 색인 등. 만성 조건 미충족.
@MainActor
final class SystemHealthEvaluator: ObservableObject {
    static let shared = SystemHealthEvaluator()

    @Published private(set) var report = SystemHealthReport.empty

    // ── 튜닝 상수 ────────────────────────────────────────────────────
    private let swapWarnRatio   = 0.50
    private let swapCritRatio   = 0.80
    private let highCPUPercent  = 50.0     // 고부하 후보 편입 기준
    private let critCPUPercent  = 150.0    // 단독으로도 위험(코어 1.5개 지속 점유)
    private let chronicSustainedSeconds = 600.0    // 연속 10분 → 만성
    private let chronicUptimeMinutes    = 60.0     // 생존 1시간↑ + 높은 생애평균 → 이미 만성
    private let chronicLifetimeAvgCPU   = 50.0
    private let benignUptimeMinutes     = 10.0     // 10분 미만 → 일시부하로 간주
    private let idleMemThresholdMB      = 1500.0   // 유휴인데 이만큼 점유하면 후보
    private let idleCPUPercent          = 5.0

    private init() {}

    // MARK: - Evaluate

    /// 한 폴링 주기 평가. GlobalProcessScanner.refresh() 이후 호출.
    func evaluate() {
        let m = SystemMetricsCollector.shared.current
        let procs = GlobalProcessScanner.shared.topProcesses
        let memPressure = SelfHealingManager.systemMemoryPressureLevel()

        var candidates: [OverheadCandidate] = []

        // ── CPU 후보 ─────────────────────────────────────────────────
        for p in procs where p.cpuPercent >= highCPUPercent {
            let chronic = isChronicCPU(p)
            // 최근 기동한 프로세스의 고CPU는 (만성 아니면) 일시부하로 표기
            let benignTransient = !chronic && p.uptimeMinutes < benignUptimeMinutes

            // 만성이면 생존시간을, 아니면 앱 관측 연속 지속시간을 대표 지속시간으로.
            let duration = chronic
                ? max(p.sustainedHighCPUSeconds, p.uptimeMinutes * 60.0)
                : p.sustainedHighCPUSeconds

            let suggestion: String
            if chronic {
                suggestion = "\(p.name) — CPU \(pct(p.cpuPercent)) \(Self.humanDuration(duration)) 지속 → 재시작/재부팅 검토"
            } else if benignTransient {
                suggestion = "\(p.name) — CPU \(pct(p.cpuPercent)) (기동 \(Self.humanDuration(p.uptimeMinutes * 60))) 일시 부하로 보임 (색인 등)"
            } else {
                suggestion = "\(p.name) — CPU \(pct(p.cpuPercent)) 관찰 중"
            }

            candidates.append(OverheadCandidate(
                pid: p.pid, name: p.name, resource: .cpu,
                value: p.cpuPercent, durationSeconds: duration,
                uptimeMinutes: p.uptimeMinutes, isChronic: chronic,
                suggestion: suggestion
            ))
        }

        // ── 메모리 후보 (유휴인데 대용량 점유) ───────────────────────
        for p in procs where p.memMB >= idleMemThresholdMB && p.cpuPercent < idleCPUPercent {
            let chronic = p.uptimeMinutes >= chronicUptimeMinutes
            candidates.append(OverheadCandidate(
                pid: p.pid, name: p.name, resource: .memory,
                value: p.memMB, durationSeconds: p.uptimeMinutes * 60.0,
                uptimeMinutes: p.uptimeMinutes, isChronic: chronic,
                suggestion: "\(p.name) — 유휴 상태로 메모리 \(gb(p.memMB)) 점유 → 필요 여부 확인"
            ))
        }

        // ── 스왑 압박: 최상위 메모리 프로세스를 기여자로 표기 ────────
        let swapRatio = m.swapUsageRatio
        if swapRatio >= swapWarnRatio, let top = procs.max(by: { $0.memMB < $1.memMB }) {
            candidates.append(OverheadCandidate(
                pid: top.pid, name: top.name, resource: .swap,
                value: m.swapUsedGB * 1024.0, durationSeconds: top.uptimeMinutes * 60.0,
                uptimeMinutes: top.uptimeMinutes,
                isChronic: swapRatio >= swapCritRatio,
                suggestion: "스왑 \(String(format: "%.0f%%", swapRatio * 100)) 사용 — 최다 메모리 \(top.name)(\(gb(top.memMB))) → 메모리 확보 검토"
            ))
        }

        // ── 시스템 상태 판정 ─────────────────────────────────────────
        let hasChronicCPU = candidates.contains { $0.resource == .cpu && $0.isChronic }
        let hasCritCPU    = candidates.contains { $0.resource == .cpu && $0.value >= critCPUPercent && $0.isChronic }

        var state: SystemHealthState = .normal
        if swapRatio >= swapCritRatio || memPressure >= 2 || hasCritCPU {
            state = .critical
        } else if swapRatio >= swapWarnRatio || memPressure == 1 || hasChronicCPU {
            state = .warning
        }

        // 만성 → 위험/경고 정렬 우선
        candidates.sort { a, b in
            if a.isChronic != b.isChronic { return a.isChronic }
            return a.value > b.value
        }

        report = SystemHealthReport(
            state: state,
            swapUsedGB: m.swapUsedGB,
            swapRatio: swapRatio,
            memPressureLevel: memPressure,
            candidates: candidates,
            summary: Self.summarize(state: state, candidates: candidates,
                                    swapRatio: swapRatio, memPressure: memPressure),
            updatedAt: Date()
        )
    }

    // MARK: - Classification

    private func isChronicCPU(_ p: GlobalProcess) -> Bool {
        if p.sustainedHighCPUSeconds >= chronicSustainedSeconds { return true }
        if p.uptimeMinutes >= chronicUptimeMinutes
            && p.lifetimeAvgCPUPercent >= chronicLifetimeAvgCPU { return true }
        return false
    }

    // MARK: - Formatting

    private func pct(_ v: Double) -> String { String(format: "%.0f%%", v) }
    private func gb(_ mb: Double) -> String { String(format: "%.1fGB", mb / 1024.0) }

    /// 초 → 사람이 읽는 지속시간 (일/시간/분).
    nonisolated static func humanDuration(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)일" + (h > 0 ? " \(h)시간" : "") }
        if h > 0 { return "\(h)시간" + (m > 0 ? " \(m)분" : "") }
        return "\(m)분"
    }

    nonisolated static func summarize(state: SystemHealthState,
                                      candidates: [OverheadCandidate],
                                      swapRatio: Double,
                                      memPressure: Int) -> String {
        var parts: [String] = []
        let chronic = candidates.filter(\.isChronic)
        if !chronic.isEmpty { parts.append("만성 과부하 \(chronic.count)건") }
        let transient = candidates.filter { $0.resource == .cpu && !$0.isChronic }
        if !transient.isEmpty { parts.append("일시부하 \(transient.count)건") }
        if swapRatio >= 0.5 { parts.append(String(format: "스왑 %.0f%%", swapRatio * 100)) }
        if memPressure >= 2 { parts.append("메모리 압박 위험") }
        else if memPressure == 1 { parts.append("메모리 압박 경고") }
        if parts.isEmpty { return "정상 — 회수 대상 없음" }
        return "\(state.emoji) " + parts.joined(separator: " · ")
    }
}
