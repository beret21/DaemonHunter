import Foundation
import Combine
import Darwin
import os

// MARK: - Global process sample

/// 시스템 전역 프로세스 1개의 관측 스냅샷 (Claude 여부 무관).
struct GlobalProcess: Identifiable, Sendable, Hashable {
    let pid: Int
    let name: String
    let cpuPercent: Double            // 직전 스냅샷 대비 CPU 사용률(%). 멀티코어 합산이라 100 초과 가능.
    let memMB: Double                 // pti_resident_size
    let uptimeMinutes: Double         // 프로세스 생존 시간 (pbi_start_tvsec 기준)
    let lifetimeAvgCPUPercent: Double // cpuRawNs / uptime — 생애 평균 CPU (기동 즉시 만성 감지용)
    let sustainedHighCPUSeconds: Double // 앱이 관측한 "연속" 고부하 지속 시간
    var id: Int { pid }
}

// MARK: - Raw (background-collected) sample

/// nonisolated 백그라운드 수집용 원시 값. 델타/지속시간은 MainActor 상태와 합산.
private struct RawGlobalProc: Sendable {
    let pid: Int
    let name: String
    let residentBytes: UInt64
    let cpuRawNs: UInt64
    let startTvSec: UInt64
}

// MARK: - GlobalProcessScanner

/// 시스템 전역 프로세스를 절대값 기준으로 관측한다.
///
/// ## 역할
/// - `proc_listpids(PROC_ALL_PIDS)`로 전체 PID 훑고, pid별 RSS·누적 CPU·생존시간 수집
/// - 스냅샷 간 CPU 누적시간 델타 / 경과 wall 시간 → 순간 CPU%
/// - **pid별 "고부하 지속시간"** 추적(연속 스냅샷에서 CPU%가 임계 이상 유지) → 만성 판정용
/// - 메모리·CPU 상위 N개만 유지(오버헤드 최소화). SelfHealing 백프레셔 존중.
@MainActor
final class GlobalProcessScanner: ObservableObject {
    static let shared = GlobalProcessScanner()

    /// 메모리/CPU 상위 후보(union). SystemHealthEvaluator가 소비.
    @Published private(set) var topProcesses: [GlobalProcess] = []
    @Published private(set) var lastScan: Date?

    // ── 튜닝 상수 ────────────────────────────────────────────────────
    private let topN = 8                    // CPU·메모리 각각 상위 N
    private let highCPUPercent = 50.0       // 이 이상이면 "고부하"로 간주(지속시간 누적 시작)

    // ── MainActor 상태(델타·지속시간 계산용) ─────────────────────────
    private var prevCPURawNs: [Int: UInt64] = [:]   // pid → 이전 누적 CPU ns
    private var highLoadSince: [Int: Date]  = [:]   // pid → 연속 고부하 시작 시각
    private var prevSampleTime: Date?               // 이전 스캔 시각(경과 wall 시간)

    private let logger = Logger(subsystem: "com.beret21.DaemonHunter", category: "GlobalScanner")

    private init() {}

    // MARK: - Public

    /// 한 폴링 주기 갱신. AppDelegate 스냅샷 루프에서 호출.
    /// 백프레셔가 심하면(.minimal↑) 전역 스캔을 건너뛰어 스스로 부하가 되지 않게 한다.
    func refresh() async {
        guard SelfHealingManager.shared.level <= .reduced else { return }

        let raw = await Task.detached(priority: .background) {
            GlobalProcessScanner.collect()
        }.value

        let now = Date()
        let elapsed = prevSampleTime.map { now.timeIntervalSince($0) } ?? 0
        prevSampleTime = now

        var samples: [GlobalProcess] = []
        samples.reserveCapacity(raw.count)

        for r in raw {
            let prevNs  = prevCPURawNs[r.pid]
            prevCPURawNs[r.pid] = r.cpuRawNs

            // 순간 CPU%: ΔCPU(ns) / Δwall(ns). 멀티코어 합산이므로 100 초과 허용.
            let cpuPct: Double
            if let prevNs, elapsed > 0, r.cpuRawNs >= prevNs {
                let deltaNs = Double(r.cpuRawNs - prevNs)
                cpuPct = deltaNs / (elapsed * 1_000_000_000) * 100.0
            } else {
                cpuPct = 0
            }

            // 생존시간 & 생애 평균 CPU (기동 즉시 만성 감지 신호)
            let startDate  = Date(timeIntervalSince1970: Double(r.startTvSec))
            let uptimeMin  = max(0.0, -startDate.timeIntervalSinceNow / 60.0)
            let uptimeSec  = uptimeMin * 60.0
            let lifetimeAvg = uptimeSec > 0
                ? Double(r.cpuRawNs) / (uptimeSec * 1_000_000_000) * 100.0
                : 0

            // 연속 고부하 지속시간
            if cpuPct >= highCPUPercent {
                if highLoadSince[r.pid] == nil { highLoadSince[r.pid] = now }
            } else {
                highLoadSince[r.pid] = nil
            }
            let sustained = highLoadSince[r.pid].map { now.timeIntervalSince($0) } ?? 0

            samples.append(GlobalProcess(
                pid: r.pid,
                name: r.name,
                cpuPercent: cpuPct,
                memMB: Double(r.residentBytes) / (1024.0 * 1024.0),
                uptimeMinutes: uptimeMin,
                lifetimeAvgCPUPercent: lifetimeAvg,
                sustainedHighCPUSeconds: sustained
            ))
        }

        // 종료된 pid 상태 정리
        let live = Set(raw.map(\.pid))
        prevCPURawNs  = prevCPURawNs.filter  { live.contains($0.key) }
        highLoadSince = highLoadSince.filter { live.contains($0.key) }

        // 상위 N(CPU) ∪ 상위 N(메모리)
        let byCPU = samples.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(topN)
        let byMem = samples.sorted { $0.memMB > $1.memMB }.prefix(topN)
        var seen = Set<Int>()
        var merged: [GlobalProcess] = []
        for p in byCPU + byMem where seen.insert(p.pid).inserted {
            merged.append(p)
        }

        topProcesses = merged
        lastScan = now
    }

    // MARK: - Collection (nonisolated, background-safe)

    /// 전체 PID를 훑어 pid별 mem/cpu/uptime/name 원시값 수집.
    /// proc_pidpath는 호출하지 않아(경로 불필요) collectProcesses보다 가볍다.
    nonisolated private static func collect() -> [RawGlobalProc] {
        let rawCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard rawCount > 0 else { return [] }

        var pids = [Int32](repeating: 0, count: Int(rawCount) + 64)
        let filled = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids,
                                   Int32(pids.count * MemoryLayout<Int32>.size))
        guard filled > 0 else { return [] }

        let pidList = pids.prefix(Int(filled) / MemoryLayout<Int32>.size)
        var result: [RawGlobalProc] = []

        for pid in pidList where pid > 0 {
            var info = proc_taskallinfo()
            let sz = Int32(MemoryLayout<proc_taskallinfo>.size)
            // 접근 권한 없거나 이미 종료된 pid는 0 이하 반환 → 건너뜀
            guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, sz) > 0 else { continue }

            let name = processName(pid: pid, info: info)
            result.append(RawGlobalProc(
                pid: Int(pid),
                name: name,
                residentBytes: info.ptinfo.pti_resident_size,
                cpuRawNs: info.ptinfo.pti_total_user + info.ptinfo.pti_total_system,
                startTvSec: info.pbsd.pbi_start_tvsec
            ))
        }
        return result
    }

    /// 표시용 프로세스 이름. proc_name 우선, 실패 시 pbsd.pbi_comm(≤16자) 사용.
    nonisolated private static func processName(pid: Int32, info: proc_taskallinfo) -> String {
        var buf = [CChar](repeating: 0, count: 64)   // proc_name: ≤ 2*MAXCOMLEN(32)
        if proc_name(pid, &buf, UInt32(buf.count - 1)) > 0 {
            let s = String(cString: buf)
            if !s.isEmpty { return s }
        }
        var comm = info.pbsd.pbi_comm
        return withUnsafeBytes(of: &comm) { raw -> String in
            let p = raw.bindMemory(to: CChar.self)
            return p.baseAddress.map { String(cString: $0) } ?? "pid\(pid)"
        }
    }
}
