import Foundation

/// One song as it gets cut into the record.
struct LPTrack: Equatable, Codable {
    var title: String
    var duration: Double   // seconds
    var number: Int
    var disc: Int = 1
}

/// The band of grooves one song occupies on one side.
struct LPBand: Equatable {
    let trackIndex: Int
    let outerRadius: Double   // metres from the spindle
    let innerRadius: Double
    let duration: Double
}

struct LPSide: Equatable {
    let index: Int
    let bands: [LPBand]
    var letter: String { String(UnicodeScalar(UInt8(65 + index))) }
    var duration: Double { bands.reduce(0) { $0 + $1.duration } }
    /// Where the smooth run-out starts.
    var runOutRadius: Double { bands.last?.innerRadius ?? LPLayout.leadInRadius }
}

/// Real LP geometry: each band is as wide as its song is long, a side holds about
/// 26 minutes at 33⅓, long albums become a double LP, short singles play at 45.
/// At a constant speed and groove pitch the radius falls linearly with time.
struct LPLayout: Equatable {
    static let recordRadius = 0.1515
    static let leadInRadius = 0.146
    static let lastGrooveRadius = 0.062
    static let labelRadius = 0.050
    static let bandGap = 0.0009
    static let longPlayCapacity = 26.0 * 60
    static let singleCapacity = 12.0 * 60

    let sides: [LPSide]
    let rpm: Double

    var isSingle: Bool { rpm > 40 }

    init(tracks: [LPTrack]) {
        let durations = tracks.map { max(1, $0.duration) }
        let total = durations.reduce(0, +)
        let single = !tracks.isEmpty && tracks.count <= 3 && total <= 2 * Self.singleCapacity
        rpm = single ? 45 : 100.0 / 3
        let capacity = single ? Self.singleCapacity : Self.longPlayCapacity

        guard !tracks.isEmpty else { sides = []; return }

        var sideCount: Int
        if single {
            sideCount = tracks.count == 1 ? 1 : 2
        } else {
            sideCount = max(2, Int((total / capacity).rounded(.up)))
            if sideCount % 2 == 1 { sideCount += 1 }
        }
        sideCount = min(sideCount, tracks.count, 12)

        let groups = Self.partition(durations, into: sideCount)
        var built: [LPSide] = []
        for (sideIndex, range) in groups.enumerated() {
            let sideDuration = range.reduce(0) { $0 + durations[$1] }
            // A side longer than the nominal capacity is cut at a finer pitch.
            let span = Self.leadInRadius - Self.lastGrooveRadius
            let gaps = Double(max(0, range.count - 1)) * Self.bandGap
            let metresPerSecond = (span - gaps) / max(capacity, sideDuration)
            var r = Self.leadInRadius
            var bands: [LPBand] = []
            for i in range {
                let width = durations[i] * metresPerSecond
                bands.append(LPBand(trackIndex: i, outerRadius: r, innerRadius: r - width, duration: durations[i]))
                r -= width + Self.bandGap
            }
            built.append(LPSide(index: sideIndex, bands: bands))
        }
        sides = built
    }

    func band(forTrack index: Int) -> (side: Int, band: LPBand)? {
        for side in sides {
            if let band = side.bands.first(where: { $0.trackIndex == index }) { return (side.index, band) }
        }
        return nil
    }

    /// Where the stylus sits for a track at a position (seconds into the song).
    func needle(track index: Int, position: Double) -> (side: Int, radius: Double)? {
        guard let (side, band) = band(forTrack: index) else { return nil }
        let t = min(max(position / band.duration, 0), 1)
        return (side, band.outerRadius - (band.outerRadius - band.innerRadius) * t)
    }

    /// Splits consecutive items into `count` runs minimising the longest run
    /// (linear partition). Small inputs, so a plain O(n²·k) DP is plenty.
    static func partition(_ values: [Double], into count: Int) -> [Range<Int>] {
        let n = values.count
        let k = max(1, min(count, n))
        var prefix = [0.0]
        for v in values { prefix.append(prefix.last! + v) }
        func sum(_ a: Int, _ b: Int) -> Double { prefix[b] - prefix[a] }

        // cost[j][i]: best max-run for the first i items in j runs.
        var cost = Array(repeating: Array(repeating: Double.infinity, count: n + 1), count: k + 1)
        var cut = Array(repeating: Array(repeating: 0, count: n + 1), count: k + 1)
        cost[0][0] = 0
        for j in 1...k {
            for i in j...n {
                for p in (j - 1)..<i {
                    let c = max(cost[j - 1][p], sum(p, i))
                    // Ties prefer a later cut so side A gets the extra song, like most pressings.
                    if c <= cost[j][i] { cost[j][i] = c; cut[j][i] = p }
                }
            }
        }
        var ranges: [Range<Int>] = []
        var i = n
        for j in stride(from: k, through: 1, by: -1) {
            let p = cut[j][i]
            ranges.insert(p..<i, at: 0)
            i = p
        }
        return ranges
    }
}
