# The Mac's sound on the iPad

Gabriel, 2026-10-22: the Mac's audio plays on the iPad, never on the Mac while Sill is connected. A
pill next to Touch/Trackpad shows it; a tap morphs it into a volume slider. Muted means silent on both.
Unmuted, the slider is the Mac's volume, which only the iPad plays. Everything is controlled from the
iPad: the Mac has no audio setting, menu item or switch.

Built fresh. Upstream's beta (`upstream/wip/audio`, Saffsanity/sill#94) was read, not merged. What it
taught, and what is done differently here:

| | Upstream's beta | This plan |
|---|---|---|
| Capture | A second ScreenCaptureKit stream with `capturesAudio`, filtered to the streamed app | A Core Audio process tap of every process but Sill (`CATapDescription`, macOS 14.2) |
| The Mac's speakers | Keep playing (ScreenCaptureKit cannot mute): an echo 60–155 ms late, so it is off by default | Silent while Sill reads the tap (`CATapMutedWhenTapped`) |
| Permission | Screen Recording only | "System Audio Recording Only" as well, asked once |
| Who turns it on | The Mac's Send Audio (Beta), off by default | Nobody: always on while a device is connected; the iPad mutes |
| Volume | None | The iPad's slider sets the Mac's output volume; the iPad plays at it |
| Messages | One per 10 ms packet, silence included | Two packets a message (20 ms), none during silence |
| Encoder input | A new `[Float]` and buffer list per capture buffer, `removeFirst` on a FIFO | One ring buffer, nothing allocated per buffer |
| Playback | `AVAudioPlayerNode.scheduleBuffer` per packet, an 868-line timing model | An `AVAudioSourceNode` pulling from a ring, a jitter target and a drift trim |
| Code | About 10,000 lines | Aim: under 2,000 |

Kept from it: AAC-ELD at 48 kHz stereo, 480-frame (10 ms) packets, 128 kbps through AudioToolbox's
`AudioConverter` (its encoder and decoder are a good model: priming, the magic cookie, the input
procs); the session's `.playback` with `.mixWithOthers`; the message header's time stamp on the
host's clock.

## What the person sees

- **The pill**, in the quick controls between Touch/Trackpad and the clipboard: a 52 pt circle with
  a speaker and, around it, an arc that fills with the volume. Muted: red, a slashed speaker, the red
  tint of Disconnect.
- **A tap** morphs it (as Quality's picker opens): the circle stays, now the mute toggle, and a
  capsule slides out to its right with a small speaker at one end and a loud one at the other, white
  filling to the volume. Drag anywhere on it to set the volume. A tap on the circle mutes or unmutes;
  a tap anywhere else, or 4 s without a touch, folds it back.
- **Dimmed** when the Mac has no sound to give: a Mac without this feature, or System Audio
  Recording not allowed on the Mac (then its accessibility hint says so).

## The rules

1. While at least one device is connected and not muted, the Mac reads its tap: every process's
   sound but Sill's goes to the devices and not to the Mac's speakers.
2. Muted (from any device): the Mac's output is muted (its own mute, as the volume keys' mute), the
   tap is stopped and nothing is sent; nothing plays anywhere.
3. Unmuted: the Mac's output is unmuted, the tap reads again.
4. The slider sets the Mac's output volume (the default output device's virtual main volume). The
   tap hears processes before the device's volume, so the iPad scales what it plays by that volume.
   The Mac reports its volume and mute to every device, also when changed on the Mac (its volume keys,
   Control Centre), so every slider follows.
5. The last device leaving destroys the tap: the Mac plays again, at the volume and mute last set.
6. A Mac whose output has no volume control (an HDMI display, some USB interfaces) keeps a volume of
   its own for Sill, applied the same way, and reports it.
7. One tap and one encoder serve every device; mute and volume are the Mac's, so every device shows
   the same.

## The wire (additive; kinds above every number upstream's open work claims)

- `WindowList.sound: Int?`: 1, this host sends its sound. Nil from every host before.
- **Kind 47 `sound`**, host → device, to a device that sent kind 48: a first byte for the type.
  - Type 1, JSON `SoundFormat {codec, sampleRate, channels, framesPerPacket, primingFrames, cookie, epoch}`,
    before the first packets of each epoch (a new tap or encoder).
  - Type 2, packets: `epoch UInt16 · seq UInt32 · flags UInt8 · count UInt8 · count × (length UInt16 · bytes)`;
    flags bit 0 a segment's start (after silence or a gap). The header's time stamp is the first
    sample's, on the host's clock.
- **Kind 48 `soundControl`**, both ways, JSON `SoundControl {volume, muted, problem, token, answering}`
  (Sound.swift):
  - device → host: any kind 48 subscribes; `volume` (0…1) and `muted` set the Mac's; `{}` only
    subscribes; `token` strictly increasing per connection. The device sends the slider at most 20
    times a second, the newest at the end of a drag.
  - host → device: the Mac's volume and mute after each change (its own keys included) and on
    subscribing, `answering` the newest token it has read from that device (a device ignores the
    volume and mute of a report answering an older one than its last: the Mac's state from before
    that change); `problem` a reason it cannot capture ("failed": macOS refused the tap, a refused
    permission among them; "unsupported": before macOS 14.2) and nothing is sent.

## The Mac (`SillHostCore`, `Sources/SillHost/Sound/`)

- `SystemAudioTap`: the tap (`initStereoGlobalTapButExcludeProcesses:` with Sill's own process
  object, `muteBehavior = .mutedWhenTapped`, private), a private aggregate device holding it
  (`kAudioAggregateDeviceTapListKey`, `tapautostart`), an IOProc that copies each buffer into a
  ring; created when the first unmuted subscriber comes, destroyed with the last or on mute.
  `CATapMutedWhenTapped` rather than `CATapMuted`, so a Sill that stops reading (hung, killed) never
  leaves the Mac silent.
- `MacVolume`: the default output device's volume and mute, set and listened to
  (`kAudioHardwareServiceDeviceProperty_VirtualMainVolume`, `kAudioDevicePropertyMute`, the default
  device changing).
- `SoundPipeline` (queue `sill.sound`): the tap's frames to `SoundEncoder` (AAC-ELD through
  AudioConverter, 128 kbps) behind `SoundGate`, pure (`Tests/checks/sound`): a packet of 480 frames
  all below −90 dBFS after a hangover of 20 is silence, not encoded, and the next sound starts a
  segment; `SoundBatch` puts two packets in a message, and what waits is sent before a segment's
  first packet.
- `HostSound` (main actor): the subscribers, the tap while one listens and the Mac is not muted, the
  devices' volume and mute, the reports; one line per subscription, mute and capture change.
- `StreamServer`: kind 47 to subscribers, two packets a message, outside the video's in-flight count;
  dropped first when a remote client's queue is over its budget.
- Synthetic hosts never tap the Mac: always a test tone (`TestTone`) and a volume and mute of their own.
  The tap would silence the Mac's speakers mid-test.
- Info.plist: `NSAudioCaptureUsageDescription`.

## The iPad (`iOSClient`)

- `SoundPlayer`: the decoder (AudioToolbox), `PlayRing` of decoded frames, an `AVAudioSourceNode`
  that reads it at the volume (gain v³, ramped across each render); a target of 40 ms at home and
  120 ms away, raised 10 ms at each underrun past the first half second, 200 ms at most; above the
  target by 60 ms a frame dropped each render, by 250 ms a skip to it; the session `.playback`,
  `.mixWithOthers`, a 5 ms IO buffer; the engine stopped after 20 s without packets, in the
  background, on interruption and when muted.
- `StreamClient+Sound` (`iOSClient/Sound/`, with SoundPlayer): subscribing at the first window list
  that says `sound` and on a move's new connection, sending the slider and the mute with their
  tokens, the Mac's reported state. The volume at nothing is muted: the slider all the way down
  mutes, up from there unmutes, the level and the mute in one message so the Mac's answer never
  carries the level from before; the circle unmutes a volume at nothing at the last level heard.
- `MacSoundControl` (`iOSClient/Desktop/QuickControls/`): the pill between Touch/Trackpad and the
  clipboard; a tap opens it into the slider, a tap on the open circle mutes, it folds after 3 s
  untouched or at a touch anywhere else (`QuickPillFocus`). DEBUG
  `-SillSoundOpen 1` keeps it open; `-SillSettingsScript '<t> volume V; <t> mute on|off'` drives it
  in a live session to a test host.

## Open questions (default taken)

1. The Mac's mute and volume after the last device leaves: left as the iPad last set them (it is the
   Mac's volume). Alternative: put back what it was before the first device came.
2. Background: silent while Sill is not in front (no background audio mode), as the picture stops.
3. AirPods and other Bluetooth outputs add 150–250 ms; the picture is not delayed to match.
4. The sound is about 40–60 ms behind the picture at home; no lip-sync delay is added to the picture.
5. Two devices: one mute and one volume for all (they are the Mac's).
6. Permission: the first tap asks macOS's own alert ("Sill would like to record system audio"); a
   refusal is reported as `problem: "permission"` and the pill dims; System Settings › Privacy &
   Security › Screen & System Audio Recording turns it on later.

## Steps

1. A probe of the tap on this Mac (a scratch binary): created, read, the speakers silent, levels
   before and after the device's volume (rule 4's assumption), destroyed. Needs the user at the Mac
   for the permission alert.
2. The wire types and their check (`Tests/checks/sound`).
3. The Mac: tap, volume, encoder, server, the synthetic tone.
4. The iPad: decoder, player, the client glue, the pill.
5. Live: a synthetic host's tone to the simulator; then Sill.app to the iPad.

## Results (2026-10-22)

- `swift build -c release`, only the CaptureProbe warning; the iOS app Debug for the simulator, only
  the known StreamClient capture warning.
- `Tests/checks/sound`: 395 checks (SoundPackets, SoundBatch, SoundGate, and a 3,000-run model of
  the gate, segments and the encoder's holdback) and 19 of 19 mutants (in CI's matrix).
- Live, `SillHost --synthetic` on loopback (software encoder) to a private iPad simulator: the
  subscription ("Sound: Sill sound (iPad17,2 simulator) plays this Mac's sound."), the tone at
  35–50 messages a second, played at the 40 ms target (one underrun in a minute, to 50 ms); the
  settings script's `volume 0.3`, `mute on` ("Sound: muted from …", the player stopped, the pill
  red), `mute off` (a new epoch, playing again), `volume 0.8`. Photos of the pill open and muted.
- Not run: steps 1 and 5's second half, the real tap (Sill.app, macOS's permission alert, the
  speakers silent, whether the device volume applies before the tap), and anything on a device.
