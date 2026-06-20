import Foundation

struct AgentProcess: Identifiable, Sendable, Hashable {
    let id: Int  // PID
    var pid: Int { id }
    let ppid: Int
    let cpu: Double        // 직전 폴링 인터벌 대비 CPU 사용률 (%)
    let memMB: Double
    let started: String
    let cpuTime: String
    let cmdArgs: String
    let ageMinutes: Double
    let parentAlive: Bool
    let isLeaked: Bool
    let leakReason: String
    // ── 유휴 감지 ────────────────────────────────────────────────────
    let isSubAgent:           Bool    // --output-format stream-json 포함
    let isClaudeMemObserver:  Bool    // --disallowedTools 포함 (claude-mem 메모리 관찰자)
    let cpuRawNs:             UInt64  // pti_total_user + pti_total_system (누적 ns)
    let isIdle:               Bool    // CPU 델타가 임계값 미만으로 N회 연속
    let idleSnapshots:        Int     // 연속 유휴 스냅샷 수

    var ageFormatted: String {
        let total = Int(ageMinutes)
        let h = total / 60
        let m = total % 60
        if h > 0 { return "\(h)h\(String(format: "%02d", m))m" }
        return "\(m)m"
    }

    var hasResume: Bool { cmdArgs.contains("--resume") }

    /// 유휴 상태를 반영한 복사본 생성 (ProcessMonitor.refresh() 전용)
    func withIdleEnrichment(
        cpu: Double,
        isIdle: Bool,
        idleSnapshots: Int,
        leakReason: String,
        isLeaked: Bool
    ) -> AgentProcess {
        AgentProcess(
            id: id, ppid: ppid,
            cpu: cpu, memMB: memMB,
            started: started, cpuTime: cpuTime,
            cmdArgs: cmdArgs, ageMinutes: ageMinutes,
            parentAlive: parentAlive,
            isLeaked: isLeaked, leakReason: leakReason,
            isSubAgent: isSubAgent, isClaudeMemObserver: isClaudeMemObserver,
            cpuRawNs: cpuRawNs,
            isIdle: isIdle, idleSnapshots: idleSnapshots
        )
    }
}

// MARK: - Snapshot

struct ProcessSnapshot: Sendable {
    let timestamp: Date
    let processes: [AgentProcess]
    let totalMemGB: Double
    let leakedCount: Int
    let status: SystemStatus

    enum SystemStatus: String, Sendable, Equatable {
        case normal   = "NORMAL"
        case warning  = "WARNING"
        case critical = "CRITICAL"

        var emoji: String {
            switch self {
            case .normal:   return "🟢"
            case .warning:  return "🟡"
            case .critical: return "🔴"
            }
        }
    }

    init(processes: [AgentProcess] = []) {
        self.timestamp  = Date()
        self.processes  = processes
        self.totalMemGB = processes.reduce(0.0) { $0 + $1.memMB } / 1024.0
        self.leakedCount = processes.filter(\.isLeaked).count

        let total = processes.count
        if total >= AppSettings.criticalProcessCount
            || totalMemGB >= AppSettings.criticalMemoryGB
            || leakedCount > 10 {
            self.status = .critical
        } else if total >= AppSettings.warningProcessCount || leakedCount > 3 {
            self.status = .warning
        } else {
            self.status = .normal
        }
    }

    // Delta between two snapshots for AI context
    func delta(from previous: ProcessSnapshot) -> SnapshotDelta {
        SnapshotDelta(
            processCountDelta: processes.count - previous.processes.count,
            memDeltaGB: totalMemGB - previous.totalMemGB,
            leakDelta: leakedCount - previous.leakedCount,
            statusChanged: status != previous.status,
            previousStatus: previous.status
        )
    }
}

struct SnapshotDelta: Sendable {
    let processCountDelta: Int
    let memDeltaGB: Double
    let leakDelta: Int
    let statusChanged: Bool
    let previousStatus: ProcessSnapshot.SystemStatus
}

// MARK: - App-wide settings (UserDefaults backed)

enum AppSettings {
    static var monitorIntervalSeconds: Double {
        UserDefaults.standard.double(forKey: "monitorInterval").nonZero ?? 30
    }
    static var leakAgeMinutes: Double {
        UserDefaults.standard.double(forKey: "leakAgeMinutes").nonZero ?? 30
    }
    static var leakCPUThreshold: Double {
        UserDefaults.standard.double(forKey: "leakCPUThreshold").nonZero ?? 0.2
    }
    static var warningProcessCount: Int {
        Int(UserDefaults.standard.double(forKey: "warnCount").nonZero ?? 20)
    }
    static var criticalProcessCount: Int {
        Int(UserDefaults.standard.double(forKey: "critCount").nonZero ?? 50)
    }
    static var criticalMemoryGB: Double {
        UserDefaults.standard.double(forKey: "critMemGB").nonZero ?? 10
    }
    static var notificationCooldownSeconds: Double { 600 }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
