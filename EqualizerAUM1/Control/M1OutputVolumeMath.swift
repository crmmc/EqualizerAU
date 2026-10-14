import Foundation

/// Pure volume math shared by the output-volume observer and the loudness
/// rebuild path (ADR-0023). Kept free of Core Audio calls so it stays inside
/// the coverage gate.
enum M1OutputVolumeMath {
    /// ADR-0023 fallback when the device cannot convert scalar to decibels.
    static func approximateDecibels(fromScalar scalar: Float) -> Double? {
        guard scalar.isFinite else { return nil }
        guard scalar > 0 else { return -120 }
        return max(20 * log10(Double(scalar)), -120)
    }

    /// Volume events are quantized onto the loudness reference grid before
    /// republishing, so the observer and the compensation curve move on the
    /// same steps (`M1LoudnessContract.referenceVolumeStepDB`).
    static func quantizedDecibels(_ decibels: Double) -> Double? {
        guard decibels.isFinite else { return nil }
        let step = M1LoudnessContract.referenceVolumeStepDB
        return (decibels / step).rounded() * step
    }
}
