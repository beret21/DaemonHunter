import Foundation

// MARK: - Kalman Filter

/// 2-state (position + velocity) Kalman filter for scalar time series.
///
/// Tracks a quantity and its rate of change using a constant-velocity process
/// model. State transition `F = [[1,1],[0,1]]`, measurement model `H = [1,0]`
/// (direct observation of position). All time steps assume `dt = 1` interval.
struct KalmanFilter {
    // State
    var estimate: Double        // current smoothed value
    var velocity: Double        // current rate of change (per interval)

    // Error covariance (2x2 stored as flat fields, row-major)
    var p00, p01, p10, p11: Double

    // Noise parameters
    let processNoise: Double      // σ² for process noise (how fast the process changes)
    let measurementNoise: Double  // σ² for measurement noise (sensor uncertainty)

    init(initial: Double, processNoise: Double = 1.0, measurementNoise: Double = 4.0) {
        self.estimate = initial
        self.velocity = 0
        // Start with moderate uncertainty on position, higher on velocity.
        self.p00 = 1.0
        self.p01 = 0.0
        self.p10 = 0.0
        self.p11 = 1.0
        self.processNoise = processNoise
        self.measurementNoise = measurementNoise
    }

    /// Run prediction step (dt = 1 interval).
    /// Returns the predicted position and its variance, and advances state +
    /// covariance to the predicted prior.
    mutating func predict() -> (value: Double, variance: Double) {
        // x_pred = F * x  with F = [[1,1],[0,1]]
        let predValue = estimate + velocity
        let predVelocity = velocity

        // P_pred = F * P * F^T + Q
        // F*P = [[p00+p10, p01+p11], [p10, p11]]
        // (F*P)*F^T = [[p00+p10+p01+p11, p01+p11], [p10+p11, p11]]
        let q00 = processNoise * 0.25
        let q01 = processNoise * 0.5
        let q10 = processNoise * 0.5
        let q11 = processNoise * 1.0

        let newP00 = (p00 + p10 + p01 + p11) + q00
        let newP01 = (p01 + p11) + q01
        let newP10 = (p10 + p11) + q10
        let newP11 = p11 + q11

        estimate = predValue
        velocity = predVelocity
        p00 = newP00
        p01 = newP01
        p10 = newP10
        p11 = newP11

        return (predValue, p00)
    }

    /// Run update step with a new measurement.
    /// Returns the corrected estimate and the innovation/residual `(z - x_pred)`.
    mutating func update(measurement z: Double) -> (estimate: Double, residual: Double) {
        // Innovation (residual) against current (predicted) position.
        let residual = z - estimate

        // S = H*P*H^T + R = p00 + R
        let s = p00 + measurementNoise

        // Kalman gain K = P*H^T / S = [p00, p10]^T / S
        let k0 = p00 / s
        let k1 = p10 / s

        // x = x_pred + K * residual
        estimate += k0 * residual
        velocity += k1 * residual

        // P = (I - K*H) * P_pred, with K*H = [[k0,0],[k1,0]]
        let newP00 = (1 - k0) * p00
        let newP01 = (1 - k0) * p01
        let newP10 = p10 - k1 * p00
        let newP11 = p11 - k1 * p01

        p00 = newP00
        p01 = newP01
        p10 = newP10
        p11 = newP11

        return (estimate, residual)
    }

    /// Projects the filter state forward by `steps` intervals without updating.
    /// Returns array of (step, value, ±1σ_bound, ±2σ_bound) where the sigma
    /// bounds are the projected position standard deviation scaled by 1 and 2.
    func forecast(steps: Int) -> [(step: Int, value: Double, sigma1: Double, sigma2: Double)] {
        guard steps > 0 else { return [] }

        // Work on a copy so the live filter is untouched.
        var copy = self
        var result: [(step: Int, value: Double, sigma1: Double, sigma2: Double)] = []
        result.reserveCapacity(steps)

        for step in 1...steps {
            let (value, variance) = copy.predict()
            let sigma = variance > 0 ? variance.squareRoot() : 0
            result.append((step: step, value: value, sigma1: sigma, sigma2: 2 * sigma))
        }

        return result
    }
}
