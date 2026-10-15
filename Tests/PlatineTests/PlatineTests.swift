import Foundation
import Testing

private func tracks(_ minutes: [Double]) -> [LPTrack] {
    minutes.enumerated().map { LPTrack(title: "T\($0.offset + 1)", duration: $0.element * 60, number: $0.offset + 1) }
}

@Suite struct LPLayoutTests {
    @Test func shortSingleSpinsAt45() {
        let layout = LPLayout(tracks: tracks([3.5, 4]))
        #expect(layout.rpm == 45)
        #expect(layout.sides.count == 2)
    }

    @Test func fortyMinuteAlbumIsTwoBalancedSides() {
        let layout = LPLayout(tracks: tracks(Array(repeating: 4, count: 10)))
        #expect(layout.rpm == 100.0 / 3)
        #expect(layout.sides.map(\.bands.count) == [5, 5])
    }

    @Test func longAlbumBecomesDoubleLP() {
        let layout = LPLayout(tracks: tracks(Array(repeating: 4, count: 20)))
        #expect(layout.sides.count == 4)
        #expect(layout.sides.map(\.letter) == ["A", "B", "C", "D"])
        #expect(layout.sides.allSatisfy { $0.duration <= LPLayout.longPlayCapacity })
    }

    @Test func bandWidthIsProportionalToDuration() {
        let layout = LPLayout(tracks: tracks([2, 6, 4, 4]))
        let a = layout.sides[0].bands
        let w0 = a[0].outerRadius - a[0].innerRadius
        let w1 = a[1].outerRadius - a[1].innerRadius
        #expect(abs(w1 / w0 - 3) < 1e-9)
        #expect(a[0].outerRadius == LPLayout.leadInRadius)
        #expect(a[1].outerRadius < a[0].innerRadius)   // a gap between songs
    }

    @Test func shortSideLeavesARunOut() {
        let layout = LPLayout(tracks: tracks([4, 4, 4, 4]))
        #expect(layout.sides[0].runOutRadius > LPLayout.lastGrooveRadius + 0.02)
    }

    @Test func overlongSideStillFitsTheGrooveArea() {
        let layout = LPLayout(tracks: tracks([40, 40]))
        for side in layout.sides {
            #expect(side.runOutRadius >= LPLayout.lastGrooveRadius - 1e-9)
        }
    }

    @Test func needleWalksInwardThroughTheSong() throws {
        let layout = LPLayout(tracks: tracks([4, 4, 4, 4, 4, 4]))
        let start = try #require(layout.needle(track: 4, position: 0))
        let mid = try #require(layout.needle(track: 4, position: 120))
        let end = try #require(layout.needle(track: 4, position: 999))
        #expect(start.side == 1)
        #expect(start.radius > mid.radius && mid.radius > end.radius)
    }

    @Test func partitionMinimisesTheLongestRun() {
        let runs = LPLayout.partition([1, 1, 1, 1, 10], into: 2)
        #expect(runs == [0..<4, 4..<5])
    }
}

@Suite struct TonearmTests {
    let geometry = TonearmGeometry(spindle: SIMD2(-0.04, 0.0), pivot: SIMD2(0.17, -0.10))

    @Test(arguments: [0.146, 0.12, 0.09, 0.062])
    func stylusLandsOnTheRequestedRadius(radius: Double) {
        let tip = geometry.stylus(atYaw: geometry.yaw(forRadius: radius))
        #expect(abs(simdLength(tip - geometry.spindle) - radius) < 1e-9)
    }

    @Test func armSweepsInwardFromTheRest() {
        let outer = geometry.yaw(forRadius: 0.146)
        let inner = geometry.yaw(forRadius: 0.062)
        #expect(geometry.restYaw > outer && outer > inner)
        // The rest keeps the stylus off the record.
        #expect(simdLength(geometry.stylus(atYaw: geometry.restYaw) - geometry.spindle) > LPLayout.recordRadius)
    }
}

@Suite struct MotionTests {
    let geometry = TonearmGeometry(spindle: SIMD2(-0.04, 0.0), pivot: SIMD2(0.17, -0.10))

    private func run(_ m: inout TurntableMotion, _ seconds: Double, _ mode: TurntableMode) {
        for _ in 0..<Int(seconds * 60) { m.step(dt: 1.0 / 60, mode: mode) }
    }

    @Test func platterReachesSpeedInSevenTenths() {
        var m = TurntableMotion(geometry: geometry)
        run(&m, 0.7, .play(radius: 0.146, rpm: 100.0 / 3))
        #expect(abs(m.platterSpeed - 100.0 / 3 / 60) < 0.01)
    }

    @Test func armCuesOntoTheLeadInThenParksAgain() {
        var m = TurntableMotion(geometry: geometry)
        #expect(m.isParked)
        run(&m, 6, .play(radius: 0.146, rpm: 100.0 / 3))
        #expect(m.phase == .down)
        #expect(m.lift == 0)
        #expect(abs(m.yaw - geometry.yaw(forRadius: 0.146)) < 1e-6)
        run(&m, 6, .rest)
        #expect(m.isParked)
    }

    @Test func skippingLiftsTheArm() {
        var m = TurntableMotion(geometry: geometry)
        run(&m, 6, .play(radius: 0.14, rpm: 100.0 / 3))
        m.step(dt: 1.0 / 60, mode: .play(radius: 0.10, rpm: 100.0 / 3))
        m.step(dt: 1.0 / 60, mode: .play(radius: 0.10, rpm: 100.0 / 3))
        #expect(m.phase == .lifting)
        run(&m, 6, .play(radius: 0.10, rpm: 100.0 / 3))
        #expect(m.phase == .down)
    }

    @Test func pauseHoversTheArm() {
        var m = TurntableMotion(geometry: geometry)
        run(&m, 6, .play(radius: 0.14, rpm: 100.0 / 3))
        let yaw = m.yaw
        run(&m, 2, .cue(rpm: 100.0 / 3))
        #expect(m.lift == 1)
        #expect(m.yaw == yaw)
    }
}

@Suite struct DayCycleTests {
    @Test func noonIsBrighterThanMidnight() {
        #expect(DayCycle.light(atHour: 12).sunIntensity > DayCycle.light(atHour: 0).sunIntensity * 10)
        #expect(DayCycle.light(atHour: 23).lamp > 0.9)
        #expect(DayCycle.light(atHour: 12).lamp == 0)
    }

    @Test func lightIsContinuousAcrossMidnightAndKeyframes() {
        var previous = DayCycle.light(atHour: 0)
        for step in 1...2880 {
            let current = DayCycle.light(atHour: Double(step) / 120)
            #expect(abs(current.sunIntensity - previous.sunIntensity) < 15)
            previous = current
        }
    }

    @Test func rainDimsTheSun() {
        let noon = DayCycle.light(atHour: 12)
        #expect(noon.overcast(1).sunIntensity < noon.sunIntensity * 0.3)
    }
}

@Suite struct ParsingTests {
    let sep = String(PlayerParsing.fieldSeparator)

    @Test func parsesSpotify() throws {
        let raw = ["playing", "Song", "Artist", "Album", "3", "1", "215000", "12,5", "spotify:track:x", "https://i.scdn.co/a"]
            .joined(separator: sep)
        let s = PlayerParsing.snapshot(raw, source: .spotify, at: Date(timeIntervalSince1970: 0))
        let t = try #require(s.track)
        #expect(s.state == .playing)
        #expect(t.duration == 215)
        #expect(s.position == 12.5)
        #expect(t.artworkURL == "https://i.scdn.co/a")
        #expect(s.position(at: Date(timeIntervalSince1970: 10)) == 22.5)
    }

    @Test func pausedPositionDoesNotAdvance() {
        let raw = ["paused", "S", "A", "B", "1", "1", "200.0", "50", "id"].joined(separator: sep)
        let s = PlayerParsing.snapshot(raw, source: .music, at: Date(timeIntervalSince1970: 0))
        #expect(s.position(at: Date(timeIntervalSince1970: 100)) == 50)
    }

    @Test func stoppedOutputHasNoTrack() {
        #expect(PlayerParsing.snapshot("stopped", source: .music).track == nil)
    }

    @Test func libraryRowsAreSortedAndFilteredByArtist() {
        let rs = String(PlayerParsing.recordSeparator)
        let raw = [["2", "1", "200", "Two", "Me"], ["1", "1", "180", "One", "Me"], ["1", "1", "100", "Other", "Them"]]
            .map { $0.joined(separator: sep) }.joined(separator: rs)
        let t = PlayerParsing.libraryTracks(raw, artist: "me")
        #expect(t.map(\.title) == ["One", "Two"])
    }

    @Test func estimatedRecordContainsTheKnownSong() {
        let track = TrackInfo(title: "X", artist: "A", album: "B", number: 5, disc: 1, duration: 300, id: "1")
        let est = PlayerParsing.estimatedTracks(around: track)
        #expect(est.count == 8)
        #expect(PlayerParsing.index(of: track, in: est) == 4)
    }
}

@Suite struct PlateScheduleTests {
    @Test func photoIsDayAtNoonNightAtMidnight() {
        #expect(PlateSchedule.photo(atHour: 12).night == 0)
        #expect(PlateSchedule.photo(atHour: 12).warmth == 0)
        #expect(PlateSchedule.photo(atHour: 2).night == 1)
        #expect(PlateSchedule.photo(atHour: 23.5).night == 1)
    }

    @Test func photoWarmsAtGoldenHourAndFadesAtDusk() {
        #expect(abs(PlateSchedule.photo(atHour: 17.6).warmth - 0.6) < 1e-9)
        #expect(PlateSchedule.photo(atHour: 19).night == 0)
        #expect(abs(PlateSchedule.photo(atHour: 19.3).night - 0.5) < 1e-9)
    }

    @Test func noonIsOnePlate() {
        let b = PlateSchedule.blend(atHour: 12)
        #expect(b.from == "noon" && b.t == 0)
    }

    @Test func nightHoldsUntilFiveThenFadesToDawn() {
        #expect(PlateSchedule.blend(atHour: 2).from == "night")
        #expect(PlateSchedule.blend(atHour: 2).to == "night")
        let b = PlateSchedule.blend(atHour: 5.65)
        #expect(b.from == "night" && b.to == "dawn")
        #expect(abs(b.t - 0.5) < 1e-9)
    }

    @Test func lateEveningFadesDuskIntoNight() {
        let b = PlateSchedule.blend(atHour: 19.9)
        #expect(b.from == "dusk" && b.to == "night" && b.t > 0.5)
        #expect(PlateSchedule.blend(atHour: 23).from == "night")
    }

    @Test func everyTagIsRendered() {
        #expect(Set(PlateSchedule.keys.map(\.tag)) == Set(PlateSchedule.tags))
    }

    @Test func cropKeepsTheCentre() {
        let wide = PlateSchedule.crop(plate: CGSize(width: 1600, height: 1000), aspect: 16.0 / 9)
        #expect(wide.width == 1600 && abs(wide.height - 900) < 1e-9 && abs(wide.minY - 50) < 1e-9)
        let tall = PlateSchedule.crop(plate: CGSize(width: 1600, height: 1000), aspect: 4.0 / 3)
        #expect(tall.height == 1000 && abs(tall.midX - 800) < 1e-9)
    }
}

@Suite struct SunTests {
    @Test func romeInMidOctober() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-10-15T12:00:00Z"))
        let t = try #require(Sun.times(on: date, latitude: 41.9, longitude: 12.5, timeZone: TimeZone(identifier: "Europe/Rome")!))
        #expect(abs(t.rise - 7.35) < 0.1 && abs(t.set - 18.51) < 0.1)
    }

    @Test func sunriseNoonAndSunsetLandOnThePlates() {
        #expect(abs(Sun.plateHour(clock: 7.35, rise: 7.35, noon: 12.9, set: 18.5) - 6.45) < 1e-9)
        #expect(abs(Sun.plateHour(clock: 12.9, rise: 7.35, noon: 12.9, set: 18.5) - 12.4) < 1e-9)
        #expect(abs(Sun.plateHour(clock: 18.5, rise: 7.35, noon: 12.9, set: 18.5) - 19.0) < 1e-9)
        #expect(abs(Sun.plateHour(clock: 22.5, rise: 7.35, noon: 12.9, set: 18.5) - 23.0) < 1e-9)
    }

    @Test func polarNightHasNoSun() {
        let date = ISO8601DateFormatter().date(from: "2026-12-21T12:00:00Z")!
        #expect(Sun.times(on: date, latitude: 78, longitude: 15) == nil)
    }
}
