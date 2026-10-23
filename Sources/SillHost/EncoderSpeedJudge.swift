import Foundation

/// Whether a hardware stream's session should favour encoding speed over quality
/// (`kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality`), decided from the frames
/// themselves (docs/encoder-speed-plan.md). Pure (Foundation only): HEVCEncoder keeps it under its
/// lock beside `EncoderSlowState`, tells it about every frame the capture delivers, every frame that
/// comes back encoded (with its turnaround: hand-over to output) and every new session, and makes the
/// session it asks for. Checked on its own with swiftc against scripted streams in virtual time
/// (`Tests/checks/encoder-speed`).
///
/// Behind: over the current session's last `window`, the capture brought at least `minInputFraction`
/// of the stream's rate (motion), fewer than `keepUpFraction` of those frames came back (the one-slot
/// mailbox dropped the rest), at least `minReturns` did, and their median turnaround is at least
/// `budgetFraction` of a frame's time at the stream's rate (the encoder is what falls behind). A
/// quality session behind is replaced by a speed one (`Event.toSpeed`).
///
/// A speed session's first full window is its verdict, unless speed is known to help (it helped
/// before in this stream, or the stream started on speed): no faster than `noFasterFraction` of the
/// quality session's median, and the stream goes back to quality and stays there (`gaveUp`): the
/// engine is slow for another reason, and a softer picture buys nothing.
///
/// Quality is tried again `retry` after speed took over, while speed has room (its median at most
/// `headroomFraction` of a frame's time, or too few frames back to tell). A quality session behind
/// again within `maxRetryAfter` of taking over doubles `retry`, up to `maxRetryAfter`; one that kept
/// up for longer starts it at `retryAfter` again.
struct EncoderSpeedJudge {
    static let window: CFTimeInterval = 3
    static let minInputFraction = 0.5
    static let keepUpFraction = 0.9
    static let minReturns = 10
    static let budgetFraction = 0.9
    static let noFasterFraction = 0.9
    static let headroomFraction = 0.6
    static let retryAfter: CFTimeInterval = 60
    static let maxRetryAfter: CFTimeInterval = 960

    /// What a window showed: the median turnaround, in seconds, and frames captured and back a second.
    struct Window: Equatable {
        let turnaround: CFTimeInterval
        let inputFPS: Double
        let outputFPS: Double
    }

    enum Event: Equatable {
        /// Make a speed session: the quality one fell behind.
        case toSpeed(Window)
        /// The speed session's verdict: as fast as this, so kept.
        case kept(speed: CFTimeInterval, quality: CFTimeInterval)
        /// Make a quality session: speed was no faster (the stream stays on quality from now on).
        case noFaster(speed: CFTimeInterval, quality: CFTimeInterval)
        /// Make a quality session: speed has had `retry` and room (its median, nil with too few frames).
        case retry(speed: CFTimeInterval?, after: CFTimeInterval)
    }

    /// The stream's frame rate: a frame's time is its inverse.
    let fps: Int
    /// The current session favours speed.
    private(set) var speed: Bool
    /// A session was asked for and has not taken over yet (or could not be made: `replacementFailed`).
    private(set) var pending: Bool?
    /// Speed was no faster: quality for the rest of the stream.
    private(set) var gaveUp = false
    /// Speed is known to help in this stream: no verdict to wait for.
    private var speedHelps: Bool
    /// The quality session's median when it fell behind, for the speed session's verdict; nil once
    /// judged (or never needed).
    private var qualityMedian: CFTimeInterval?
    /// When the current session took over: the evidence starts here.
    private var since: CFTimeInterval
    /// The wait before quality is tried again, and whether the current quality session is such a try.
    private(set) var retry = retryAfter
    private var retrying = false
    private var captures: [CFTimeInterval] = []
    private var returns: [(at: CFTimeInterval, turnaround: CFTimeInterval)] = []

    /// `startFast`: the stream starts on speed, which helped in the stream before it.
    init(fps: Int, now: CFTimeInterval, startFast: Bool = false) {
        self.fps = fps
        speed = startFast
        speedHelps = startFast
        since = now
    }

    private var budget: CFTimeInterval { 1 / Double(max(fps, 1)) }

    /// The capture delivered a frame (a re-encode of the last frame is not one).
    mutating func captured(at now: CFTimeInterval) {
        captures.append(now)
        dropOld(now)
    }

    /// A frame came back encoded, `turnaround` seconds after it was handed over. `mayAct`: no other
    /// session is being made or judged (the slow state's), so a switch can be asked for now; the
    /// frame is counted either way.
    mutating func returned(turnaround: CFTimeInterval, at now: CFTimeInterval, mayAct: Bool) -> Event? {
        returns.append((now, turnaround))
        dropOld(now)
        guard mayAct, pending == nil, now - since >= Self.window else { return nil }
        let enough = returns.count >= Self.minReturns
        let median = enough ? Self.median(returns.map(\.turnaround)) : nil
        if !speed {
            guard !gaveUp, let median, behind(median: median) else { return nil }
            let lasted = now - since
            retry = retrying && lasted < Self.maxRetryAfter ? min(retry * 2, Self.maxRetryAfter) : Self.retryAfter
            retrying = false
            qualityMedian = speedHelps ? nil : median
            pending = true
            return .toSpeed(Window(turnaround: median, inputFPS: Double(captures.count) / Self.window,
                                   outputFPS: Double(returns.count) / Self.window))
        }
        if let quality = qualityMedian {
            guard let median else { return nil }   // the picture went still: judged on the next window
            if median >= Self.noFasterFraction * quality {
                gaveUp = true
                pending = false
                return .noFaster(speed: median, quality: quality)
            }
            qualityMedian = nil
            speedHelps = true
            return .kept(speed: median, quality: quality)
        }
        guard now - since >= retry, median.map({ $0 <= Self.headroomFraction * budget }) ?? true else { return nil }
        retrying = true
        pending = false
        return .retry(speed: median, after: retry)
    }

    /// A new session took over: the one asked for (`pending`), or another (the slow state's), with the
    /// same setting. Its evidence starts now: nothing is decided until a whole `window` of it, by
    /// when every frame of the old session is out of the window.
    mutating func swapped(at now: CFTimeInterval) {
        if let next = pending { speed = next }
        pending = nil
        since = now
    }

    /// The session asked for could not be made: the stream goes on with the one it has, judged again
    /// a whole `window` from now. A speed session no faster asks again then; a retry waits another
    /// `retry`.
    mutating func replacementFailed(at now: CFTimeInterval) {
        guard pending != nil else { return }
        pending = nil
        since = now
    }

    private func behind(median: CFTimeInterval) -> Bool {
        Double(captures.count) >= Self.minInputFraction * Double(fps) * Self.window
            && Double(returns.count) < Self.keepUpFraction * Double(captures.count)
            && median >= Self.budgetFraction * budget
    }

    private mutating func dropOld(_ now: CFTimeInterval) {
        let edge = now - Self.window
        if let k = captures.firstIndex(where: { $0 > edge }) { captures.removeFirst(k) } else { captures.removeAll(keepingCapacity: true) }
        if let k = returns.firstIndex(where: { $0.at > edge }) { returns.removeFirst(k) } else { returns.removeAll(keepingCapacity: true) }
    }

    /// The log line for an event, after "Encoder (hardware HEVC 3024×1964): ".
    static func describe(_ event: Event, fps: Int) -> String {
        func ms(_ t: CFTimeInterval) -> String { "\(Int((t * 1000).rounded())) ms" }
        switch event {
        case .toSpeed(let w):
            return "frames took \(ms(w.turnaround)) each, over the \(ms(1 / Double(max(fps, 1)))) a frame has at \(fps) fps (\(Int(w.outputFPS.rounded())) fps out of \(Int(w.inputFPS.rounded())) captured); switching to encoding speed."
        case .kept(let speed, let quality):
            return "encoding speed takes \(ms(speed)) a frame against quality’s \(ms(quality)); keeping it."
        case .noFaster(let speed, let quality):
            return "encoding speed takes \(ms(speed)) a frame against quality’s \(ms(quality)), no faster; back to quality for this stream."
        case .retry(let speed, let after):
            let how = speed.map { "\(ms($0)) a frame" } ?? "the picture still"
            return "trying quality again after \(Int(after.rounded())) s on encoding speed (\(how))."
        }
    }

    static func median(_ values: [CFTimeInterval]) -> CFTimeInterval {
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
