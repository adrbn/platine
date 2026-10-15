import Foundation

/// Plan-view geometry of a pivoted tonearm, in the turntable's top plane.
/// Coordinates: x to the right, z toward the viewer (SceneKit convention).
/// Yaw is the rotation about +y, so the arm points along (cos yaw, -sin yaw).
struct TonearmGeometry: Equatable {
    var spindle: SIMD2<Double>   // (x, z)
    var pivot: SIMD2<Double>
    var overhang: Double = 0.015

    var mountingDistance: Double { simdLength(spindle - pivot) }
    /// Pivot to stylus tip: mounting distance plus overhang, like a real arm.
    var effectiveLength: Double { mountingDistance + overhang }

    /// Arm on its rest, parallel to the plinth's right edge, pointing to the front.
    var restYaw: Double { -Double.pi / 2 + 0.035 }

    /// The yaw that puts the stylus `radius` metres from the spindle.
    func yaw(forRadius radius: Double) -> Double {
        let v = spindle - pivot
        let d = mountingDistance
        let l = effectiveLength
        let base = atan2(-v.y, v.x)
        let c = (d * d + l * l - radius * radius) / (2 * d * l)
        return base + acos(min(1, max(-1, c)))
    }

    func stylus(atYaw yaw: Double) -> SIMD2<Double> {
        pivot + effectiveLength * SIMD2(cos(yaw), -sin(yaw))
    }
}

func simdLength(_ v: SIMD2<Double>) -> Double { (v * v).sum().squareRoot() }
