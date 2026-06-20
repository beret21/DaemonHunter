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
        thermalState: .nominal, fanSpeedRPM: nil, timestamp: Date()
    )
}

// MARK: - Collector

@MainActor
final class SystemMetricsCollector: ObservableObject {
    @Published private(set) var current = SystemMetrics.empty

    private let cpuSampler = CPUSampler()
    private var timer: Timer?
    private let logger = Logger(subsystem: "com.beret21.DaemonHunter", category: "SystemMetrics")

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
        let mem     = Self.memoryStats()
        let thermal = Self.thermalLevel()
        let fan     = Self.fanSpeedRPM()

        current = SystemMetrics(
            cpuUsagePercent: cpu,
            loadAvg1min:  load.0,
            loadAvg5min:  load.1,
            memUsedGB:    mem.used,
            memTotalGB:   mem.total,
            memPressure:  mem.pressure,
            thermalState: thermal,
            fanSpeedRPM:  fan,
            timestamp: Date()
        )
    }

    // MARK: - Load average

    private static func loadAverage() -> (Double, Double) {
        var avg = [Double](repeating: 0, count: 2)
        getloadavg(&avg, 2)
        return (avg[0], avg[1])
    }

    // MARK: - Memory

    private static func memoryStats() -> (used: Double, total: Double, pressure: SystemMetrics.MemPressure) {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return (0, ProcessInfo.processInfo.physicalMemory.toGB, .normal)
        }

        let page    = Double(getpagesize())  // C function; avoids Swift 6 shared-mutable-state error on vm_*_page_size
        let active  = Double(stats.active_count)   * page
        let inactive = Double(stats.inactive_count) * page
        let wired   = Double(stats.wire_count)      * page
        let free    = Double(stats.free_count)      * page
        let used    = (active + inactive + wired) / 1e9
        let total   = Double(ProcessInfo.processInfo.physicalMemory) / 1e9

        // 압력 판정: 사용률 기준
        let ratio = used / max(1, total)
        let pressure: SystemMetrics.MemPressure = ratio > 0.90 ? .critical : ratio > 0.75 ? .warning : .normal

        return (used, total, pressure)
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
