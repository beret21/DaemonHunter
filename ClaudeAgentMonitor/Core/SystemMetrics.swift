import Foundation
import IOKit
import Darwin
import os

// MARK: - Data model

struct SystemMetrics: Sendable {
    let cpuUsagePercent: Double         // 0–100
    let loadAvg1min: Double
    let loadAvg5min: Double
    let memUsedGB: Double
    let memTotalGB: Double
    let memPressure: MemPressure
    let thermalState: ThermalLevel
    let fanSpeedRPM: Int?               // nil if not available

    // ── 절대 관측 지표 (스왑·메모리 압박) ─────────────────────────────
    let swapUsedGB:      Double         // vm.swapusage xsu_used
    let swapTotalGB:     Double         // vm.swapusage xsu_total
    let memFreeGB:       Double         // HOST_VM_INFO64 free_count
    let memActiveGB:     Double         // active_count
    let memInactiveGB:   Double         // inactive_count
    let memWiredGB:      Double         // wire_count
    let memCompressedGB: Double         // compressor_page_count
    let swapoutsLifetime: UInt64        // 누적 swapouts (page-out via compressor)
    let swapinsLifetime:  UInt64        // 누적 swapins  (page-in  via compressor)

    // ── swap IO RATE (stock이 아닌 throughput; 스왑 스래싱 판정용) ──────
    // 직전 표본 대비 swapins/swapouts 카운터 델타를 경과 wall 시간으로 나눈 값.
    let swapInsPerSec:  Double          // pages/sec
    let swapOutsPerSec: Double          // pages/sec

    /// 스왑 사용률 0.0–1.0 (used / total). 스왑 미구성 시 0.
    var swapUsageRatio: Double { swapTotalGB > 0 ? swapUsedGB / swapTotalGB : 0 }

    /// 스왑 IO 총 처리율 (pages/sec). 크기(ratio)가 아니라 실제 페이징 활동량 → 스래싱 신호.
    var swapIOPagesPerSec: Double { swapInsPerSec + swapOutsPerSec }

    let timestamp: Date

    enum MemPressure: String, Sendable {
        case normal = "정상"
        case warning = "주의"
        case critical = "위험"
    }

    enum ThermalLevel: String, Sendable {
        case nominal = "정상"
        case fair    = "주의"
        case serious = "위험"
        case critical = "심각"

        var emoji: String {
            switch self {
            case .nominal:  return "🟢"
            case .fair:     return "🟡"
            case .serious:  return "🟠"
            case .critical: return "🔴"
            }
        }
    }

    static let empty = SystemMetrics(
        cpuUsagePercent: 0, loadAvg1min: 0, loadAvg5min: 0,
        memUsedGB: 0, memTotalGB: 0, memPressure: .normal,
        thermalState: .nominal, fanSpeedRPM: nil,
        swapUsedGB: 0, swapTotalGB: 0, memFreeGB: 0, memActiveGB: 0,
        memInactiveGB: 0, memWiredGB: 0, memCompressedGB: 0, swapoutsLifetime: 0,
        swapinsLifetime: 0, swapInsPerSec: 0, swapOutsPerSec: 0,
        timestamp: Date()
    )
}

// MARK: - Collector

@MainActor
final class SystemMetricsCollector: ObservableObject {
    @Published private(set) var current = SystemMetrics.empty

    private let cpuSampler = CPUSampler()
    private var timer: Timer?
    private let logger = Logger(subsystem: "com.beret21.DaemonHunter", category: "SystemMetrics")

    // ── swap IO rate 계산용 이전 표본 (누적 카운터 델타) ─────────────────
    private var prevSwapins:  UInt64 = 0
    private var prevSwapouts: UInt64 = 0
    private var prevSwapTime: Date?

    static let shared = SystemMetricsCollector()
    private init() {}

    func start() {
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        let cpu     = cpuSampler.usage()
        let load    = Self.loadAverage()
        let mem     = Self.memoryDetail()
        let swap    = Self.swapUsage()
        let thermal = Self.thermalLevel()
        let fan     = Self.fanSpeedRPM()

        // swap IO rate: 누적 카운터 델타 / 경과 wall 시간. 첫 표본·카운터 리셋 시 0.
        let now = Date()
        var swapInRate = 0.0, swapOutRate = 0.0
        if let prev = prevSwapTime {
            let dt = now.timeIntervalSince(prev)
            if dt > 0 {
                if mem.swapins  >= prevSwapins  { swapInRate  = Double(mem.swapins  - prevSwapins)  / dt }
                if mem.swapouts >= prevSwapouts { swapOutRate = Double(mem.swapouts - prevSwapouts) / dt }
            }
        }
        prevSwapins = mem.swapins; prevSwapouts = mem.swapouts; prevSwapTime = now

        current = SystemMetrics(
            cpuUsagePercent: cpu,
            loadAvg1min:  load.0,
            loadAvg5min:  load.1,
            memUsedGB:    mem.used,
            memTotalGB:   mem.total,
            memPressure:  mem.pressure,
            thermalState: thermal,
            fanSpeedRPM:  fan,
            swapUsedGB:      swap.used,
            swapTotalGB:     swap.total,
            memFreeGB:       mem.free,
            memActiveGB:     mem.active,
            memInactiveGB:   mem.inactive,
            memWiredGB:      mem.wired,
            memCompressedGB: mem.compressed,
            swapoutsLifetime: mem.swapouts,
            swapinsLifetime:  mem.swapins,
            swapInsPerSec:    swapInRate,
            swapOutsPerSec:   swapOutRate,
            timestamp: now
        )
    }

    // MARK: - Load average

    private static func loadAverage() -> (Double, Double) {
        var avg = [Double](repeating: 0, count: 2)
        getloadavg(&avg, 2)
        return (avg[0], avg[1])
    }

    // MARK: - Memory (host_statistics64 / HOST_VM_INFO64)

    private struct MemBreakdown {
        let used: Double; let total: Double; let pressure: SystemMetrics.MemPressure
        let free: Double; let active: Double; let inactive: Double
        let wired: Double; let compressed: Double
        let swapouts: UInt64; let swapins: UInt64
    }

    private static func memoryDetail() -> MemBreakdown {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        let total = Double(ProcessInfo.processInfo.physicalMemory) / 1e9
        guard result == KERN_SUCCESS else {
            return MemBreakdown(used: 0, total: total, pressure: .normal,
                                free: 0, active: 0, inactive: 0,
                                wired: 0, compressed: 0, swapouts: 0, swapins: 0)
        }

        let page     = Double(getpagesize())  // C function; avoids Swift 6 shared-mutable-state error on vm_*_page_size
        let active   = Double(stats.active_count)          * page
        let inactive = Double(stats.inactive_count)        * page
        let wired    = Double(stats.wire_count)            * page
        let free     = Double(stats.free_count)            * page
        let compressed = Double(stats.compressor_page_count) * page
        let used     = (active + inactive + wired) / 1e9

        // 압력 판정: 사용률 기준
        let ratio = used / max(1, total)
        let pressure: SystemMetrics.MemPressure = ratio > 0.90 ? .critical : ratio > 0.75 ? .warning : .normal

        return MemBreakdown(
            used: used, total: total, pressure: pressure,
            free: free / 1e9, active: active / 1e9, inactive: inactive / 1e9,
            wired: wired / 1e9, compressed: compressed / 1e9,
            swapouts: stats.swapouts, swapins: stats.swapins
        )
    }

    // MARK: - Swap (sysctlbyname vm.swapusage → xsw_usage)

    private static func swapUsage() -> (used: Double, total: Double) {
        var usage = xsw_usage()
        var size  = MemoryLayout<xsw_usage>.stride
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else {
            return (0, 0)
        }
        // xsu_used / xsu_total are bytes
        return (Double(usage.xsu_used) / 1e9, Double(usage.xsu_total) / 1e9)
    }

    // MARK: - Thermal (ProcessInfo)

    private static func thermalLevel() -> SystemMetrics.ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return .nominal
        case .fair:     return .fair
        case .serious:  return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }

    // MARK: - Fan speed via IOKit (best-effort, Apple Silicon)

    private static func fanSpeedRPM() -> Int? {
        // AppleSmartFanControl — available on many Macs
        let matchDict = IOServiceMatching("AppleSmartFanControl")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matchDict)
        defer { if service != 0 { IOObjectRelease(service) } }

        guard service != 0 else { return fallbackFanFromIOHID() }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }

        // Key names differ by model — try common patterns
        for key in ["Fan0Speed", "FAN_0_RPM", "F0Ac", "fan-speed"] {
            if let val = dict[key] as? Int, val > 0 { return val }
            if let val = dict[key] as? Double, val > 0 { return Int(val) }
        }
        return nil
    }

    private static func fallbackFanFromIOHID() -> Int? {
        // Try IOPlatformExpertDevice power data
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice"))
        defer { if service != 0 { IOObjectRelease(service) } }
        guard service != 0 else { return nil }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }

        // Some M-series Macs report fan data here
        for key in ["FanSpeed", "fan-speed", "FAN0"] {
            if let val = dict[key] as? Int, val > 0 { return val }
        }
        return nil
    }
}

// MARK: - CPU Sampler (delta between calls)

final class CPUSampler {
    private var prevIdle:  Double = 0
    private var prevTotal: Double = 0

    func usage() -> Double {
        let (idle, total) = ticks()
        let dIdle  = idle  - prevIdle
        let dTotal = total - prevTotal
        prevIdle = idle; prevTotal = total
        guard dTotal > 0 else { return 0 }
        return max(0, min(100, (1.0 - dIdle / dTotal) * 100.0))
    }

    private func ticks() -> (idle: Double, total: Double) {
        var cpuInfo: processor_info_array_t?
        var numInfo: mach_msg_type_number_t = 0
        var numCPUs: natural_t = 0

        let err = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                      &numCPUs, &cpuInfo, &numInfo)
        guard err == KERN_SUCCESS, let info = cpuInfo else { return (0, 0) }

        var idleSum = 0.0, totalSum = 0.0
        for i in 0..<Int(numCPUs) {
            let base   = Int(CPU_STATE_MAX) * i
            let user   = Double(info[base + Int(CPU_STATE_USER)])
            let sys    = Double(info[base + Int(CPU_STATE_SYSTEM)])
            let idle   = Double(info[base + Int(CPU_STATE_IDLE)])
            let nice   = Double(info[base + Int(CPU_STATE_NICE)])
            idleSum   += idle
            totalSum  += user + sys + idle + nice
        }

        vm_deallocate(mach_task_self_,
                      vm_address_t(bitPattern: info),
                      vm_size_t(Int(numInfo) * MemoryLayout<integer_t>.size))
        return (idleSum, totalSum)
    }
}

// MARK: - Helpers

private extension UInt64 {
    var toGB: Double { Double(self) / 1e9 }
}
