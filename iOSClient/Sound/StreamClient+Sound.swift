import Foundation
import StreamProtocol

// The Mac's sound, this device's side (kinds 47 and 48; docs/mac-sound-plan.md). Every control is
// here: the Mac has none, and does what its devices ask.
//
// - The subscription: an empty kind 48 at the first window list that says `sound`, again on a move's
//   new connection. The Mac then sends its sound (SoundPlayer plays it) and its volume and mute.
// - The pill's slider sets the Mac's volume, its circle the Mac's mute (silent everywhere). The
//   volume at nothing is muted: the slider all the way down mutes, up from there unmutes, and the
//   circle unmutes at the last level heard. Each
//   change carries a token; a report answering an older one than this device's last is the Mac's
//   state from before that change, so the pill keeps what the person set until it is answered.
// - The slider sends at most 20 changes a second, the newest at the end of a drag.
//
// Everything here is main thread.
extension StreamClient {
    /// The Mac sends its sound (its window list's `sound`).
    var hostSendsSound: Bool { (hostSound ?? 0) >= SoundControl.generation }

    /// A volume below this is nothing: muted.
    static let soundFloor = 0.005

    /// What the pill shows as muted: the Mac muted, or its volume at nothing (the Mac's own keys).
    var soundSilent: Bool { soundMuted || soundVolume < Self.soundFloor }

    /// Each window list's `sound`: the first that says so subscribes.
    func hostSoundChanged(_ value: Int?) {
        if hostSound != value { hostSound = value }
        guard hostSendsSound, !soundSubscribed else { return }
        soundSubscribed = true
        send(.soundControl, payload: Wire.encode(SoundControl()))
        #if DEBUG
        print("sound: subscribed")
        #endif
    }

    /// A move handed the session to its new connection: the Mac keeps subscriptions per connection.
    func soundMoved() {
        soundSubscribed = false
        hostSoundChanged(hostSound)
    }

    /// The session ended: nothing of it is kept.
    func resetSound() {
        hostSound = nil
        soundSubscribed = false
        soundKnown = false
        soundProblem = nil
        soundSendWork?.cancel()
        soundSendWork = nil
        soundPlayer.reset()
    }

    /// A kind 48 from the Mac.
    func receiveSoundControl(_ payload: Data) {
        guard let report = Wire.decode(SoundControl.self, from: payload) else { return }
        soundKnown = true
        if soundProblem != report.problem { soundProblem = report.problem }
        // The Mac's state from before this device's latest change: the pill keeps the change.
        if soundToken > 0, (report.answering ?? 0) < soundToken { return }
        if let volume = report.volume, volume.isFinite, abs(volume - soundVolume) > 0.0005 {
            soundVolume = min(max(volume, 0), 1)
            if soundVolume >= Self.soundFloor { soundLastAudible = soundVolume }
        }
        if let muted = report.muted, muted != soundMuted { soundMuted = muted }
        applySound()
    }

    /// The slider: shown and played at once, sent at most 20 times a second. At nothing it mutes, and
    /// above it a muted Mac unmutes: then the level and the mute go at once, in one message, so the
    /// Mac's answer never carries a level from before.
    func setSoundVolume(_ volume: Double) {
        let silent = !(volume >= Self.soundFloor)
        soundVolume = silent ? 0 : min(volume, 1)
        if !silent { soundLastAudible = soundVolume }
        if silent != soundMuted {
            soundMuted = silent
            soundSendWork?.cancel()
            soundSendWork = nil
            applySound()
            sendSound(SoundControl(volume: (soundVolume * 1000).rounded() / 1000, muted: silent))
            return
        }
        applySound()
        guard soundSendWork == nil else { return }
        let wait = max(0, soundSentAt + 0.05 - ProcessInfo.processInfo.systemUptime)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.soundSendWork = nil
            self.sendSound(SoundControl(volume: (self.soundVolume * 1000).rounded() / 1000))
        }
        soundSendWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    /// The circle: silent unmutes, at the last level heard when the volume is at nothing; else mutes.
    func toggleSoundMute() {
        if !soundSilent { setSoundMuted(true) }
        else if soundVolume < Self.soundFloor { setSoundVolume(max(soundLastAudible, 0.1)) }
        else { setSoundMuted(false) }
    }

    /// Muted is silent here and on the Mac.
    func setSoundMuted(_ muted: Bool) {
        soundMuted = muted
        applySound()
        sendSound(SoundControl(muted: muted))
    }

    private func sendSound(_ change: SoundControl) {
        guard hostSendsSound else { return }
        var change = change
        soundToken += 1
        change.token = soundToken
        soundSentAt = ProcessInfo.processInfo.systemUptime
        send(.soundControl, payload: Wire.encode(change))
    }

    /// The player follows what the pill shows.
    private func applySound() {
        soundPlayer.setVolume(soundVolume)
        soundPlayer.setAllowed(!soundMuted)
        if soundMuted { soundPlayer.reset() }
    }
}
