import Foundation
import Darwin
import os

// MARK: - App category detection

extension String {

    /// 실행 경로에서 사용자에게 보여줄 앱 이름 추출.
    /// - `/Applications/Arc.app/Contents/MacOS/Arc` → "Arc"
    /// - `/usr/bin/python3`                          → "python3"
    /// - `~/.local/share/claude/versions/2.1/claude` → "claude"
    func appDisplayName() -> String {
        // .app 번들이면 번들 이름을 우선 사용 (가장 직관적)
        if let range = self.range(of: ".app/") {
            let prefix = self[self.startIndex..<range.lowerBound]
            if let slash = prefix.lastIndex(of: "/") {
                let name = prefix[prefix.index(after: slash)...]
                if !name.isEmpty { return String(name) }
            }
        }
        // 그 외엔 실행 파일명 사용
        let exe = (self as NSString).lastPathComponent
        return exe.isEmpty ? self : exe
    }

    /// 앱 분류: "ai_agent" | "cloud_sync" | "browser" | "dev_tool" | "system" | "other"
    func appCategory() -> String {
        let p = self.lowercased()

        // 시스템 내부 경로 (가장 먼저 판별)
        if p.hasPrefix("/system/") || p.hasPrefix("/usr/") || p.hasPrefix("/sbin/") {
            return "system"
        }

        if p.contains("/claude/") || p.hasSuffix("/claude")
            || p.contains("/codex/") || p.contains("ollama") || p.contains("copilot") {
            return "ai_agent"
        }
        if p.contains("dropbox") || p.contains("onedrive") || p.contains("googledrive")
            || p.contains("google drive") || p.contains("icloud") || p.contains("/box ")
            || p.contains("boxapp") {
            return "cloud_sync"
        }
        if p.contains("safari") || p.contains("chrome") || p.contains("firefox")
            || p.contains("/arc.app") || p.contains("/arc ") || p.contains("brave")
            || p.contains("microsoft edge") || p.contains("/edge") {
            return "browser"
        }
        if p.contains("xcode") || p.contains("visual studio code") || p.contains("vscode")
            || p.contains("/code helper") || p.contains("terminal") || p.contains("iterm")
            || p.contains("/node") || p.contains("python") {
            return "dev_tool"
        }
        return "other"
    }
}

// MARK: - Models

struct AppResourceSample: Identifiable, Sendable {
    let id: UUID
    let appName: String
    let execPath: String
    let category: String
    let pids: [Int32]
    let totalMemMB: Double
    let cpuTimeSeconds: Double
    let timestamp: Date
}

struct SystemMemoryInfo: Sendable {
    let totalGB: Double
    let usedGB: Double
    let swapUsedGB: Double
    let pressureLevel: PressureLevel

    enum PressureLevel: String, Sendable {
        case normal   = "normal"
        case warning  = "warning"    // >75% used
        case critical = "critical"   // >90% used or swap > 2GB
    }

    static func compute(totalGB: Double, usedGB: Double, swapUsedGB: Double) -> SystemMemoryInfo {
        let ratio = totalGB > 0 ? usedGB / totalGB : 0
        let level: PressureLevel
        if ratio > 0.90 || swapUsedGB > 2.0 { level = .critical }
        else if ratio > 0.75               { level = .warning }
        else                                { level = .normal }
        return SystemMemoryInfo(totalGB: totalGB, usedGB: usedGB,
                                swapUsedGB: swapUsedGB, pressureLevel: level)
    }

    static let empty = SystemMemoryInfo(totalGB: 0, usedGB: 0, swapUsedGB: 0, pressureLevel: .normal)
}

// MARK: - ResourceTracker

@MainActor
final class ResourceTracker: ObservableObject {
    static let shared = ResourceTracker()

    @Published private(set) var topApps:      [AppResourceSample] = []   // top 15 by memory
    @Published private(set) var memoryInfo:   SystemMemoryInfo = .empty
    @Published private(set) var leakSuspects: [AppResourceSample] = []   // apps with growing memory

    private let logger = Logger(subsystem: "com.beret21.DaemonHunter", category: "ResourceTracker")
    private var timer: Timer?

    // 앱별 직전 메모리 (델타 계산 + 누수 탐지)
    private var previousMemory: [String: Double] = [:]
    // 앱별 연속 증가 카운터 (5+ = 누수 의심)
    private var growthCounter:  [String: Int] = [:]
    // 앱별 최근 샘플 순환 버퍼 (최대 10)
    private var sampleHistory:  [String: [Double]] = [:]

    nonisolated private static let memFloorMB:    Double = 20    // 노이즈 필터
    nonisolated private static let leakThreshold: Int    = 5     // 연속 증가 횟수
    nonisolated private static let intervalSec:   TimeInterval = 30

    private init() {}

    // MARK: - Lifecycle

    func start() {
        collect()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.intervalSec, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.collect() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 백그라운드 수집 후 메인 액터로 결과 반영.
    func collect() {
        Task.detached(priority: .background) {
            let raw  = ResourceTracker.scanProcesses()
            let mem  = ResourceTracker.systemMemory()
            await self.apply(raw: raw, memory: mem)
        }
    }

    // MARK: - State update (MainActor)

    private func apply(raw: [RawAppGroup], memory: SystemMemoryInfo) {
        let now = Date()

        var samples:   [AppResourceSample] = []
        var suspects:  [AppResourceSample] = []
        var seenNames: Set<String> = []

        // 메모리 내림차순 정렬 후 상위 20개만 추적
        let sorted = raw.sorted { $0.totalMemMB > $1.totalMemMB }.prefix(20)

        for group in sorted {
            let name  = group.appName
            seenNames.insert(name)

            let prev  = previousMemory[name]
            let delta = prev.map { group.totalMemMB - $0 } ?? 0
            previousMemory[name] = group.totalMemMB

            // 순환 버퍼 갱신 (최근 10개)
            var history = sampleHistory[name] ?? []
            history.append(group.totalMemMB)
            if history.count > 10 { history.removeFirst(history.count - 10) }
            sampleHistory[name] = history

            // 연속 증가 카운터: 의미 있는 증가(>1MB)만 누적, 아니면 리셋
            if delta > 1.0 { growthCounter[name, default: 0] += 1 }
            else           { growthCounter[name] = 0 }

            let isSuspect = (growthCounter[name] ?? 0) >= Self.leakThreshold

            let sample = AppResourceSample(
                id: UUID(),
                appName: name,
                execPath: group.execPath,
                category: group.category,
                pids: group.pids,
                totalMemMB: group.totalMemMB,
                cpuTimeSeconds: group.cpuTimeSeconds,
                timestamp: now
            )
            samples.append(sample)
            if isSuspect { suspects.append(sample) }

            DatabaseManager.shared.insertResourceSnapshot(
                appName: name, execPath: group.execPath, category: group.category,
                pidCount: group.pids.count, totalMemMB: group.totalMemMB,
                cpuPercent: 0, memDeltaMB: delta, isLeakSuspect: isSuspect
            )
        }

        // 더 이상 보이지 않는 앱 상태 정리 (종료된 프로세스)
        previousMemory = previousMemory.filter { seenNames.contains($0.key) }
        growthCounter  = growthCounter.filter  { seenNames.contains($0.key) }
        sampleHistory  = sampleHistory.filter  { seenNames.contains($0.key) }

        self.memoryInfo   = memory
        self.topApps      = Array(samples.prefix(15))
        self.leakSuspects = suspects

        recordPressureIfNeeded(memory: memory, samples: samples, suspects: suspects)
    }

    /// 메모리 압박 상태 + 신규 누수 의심 동시 발생 시에만 기록 (DB 노이즈 방지).
    private func recordPressureIfNeeded(memory: SystemMemoryInfo,
                                        samples: [AppResourceSample],
                                        suspects: [AppResourceSample]) {
        guard memory.pressureLevel != .normal, !suspects.isEmpty else { return }

        let top = samples.first
        DatabaseManager.shared.insertSystemPressureEvent(
            memPressure: memory.pressureLevel.rawValue,
            memUsedGB: memory.usedGB, memTotalGB: memory.totalGB,
            swapUsedGB: memory.swapUsedGB, thermalLevel: ResourceTracker.thermalLevel(),
            cpuPercent: 0,
            topConsumer: top?.appName ?? "", topConsumerMB: top?.totalMemMB ?? 0
        )

        for s in suspects {
            let severity = min(1.0, Double(growthCounter[s.appName] ?? Self.leakThreshold) / 10.0)
            DatabaseManager.shared.insertAppHealthLog(
                appName: s.appName, execPath: s.execPath, version: "",
                healthScore: max(0.0, 1.0 - severity), issueType: "mem_leak",
                issueSeverity: severity, memMBAtIssue: s.totalMemMB,
                notes: "growing \(growthCounter[s.appName] ?? 0) intervals under \(memory.pressureLevel.rawValue) pressure"
            )
        }

        logger.warning("Memory pressure \(memory.pressureLevel.rawValue): \(suspects.count) leak suspect(s)")
    }

    // MARK: - Background collection (nonisolated)

    /// 앱 단위로 집계된 중간 결과 (Sendable, 액터 경계 통과용).
    private struct RawAppGroup: Sendable {
        let appName: String
        let execPath: String
        let category: String
        var pids: [Int32]
        var totalMemMB: Double
        var cpuTimeSeconds: Double
    }

    /// 시스템 전체 프로세스를 스캔해 앱 단위(appDisplayName)로 그룹화.
    nonisolated private static func scanProcesses() -> [RawAppGroup] {
        let rawCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard rawCount > 0 else { return [] }

        var pids = [Int32](repeating: 0, count: Int(rawCount) + 64)
        let filled = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids,
                                   Int32(pids.count * MemoryLayout<Int32>.size))
        guard filled > 0 else { return [] }

        let pidList = pids.prefix(Int(filled) / MemoryLayout<Int32>.size)
        var groups: [String: RawAppGroup] = [:]

        for pid in pidList where pid > 1 {
            var pathBuf = [CChar](repeating: 0, count: Int(PROC_PIDPATHINFO_MAXSIZE_SWIFT))
            guard proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 else { continue }
            let execPath = String(cString: &pathBuf)
            guard !execPath.isEmpty else { continue }

            // 시스템 내부 프로세스 제외
            if execPath.hasPrefix("/System/Library/")
                || execPath.hasPrefix("/usr/sbin/")
                || execPath.hasPrefix("/usr/libexec/")
                || execPath.hasPrefix("/sbin/") { continue }

            var info = proc_taskallinfo()
            let infoSize = Int32(MemoryLayout<proc_taskallinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, infoSize) > 0 else { continue }

            let memMB = Double(info.ptinfo.pti_resident_size) / (1024.0 * 1024.0)
            // CPU 누적 시간(초): user + system (나노초 단위)
            let cpuSec = Double(info.ptinfo.pti_total_user + info.ptinfo.pti_total_system) / 1_000_000_000.0

            let name = execPath.appDisplayName()
            if var g = groups[name] {
                g.pids.append(pid)
                g.totalMemMB += memMB
                g.cpuTimeSeconds += cpuSec
                groups[name] = g
            } else {
                groups[name] = RawAppGroup(
                    appName: name, execPath: execPath, category: execPath.appCategory(),
                    pids: [pid], totalMemMB: memMB, cpuTimeSeconds: cpuSec
                )
            }
        }

        // 20MB 미만 노이즈 제거
        return groups.values.filter { $0.totalMemMB > memFloorMB }
    }

    // MARK: - System memory (sysctl)

    nonisolated private static func systemMemory() -> SystemMemoryInfo {
        // 총 물리 메모리: hw.memsize
        var totalBytes: UInt64 = 0
        var tSize = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &totalBytes, &tSize, nil, 0)
        let totalGB = Double(totalBytes) / (1024.0 * 1024.0 * 1024.0)

        // 사용 메모리: host_statistics64 (HOST_VM_INFO64)
        var usedGB = 0.0
        var vmStat = vm_statistics64_data_t()
        var count  = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let host   = mach_host_self()
        let kr = withUnsafeMutablePointer(to: &vmStat) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            var pageSize: vm_size_t = 0
            host_page_size(host, &pageSize)
            let ps = Double(pageSize)
            // active + wired + compressed = 회수 불가에 가까운 사용량
            let usedPages = Double(vmStat.active_count)
                          + Double(vmStat.wire_count)
                          + Double(vmStat.compressor_page_count)
            usedGB = usedPages * ps / (1024.0 * 1024.0 * 1024.0)
        }

        // 스왑: vm.swapusage → struct xsw_usage
        var swapUsedGB = 0.0
        var swap = xsw_usage()
        var sSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &sSize, nil, 0) == 0 {
            swapUsedGB = Double(swap.xsu_used) / (1024.0 * 1024.0 * 1024.0)
        }

        return SystemMemoryInfo.compute(totalGB: totalGB, usedGB: usedGB, swapUsedGB: swapUsedGB)
    }

    /// 온도 레벨: 0=nominal,1=fair,2=serious,3=critical
    nonisolated private static func thermalLevel() -> Int {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return 0
        case .fair:     return 1
        case .serious:  return 2
        case .critical: return 3
        @unknown default: return 0
        }
    }
}
