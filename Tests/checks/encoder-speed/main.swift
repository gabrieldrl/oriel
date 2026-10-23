import Foundation

// Encoder-free check of EncoderSpeedJudge (the real Sources/SillHost/EncoderSpeedJudge.swift,
// compiled beside this file): when a hardware stream's session switches to encoding speed, how that
// session is judged, and when quality is tried again. Part one feeds it events by hand at its edges;
// part two runs streams in virtual time through a stand-in for HEVCEncoder's glue (one frame inside,
// a one-slot mailbox, a new session made `makeDelay` after it is asked for and taken at the next
// hand-over) against an engine whose turnaround is scripted for each setting. Nothing here links
// VideoToolbox.
//
//   Tests/checks/encoder-speed/run.sh [--mutants]
// or by hand, from the repository's root:
//   swiftc -O Sources/SillHost/EncoderSpeedJudge.swift Tests/checks/encoder-speed/main.swift -o .build/speed-check && .build/speed-check

var checks = 0, failures = 0
var scenarioName = ""
func expect(_ ok: Bool, _ what: @autoclosure () -> String) {
    checks += 1
    if !ok { failures += 1; if failures <= 40 { print("  FAIL [\(scenarioName)]: \(what())") } }
}
typealias J = EncoderSpeedJudge
func isToSpeed(_ e: J.Event?) -> Bool { if case .toSpeed = e { return true }; return false }
func isRetry(_ e: J.Event?) -> Bool { if case .retry = e { return true }; return false }

// MARK: - Part one: the edges, by hand

/// A quality judge at `fps` started exactly `window` before `at`, with `captured` frames evenly over
/// the window and `back` frames back at `turnaround`; then one more back at `at` with the same
/// turnaround: what that one says (`mayAct` for it).
func probe(fps: Int = 60, captured: Int = 180, back: Int = 120, turnaround: Double = 0.025, at: Double = 10,
           started: Double? = nil, mayAct: Bool = true, startFast: Bool = false) -> J.Event? {
    var j = J(fps: fps, now: started ?? at - J.window, startFast: startFast)
    var ev: [(Double, Int)] = []
    for i in 0..<captured { ev.append((at - J.window + 0.001 + Double(i) * ((J.window - 0.002) / Double(max(captured, 1))), 0)) }
    for i in 0..<back { ev.append((at - J.window + 0.002 + Double(i) * ((J.window - 0.004) / Double(max(back, 1))), 1)) }
    ev.sort { $0.0 < $1.0 }
    for (t, k) in ev {
        if k == 0 { j.captured(at: t) } else { expect(j.returned(turnaround: turnaround, at: t, mayAct: true) == nil, "an event before the probe's own frame, at \(t)") }
    }
    return j.returned(turnaround: turnaround, at: at, mayAct: mayAct)
}

scenarioName = "edges"
expect(isToSpeed(probe()), "60 fps captured, 40 back, 25 ms each: no switch to speed")
// Back: 120 + the probe's own over 180 captured is 67%. The fraction kept up is 90%.
expect(!isToSpeed(probe(back: 161)), "162 back of 180 (90%): a switch (at the edge it keeps up)")
expect(isToSpeed(probe(back: 160)), "161 back of 180 (89.4%): no switch")
// Motion: half of 60 fps over 3 s is 90 captured.
expect(!isToSpeed(probe(captured: 89, back: 40)), "89 captured in 3 s (under half the rate): a switch")
expect(isToSpeed(probe(captured: 90, back: 40)), "90 captured in 3 s (half the rate): no switch")
// The encoder is what falls behind: a median of at least 90% of 16.7 ms (15 ms).
expect(!isToSpeed(probe(turnaround: 0.0149)), "a median of 14.9 ms: a switch (the encoder has room)")
expect(isToSpeed(probe(turnaround: 0.0151)), "a median of 15.1 ms: no switch")
expect(!isToSpeed(probe(captured: 20, back: 8)), "9 back in the window: a switch")
expect(isToSpeed(probe(captured: 100, back: 9, turnaround: 0.03)), "10 back in the window: no switch")
expect(probe(started: 7.01) == nil, "a session 2.99 s old: an event")
expect(isToSpeed(probe(started: 7)), "a session 3 s old: no switch")
expect(probe(mayAct: false) == nil, "mayAct false (the slow state busy): an event")
expect(isToSpeed(probe(fps: 120, captured: 360, back: 200, turnaround: 0.0076)), "120 fps, 7.6 ms (over 90% of 8.3): no switch")
expect(!isToSpeed(probe(fps: 120, captured: 360, back: 200, turnaround: 0.0074)), "120 fps, 7.4 ms: a switch")
expect(probe(startFast: true) == nil, "a stream started on speed: a switch before its retry")

// The lines.
expect(J.describe(.toSpeed(J.Window(turnaround: 0.0244, inputFPS: 58, outputFPS: 41)), fps: 60)
       == "frames took 24 ms each, over the 17 ms a frame has at 60 fps (41 fps out of 58 captured); switching to encoding speed.",
       "the switch's line: \(J.describe(.toSpeed(J.Window(turnaround: 0.0244, inputFPS: 58, outputFPS: 41)), fps: 60))")
expect(J.describe(.kept(speed: 0.012, quality: 0.024), fps: 60) == "encoding speed takes 12 ms a frame against quality’s 24 ms; keeping it.", "the kept line")
expect(J.describe(.noFaster(speed: 0.023, quality: 0.024), fps: 60)
       == "encoding speed takes 23 ms a frame against quality’s 24 ms, no faster; back to quality for this stream.", "the no-faster line")
expect(J.describe(.retry(speed: 0.008, after: 60), fps: 60) == "trying quality again after 60 s on encoding speed (8 ms a frame).", "the retry line")
expect(J.describe(.retry(speed: nil, after: 120), fps: 60) == "trying quality again after 120 s on encoding speed (the picture still).", "the still retry line")

// MARK: - Part two: streams in virtual time

/// One stream: captures at `fps` while `motion(t)` (else one every `stillEvery` s, a lone repaint),
/// one frame inside the engine at a time, a one-slot mailbox, and each switch the judge asks for made
/// `makeDelay` later and taken at the next hand-over. `engine(t, speed)` is a frame's turnaround.
struct Run {
    var events: [(t: Double, e: J.Event)] = []
    var swaps: [(t: Double, speed: Bool)] = []
    var judge: J
    /// The share of captured frames that came back, per setting, between `from` and the end.
    var captured = 0, back = 0
}

let makeDelay = 0.03
func simulate(fps: Int = 60, seconds: Double, startFast: Bool = false, stillEvery: Double = 1,
              failMaking: (Double) -> Bool = { _ in false }, mayAct: (Double) -> Bool = { _ in true },
              motion: (Double) -> Bool = { _ in true }, engine: (Double, Bool) -> Double, countFrom: Double = 0) -> Run {
    var run = Run(judge: J(fps: fps, now: 0, startFast: startFast))
    var speed = startFast
    var inside: (handed: Double, back: Double)?
    var waiting = false
    var pending: (speed: Bool, readyAt: Double)?
    var nextCapture = 0.0
    let frame = 1 / Double(fps)
    func handOver(_ t: Double) {
        if let p = pending, p.readyAt <= t {
            speed = p.speed
            pending = nil
            run.judge.swapped(at: t)
            run.swaps.append((t, speed))
        }
        inside = (t, t + engine(t, speed))
    }
    while true {
        let ret = inside?.back ?? .infinity
        let t = min(nextCapture, ret)
        if t > seconds { break }
        if ret <= nextCapture, let i = inside {
            inside = nil
            if t >= countFrom { run.back += 1 }
            if let e = run.judge.returned(turnaround: t - i.handed, at: t, mayAct: mayAct(t)) {
                run.events.append((t, e))
                switch e {
                case .toSpeed: pending = (true, t + makeDelay)
                case .noFaster, .retry: pending = (false, t + makeDelay)
                case .kept: break
                }
                if pending != nil, failMaking(t) {
                    pending = nil
                    run.judge.replacementFailed(at: t + makeDelay)
                }
            }
            if waiting { waiting = false; handOver(t) }
        } else {
            run.judge.captured(at: t)
            if t >= countFrom { run.captured += 1 }
            if inside == nil { handOver(t) } else { waiting = true }
            nextCapture = t + (motion(t) ? frame : stillEvery)
        }
    }
    return run
}
func kinds(_ r: Run) -> String {
    r.events.map { e -> String in
        switch e.e {
        case .toSpeed: return "speed"
        case .kept: return "kept"
        case .noFaster: return "noFaster"
        case .retry: return "retry"
        }
    }.joined(separator: " ")
}

// A light stream: quality keeps up (10 ms at 60 fps). Nothing happens.
scenarioName = "light"
var r = simulate(seconds: 300, engine: { _, _ in 0.010 })
expect(r.events.isEmpty, "events: \(kinds(r))")

// The slow state's territory (29 ms against 9 at its start) is the slow state's: a session at 14 ms,
// under 90% of a frame's time, is never switched, whatever else the stream does.
scenarioName = "under the budget"
r = simulate(seconds: 300, engine: { _, _ in 0.0145 })
expect(r.events.isEmpty, "events: \(kinds(r))")

// Busy from 5 s to 200 s: quality 24 ms, speed 12 ms; then quality 10 ms, speed 6 ms. Speed within
// about 3 s, kept; no retry while speed has no room (12 ms is over 60% of 16.7); once the load ends,
// a retry at the first window with room, 60 s or more after the switch; quality keeps up after it.
scenarioName = "busy, then not"
r = simulate(seconds: 400, engine: { t, s in t >= 5 && t < 200 ? (s ? 0.012 : 0.024) : (s ? 0.006 : 0.010) })
expect(kinds(r) == "speed kept retry", "events: \(kinds(r))")
if r.events.count == 3 {
    // The window is mostly the load's after about 1.8 s of it: the median is then the load's.
    expect(r.events[0].t >= 6.5 && r.events[0].t < 8.2, "the switch at \(r.events[0].t) s, not within 3 s of the load")
    expect(r.events[1].t > r.events[0].t + 3 && r.events[1].t < r.events[0].t + 3.2, "the verdict at \(r.events[1].t) s, not one window after the swap")
    expect(r.events[2].t >= 201 && r.events[2].t < 203.2, "the retry at \(r.events[2].t) s, not once most of a window has room after the load")
}
expect(r.swaps.map(\.speed) == [true, false], "swaps: \(r.swaps.map(\.speed))")
expect(!r.judge.speed && !r.judge.gaveUp, "the stream ends on speed, or gave up")

// The engine is slow for another reason: speed is no faster (23 ms against 24). Back to quality,
// and the stream stays there however far behind it is.
scenarioName = "no faster"
r = simulate(seconds: 300, engine: { _, s in s ? 0.023 : 0.024 })
expect(kinds(r) == "speed noFaster", "events: \(kinds(r))")
expect(r.swaps.map(\.speed) == [true, false] && r.judge.gaveUp && !r.judge.speed, "swaps \(r.swaps.map(\.speed)), gave up \(r.judge.gaveUp)")
// …speed at 90% of quality is no faster too; at 89% it helps.
r = simulate(seconds: 30, engine: { _, s in s ? 0.0216 : 0.024 })
expect(kinds(r) == "speed noFaster", "90% of quality: events \(kinds(r))")
r = simulate(seconds: 30, engine: { _, s in s ? 0.0213 : 0.024 })
expect(kinds(r) == "speed kept", "89% of quality: events \(kinds(r))")

// Speed with room but quality behind for good (24 against 8 ms): retries at 60 s, then 120, 240,
// 480, 960, 960, 960: each try behind again within its window, so the wait doubles up to 16 min.
scenarioName = "backoff"
r = simulate(seconds: 4000, engine: { _, s in s ? 0.008 : 0.024 })
let retries = r.events.compactMap { e -> Double? in if case .retry(_, let after) = e.e { return after }; return nil }
expect(retries == [60, 120, 240, 480, 960, 960, 960], "the waits: \(retries)")
expect(kinds(r).hasPrefix("speed kept retry speed retry speed"), "events: \(kinds(r))")
expect(r.judge.speed, "the stream ends on quality")
// Between retries, on speed: only the verdict once, never again.
expect(r.events.filter { if case .kept = $0.e { return true }; return false }.count == 1, "verdicts: \(kinds(r))")

// A quality try that keeps up longer than 16 min starts the wait at 60 s again when it falls behind.
scenarioName = "backoff reset"
r = simulate(seconds: 2400, engine: { t, s in
    if t < 100 { return s ? 0.008 : 0.024 }      // speed at about 3 s, a retry at about 63 s, behind: speed (wait 120)
    if t < 300 { return s ? 0.008 : 0.010 }      // the retry at about 186 s keeps up
    if t >= 1300 { return s ? 0.008 : 0.024 }    // 1100 s later, behind again
    return s ? 0.008 : 0.010
})
let waits = r.events.compactMap { e -> Double? in if case .retry(_, let after) = e.e { return after }; return nil }
expect(waits.count >= 3 && waits[0] == 60 && waits[1] == 120 && waits[2] == 60, "the waits: \(waits)")

// A still picture on speed: one repaint a second, too few frames back to tell. The retry comes at
// the first frame back 60 s after the switch.
scenarioName = "still"
r = simulate(seconds: 200, motion: { t in t < 20 }, engine: { t, s in t < 20 ? (s ? 0.012 : 0.024) : 0.004 })
expect(kinds(r) == "speed kept retry", "events: \(kinds(r))")
if r.events.count == 3, case .retry(let speed, _) = r.events[2].e {
    expect(speed == nil, "the still retry's median: \(String(describing: speed))")
    expect(r.events[2].t - r.events[0].t >= 60 && r.events[2].t - r.events[0].t < 61.1, "the retry \(r.events[2].t - r.events[0].t) s after the switch")
}
// …and a still picture on quality never switches: the capture brought too little.
r = simulate(seconds: 200, motion: { _ in false }, engine: { _, _ in 0.030 })
expect(r.events.isEmpty, "a still picture: events \(kinds(r))")

// A stream that starts on speed (the last one ended there): no verdict, a retry after 60 s.
scenarioName = "start fast"
r = simulate(seconds: 100, startFast: true, engine: { _, s in s ? 0.006 : 0.010 })
expect(kinds(r) == "retry", "events: \(kinds(r))")
if let first = r.events.first { expect(first.t >= 60 && first.t < 60.2, "the retry at \(first.t) s") }
expect(!r.judge.speed, "the stream ends on speed")
// …and behind again on quality: back to speed with no verdict (speed helps in this stream).
r = simulate(seconds: 100, startFast: true, engine: { _, s in s ? 0.008 : 0.024 })
expect(kinds(r) == "retry speed", "behind after the retry: events \(kinds(r))")

// The slow state busy (mayAct false) holds every switch back; once it is not, the switch comes.
scenarioName = "slow state busy"
r = simulate(seconds: 30, mayAct: { t in t > 12 }, engine: { _, s in s ? 0.012 : 0.024 })
expect(kinds(r) == "speed kept" && (r.events.first?.t ?? 0) > 12 && (r.events.first?.t ?? 99) < 12.1,
       "events: \(kinds(r)) at \(r.events.map(\.t))")

// A speed session that could not be made: the stream goes on with quality, judged again from then,
// so the next switch is one window later.
scenarioName = "making fails"
var failed = 0
r = simulate(seconds: 30, failMaking: { _ in failed += 1; return failed == 1 }, engine: { _, s in s ? 0.012 : 0.024 })
expect(kinds(r) == "speed speed kept", "events: \(kinds(r))")
if r.events.count >= 2 { expect(r.events[1].t - r.events[0].t >= 3 && r.events[1].t - r.events[0].t < 3.2, "the second try \(r.events[1].t - r.events[0].t) s after the first") }
expect(r.swaps.map(\.speed) == [true], "swaps: \(r.swaps.map(\.speed))")
// …a back-to-quality that could not be made after a no-faster verdict: judged again one window
// later, no faster again, and asked again (never left on a speed session that does not help).
failed = 0
r = simulate(seconds: 200, failMaking: { _ in failed += 1; return failed == 2 }, engine: { _, s in s ? 0.023 : 0.024 })
expect(kinds(r) == "speed noFaster noFaster", "no faster, unmade: events \(kinds(r))")
if r.events.count == 3 { expect(r.events[2].t - r.events[1].t >= 3 && r.events[2].t - r.events[1].t < 3.2, "asked again \(r.events[2].t - r.events[1].t) s later") }
expect(r.judge.gaveUp && r.swaps.map(\.speed) == [true, false], "gave up \(r.judge.gaveUp), swaps \(r.swaps.map(\.speed))")

// 120 fps at Retina size. Quality at 9 ms keeps 111 of 120 frames (92%): it keeps up, no switch.
scenarioName = "120 fps"
r = simulate(fps: 120, seconds: 60, engine: { _, _ in 0.009 })
expect(r.events.isEmpty, "9 ms: events \(kinds(r))")
// …at 10 ms (100 of 120) it is behind; speed at 9.5 ms is no faster, so back to quality, for good.
r = simulate(fps: 120, seconds: 60, engine: { _, s in s ? 0.0095 : 0.010 })
expect(kinds(r) == "speed noFaster", "events: \(kinds(r))")
// …speed at 6 ms helps, and keeps every frame.
r = simulate(fps: 120, seconds: 60, engine: { _, s in s ? 0.006 : 0.010 }, countFrom: 10)
expect(kinds(r) == "speed kept", "speed at 6 ms: events \(kinds(r))")
expect(r.back >= r.captured - 1, "speed at 6 ms: \(r.back) back of \(r.captured) captured after 10 s (the last may still be inside)")

print(failures == 0 ? "\(checks) checks, 0 failed" : "\(checks) checks, \(failures) failed")
exit(failures == 0 ? 0 : 1)
