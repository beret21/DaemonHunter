import Foundation
import Combine
import Darwin
import AppKit   // NSWorkspace.frontmostApplication (포그라운드 워크로드 식별)

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

/// 오버헤드 후보 1건. 실제로 죽이지 않고 리포트만 한다.
///
/// 합의 1·11: 후보는 **"소비 중(consuming)"** 이지 원인이 아니다. 인과 단정 금지.
/// `causalPointer`는 결론이 아니라 반증 가능한 **"다음 확인 대상"**(부모 pid·상위 소비 자원).
struct OverheadCandidate: Identifiable, Sendable, Hashable {
    let pid: Int
    let name: String
    let resource: OverheadResource
    let value: Double            // CPU% · 메모리MB · 스왑MB
    let durationSeconds: Double  // 관측된 소비 지속시간(연속 고부하 또는 상주시간)
    let uptimeMinutes: Double
    let isChronic: Bool          // true=장시간 지속 소비 관측, false=일시(양성) — UI 뱃지용
    let suggestion: String
    // ── 재설계 추가 필드(기존 UI 비파괴, 필드만 추가) ──────────────────
    let isConsuming: Bool        // true=현재 활발히 소비(flow) · false=parked(압박 임계 넘어 편입된 잠재 위험/eviction 후보)
    let causalPointer: String?   // 인과 확인 포인터 — "다음 확인 대상"(부모 pid 등). 결론 아님.
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
    // ── 재설계 추가 필드 ─────────────────────────────────────────────
    let cpuLoadRatio: Double            // load average(1m, 자기 부하 제외) / 활성 코어수 — >1이면 CPU 압박
    let swapIOPagesPerSec: Double       // 스왑 IO 처리율(크기 아님) — 스래싱 신호
    let memTimeToExhaustionSeconds: Double?   // 정직한 선형 외삽(rate 안정 시에만), 그 외 nil
    let swapTimeToExhaustionSeconds: Double?
    let foregroundAppPID: Int?          // NSWorkspace 포그라운드 앱 pid (starvation 판정 맥락)

    static let empty = SystemHealthReport(
        state: .normal, swapUsedGB: 0, swapRatio: 0, memPressureLevel: 0,
        candidates: [], summary: "관측 대기 중", updatedAt: Date(),
        cpuLoadRatio: 0, swapIOPagesPerSec: 0,
        memTimeToExhaustionSeconds: nil, swapTimeToExhaustionSeconds: nil,
        foregroundAppPID: nil
    )
}

// MARK: - SystemHealthEvaluator

/// 시스템 **압박(pressure)**에서 심각도를 판정한다. per-process 절대 레벨이 아니다.
///
/// ## 재설계 원칙 (studio×mactr 합의 1·2·3·4·5·6·8)
/// - **심각도 = 시스템 압박**(load≫코어 · 메모리 압박 · swap IO rate) × 포그라운드 주목.
///   per-process는 "소비"일 뿐 인과가 아니다.
/// - **레벨 ≠ 심각도(stock)**: 유휴 대용량 메모리 프로세스는 압박이 낮으면 무해(parked)로
///   **후보에서 제외**. 메모리 압박이 임계를 넘을 때만 eviction 후보로 표시.
///   → `corespotlightd` 유휴 1.9GB 같은 오탐 제거.
/// - **swap은 크기(ratio)가 아니라 IO rate(throughput)로** 스래싱을 본다.
/// - **"위험(critical)"은 압박이 높고 포그라운드/상호작용 워크로드가 굶을 때만.** 정밀 측정이
///   어려우므로 실용 프록시: 메모리 압박 위험 · swap IO 스래싱 · load ≫ 코어. 그 외는 경고.
/// - **비대칭 히스테리시스**: 올릴 땐 즉시, 내릴 땐 연속 clear 후에만(flapping 방지).
/// - **관측자 효과**: DaemonHunter 자기 pid의 부하는 압박·후보에서 뺀다.
/// - **정직한 예측만**: 학습된 정상(칼만 잔차) 대신 fill rate 선형 외삽 time-to-exhaustion,
///   rate가 안정적일 때만 신뢰.
@MainActor
final class SystemHealthEvaluator: ObservableObject {
    static let shared = SystemHealthEvaluator()

    @Published private(set) var report = SystemHealthReport.empty

    // ── 튜닝 상수 ────────────────────────────────────────────────────
    private let highCPUPercent  = 50.0     // 이 이상이면 "CPU 소비 중" 후보로 편입(flow)
    private let idleCPUPercent   = 5.0     // 이 미만이면 유휴로 간주
    private let idleMemThresholdMB = 1500.0 // 유휴이면서 이만큼 점유 → 압박 시 eviction 후보
    private let chronicSustainedSeconds = 600.0  // 연속 10분↑ 관측 → "지속 소비"(UI 만성 뱃지)
    private let chronicUptimeMinutes    = 60.0
    private let chronicLifetimeAvgCPU   = 50.0

    // swap IO rate 임계 (pages/sec). 16KB page 기준 대략 warn≈0.8MB/s, crit≈8MB/s 지속.
    nonisolated private static let swapWarnPagesPerSec = 50.0
    nonisolated private static let swapCritPagesPerSec = 500.0
    // load ≫ 코어: 코어수의 이 배수를 넘으면 심각한 run-queue 포화로 본다.
    private let loadCriticalMultiplier = 2.0

    // time-to-exhaustion 신뢰 게이팅
    private let rateWindowSize   = 5        // 최근 표본 수
    private let minFillRateGBs   = 0.001    // 1MB/s 미만 증가는 노이즈로 무시
    private let rateStabilityCV  = 0.5      // 변동계수 이 미만일 때만 외삽 신뢰

    // 히스테리시스
    private let clearsNeededToLower = 3     // 내릴 때 필요한 연속 clear 수

    // ── 상태(히스테리시스 · fill rate 외삽) ──────────────────────────
    private var currentState: SystemHealthState = .normal
    private var clearStreak = 0
    private var prevMemUsedGB:  Double?
    private var prevSwapUsedGB: Double?
    private var prevFillTime:   Date?
    private var memRateWindow:  [Double] = []
    private var swapRateWindow: [Double] = []

    private init() {}

    // MARK: - Evaluate

    /// 한 폴링 주기 평가. GlobalProcessScanner.refresh() 이후 호출.
    func evaluate() {
        let m = SystemMetricsCollector.shared.current
        let procs = GlobalProcessScanner.shared.topProcesses
        let memPressure = SelfHealingManager.systemMemoryPressureLevel()

        // 관측자 효과: 자기 pid는 압박·후보 판정에서 제외.
        let selfPID = Int(ProcessInfo.processInfo.processIdentifier)

        // 포그라운드(사용자 주목) 워크로드.
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let foregroundPID = frontPID.map { Int($0) }

        // ── 압박 신호 계산 ───────────────────────────────────────────
        let cores = Self.activeCoreCount()
        // load average는 자기 CPU 기여분(≈코어 환산)을 빼서 관측자 효과를 정직하게 보정.
        let selfLoad = SelfHealingManager.shared.selfMetrics?.cpuFraction ?? 0
        let load1 = max(0, m.loadAvg1min - selfLoad)
        let cpuLoadRatio = load1 / max(1, Double(cores))

        let swapIO = m.swapIOPagesPerSec
        let swapThrashWarn = swapIO >= Self.swapWarnPagesPerSec
        let swapThrashCrit = swapIO >= Self.swapCritPagesPerSec
        let loadWayOverCores = load1 > Double(cores) * loadCriticalMultiplier

        // ── time-to-exhaustion (정직한 선형 외삽) ────────────────────
        let now = Date()
        if let pt = prevFillTime, let pMem = prevMemUsedGB, let pSwap = prevSwapUsedGB {
            let dt = now.timeIntervalSince(pt)
            if dt > 0 {
                push(&memRateWindow,  (m.memUsedGB  - pMem)  / dt)
                push(&swapRateWindow, (m.swapUsedGB - pSwap) / dt)
            }
        }
        prevMemUsedGB = m.memUsedGB; prevSwapUsedGB = m.swapUsedGB; prevFillTime = now
        let memTTE  = timeToExhaustion(rates: memRateWindow,  remaining: m.memTotalGB  - m.memUsedGB)
        let swapTTE = timeToExhaustion(rates: swapRateWindow, remaining: max(0, m.swapTotalGB - m.swapUsedGB))

        // ── 후보 수집 (소비 중; 인과 단정 금지) ──────────────────────
        var candidates: [OverheadCandidate] = []

        // CPU: flow(rate) 그대로 — 현재 활발히 소비하는 프로세스.
        for p in procs where p.pid != selfPID && p.cpuPercent >= highCPUPercent {
            let sustainedConsume = isSustainedCPU(p)
            let duration = sustainedConsume
                ? max(p.sustainedHighCPUSeconds, p.uptimeMinutes * 60.0)
                : p.sustainedHighCPUSeconds
            candidates.append(OverheadCandidate(
                pid: p.pid, name: p.name, resource: .cpu,
                value: p.cpuPercent, durationSeconds: duration,
                uptimeMinutes: p.uptimeMinutes, isChronic: sustainedConsume,
                suggestion: "\(p.name) — CPU \(pct(p.cpuPercent)) 소비 중 (\(Self.humanDuration(duration)) 관측)",
                isConsuming: true,
                causalPointer: causalPointer(for: p, topResource: "CPU")
            ))
        }

        // 메모리: stock ≠ 심각도. 유휴 대용량은 압박이 낮으면 무해(parked) → 제외.
        //         메모리 압박이 임계(≥경고)를 넘을 때만 잠재 위험(eviction 후보)으로 표시.
        //         → corespotlightd 유휴 1.9GB 오탐 제거.
        if memPressure >= 1 {
            for p in procs where p.pid != selfPID
                && p.memMB >= idleMemThresholdMB && p.cpuPercent < idleCPUPercent {
                candidates.append(OverheadCandidate(
                    pid: p.pid, name: p.name, resource: .memory,
                    value: p.memMB, durationSeconds: p.uptimeMinutes * 60.0,
                    uptimeMinutes: p.uptimeMinutes,
                    isChronic: p.uptimeMinutes >= chronicUptimeMinutes,
                    suggestion: "\(p.name) — 유휴 상태로 \(gb(p.memMB)) 점유. 메모리 압박 중이라 회수(eviction) 후보",
                    isConsuming: false,   // parked — 압박 임계를 넘겨 편입된 잠재 위험
                    causalPointer: causalPointer(for: p, topResource: "메모리")
                ))
            }
        }

        // 스왑: 크기(ratio) 아님 → IO rate 스래싱일 때만. 최다 메모리 소비자를 기여자로.
        if swapThrashWarn,
           let top = procs.filter({ $0.pid != selfPID }).max(by: { $0.memMB < $1.memMB }) {
            candidates.append(OverheadCandidate(
                pid: top.pid, name: top.name, resource: .swap,
                value: m.swapUsedGB * 1024.0, durationSeconds: top.uptimeMinutes * 60.0,
                uptimeMinutes: top.uptimeMinutes, isChronic: swapThrashCrit,
                suggestion: "스왑 IO \(String(format: "%.0f", swapIO)) pages/s 스래싱 — 최다 메모리 \(top.name)(\(gb(top.memMB))) 소비 중",
                isConsuming: true,
                causalPointer: causalPointer(for: top, topResource: "메모리")
            ))
        }

        // ── 심각도 판정 (압박 기반) ──────────────────────────────────
        // critical: 압박이 높고 포그라운드/상호작용 워크로드가 굶을 때만.
        //   정밀 starvation 측정이 어려우므로 실용 프록시(합의 6): 메모리 압박 위험 · swap 스래싱 · load≫코어.
        //   못 보이면 위험이라 하지 않는다(억지 추론 금지) → 그 외 압박은 경고.
        let criticalPressure = (memPressure >= 2) || swapThrashCrit || loadWayOverCores
        let warningPressure  = (memPressure >= 1) || (cpuLoadRatio > 1.0) || swapThrashWarn

        var desired: SystemHealthState = .normal
        if criticalPressure       { desired = .critical }
        else if warningPressure   { desired = .warning }

        let state = applyHysteresis(desired: desired)

        // 소비(flow) 우선, 그다음 값 큰 순.
        candidates.sort { a, b in
            if a.isConsuming != b.isConsuming { return a.isConsuming }
            return a.value > b.value
        }

        report = SystemHealthReport(
            state: state,
            swapUsedGB: m.swapUsedGB,
            swapRatio: m.swapUsageRatio,
            memPressureLevel: memPressure,
            candidates: candidates,
            summary: Self.summarize(state: state, candidates: candidates,
                                    memPressure: memPressure, cpuLoadRatio: cpuLoadRatio,
                                    swapIO: swapIO, memTTE: memTTE, swapTTE: swapTTE),
            updatedAt: now,
            cpuLoadRatio: cpuLoadRatio,
            swapIOPagesPerSec: swapIO,
            memTimeToExhaustionSeconds: memTTE,
            swapTimeToExhaustionSeconds: swapTTE,
            foregroundAppPID: foregroundPID
        )
    }

    // MARK: - Hysteresis (올릴 땐 즉시, 내릴 땐 연속 clear 후)

    private func applyHysteresis(desired: SystemHealthState) -> SystemHealthState {
        if desired > currentState {
            currentState = desired          // 악화는 즉시 반영
            clearStreak = 0
        } else if desired < currentState {
            clearStreak += 1                // 개선은 연속 clear 통과 후 한 단계씩
            if clearStreak >= clearsNeededToLower {
                clearStreak = 0
                currentState = SystemHealthState(rawValue: currentState.rawValue - 1) ?? .normal
            }
        } else {
            clearStreak = 0
        }
        return currentState
    }

    // MARK: - Time-to-exhaustion (정직한 선형 외삽 + 안정성 게이팅)

    private func push(_ window: inout [Double], _ v: Double) {
        window.append(v)
        if window.count > rateWindowSize { window.removeFirst(window.count - rateWindowSize) }
    }

    /// 최근 fill rate가 (a) 창을 채웠고 (b) 유의미하게 양(+)이고 (c) 안정적(변동계수 낮음)일
    /// 때만 remaining/mean 을 반환. 그 외엔 nil — 불안정한 예측은 하지 않는다.
    private func timeToExhaustion(rates: [Double], remaining: Double) -> Double? {
        guard rates.count >= rateWindowSize, remaining > 0 else { return nil }
        let mean = rates.reduce(0, +) / Double(rates.count)
        guard mean > minFillRateGBs else { return nil }
        let variance = rates.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(rates.count)
        let cv = variance.squareRoot() / mean
        guard cv < rateStabilityCV else { return nil }
        return remaining / mean
    }

    // MARK: - Classification helpers

    /// 장시간 지속 소비 관측 여부 (UI "만성/일시" 뱃지용 — 위험 판정과 무관).
    private func isSustainedCPU(_ p: GlobalProcess) -> Bool {
        if p.sustainedHighCPUSeconds >= chronicSustainedSeconds { return true }
        if p.uptimeMinutes >= chronicUptimeMinutes
            && p.lifetimeAvgCPUPercent >= chronicLifetimeAvgCPU { return true }
        return false
    }

    /// 인과 확인 포인터(결론 아님). 부모 pid가 launchd(1)가 아니면 그걸 "다음 확인 대상"으로.
    private func causalPointer(for p: GlobalProcess, topResource: String) -> String? {
        if p.ppid > 1 { return "확인: 부모 pid \(p.ppid) · 상위 소비 \(topResource)" }
        return "확인: 상위 소비 \(topResource)"
    }

    /// 활성 코어수 (hw.ncpu).
    private static func activeCoreCount() -> Int {
        var n: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.ncpu", &n, &size, nil, 0) == 0, n > 0 { return Int(n) }
        return max(1, ProcessInfo.processInfo.activeProcessorCount)
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
                                      memPressure: Int,
                                      cpuLoadRatio: Double,
                                      swapIO: Double,
                                      memTTE: Double?,
                                      swapTTE: Double?) -> String {
        var parts: [String] = []
        if memPressure >= 2       { parts.append("메모리 압박 위험") }
        else if memPressure == 1  { parts.append("메모리 압박 경고") }
        if cpuLoadRatio > 1.0     { parts.append(String(format: "CPU 부하 %.1f×코어", cpuLoadRatio)) }
        if swapIO >= swapWarnPagesPerSec {
            parts.append(String(format: "스왑 IO %.0f p/s", swapIO))
        }
        let cpuConsumers = candidates.filter { $0.resource == .cpu }.count
        if cpuConsumers > 0 { parts.append("CPU 소비 \(cpuConsumers)건") }
        // 정직한 예측: 임박한 소진만 알린다.
        if let t = swapTTE, t < 3600 {
            parts.append("스왑 소진 예상 ~\(humanDuration(t))")
        } else if let t = memTTE, t < 1800 {
            parts.append("메모리 소진 예상 ~\(humanDuration(t))")
        }
        if parts.isEmpty { return "정상 — 압박 신호 없음" }
        return "\(state.emoji) " + parts.joined(separator: " · ")
    }
}
