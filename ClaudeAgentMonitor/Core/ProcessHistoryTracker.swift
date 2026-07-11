import Foundation
import Combine
import os

// MARK: - Models

enum GrowthPattern: String, Sendable {
    case stable       = "안정"
    case slowGrowing  = "완만 증가"
    case fastGrowing  = "급속 증가"
    case spike        = "일시 급증"
    case shrinking    = "감소 중"
}

struct ProcessGroup: Sendable, Identifiable {
    var id: String { type }
    let type: String          // "resume", "fresh", "longRunning(Xh)", 모델명 등
    let count: Int
    let deltaFromPrev: Int    // 이전 스냅샷 대비 ±
    let avgMemMB: Double
    let avgAgeMins: Double
}

struct ChronicLeaker: Sendable, Identifiable {
    let id: Int  // PID
    let pid: Int
    let consecutiveSnapshots: Int
    let queueDwellMinutes: Double  // 스냅샷에 연속 등장한 실제 시간
    let avgMemMB: Double
    let leakReason: String
    let ageFormatted: String
}

struct TrendAnalysis: Sendable {
    let pattern: GrowthPattern
    let countHistory: [Int]         // 최근 N 스냅샷의 프로세스 수
    let leakHistory: [Int]          // 최근 N 스냅샷의 누수 수
    let newPerInterval: Double      // 평균 신규 프로세스/인터벌
    let chronicLeakers: [ChronicLeaker]
    let processGroups: [ProcessGroup]
    let spikeProbability: Double    // 0.0~1.0 (일시 급증 가능성)
    let trendDurationMinutes: Double
    let slopePerMinute: Double      // 프로세스/분 기울기

    static let empty = TrendAnalysis(
        pattern: .stable, countHistory: [], leakHistory: [],
        newPerInterval: 0, chronicLeakers: [], processGroups: [],
        spikeProbability: 0, trendDurationMinutes: 0, slopePerMinute: 0
    )

    var patternEmoji: String {
        switch pattern {
        case .stable:      return "━"
        case .slowGrowing: return "↗"
        case .fastGrowing: return "⬆"
        case .spike:       return "⚡"
        case .shrinking:   return "↘"
        }
    }
}

// MARK: - Tracker

@MainActor
final class ProcessHistoryTracker: ObservableObject {
    @Published private(set) var analysis = TrendAnalysis.empty

    private let maxHistory    = 30   // ~15분 (30s × 30)
    private let analysisWindow = 10  // 기울기 계산에 쓸 최근 스냅샷 수 (5분)
    private let chronicThreshold = 5 // N스냅샷 이상 연속 등장 → chronic

    // PID → 연속 등장 카운터
    private var consecutiveCounts: [Int: Int] = [:]
    // 이전 스냅샷 프로세스 목록 (그룹 delta 계산용)
    private var previousProcesses: [AgentProcess] = []
    // 히스토리 (스냅샷 시각 포함)
    private var history: [(timestamp: Date, snapshot: ProcessSnapshot)] = []

    private let logger = Logger(subsystem: "com.beret21.DaemonHunter", category: "HistoryTracker")

    static let shared = ProcessHistoryTracker()
    private init() {}

    // MARK: - Self-healing support

    /// SelfHealingManager 요청 시 인메모리 히스토리를 최근 N개로 트림.
    func trimHistory(keepLast n: Int) {
        guard history.count > n else { return }
        history = Array(history.suffix(n))
    }

    // MARK: - Record

    func record(_ snapshot: ProcessSnapshot) {
        let entry = (timestamp: Date(), snapshot: snapshot)

        // 신규 프로세스 계산 (DB 저장 전에)
        let prevPIDs    = Set(previousProcesses.map(\.pid))
        let newProcs    = snapshot.processes.filter { !prevPIDs.contains($0.pid) }
        let leakedProcs = snapshot.processes.filter(\.isLeaked)

        history.append(entry)
        if history.count > maxHistory { history.removeFirst() }

        updateConsecutiveCounts(current: snapshot.processes)
        analysis = computeAnalysis(snapshot: snapshot)

        let capturedAnalysis = analysis
        let capturedSnapshot = snapshot
        let capturedStatus   = snapshot.status.rawValue

        // 매 5번째 스냅샷마다 DB에 저장 (너무 잦은 쓰기 방지)
        // 단, 이번 세션의 첫 스냅샷은 즉시 저장 — 재시작 직후 팝오버 트렌드 차트가
        // 몇 분간 이전 세션의 마지막 DB 행에 멈춰 보이는 것을 방지.
        let shouldPersist = history.count == 1 || history.count % 5 == 0
        if shouldPersist || !newProcs.isEmpty {
            let newRecords = newProcs.map {
                ProcessEventRecord(pid: $0.pid, ppid: $0.ppid,
                                   ageMinutes: $0.ageMinutes, memMB: $0.memMB,
                                   cmdArgs: $0.cmdArgs, leakReason: $0.leakReason)
            }
            Task.detached(priority: .background) {
                if shouldPersist {
                    DatabaseManager.shared.insertSnapshot(
                        snapshot: capturedSnapshot,
                        pattern: capturedAnalysis.pattern.rawValue,
                        slope: capturedAnalysis.slopePerMinute,
                        newProcesses: newRecords
                    )
                }
                // 신규 프로세스 → spawn 이벤트
                if !newRecords.isEmpty {
                    let events = newRecords.map {
                        (record: $0, type: "spawn", status: capturedStatus, refId: nil as Int64?)
                    }
                    DatabaseManager.shared.insertProcessEvents(events)
                }
            }
        }

        // 누수 판정된 프로세스 → leak_detected 이벤트 (상태가 바뀐 것만)
        let prevLeakedPIDs = Set(previousProcesses.filter(\.isLeaked).map(\.pid))
        let newLeaked      = leakedProcs.filter { !prevLeakedPIDs.contains($0.pid) }
        if !newLeaked.isEmpty {
            let leakRecords = newLeaked.map {
                ProcessEventRecord(pid: $0.pid, ppid: $0.ppid,
                                   ageMinutes: $0.ageMinutes, memMB: $0.memMB,
                                   cmdArgs: $0.cmdArgs, leakReason: $0.leakReason)
            }
            Task.detached(priority: .background) {
                let events = leakRecords.map {
                    (record: $0, type: "leak_detected", status: capturedStatus, refId: nil as Int64?)
                }
                DatabaseManager.shared.insertProcessEvents(events)
            }
        }

        // 유휴 상태로 전환된 서브에이전트 → idle_detected 이벤트 (상태 전환만)
        let prevIdlePIDs = Set(previousProcesses.filter(\.isIdle).map(\.pid))
        let newIdle = snapshot.processes.filter { $0.isIdle && !prevIdlePIDs.contains($0.pid) }
        if !newIdle.isEmpty {
            let idleRecords = newIdle.map {
                ProcessEventRecord(pid: $0.pid, ppid: $0.ppid,
                                   ageMinutes: $0.ageMinutes, memMB: $0.memMB,
                                   cmdArgs: $0.cmdArgs, leakReason: $0.leakReason)
            }
            Task.detached(priority: .background) {
                let events = idleRecords.map {
                    (record: $0, type: "idle_detected", status: capturedStatus, refId: nil as Int64?)
                }
                DatabaseManager.shared.insertProcessEvents(events)
            }
        }

        previousProcesses = snapshot.processes
    }

    // MARK: - Consecutive counter update

    private func updateConsecutiveCounts(current: [AgentProcess]) {
        let currentPIDs = Set(current.map(\.pid))
        // 사라진 PID 제거
        consecutiveCounts = consecutiveCounts.filter { currentPIDs.contains($0.key) }
        // 등장 카운터 증가
        for p in current {
            consecutiveCounts[p.pid, default: 0] += 1
        }
    }

    // MARK: - Analysis

    private func computeAnalysis(snapshot: ProcessSnapshot) -> TrendAnalysis {
        let counts  = history.map { $0.snapshot.processes.count }
        let leaks   = history.map { $0.snapshot.leakedCount }
        let interval = AppSettings.monitorIntervalSeconds / 60.0  // 분 단위 (chronic dwell 계산용)

        // ── 기울기 계산 (최근 analysisWindow 개, 실제 timestamp 경과시간 기반) ──
        // 고정 폴링 간격을 가정하지 않고, history에 실제 기록된 timestamp 차이로
        // 분당 기울기를 낸다. 재시작 직후처럼 세션 내 표본이 몇 개 안 쌓였을 때
        // 고정 간격 가정으로 튀는 slope를 내는 문제를 방지.
        let rawWindowEntries = Array(history.suffix(analysisWindow))
        let windowEntries = trimAfterLastGap(rawWindowEntries, expectedIntervalSeconds: AppSettings.monitorIntervalSeconds)
        let window = windowEntries.map { $0.snapshot.processes.count }

        let elapsedMinutes: Double = {
            guard let first = windowEntries.first?.timestamp,
                  let last  = windowEntries.last?.timestamp else { return 0 }
            return last.timeIntervalSince(first) / 60.0
        }()
        let slopeStep = linearSlope(window)   // 스냅샷 인덱스당 기울기
        let slopePerMin: Double
        if windowEntries.count > 1 && elapsedMinutes > 0 {
            slopePerMin = slopeStep * Double(windowEntries.count - 1) / elapsedMinutes
        } else {
            slopePerMin = 0
        }

        // ── 표본 부족/워밍업 가드 ──────────────────────────────────────
        // 세션 내 history가 analysisWindow개 미만이거나, 갭 트리밍 후 표본이
        // 부족하거나, 실제 경과시간이 예상 폴링 간격의 절반에도 못 미치면
        // 확신 있는 증가/감소 패턴을 내지 않고 관측 중(.stable)으로 둔다.
        let minElapsedMinutes = (AppSettings.monitorIntervalSeconds / 2.0) / 60.0
        let hasEnoughSamples = history.count >= analysisWindow
            && windowEntries.count >= analysisWindow
            && elapsedMinutes >= minElapsedMinutes

        // ── 급증 탐지 ──────────────────────────────────────────────────
        let baseline    = Double(counts.prefix(3).reduce(0, +)) / 3.0
        let peak        = Double(counts.max() ?? 0)
        let current     = Double(counts.last ?? 0)
        let spikeRange  = peak - baseline
        let spikeProb: Double
        if spikeRange > 10 && current < baseline + spikeRange * 0.5 {
            spikeProb = min(1.0, (peak - current) / max(1, spikeRange))
        } else {
            spikeProb = 0
        }

        // ── 패턴 분류 ──────────────────────────────────────────────────
        let pattern: GrowthPattern
        if !hasEnoughSamples {
            pattern = .stable
        } else if spikeProb > 0.6 {
            pattern = .spike
        } else if slopePerMin > 0.5 {
            pattern = .fastGrowing
        } else if slopePerMin > 0.1 {
            pattern = .slowGrowing
        } else if slopePerMin < -0.1 {
            pattern = .shrinking
        } else {
            pattern = .stable
        }

        // ── chronic leakers ───────────────────────────────────────────
        let chronic = snapshot.processes
            .filter { p in
                guard let cnt = consecutiveCounts[p.pid] else { return false }
                return cnt >= chronicThreshold && p.isLeaked
            }
            .map { p -> ChronicLeaker in
                let cnt = consecutiveCounts[p.pid] ?? chronicThreshold
                return ChronicLeaker(
                    id: p.pid, pid: p.pid,
                    consecutiveSnapshots: cnt,
                    queueDwellMinutes: Double(cnt) * interval,
                    avgMemMB: p.memMB,
                    leakReason: p.leakReason,
                    ageFormatted: p.ageFormatted
                )
            }
            .sorted { $0.consecutiveSnapshots > $1.consecutiveSnapshots }

        // ── 프로세스 그룹 ──────────────────────────────────────────────
        let groups = buildGroups(snapshot.processes)

        // ── 신규 프로세스/인터벌 ──────────────────────────────────────
        let prevPIDs = Set(previousProcesses.map(\.pid))
        let newCount = snapshot.processes.filter { !prevPIDs.contains($0.pid) }.count
        // 이동 평균 (단순화)
        let avgNew = history.count > 1
            ? Double(newCount)      // 이번 인터벌만 사용 (단순 버전)
            : 0

        let duration = Double(history.count) * interval

        return TrendAnalysis(
            pattern: pattern,
            countHistory: counts,
            leakHistory: leaks,
            newPerInterval: avgNew,
            chronicLeakers: chronic,
            processGroups: groups,
            spikeProbability: spikeProb,
            trendDurationMinutes: duration,
            slopePerMinute: slopePerMin
        )
    }

    // MARK: - Group builder

    private func buildGroups(_ processes: [AgentProcess]) -> [ProcessGroup] {
        var buckets: [String: [AgentProcess]] = [:]

        for p in processes {
            let key: String
            if p.hasResume {
                key = "세션 재개(resume)"
            } else if p.ageMinutes > 120 {
                let h = Int(p.ageMinutes / 60)
                key = "장기실행 \(h)h+"
            } else {
                // model 추출
                let parts = p.cmdArgs.split(separator: " ")
                if let idx = parts.firstIndex(of: "--model"), parts.indices.contains(idx + 1) {
                    let model = String(parts[idx + 1])
                        .components(separatedBy: "-").last ?? "unknown"
                    key = "신규(\(model))"
                } else {
                    key = "신규(unknown)"
                }
            }
            buckets[key, default: []].append(p)
        }

        let prevPIDs = Dictionary(uniqueKeysWithValues: previousProcesses.map { ($0.pid, true) })

        return buckets.map { key, procs in
            let prevCount = previousProcesses.filter { p in
                // rough: 같은 그룹 분류 로직 재적용 어렵기 때문에, 이번 vs 이전 PID 집합으로 delta 계산
                procs.contains(where: { $0.pid == p.pid })
            }.count
            let delta = procs.count - prevCount
            return ProcessGroup(
                type: key,
                count: procs.count,
                deltaFromPrev: delta,
                avgMemMB: procs.reduce(0.0) { $0 + $1.memMB } / Double(max(1, procs.count)),
                avgAgeMins: procs.reduce(0.0) { $0 + $1.ageMinutes } / Double(max(1, procs.count))
            )
        }
        .sorted { $0.count > $1.count }
    }

    // MARK: - Gap guard

    /// 윈도우 내 연속 항목 사이 실제 timestamp 간격이 예상 폴링 간격의 3배를
    /// 넘는 지점(백프레셔로 폴링이 늘어졌거나 절전 등으로 세션이 끊긴 경우)이
    /// 있으면, 그 갭 이전 항목들은 버리고 갭 이후 항목만 남긴다.
    /// (갭을 가로질러 추세를 내지 않기 위함)
    private func trimAfterLastGap(
        _ entries: [(timestamp: Date, snapshot: ProcessSnapshot)],
        expectedIntervalSeconds: Double
    ) -> [(timestamp: Date, snapshot: ProcessSnapshot)] {
        guard entries.count > 1 else { return entries }
        let gapThreshold = expectedIntervalSeconds * 3
        var lastGapIndex = -1
        for i in 1..<entries.count {
            let delta = entries[i].timestamp.timeIntervalSince(entries[i - 1].timestamp)
            if delta > gapThreshold {
                lastGapIndex = i
            }
        }
        guard lastGapIndex >= 0 else { return entries }
        return Array(entries[lastGapIndex...])
    }

    // MARK: - Linear slope (least squares, simplified)

    private func linearSlope(_ data: [Int]) -> Double {
        let n = Double(data.count)
        guard n > 1 else { return 0 }
        let x̄ = (n - 1) / 2
        let ȳ = data.reduce(0.0, { $0 + Double($1) }) / n
        var num = 0.0, den = 0.0
        for (i, v) in data.enumerated() {
            let xi = Double(i) - x̄
            num += xi * (Double(v) - ȳ)
            den += xi * xi
        }
        return den == 0 ? 0 : num / den
    }
}
