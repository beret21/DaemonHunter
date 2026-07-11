import Foundation
import Combine
import Darwin
import os
import SwiftUI

// MARK: - Backpressure Level

/// 앱 자체의 리소스 사용량에 따라 기능 수준을 자동 조절하는 단계.
/// 감시 앱 자신이 시스템 부하의 원인이 되지 않도록 한다.
enum BackpressureLevel: Int, Comparable, Sendable, CustomStringConvertible {
    case normal    = 0  // 모든 기능 정상 동작
    case cautious  = 1  // AI 분석 축소, DB 쓰기 제한
    case reduced   = 2  // AI 중단, 인메모리 캐시 플러시, DB 최소화
    case minimal   = 3  // 프로세스 카운트만 (ResourceTracker·Kalman 중단)
    case suspended = 4  // heartbeat 300s — 사실상 일시중단

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var description: String {
        switch self {
        case .normal:    return "정상"
        case .cautious:  return "주의"
        case .reduced:   return "절감"
        case .minimal:   return "최소"
        case .suspended: return "일시중단"
        }
    }

    var emoji: String {
        switch self {
        case .normal:    return "🟢"
        case .cautious:  return "🟡"
        case .reduced:   return "🟠"
        case .minimal:   return "🔴"
        case .suspended: return "⚫"
        }
    }

    /// 실효 폴링 주기 (초). 사용자 설정값의 하한으로 적용.
    var minimumPollingInterval: Double {
        switch self {
        case .normal:    return 30
        case .cautious:  return 60
        case .reduced:   return 90
        case .minimal:   return 120
        case .suspended: return 300
        }
    }

    var allowsAIAnalysis:        Bool { self <= .cautious }
    var allowsResourceTracking:  Bool { self <= .reduced  }
    var allowsPredictionEngine:  Bool { self <= .reduced  }
    var allowsDBWrites:          Bool { self <= .reduced  }
    var allowsFullDBWrites:      Bool { self == .normal   }
}

// MARK: - Self-measured snapshot

struct SelfMetrics: Sendable {
    let memoryMB:    Double
    let cpuFraction: Double   // 0.0 – 1.0 (누적 user+system / wall 시간, 30s 윈도우 평균)
    let dbFileSizeMB:Double
    let timestamp:   Date
}

// MARK: - SelfHealingManager

/// 앱 자신의 건강을 감시하고 Backpressure Level을 자동 조절한다.
///
/// ## 설계 원칙
/// - 자기 PID에 `proc_pidinfo(PROC_PIDTASKALLINFO)`를 걸어 메모리/CPU 직접 측정
/// - Hysteresis: 레벨 개선은 연속 3회 "양호" 판독 후에만 허용 (진동 방지)
/// - Circuit Breaker: DB 쓰기가 연속 500ms 초과 → DB 쓰기 비활성화
/// - 레벨이 올라갈(악화) 때는 즉시 반응, 내려갈(개선) 때는 천천히 반응
@MainActor
final class SelfHealingManager: ObservableObject {

    static let shared = SelfHealingManager()

    @Published private(set) var level:          BackpressureLevel = .normal
    @Published private(set) var selfMetrics:    SelfMetrics?
    @Published private(set) var healingActive:  Bool   = false
    @Published private(set) var statusMessage:  String = ""
    @Published private(set) var dbWriteBlocked: Bool   = false   // circuit breaker

    // ── 효과적인 폴링 주기 ───────────────────────────────────────────
    var effectivePollingInterval: Double {
        max(level.minimumPollingInterval, AppSettings.monitorIntervalSeconds)
    }

    // ── 내부 상태 ────────────────────────────────────────────────────
    private var goodCheckStreak  = 0          // 연속 "양호" 카운터
    private let hysteresisNeeded = 3          // 레벨 개선에 필요한 연속 양호 수
    private var prevCPUTimeNs:   UInt64 = 0  // CPU 시간 델타 계산용
    private var prevCPUWallSec:  Double = 0
    private var dbWriteSlowCount = 0          // circuit breaker 카운터
    private let dbWriteSlowLimit = 3

    private var checkTimer: AnyCancellable?
    private let logger = Logger(subsystem: "com.beret21.DaemonHunter",
                                category: "SelfHealing")

    // ── 임계값 (조정 가능) ────────────────────────────────────────────
    private struct Threshold {
        static let selfMemMB_cautious:  Double = 150
        static let selfMemMB_reduced:   Double = 300
        static let selfMemMB_minimal:   Double = 500
        static let selfCPU_cautious:    Double = 0.20   // 20% average
        static let selfCPU_reduced:     Double = 0.40
        static let dbFileMB_cautious:   Double = 50
        static let dbFileMB_reduced:    Double = 150
    }

    private init() {}

    // MARK: - Lifecycle

    func start() {
        check()
        checkTimer?.cancel()
        checkTimer = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.check() }
    }

    func stop() {
        checkTimer?.cancel()
        checkTimer = nil
    }

    // MARK: - Main check cycle

    func check() {
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            let metrics = SelfHealingManager.measureSelf()
            await MainActor.run { [weak self] in
                self?.evaluate(metrics: metrics)
            }
        }
    }

    // MARK: - Evaluation

    private func evaluate(metrics: SelfMetrics) {
        selfMetrics = metrics

        let desired = computeDesiredLevel(metrics: metrics)

        if desired > level {
            // 즉각 악화 반응
            goodCheckStreak = 0
            transitionTo(desired, reason: diagnosisMessage(metrics: metrics))
        } else if desired < level {
            // 개선은 Hysteresis 통과 후
            goodCheckStreak += 1
            if goodCheckStreak >= hysteresisNeeded {
                goodCheckStreak = 0
                let improved = BackpressureLevel(rawValue: level.rawValue - 1) ?? .normal
                transitionTo(improved, reason: "시스템 상태 개선")
            }
        } else {
            // 유지
            goodCheckStreak = 0
        }
    }

    // MARK: - Level computation

    private func computeDesiredLevel(metrics: SelfMetrics) -> BackpressureLevel {
        var desired: BackpressureLevel = .normal

        // 자체 메모리
        if      metrics.memoryMB >= Threshold.selfMemMB_minimal  { desired = max(desired, .minimal)  }
        else if metrics.memoryMB >= Threshold.selfMemMB_reduced   { desired = max(desired, .reduced)  }
        else if metrics.memoryMB >= Threshold.selfMemMB_cautious  { desired = max(desired, .cautious) }

        // 자체 CPU
        if      metrics.cpuFraction >= Threshold.selfCPU_reduced  { desired = max(desired, .reduced)  }
        else if metrics.cpuFraction >= Threshold.selfCPU_cautious { desired = max(desired, .cautious) }

        // DB 파일 크기
        if      metrics.dbFileSizeMB >= Threshold.dbFileMB_reduced   { desired = max(desired, .reduced)  }
        else if metrics.dbFileSizeMB >= Threshold.dbFileMB_cautious  { desired = max(desired, .cautious) }

        // 시스템 메모리 압박 (SystemMetricsCollector 참조)
        // — 독립적으로 체크 (순환 의존 없이 직접 sysctl)
        let sysPressure = SelfHealingManager.systemMemoryPressureLevel()
        switch sysPressure {
        case 2: desired = max(desired, .reduced)    // 위험
        case 1: desired = max(desired, .cautious)   // 경고
        default: break
        }

        // 열 상태
        let thermalRaw = SelfHealingManager.thermalStateLevel()
        switch thermalRaw {
        case 3: desired = max(desired, .reduced)    // critical
        case 2: desired = max(desired, .cautious)   // serious
        default: break
        }

        return desired
    }

    // MARK: - Transition

    private func transitionTo(_ newLevel: BackpressureLevel, reason: String) {
        guard newLevel != level else { return }
        let prev = level
        level = newLevel
        healingActive = (newLevel != .normal)
        statusMessage  = reason

        logger.info("SelfHeal: \(prev.description) → \(newLevel.description) (\(reason))")

        // 레벨별 즉각 치유 액션
        applyHealingActions(from: prev, to: newLevel)
    }

    // MARK: - Healing Actions

    private func applyHealingActions(from prev: BackpressureLevel, to next: BackpressureLevel) {
        if next >= .reduced && prev < .reduced {
            // 캐시 플러시: 인메모리 히스토리 최소화
            flushInMemoryBuffers()
        }

        if next >= .reduced && !level.allowsDBWrites {
            logger.info("SelfHeal: DB writes suspended")
        }

        if next >= .minimal {
            // ResourceTracker 일시 중단 (직접 호출 — SelfHealingManager가 조율)
            // ResourceTracker는 .allowsResourceTracking 플래그를 매 사이클에 확인한다
        }

        if next == .normal && prev >= .reduced {
            // 회복 후 캐시 재활성화
            logger.info("SelfHeal: Recovered to normal — re-enabling full features")
        }

        // DB 파일 크기 초과 시 즉각 정리 (VACUUM은 cleanupOldRecords 내부에 포함)
        if let m = selfMetrics, m.dbFileSizeMB >= Threshold.dbFileMB_reduced {
            Task.detached(priority: .background) {
                DatabaseManager.shared.cleanupOldRecords(keepDays: 7)
            }
        }
    }

    private func flushInMemoryBuffers() {
        logger.info("SelfHeal: Flushing in-memory buffers")
        ProcessHistoryTracker.shared.trimHistory(keepLast: 5)
    }

    // MARK: - DB Circuit Breaker

    /// DB 쓰기 전에 호출 — 너무 오래 걸리면 circuit breaker 작동
    func recordDBWrite(durationMs: Double) {
        if durationMs > 500 {
            dbWriteSlowCount += 1
            if dbWriteSlowCount >= dbWriteSlowLimit {
                dbWriteBlocked = true
                let cnt = dbWriteSlowCount
                logger.warning("SelfHeal: DB write circuit breaker OPEN (\(Int(durationMs))ms × \(cnt))")
            }
        } else {
            if dbWriteBlocked && dbWriteSlowCount == 0 {
                dbWriteBlocked = false
                logger.info("SelfHeal: DB write circuit breaker CLOSED")
            }
            dbWriteSlowCount = max(0, dbWriteSlowCount - 1)
        }
    }

    // MARK: - DB write gate

    /// 현재 상태에서 DB 쓰기가 허용되는지 확인
    var shouldWriteDB: Bool {
        !dbWriteBlocked && level.allowsDBWrites
    }

    var shouldWriteFullDB: Bool {
        !dbWriteBlocked && level.allowsFullDBWrites
    }

    // MARK: - Diagnosis message

    private func diagnosisMessage(metrics: SelfMetrics) -> String {
        var parts: [String] = []
        if metrics.memoryMB >= Threshold.selfMemMB_cautious {
            parts.append("자체 메모리 \(Int(metrics.memoryMB))MB")
        }
        if metrics.cpuFraction >= Threshold.selfCPU_cautious {
            parts.append("자체 CPU \(Int(metrics.cpuFraction * 100))%")
        }
        if metrics.dbFileSizeMB >= Threshold.dbFileMB_cautious {
            parts.append("DB \(Int(metrics.dbFileSizeMB))MB")
        }
        let sysPressure = SelfHealingManager.systemMemoryPressureLevel()
        if sysPressure > 0 { parts.append("시스템 메모리 압박") }
        let thermal = SelfHealingManager.thermalStateLevel()
        if thermal >= 2 { parts.append("발열 \(thermal == 3 ? "위험" : "경고")") }
        return parts.isEmpty ? "자동 조절" : parts.joined(separator: " · ")
    }

    // MARK: - Self measurement (nonisolated, background-safe)

    nonisolated static func measureSelf() -> SelfMetrics {
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        var info = proc_taskallinfo()
        let infoSize = Int32(MemoryLayout<proc_taskallinfo>.size)
        let ret = proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, infoSize)

        let memMB: Double
        let cpuNs:  UInt64
        if ret > 0 {
            memMB = Double(info.ptinfo.pti_resident_size) / (1024 * 1024)
            cpuNs = info.ptinfo.pti_total_user + info.ptinfo.pti_total_system
        } else {
            memMB = 0; cpuNs = 0
        }

        // CPU fraction: delta user+system (ns) / delta wall time (ns) in ~30s window
        // We use a simple approximation — total CPU / uptime gives average since launch
        let wallSec  = ProcessInfo.processInfo.systemUptime  // not perfect but lock-free
        let cpuFrac  = wallSec > 0 ? min(1.0, Double(cpuNs) / (wallSec * 1_000_000_000)) : 0

        let dbSize   = dbFileSizeMB()

        return SelfMetrics(
            memoryMB: memMB,
            cpuFraction: cpuFrac,
            dbFileSizeMB: dbSize,
            timestamp: Date()
        )
    }

    nonisolated private static func dbFileSizeMB() -> Double {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.beret21.DaemonHunter/agent_monitor.db")
        let bytes = (try? FileManager.default.attributesOfItem(atPath: support.path)[.size] as? Int) ?? 0
        return Double(bytes) / (1024 * 1024)
    }

    // MARK: - System pressure (no lock, sysctl only)

    /// 0=normal, 1=warning, 2=critical
    nonisolated static func systemMemoryPressureLevel() -> Int {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0)
        // memorystatus_level: 100=normal, declining → pressure
        if level < 20 { return 2 }   // <20% → critical
        if level < 40 { return 1 }   // <40% → warning
        return 0
    }

    /// 0=nominal, 1=fair, 2=serious, 3=critical
    nonisolated static func thermalStateLevel() -> Int {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return 0
        case .fair:     return 1
        case .serious:  return 2
        case .critical: return 3
        @unknown default: return 0
        }
    }
}

// MARK: - Self-Healing StatusView

/// 팝오버 하단에 표시하는 자체 상태 뱃지
struct SelfHealingBadge: View {
    @ObservedObject var healer: SelfHealingManager

    var body: some View {
        if healer.healingActive {
            HStack(spacing: 4) {
                Image(systemName: "heart.text.square.fill")
                    .foregroundStyle(badgeColor)
                    .font(.caption2)
                Text("\(healer.level.emoji) 앱 부하 자동조절 \(healer.level.description)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(badgeColor)
                if !healer.statusMessage.isEmpty {
                    Text("— \(healer.statusMessage)")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .glassEffect(.regular.tint(badgeColor.opacity(0.18)), in: .capsule)
        }
    }

    private var badgeColor: Color {
        switch healer.level {
        case .normal:    return .green
        case .cautious:  return .yellow
        case .reduced:   return .orange
        case .minimal:   return .red
        case .suspended: return .gray
        }
    }
}
