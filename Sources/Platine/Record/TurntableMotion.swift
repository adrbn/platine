import Foundation

/// What the turntable should be doing right now.
enum TurntableMode: Equatable {
    /// Stylus in the groove at this radius, platter at speed.
    case play(radius: Double, rpm: Double)
    /// Cue lever up: arm hovers where it is, platter keeps turning.
    case cue(rpm: Double)
    /// Arm back on its rest, platter stopped.
    case rest
}

/// Kinematics of the platter and the automatic arm, stepped once per frame.
/// Pure state, no SceneKit, so it can be unit tested.
struct TurntableMotion {
    enum ArmPhase: Equatable { case down, lifting, moving, lowering }

    static let spinUpTime = 0.7          // 0 → 33⅓ in 0.7 s
    static let brakeTime = 1.1
    static let liftTime = 0.45
    static let lowerTime = 1.5           // the cue comes down slowly
    static let maxSwing = 0.55           // rad/s
    static let skipThreshold = 0.004     // m: a jump this big means lift and re-land

    let geometry: TonearmGeometry
    private(set) var phase: ArmPhase = .down
    private(set) var yaw: Double
    private(set) var lift: Double = 0            // 0 = resting/in groove, 1 = raised
    private(set) var platterSpeed: Double = 0    // rev/s
    private(set) var platterAngle: Double = 0    // rad

    init(geometry: TonearmGeometry) {
        self.geometry = geometry
        yaw = geometry.restYaw
    }

    /// Arm on its rest and platter stopped: safe to swap or flip the record.
    var isParked: Bool {
        phase == .down && abs(yaw - geometry.restYaw) < 0.002 && platterSpeed < 0.01
    }

    mutating func step(dt rawDt: Double, mode: TurntableMode) {
        let dt = min(max(rawDt, 0), 0.1)
        stepPlatter(dt: dt, mode: mode)
        stepArm(dt: dt, mode: mode)
    }

    private mutating func stepPlatter(dt: Double, mode: TurntableMode) {
        let target: Double
        switch mode {
        case .play(_, let rpm), .cue(let rpm): target = rpm / 60
        case .rest: target = 0
        }
        let accel = (100.0 / 3 / 60) / Self.spinUpTime
        let brake = (100.0 / 3 / 60) / Self.brakeTime
        if platterSpeed < target {
            platterSpeed = min(target, platterSpeed + accel * dt)
        } else {
            platterSpeed = max(target, platterSpeed - brake * dt)
        }
        platterAngle = (platterAngle + platterSpeed * 2 * .pi * dt).truncatingRemainder(dividingBy: 2 * .pi)
    }

    private mutating func stepArm(dt: Double, mode: TurntableMode) {
        let targetYaw: Double
        let wantsDown: Bool
        switch mode {
        case .play(let radius, let rpm):
            targetYaw = geometry.yaw(forRadius: radius)
            // An automatic arm only drops once the platter is at speed.
            wantsDown = platterSpeed >= rpm / 60 * 0.9
        case .cue:
            targetYaw = yaw
            wantsDown = false
        case .rest:
            targetYaw = geometry.restYaw
            wantsDown = true
        }
        let threshold = Self.skipThreshold / geometry.effectiveLength

        switch phase {
        case .down:
            let diff = abs(targetYaw - yaw)
            if case .play = mode, diff < threshold {
                yaw = targetYaw                  // tracking the groove
            } else if case .rest = mode, diff < 0.0005 {
                // parked on the rest
            } else {
                phase = .lifting
            }
        case .lifting:
            lift = min(1, lift + dt / Self.liftTime)
            if lift >= 1 { phase = .moving }
        case .moving:
            let diff = targetYaw - yaw
            let speed = min(Self.maxSwing, abs(diff) * 3 + 0.02)
            yaw += max(-speed * dt, min(speed * dt, diff))
            if abs(targetYaw - yaw) < 0.0004 && wantsDown {
                yaw = targetYaw
                phase = .lowering
            }
        case .lowering:
            if abs(targetYaw - yaw) > threshold || !wantsDown {
                phase = .lifting
            } else {
                yaw = targetYaw
                lift = max(0, lift - dt / Self.lowerTime)
                if lift <= 0 { phase = .down }
            }
        }
    }
}
