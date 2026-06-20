import Foundation
import Combine
import Darwin
import os

@MainActor
final class ProcessMonitor: ObservableObject {
    @Published private(set) var snapshot         = ProcessSnapshot()
    @Published private(set) var previousSnapshot = ProcessSnapshot()

    private var timer: AnyCancellable?
    private let logger = Logger(subsystem: "com.beret21.DaemonHunter", category: "ProcessMonitor")

    // ── 유휴(Idle) 감지 인스턴스 상태 ───────────────────────────────
    private var prevCPURawNs:    [Int: UInt64] = [:]  // PID → 이전 스냅샷 누적 CPU ns
    private var idleCounters:    [Int: Int]    = [:]  // PID → 연속 유휴 카운터
    private let idleThresholdNs: UInt64        = 10_000_000   // 10ms
    private let idleSnapNeeded:  Int           = 3            // 3회 연속 ≈ 90초

    static let shared = ProcessMonitor()
    private init() {}

    // MARK: - Lifecycle

    func startMonitoring() {
        refresh()
        scheduleTimer()
    }

    func stopMonitoring() {
        timer?.cancel()
        timer = nil
    }

    func refresh() {
        Task.detached(priority: .background) {
            let raw = ProcessMonitor.collectProcesses()
            await MainActor.run { [weak self] in
                guard let self else { return }
                let enriched = self.enrichWithIdleState(raw)
                self.previousSnapshot = self.snapshot
                self.snapshot = ProcessSnapshot(processes: enriched)
            }
        }
    }

    /// CPU 델타를 계산해 isIdle / cpu(%) 필드를 채운다. 메인 스레드 전용.
    private func enrichWithIdleState(_ raw: [AgentProcess]) -> [AgentProcess] {
        let intervalNs = UInt64(max(1, AppSettings.monitorIntervalSeconds) * 1_000_000_000)
        var enriched: [AgentProcess] = []

        for proc in raw {
            let prevNs  = prevCPURawNs[proc.pid] ?? proc.cpuRawNs
            let deltaNs = proc.cpuRawNs > prevNs ? proc.cpuRawNs - prevNs : 0
            prevCPURawNs[proc.pid] = proc.cpuRawNs

            // 순간 CPU 사용률 (이 인터벌 기준)
            let cpuPct = min(100.0, Double(deltaNs) / Double(intervalNs) * 100.0)

            // 유휴 카운터 갱신
            if proc.isSubAgent && deltaNs < idleThresholdNs {
                idleCounters[proc.pid, default: 0] += 1
            } else {
                idleCounters[proc.pid] = 0
            }
            let snapCount = idleCounters[proc.pid] ?? 0
            let isIdle    = proc.isSubAgent && snapCount >= idleSnapNeeded

            // leakReason 업데이트
            var newReason = proc.leakReason
            if isIdle && !newReason.contains("유휴") {
                newReason = newReason.isEmpty ? "유휴" : newReason + ", 유휴"
            }

            enriched.append(proc.withIdleEnrichment(
                cpu: cpuPct,
                isIdle: isIdle,
                idleSnapshots: snapCount,
                leakReason: newReason,
                isLeaked: proc.isLeaked || isIdle
            ))
        }

        // 종료된 PID 정리
        let livePIDs = Set(raw.map(\.pid))
        prevCPURawNs = prevCPURawNs.filter { livePIDs.contains($0.key) }
        idleCounters  = idleCounters.filter  { livePIDs.contains($0.key) }

        return enriched
    }

    private func scheduleTimer() {
        timer?.cancel()
        // SelfHealingManager가 시스템 압박 시 간격을 늘린다 (자가치유)
        let interval = SelfHealingManager.shared.effectivePollingInterval
        timer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }

    // MARK: - Kill leaked

    struct KillResult {
        let killed:           Int
        let failed:           Int
        let reclaimedMB:      Double
        let killedProcesses:  [AgentProcess]
        let failedProcesses:  [AgentProcess]
    }

    func killLeaked() async -> KillResult {
        let leaked = snapshot.processes.filter(\.isLeaked)
        var killedProcs:  [AgentProcess] = []
        var failedProcs:  [AgentProcess] = []
        var reclaimedMB = 0.0

        for p in leaked {
            if kill(Int32(p.pid), SIGTERM) == 0 {
                killedProcs.append(p)
                reclaimedMB += p.memMB
                logger.info("Terminated PID \(p.pid)")
            } else {
                failedProcs.append(p)
                logger.error("Failed SIGTERM PID \(p.pid) errno=\(errno)")
            }
        }

        try? await Task.sleep(for: .milliseconds(800))
        refresh()
        return KillResult(
            killed: killedProcs.count,
            failed: failedProcs.count,
            reclaimedMB: reclaimedMB,
            killedProcesses: killedProcs,
            failedProcesses: failedProcs
        )
    }

    // MARK: - Process collection

    /// Claude Code 바이너리는 .local/share/claude/versions/X.Y.Z 에 있고
    /// p_comm은 버전번호("2.1.183")로 표시됨 → proc_pidpath로 경로에 "/claude/" 포함 여부 확인
    nonisolated static func collectProcesses() -> [AgentProcess] {
        // 1. 모든 PID 수집
        let rawCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard rawCount > 0 else { return [] }

        var pids = [Int32](repeating: 0, count: Int(rawCount) + 64)
        let filled = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids,
                                   Int32(pids.count * MemoryLayout<Int32>.size))
        guard filled > 0 else { return [] }

        var result: [AgentProcess] = []

        let pidList = pids.prefix(Int(filled) / MemoryLayout<Int32>.size)

        for pid in pidList where pid > 1 {
            // 2. 실행 파일 전체 경로 확인
            var pathBuf = [CChar](repeating: 0, count: Int(PROC_PIDPATHINFO_MAXSIZE_SWIFT))
            guard proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 else { continue }
            let execPath = String(cString: &pathBuf)

            // 경로에 "/claude/" 포함 = Claude Code 계열
            // ClaudeAgentMonitor 자신은 경로에 "/claude/" 없으므로 제외됨
            guard execPath.contains("/claude/") || execPath.hasSuffix("/claude") else { continue }

            // 3. 커맨드라인 인수 파싱
            let args = cmdlineArgs(pid: pid)
            guard !args.isEmpty else { continue }
            let cmdStr = args.joined(separator: " ")

            let isSubAgent           = cmdStr.contains("--output-format stream-json")
            let isClaudeMemObserver  = isSubAgent && cmdStr.contains("--disallowedTools")
            let isMain               = cmdStr.contains("--dangerously-skip-permissions")
                                    || (cmdStr.contains("--permission-mode") && !isSubAgent)
            guard isSubAgent || isMain else { continue }

            // 4. 메모리·CPU 누적시간·시작시각 (proc_pidinfo)
            var info = proc_taskallinfo()
            let infoSize = Int32(MemoryLayout<proc_taskallinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, infoSize) > 0 else { continue }

            let memMB      = Double(info.ptinfo.pti_resident_size) / (1024.0 * 1024.0)
            let cpuRawNs   = UInt64(info.ptinfo.pti_total_user) + UInt64(info.ptinfo.pti_total_system)
            let startDate  = Date(timeIntervalSince1970: Double(info.pbsd.pbi_start_tvsec))
            let ageMinutes = max(0.0, -startDate.timeIntervalSinceNow / 60.0)
            let ppid       = Int(info.pbsd.pbi_ppid)
            let parentAlive = ppid > 1 ? (kill(Int32(ppid), 0) == 0 || errno == EPERM) : true

            // 5. 표시용 레이블 파싱 (--name, --model, --resume)
            var sessionName: String? = nil
            var modelShort:  String? = nil
            var hasResume           = false
            for (idx, arg) in args.enumerated() {
                switch arg {
                case "--name":
                    if args.indices.contains(idx + 1) { sessionName = args[idx + 1] }
                case "--model":
                    if args.indices.contains(idx + 1) {
                        let m = args[idx + 1]
                        modelShort = m.split(separator: "-").dropFirst().joined(separator: "-")
                    }
                case "--resume":
                    hasResume = true
                default: break
                }
            }

            // 6. 누수 판정: 고아 서브에이전트(부모 사망) 또는 장기 실행
            var reasons: [String] = []
            if isSubAgent && !parentAlive && ppid > 1 { reasons.append("부모사망") }
            if isSubAgent && ageMinutes > AppSettings.leakAgeMinutes * 3 { reasons.append("장기실행") }
            // claude-mem 관찰자: 작업 자체가 짧아야 함 — leakAgeMinutes(기본 30분)만 지나도 비정상
            if isClaudeMemObserver && ageMinutes > AppSettings.leakAgeMinutes { reasons.append("메모리관찰자미종료") }

            let displayLabel: String
            if isClaudeMemObserver     { displayLabel = "claude-mem 관찰자" }
            else if let n = sessionName { displayLabel = n }
            else if let m = modelShort { displayLabel = m }
            else if hasResume          { displayLabel = "재개" }
            else if isMain             { displayLabel = "메인세션" }
            else                       { displayLabel = "서브에이전트" }

            // cpu / isIdle / idleSnapshots 는 enrichWithIdleState() 에서 채워진다
            result.append(AgentProcess(
                id: Int(pid), ppid: ppid,
                cpu: 0.0,                           // enrichWithIdleState 에서 덮어씀
                memMB: memMB,
                started: formatTime(startDate),
                cpuTime: formatDuration(ageMinutes),
                cmdArgs: displayLabel,
                ageMinutes: ageMinutes,
                parentAlive: parentAlive,
                isLeaked: !reasons.isEmpty,
                leakReason: reasons.joined(separator: ", "),
                isSubAgent: isSubAgent,
                isClaudeMemObserver: isClaudeMemObserver,
                cpuRawNs: cpuRawNs,
                isIdle: false,                      // enrichWithIdleState 에서 덮어씀
                idleSnapshots: 0
            ))
        }

        return result.sorted { $0.ageMinutes > $1.ageMinutes }
    }

    // MARK: - KERN_PROCARGS2 → argv 배열

    nonisolated static func cmdlineArgs(pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var sz = 0
        guard sysctl(&mib, 3, nil, &sz, nil, 0) == 0, sz > 4 else { return [] }

        var buf = [UInt8](repeating: 0, count: sz)
        var readSz = sz
        guard sysctl(&mib, 3, &buf, &readSz, nil, 0) == 0 else { return [] }

        let argc = Int(UInt32(buf[0]) | (UInt32(buf[1]) << 8) | (UInt32(buf[2]) << 16) | (UInt32(buf[3]) << 24))
        guard argc > 0, argc < 512 else { return [] }

        var idx = 4
        while idx < readSz && buf[idx] != 0 { idx += 1 }; idx += 1  // exec_path 건너뜀
        while idx < readSz && buf[idx] == 0 { idx += 1 }             // null padding 건너뜀

        var args: [String] = []
        for _ in 0..<argc {
            guard idx < readSz else { break }
            let start = idx
            while idx < readSz && buf[idx] != 0 { idx += 1 }
            if let s = String(bytes: buf[start..<idx], encoding: .utf8), !s.isEmpty {
                args.append(s)
            }
            idx += 1
        }
        return args
    }

    // MARK: - Helpers

    nonisolated static func isAlive(_ pid: Int) -> Bool {
        kill(Int32(pid), 0) == 0 || errno == EPERM
    }

    nonisolated private static func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    nonisolated private static func formatDuration(_ minutes: Double) -> String {
        let h = Int(minutes) / 60
        let m = Int(minutes) % 60
        return h > 0 ? "\(h)h\(String(format: "%02d", m))m" : "\(m)m"
    }
}
