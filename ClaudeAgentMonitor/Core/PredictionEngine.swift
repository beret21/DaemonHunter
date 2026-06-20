import Foundation
import Combine

// MARK: - Absolute Anomaly Level

enum AbsoluteAnomalyLevel: Int, Comparable, Sendable {
    case none     = 0
    case warning  = 1
    case critical = 2
    static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
}

// MARK: - Prediction Engine

/// Manages Kalman filters for multiple metrics and performs residual-based
/// anomaly detection.
///
/// One `KalmanFilter` is kept per metric. Each `update(...)` call runs a
/// predict/update cycle, records the innovation in a rolling window, and emits
/// a `Prediction` with short-horizon forecasts and an anomaly verdict.
@MainActor
final class PredictionEngine: ObservableObject {
    static let shared = PredictionEngine()

    struct Prediction: Sendable {
        let metric: String
        let currentEstimate: Double
        let velocity: Double          // per-interval rate of change
        let forecast5min: Double      // estimated value in 5 min (~10 intervals at 30s)
        let forecast10min: Double
        let sigma1: Double            // 1-sigma confidence bound at 5min
        let sigma2: Double            // 2-sigma confidence bound at 5min
        let residual: Double?         // latest innovation (actual - predicted)
        let residualZScore: Double?   // how many σ the residual is
        let isAnomaly: Bool           // |z-score| > 3.0 OR fast growth OR absolute threshold
        let anomalyDescription: String?
        // ── 절대값 기반 이상 ─────────────────────────────────────────
        let isAbsoluteAnomaly:          Bool
        let absoluteAnomalyLevel:       AbsoluteAnomalyLevel
        let absoluteAnomalyDescription: String?
        let updatedAt: Date
    }

    @Published private(set) var predictions: [String: Prediction] = [:]
    @Published private(set) var activeAnomalies: [Prediction] = []

    // Snapshot cadence: 30s intervals → 10 steps ≈ 5 min, 20 steps ≈ 10 min.
    private let intervalsPer5Min = 10
    private let intervalsPer10Min = 20

    private let anomalyZThreshold = 3.0
    private let processGrowthThreshold = 2.0   // processes/interval considered fast growth
    private let residualWindow = 30

    private static let metricKeys = ["process_count", "memory_gb", "cpu_percent", "thermal_level"]

    private struct NoiseConfig {
        let processNoise: Double
        let measurementNoise: Double
    }

    private static let noiseConfigs: [String: NoiseConfig] = [
        "process_count": NoiseConfig(processNoise: 0.5, measurementNoise: 2.0),
        "memory_gb":     NoiseConfig(processNoise: 0.1, measurementNoise: 0.5),
        "cpu_percent":   NoiseConfig(processNoise: 5.0, measurementNoise: 10.0),
        "thermal_level": NoiseConfig(processNoise: 0.1, measurementNoise: 0.3)
    ]

    // ── 절대값 임계값 (AppSettings 연동 — process_count/memory_gb는 UserDefaults 반영) ──
    private struct AbsoluteThreshold { let warning: Double; let critical: Double }
    private var absoluteThresholds: [String: AbsoluteThreshold] {
        [
            "process_count": AbsoluteThreshold(
                warning:  Double(AppSettings.warningProcessCount),
                critical: Double(AppSettings.criticalProcessCount)
            ),
            "memory_gb":     AbsoluteThreshold(warning: AppSettings.criticalMemoryGB * 0.5,
                                               critical: AppSettings.criticalMemoryGB),
            "cpu_percent":   AbsoluteThreshold(warning: 70, critical: 90),
            "thermal_level": AbsoluteThreshold(warning: 2,  critical: 3)   // serious=2, critical=3
        ]
    }

    private func absoluteLevel(metric: String, value: Double) -> AbsoluteAnomalyLevel {
        guard let t = absoluteThresholds[metric] else { return .none }
        if value >= t.critical { return .critical }
        if value >= t.warning  { return .warning  }
        return .none
    }

    private func absoluteAnomalyDesc(metric: String, value: Double, level: AbsoluteAnomalyLevel) -> String? {
        guard level != .none else { return nil }
        let label = level == .critical ? "위험" : "경고"
        switch metric {
        case "process_count": return "프로세스 수 \(Int(value))개 [\(label)]"
        case "memory_gb":     return String(format: "메모리 %.1fGB [%@]", value, label)
        case "cpu_percent":   return String(format: "CPU %.0f%% [%@]", value, label)
        case "thermal_level": return "발열 \(value >= 3 ? "위험" : "경고") [\(label)]"
        default:              return "\(metric) = \(value) [\(label)]"
        }
    }

    private var filters: [String: KalmanFilter] = [:]

    // Rolling residual history (circular buffer) per metric.
    private var residuals: [String: [Double]] = [:]
    private var residualIndex: [String: Int] = [:]

    private init() {}

    // MARK: Public API

    /// Call this whenever a new snapshot is available.
    func update(processCount: Int, memoryGB: Double, cpuPercent: Double, thermalLevel: Int) {
        let now = Date()
        ingest(metric: "process_count", value: Double(processCount), at: now)
        ingest(metric: "memory_gb",     value: memoryGB,            at: now)
        ingest(metric: "cpu_percent",   value: cpuPercent,          at: now)
        ingest(metric: "thermal_level", value: Double(thermalLevel), at: now)

        refreshActiveAnomalies()
    }

    /// Fills in the residual for the metric using a freshly observed value.
    /// Runs the filter's update step (correcting state toward the observation)
    /// and records the innovation in the rolling window.
    func updateResiduals(metric: String, actualValue: Double) {
        guard var filter = filters[metric] else { return }
        let (_, residual) = filter.update(measurement: actualValue)
        filters[metric] = filter
        recordResidual(metric: metric, residual: residual)
    }

    /// Returns forecast bounds for a specific metric across the requested
    /// step offsets. Bounds are estimate ± k·σ for the projected position.
    func forecast(metric: String, stepsAhead: [Int]) -> [(step: Int, value: Double, low1σ: Double, high1σ: Double, low2σ: Double, high2σ: Double)] {
        guard let filter = filters[metric], let maxStep = stepsAhead.max(), maxStep > 0 else {
            return []
        }

        let projection = filter.forecast(steps: maxStep)
        let wanted = Set(stepsAhead.filter { $0 > 0 })

        return projection
            .filter { wanted.contains($0.step) }
            .map { p in
                (
                    step: p.step,
                    value: p.value,
                    low1σ: p.value - p.sigma1,
                    high1σ: p.value + p.sigma1,
                    low2σ: p.value - p.sigma2,
                    high2σ: p.value + p.sigma2
                )
            }
    }

    // MARK: Core pipeline

    private func ingest(metric: String, value: Double, at now: Date) {
        let config = Self.noiseConfigs[metric] ?? NoiseConfig(processNoise: 1.0, measurementNoise: 4.0)

        // Lazily create the filter on first observation, seeded at that value.
        guard var filter = filters[metric] else {
            var seeded = KalmanFilter(
                initial: value,
                processNoise: config.processNoise,
                measurementNoise: config.measurementNoise
            )
            _ = seeded.predict()
            let (_, residual) = seeded.update(measurement: value)
            filters[metric] = seeded
            recordResidual(metric: metric, residual: residual)
            emitPrediction(metric: metric, residual: residual, now: now)
            return
        }

        // Predict the prior for this interval, then correct with the measurement.
        let (predictedValue, predictionVar) = filter.predict()
        let (_, residual) = filter.update(measurement: value)
        filters[metric] = filter

        recordResidual(metric: metric, residual: residual)
        emitPrediction(metric: metric, residual: residual, now: now)

        DatabaseManager.shared.insertKalmanPrediction(
            metric: metric,
            predictedValue: predictedValue,
            actualValue: value,
            residual: residual,
            predictionVar: predictionVar,
            horizonMinutes: 0.5
        )
    }

    private func emitPrediction(metric: String, residual: Double?, now: Date) {
        guard let filter = filters[metric] else { return }

        let forecast5 = filter.forecast(steps: intervalsPer5Min)
        let forecast10 = filter.forecast(steps: intervalsPer10Min)

        let at5 = forecast5.last
        let at10 = forecast10.last

        let zScore = residual.map { residualZScore(metric: metric, residual: $0) }

        let velocity   = filter.velocity
        let fastGrowth = metric == "process_count" && velocity > processGrowthThreshold
        let zAnomaly   = (zScore.map { abs($0) > anomalyZThreshold }) ?? false

        // 절대값 이상 판정 — 잔차와 무관하게 현재 추정값 자체가 위험 수준인지 확인
        let absLevel   = absoluteLevel(metric: metric, value: filter.estimate)
        let absDesc    = absoluteAnomalyDesc(metric: metric, value: filter.estimate, level: absLevel)

        let isAnomaly  = zAnomaly || fastGrowth || (absLevel != .none)

        let description = anomalyDescription(
            metric: metric,
            zScore: zScore,
            zAnomaly: zAnomaly,
            velocity: velocity,
            fastGrowth: fastGrowth,
            absDesc: absDesc
        )

        predictions[metric] = Prediction(
            metric: metric,
            currentEstimate: filter.estimate,
            velocity: velocity,
            forecast5min: at5?.value ?? filter.estimate,
            forecast10min: at10?.value ?? filter.estimate,
            sigma1: at5?.sigma1 ?? 0,
            sigma2: at5?.sigma2 ?? 0,
            residual: residual,
            residualZScore: zScore,
            isAnomaly: isAnomaly,
            anomalyDescription: description,
            isAbsoluteAnomaly: absLevel != .none,
            absoluteAnomalyLevel: absLevel,
            absoluteAnomalyDescription: absDesc,
            updatedAt: now
        )
    }

    private func refreshActiveAnomalies() {
        activeAnomalies = predictions.values
            .filter { $0.isAnomaly }
            .sorted { a, b in
                // Critical 절대값 > Warning 절대값 > 잔차 z-score
                if a.absoluteAnomalyLevel != b.absoluteAnomalyLevel {
                    return a.absoluteAnomalyLevel > b.absoluteAnomalyLevel
                }
                return abs(a.residualZScore ?? 0) > abs(b.residualZScore ?? 0)
            }
    }

    // MARK: Residual statistics

    private func recordResidual(metric: String, residual: Double) {
        var buffer = residuals[metric] ?? []
        if buffer.count < residualWindow {
            buffer.append(residual)
        } else {
            let idx = residualIndex[metric] ?? 0
            buffer[idx] = residual
            residualIndex[metric] = (idx + 1) % residualWindow
        }
        residuals[metric] = buffer
    }

    private func residualZScore(metric: String, residual: Double) -> Double {
        let std = residualStdDev(metric: metric)
        return residual / (std + 1e-6)
    }

    private func residualStdDev(metric: String) -> Double {
        guard let buffer = residuals[metric], buffer.count > 1 else { return 0 }
        let mean = buffer.reduce(0, +) / Double(buffer.count)
        let variance = buffer.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(buffer.count)
        return variance.squareRoot()
    }

    private func anomalyDescription(
        metric: String,
        zScore: Double?,
        zAnomaly: Bool,
        velocity: Double,
        fastGrowth: Bool,
        absDesc: String?
    ) -> String? {
        var parts: [String] = []
        if let d = absDesc { parts.append(d) }
        if zAnomaly, let z = zScore {
            let dir = z > 0 ? "초과" : "미달"
            parts.append(String(format: "%@ 잔차 %.1fσ %@", metric, abs(z), dir))
        }
        if fastGrowth {
            parts.append(String(format: "프로세스 급증 +%.1f/인터벌", velocity))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
