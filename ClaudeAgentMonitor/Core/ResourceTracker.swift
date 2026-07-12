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
    /// 순간 CPU 사용률(%) — 누적 CPU초 델타 / 경과 wall 시간. 멀티코어 합산이라 100 초과 가능.
    /// 첫 표본(직전 누적치 없음)은 0.
    let cpuPercent: Double
    let timestamp: Date
}

/// 드릴다운 상세 프로세스 (FR3): 임계 초과/누수 의심 앱의 개별 PID 판정 결과.
struct ProcessDetail: Identifiable, Sendable {
    let pid: Int32
    let ppid: Int32
    let memMB: Double
    let cpuPercent: Double
    let isOrphan: Bool      // 부모 사망 입증 — kill(ppid, 0) 실패 (ProcessMonitor parentAlive 로직)
    let isIdle: Bool        // 누적 CPU ns 델타가 임계 미만으로 연속 N회
    let ageMinutes: Double
    var id: Int32 { pid }
}

/// 한 collect 사이클의 집계 결과 — HistoryTracker/PredictionEngine이 소비 (AppDelegate에서 연결).
struct ResourceReport: Sendable {
    let timestamp: Date
    let apps: [AppResourceSample]       // 추적 대상 전체 (메모리 상위 최대 20)
    let suspects: [AppResourceSample]   // 누수 의심 (연속 증가)
    let memory: SystemMemoryInfo

    /// 추적 앱 총 메모리 (GB)
    var totalMemGB: Double { apps.reduce(0.0) { $0 + $1.totalMemMB } / 1024.0 }
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
    // 드릴다운 대상 앱 (leak-suspect 또는 메모리/CPU 임계 초과) — 매 collect마다 갱신, UI/AI가 소비
    @Published private(set) var drilldownApps: [String] = []
    // 한 collect 사이클의 집계 결과 — AppDelegate가 구독해 HistoryTracker/PredictionEngine에 전달
    @Published private(set) var latestReport: ResourceReport?

    private let logger = Logger(subsystem: "com.beret21.DaemonHunter", category: "ResourceTracker")
    private var timer: Timer?

    // 앱별 직전 메모리 (델타 계산 + 누수 탐지)
    private var previousMemory: [String: Double] = [:]
    // 앱별 연속 증가 카운터 (5+ = 누수 의심)
    private var growthCounter:  [String: Int] = [:]
    // 앱별 최근 샘플 순환 버퍼 (최대 10)
    private var sampleHistory:  [String: [Double]] = [:]

    // ── CPU% 델타 상태 (앱 단위, 누적 카운터 델타 원칙) ─────────────────
    private var prevCPUSeconds: [String: Double] = [:]   // 앱 이름 → 직전 누적 CPU초
    private var prevScanTime:   Date?                    // 직전 collect 시각 (경과 wall 시간)

    // ── 드릴다운 PID 상태 (대상 앱의 pid에 대해서만 유지 — NFR: 관측 오버헤드 최소) ──
    private var prevPidCPURawNs: [Int32: UInt64] = [:]   // pid → 직전 누적 CPU ns
    private var pidIdleCounters: [Int32: Int]    = [:]   // pid → 연속 유휴 카운터
    private var latestDetails:   [String: [ProcessDetail]] = [:]  // 앱 이름 → PID 상세
    // 앱 이름 → 현재 pid 목록 (killApp 조회용, 추적 앱 전체)
    private var pidsByApp:       [String: [Int32]] = [:]

    nonisolated private static let memFloorMB:    Double = 20    // 노이즈 필터
    nonisolated private static let leakThreshold: Int    = 5     // 연속 증가 횟수
    nonisolated static let intervalSec:   TimeInterval = 30      // 수집 주기 (HistoryTracker 갭 가드에서 참조)

    // ── 드릴다운 임계 (FR3: 부하가 임계를 넘은 앱만 온디맨드 상세평가) ──
    nonisolated private static let drilldownMemThresholdMB: Double = 2048  // 2GB 이상 점유
    nonisolated private static let drilldownCPUThresholdPct: Double = 50   // GlobalProcessScanner.highCPUPercent와 동일
    // 유휴 판정 상수 — ProcessMonitor.enrichWithIdleState와 동일 (10ms 미만 델타 3회 연속)
    nonisolated private static let idleThresholdNs: UInt64 = 10_000_000
    nonisolated private static let idleSnapNeeded:  Int    = 3

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
        let elapsed = prevScanTime.map { now.timeIntervalSince($0) } ?? 0
        prevScanTime = now

        var samples:   [AppResourceSample] = []
        var suspects:  [AppResourceSample] = []
        var seenNames: Set<String> = []
        var newDetails:   [String: [ProcessDetail]] = [:]
        var newPidsByApp: [String: [Int32]] = [:]
        var eligibleApps: [String] = []
        var trackedPids:  Set<Int32> = []

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

            // CPU%: 앱별 누적 CPU초 델타 / 경과 wall 시간 (GlobalProcessScanner의 누적 카운터 델타 방식).
            // 첫 표본이거나 pid 구성 변화로 누적치가 감소하면 0.
            let prevCPU = prevCPUSeconds[name]
            let cpuPercent: Double
            if let prevCPU, elapsed > 0, group.cpuTimeSeconds >= prevCPU {
                cpuPercent = (group.cpuTimeSeconds - prevCPU) / elapsed * 100.0
            } else {
                cpuPercent = 0
            }
            prevCPUSeconds[name] = group.cpuTimeSeconds

            let sample = AppResourceSample(
                id: UUID(),
                appName: name,
                execPath: group.execPath,
                category: group.category,
                pids: group.pids,
                totalMemMB: group.totalMemMB,
                cpuTimeSeconds: group.cpuTimeSeconds,
                cpuPercent: cpuPercent,
                timestamp: now
            )
            samples.append(sample)
            if isSuspect { suspects.append(sample) }
            newPidsByApp[name] = group.pids

            // 드릴다운 대상: leak-suspect 또는 메모리/CPU 임계 초과 앱만 PID별 상세평가 (FR3)
            if isSuspect
                || group.totalMemMB > Self.drilldownMemThresholdMB
                || cpuPercent > Self.drilldownCPUThresholdPct {
                eligibleApps.append(name)
                newDetails[name] = buildDetails(group: group, elapsed: elapsed,
                                                now: now, trackedPids: &trackedPids)
            }

            DatabaseManager.shared.insertResourceSnapshot(
                appName: name, execPath: group.execPath, category: group.category,
                pidCount: group.pids.count, totalMemMB: group.totalMemMB,
                cpuPercent: cpuPercent, memDeltaMB: delta, isLeakSuspect: isSuspect
            )
        }

        // 더 이상 보이지 않는 앱 상태 정리 (종료된 프로세스)
        previousMemory = previousMemory.filter { seenNames.contains($0.key) }
        growthCounter  = growthCounter.filter  { seenNames.contains($0.key) }
        sampleHistory  = sampleHistory.filter  { seenNames.contains($0.key) }
        prevCPUSeconds = prevCPUSeconds.filter { seenNames.contains($0.key) }
        // 드릴다운 대상에서 빠진 pid 상태 정리 (대상 앱의 pid만 유지)
        prevPidCPURawNs = prevPidCPURawNs.filter { trackedPids.contains($0.key) }
        pidIdleCounters = pidIdleCounters.filter { trackedPids.contains($0.key) }

        self.memoryInfo    = memory
        self.topApps       = Array(samples.prefix(15))
        self.leakSuspects  = suspects
        self.latestDetails = newDetails
        self.pidsByApp     = newPidsByApp
        self.drilldownApps = eligibleApps
        self.latestReport  = ResourceReport(timestamp: now, apps: samples,
                                            suspects: suspects, memory: memory)

        recordPressureIfNeeded(memory: memory, samples: samples, suspects: suspects)
    }

    /// 드릴다운 대상 앱 1개의 PID별 고아/유휴 판정 (ProcessMonitor 알고리즘 이식).
    private func buildDetails(group: RawAppGroup, elapsed: TimeInterval,
                              now: Date, trackedPids: inout Set<Int32>) -> [ProcessDetail] {
        var details: [ProcessDetail] = []
        details.reserveCapacity(group.procs.count)

        for p in group.procs {
            trackedPids.insert(p.pid)

            // 유휴: pid별 누적 CPU ns 델타 (ProcessMonitor.enrichWithIdleState와 동일 원리)
            let prevNs  = prevPidCPURawNs[p.pid]
            let deltaNs: UInt64? = prevNs.flatMap { p.cpuRawNs >= $0 ? p.cpuRawNs - $0 : nil }
            prevPidCPURawNs[p.pid] = p.cpuRawNs

            let cpuPct: Double
            if let deltaNs, elapsed > 0 {
                cpuPct = Double(deltaNs) / (elapsed * 1_000_000_000) * 100.0
            } else {
                cpuPct = 0   // 첫 표본 가드
            }

            // 첫 표본(델타 미상)은 유휴 카운트하지 않음
            if let deltaNs {
                if deltaNs < Self.idleThresholdNs { pidIdleCounters[p.pid, default: 0] += 1 }
                else                              { pidIdleCounters[p.pid] = 0 }
            }
            let isIdle = (pidIdleCounters[p.pid] ?? 0) >= Self.idleSnapNeeded

            // 고아: 스캔 시점 ppid의 생존 확인 — kill(ppid, 0) (ProcessMonitor parentAlive 로직)
            let parentAlive = p.ppid > 1 ? (kill(p.ppid, 0) == 0 || errno == EPERM) : true

            let startDate  = Date(timeIntervalSince1970: Double(p.startTvSec))
            let ageMinutes = max(0.0, now.timeIntervalSince(startDate) / 60.0)

            details.append(ProcessDetail(
                pid: p.pid, ppid: p.ppid,
                memMB: p.memMB, cpuPercent: cpuPct,
                isOrphan: !parentAlive, isIdle: isIdle,
                ageMinutes: ageMinutes
            ))
        }
        return details.sorted { $0.memMB > $1.memMB }
    }

    // MARK: - On-demand drilldown (FR3)

    /// 온디맨드 드릴다운: leak-suspect이거나 메모리/CPU 임계 초과 앱의 PID별 상세 판정.
    /// `drilldownApps`에 없는 앱은 빈 배열을 반환한다 (상세 상태는 대상 앱에 대해서만 유지).
    func detailedProcesses(for appName: String) -> [ProcessDetail] {
        latestDetails[appName] ?? []
    }

    // MARK: - Kill (FR5 — 실행 함수만 제공, 호출 UI는 2단계)

    struct KillOutcome: Sendable {
        let killed:      Int
        let failed:      Int
        let reclaimedMB: Double
    }

    /// 추적 중인 앱의 모든 PID에 SIGTERM (ProcessMonitor.killLeaked의 시그널 방식 일반화).
    @discardableResult
    func killApp(appName: String) -> KillOutcome {
        killPIDs(pidsByApp[appName] ?? [])
    }

    /// 지정 PID들에 SIGTERM. 종료 직전 RSS를 조회해 회수 메모리를 집계한다.
    @discardableResult
    func killPIDs(_ pids: [Int32]) -> KillOutcome {
        var killed = 0
        var failed = 0
        var reclaimedMB = 0.0
        let selfPid = getpid()

        for pid in pids where pid > 1 && pid != selfPid {
            // 종료 전 RSS 조회 (회수량 집계용)
            var info = proc_taskallinfo()
            let infoSize = Int32(MemoryLayout<proc_taskallinfo>.size)
            let memMB = proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, infoSize) > 0
                ? Double(info.ptinfo.pti_resident_size) / (1024.0 * 1024.0)
                : 0

            if kill(pid, SIGTERM) == 0 {
                killed += 1
                reclaimedMB += memMB
                logger.info("Terminated PID \(pid)")
            } else {
                failed += 1
                logger.error("Failed SIGTERM PID \(pid) errno=\(errno)")
            }
        }

        // killLeaked와 동일하게 잠시 후 재수집해 상태 반영
        if killed > 0 {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                self.collect()
            }
        }
        return KillOutcome(killed: killed, failed: failed, reclaimedMB: reclaimedMB)
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

    /// PID 1개의 원시 관측값 (드릴다운 판정 재료).
    private struct RawPidInfo: Sendable {
        let pid: Int32
        let ppid: Int32
        let memMB: Double
        let cpuRawNs: UInt64      // pti_total_user + pti_total_system (누적 ns)
        let startTvSec: UInt64    // pbsd.pbi_start_tvsec
    }

    /// 앱 단위로 집계된 중간 결과 (Sendable, 액터 경계 통과용).
    private struct RawAppGroup: Sendable {
        let appName: String
        let execPath: String
        let category: String
        var pids: [Int32]
        var totalMemMB: Double
        var cpuTimeSeconds: Double
        var procs: [RawPidInfo]
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
            // CPU 누적 시간: user + system (나노초 단위)
            let cpuRawNs = UInt64(info.ptinfo.pti_total_user) + UInt64(info.ptinfo.pti_total_system)
            let cpuSec   = Double(cpuRawNs) / 1_000_000_000.0

            let pidInfo = RawPidInfo(
                pid: pid, ppid: Int32(info.pbsd.pbi_ppid),
                memMB: memMB, cpuRawNs: cpuRawNs,
                startTvSec: info.pbsd.pbi_start_tvsec
            )

            let name = execPath.appDisplayName()
            if var g = groups[name] {
                g.pids.append(pid)
                g.totalMemMB += memMB
                g.cpuTimeSeconds += cpuSec
                g.procs.append(pidInfo)
                groups[name] = g
            } else {
                groups[name] = RawAppGroup(
                    appName: name, execPath: execPath, category: execPath.appCategory(),
                    pids: [pid], totalMemMB: memMB, cpuTimeSeconds: cpuSec,
                    procs: [pidInfo]
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
