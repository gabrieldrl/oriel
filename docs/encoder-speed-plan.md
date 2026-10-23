# Encoding speed, chosen by the Mac (2026-10-23)

Gabriel's ask: Prioritize encoding speed should be automatic. The Mac turns it on when its encoder
falls behind, and off again once it no longer needs it.

## What it is

`kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality` on the stream's VideoToolbox
session: less effort per frame, a softer picture. Until now it was a setting, off by default and
set by a device (kind 16) or the Mac's old Streaming tab. Changing the setting restarts the stream.

## The plan

- **A pure judge, `EncoderSpeedJudge`** (`Sources/SillHost/EncoderSpeedJudge.swift`, checked in
  `Tests/checks/encoder-speed`).
  - HEVCEncoder tells it about every captured frame and every frame back encoded, with its
    turnaround (hand-over to output). It answers with a switch.
  - It is one per hardware stream, as `EncoderSlowState` is. A quiet probe, the software encoder
    (always on speed) and a forced setting have none.
- **Behind,** over the last `window` (3 s) of the current session:
  - the capture brought at least half the stream's rate (motion: a still picture loses nothing);
  - fewer than 90% of the captured frames came back (the one-slot mailbox dropped the rest);
  - at least 10 came back;
  - and their median turnaround is at least 90% of a frame's time at the stream's rate, so the
    encoder is what falls behind.

  Behind on quality, the session switches to speed.
- **The switch is the slow state's mechanism, not a restart.**
  - A new session with the other setting is made on a queue of its own.
  - It is taken at the next hand-over with a forced keyframe, and the old one is completed and
    retired.
  - The stream, the capture, the mailbox and the watchdog carry on, so it costs one keyframe.
  - One replacement at a time: the judge acts only while the slow state is not making or judging
    one. Every session change starts both watches' evidence again (`EncoderSlowState.sessionChanged`,
    new). The slow state gets the first look, since its window is 2 s and this one 3 s.
- **Did it help?** The speed session's first window with 10 frames back is its verdict.
  - A median at least 90% of the quality session's is no faster: back to quality, and the stream
    stays there (`gaveUp`).
  - The engine is then slow for another reason (another app on it), and a softer picture buys
    nothing.
- **Back to quality:**
  - Tried after `retryAfter` (60 s) on speed, and only while speed has room: its median at most 60%
    of a frame's time, or too few frames to tell (a still picture, where the swap costs nothing to
    see).
  - When quality falls behind again within `maxRetryAfter` (16 min), speed comes back and the next
    retry waits twice as long, up to 16 min. One that kept up longer than that starts the wait at
    60 s again.
- **Across streams:**
  - A stream started within 60 s of one that ended on speed starts on speed (StreamCoordinator
    keeps the last hardware encoder's `runsFast`). A window switch would otherwise repeat the 3 s of
    falling behind.
  - It skips the verdict (speed helped before) and tries quality after `retryAfter`, as above.
- **The setting:**
  - `prioritizeSpeed` stays on the wire and in HostConfig. On, it now means always: no judge.
  - Off, the default, means the Mac decides.
  - The device's footnote says so.
- **Lines:** one in the log for each switch and for each verdict.
- **A TEST ONLY hook, `SILL_TEST_SLOW_QUALITY=<ms>`:** every frame of a quality hardware session
  waits that long on `encodeQueue` before it goes in, as a busy engine would make it. It exercises
  the glue on a real session: behind, then speed, then the retry, then behind again.

## Results

- `Tests/checks/encoder-speed`: 1,714 checks, and 27 of 27 mutants caught. They cover:
  - the rule at its edges, by hand;
  - streams in virtual time: light, busy then not, no faster, the doubling wait and its reset, a
    still picture, a stream started on speed, the slow state busy, a session that could not be
    made, and 120 fps.
- **The review the mutants made.** Two survived at first. Both pointed at code that did nothing: a
  swap clearing the old frames, and a failed switch resetting "gave up". Waiting a whole window
  after every session change already covers both, so the code went. A bug the check found: when the
  switch back to quality after "no faster" could not be made, the stream stayed on a speed session
  that did not help, for good. It now asks again one window later.
- `Tests/checks/encoder-slowstate`: `sessionChanged`. 1,210 checks, and 31 of 31 mutants caught,
  two of them new. `encoder-mailbox` passes as before.
- **A synthetic host on this Mac's hardware encoder** (`SILL_TEST_LOOPBACK=1 SILL_TEST_NO_ROUTER=1
  SILL_TEST_SLOW_QUALITY=25 SillHost --synthetic` and `sillclient.py <port> 80 desktop`), at
  3024×1898 and 60 fps:
  - **First switch:** quality frames took 42 ms (24 fps out of 60). The switch to speed came at
    3.1 s (keyframe).
  - **On speed:** 7 ms a frame, kept, with 300 frames every 5 s from then on.
  - **Quality again:** tried at 63.1 s, 41 ms a frame and behind (233 and 259 frames in those 5 s
    spans), then speed again at 66.2 s.
  - **Encoding speed on this hardware:** 7 ms a frame against about 17 ms for quality at this size
    (42 less the 25 held).

## Untested

On a device with real load: a busy Mac, a 120 fps stream at Retina size, another app encoding.
Also not measured: how much faster speed actually is on this hardware at each size.
