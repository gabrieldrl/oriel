import AudioToolbox
import Foundation

/// Interleaved stereo Float32 at the capture's rate to AAC-ELD (docs/mac-sound-plan.md): 480 frames
/// a packet (10 ms at 48 kHz), 128 kbps. A capture above 48 kHz (a 96 kHz interface) is resampled by
/// the converter to 48 or 44.1 kHz, so a packet takes `inputFramesPerPacket` of its frames. Not thread-safe: the pipeline's queue alone calls it.
/// Nothing is allocated per packet: the output buffer is the encoder's own, and `encode` hands its
/// bytes to a closure that copies what it keeps.
final class SoundEncoder {
    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        let step: String
        var description: String { "\(step) failed (\(status))" }
    }

    static let channels = 2
    static let framesPerPacket = 480
    static let bitrate = 128_000

    /// The packets' rate, and the capture's.
    let sampleRate: Double
    let inputRate: Double
    let cookie: Data
    let framesPerPacket: Int
    /// The capture's frames one packet takes.
    let inputFramesPerPacket: Int

    private let converter: AudioConverterRef
    private let maxPacketBytes: Int
    private let output: UnsafeMutableRawPointer
    private let feed = Feed()

    /// The rate a capture at `inputRate` is encoded at: its own up to 48 kHz, else 44.1 kHz for a
    /// multiple of it, else 48 kHz.
    static func outputRate(for inputRate: Double) -> Double {
        if inputRate <= 48_000 { return inputRate }
        return inputRate.truncatingRemainder(dividingBy: 44_100) == 0 ? 44_100 : 48_000
    }

    init(inputRate: Double) throws {
        let sampleRate = Self.outputRate(for: inputRate)
        let ch = UInt32(Self.channels)
        var input = AudioStreamBasicDescription(mSampleRate: inputRate, mFormatID: kAudioFormatLinearPCM,
                                                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                mBytesPerPacket: 4 * ch, mFramesPerPacket: 1, mBytesPerFrame: 4 * ch,
                                                mChannelsPerFrame: ch, mBitsPerChannel: 32, mReserved: 0)
        var out = AudioStreamBasicDescription()
        out.mFormatID = kAudioFormatMPEG4AAC_ELD
        out.mSampleRate = sampleRate
        out.mChannelsPerFrame = ch
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var status = AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &size, &out)
        guard status == noErr else { throw Failure(status: status, step: "AAC-ELD's format") }
        out.mFramesPerPacket = UInt32(Self.framesPerPacket)
        var made: AudioConverterRef?
        status = AudioConverterNew(&input, &out, &made)
        guard status == noErr, let converter = made else { throw Failure(status: status, step: "the AAC-ELD encoder") }
        var rate = UInt32(Self.bitrate)
        AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &rate)

        var got = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioConverterGetProperty(converter, kAudioConverterCurrentOutputStreamDescription, &size, &got)
        var cookieSize: UInt32 = 0
        var cookie = Data()
        if AudioConverterGetPropertyInfo(converter, kAudioConverterCompressionMagicCookie, &cookieSize, nil) == noErr, cookieSize > 0 {
            cookie = Data(count: Int(cookieSize))
            status = cookie.withUnsafeMutableBytes {
                AudioConverterGetProperty(converter, kAudioConverterCompressionMagicCookie, &cookieSize, $0.baseAddress!)
            }
            guard status == noErr else { AudioConverterDispose(converter); throw Failure(status: status, step: "the magic cookie") }
            cookie = cookie.prefix(Int(cookieSize))
        }
        var maxPacket: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioConverterGetProperty(converter, kAudioConverterPropertyMaximumOutputPacketSize, &size, &maxPacket) != noErr || maxPacket == 0 {
            maxPacket = 4096
        }
        self.converter = converter
        self.sampleRate = sampleRate
        self.inputRate = inputRate
        self.cookie = cookie
        self.framesPerPacket = got.mFramesPerPacket > 0 ? Int(got.mFramesPerPacket) : Self.framesPerPacket
        self.inputFramesPerPacket = Int((Double(self.framesPerPacket) * inputRate / sampleRate).rounded())
        self.maxPacketBytes = Int(maxPacket)
        self.output = UnsafeMutableRawPointer.allocate(byteCount: Int(maxPacket), alignment: 16)
    }

    deinit {
        AudioConverterDispose(converter)
        output.deallocate()
    }

    /// One packet's `inputFramesPerPacket` interleaved frames. The encoder may hold the first few
    /// back (its look-ahead, a resampler's): then `body` is not called.
    func encode(_ samples: UnsafePointer<Float>, _ body: (UnsafeRawBufferPointer) -> Void) {
        feed.samples = UnsafeRawPointer(samples)
        feed.frames = inputFramesPerPacket
        defer { feed.samples = nil; feed.frames = 0 }
        var packets: UInt32 = 1
        var description = AudioStreamPacketDescription()
        var list = AudioBufferList(mNumberBuffers: 1,
                                   mBuffers: AudioBuffer(mNumberChannels: UInt32(Self.channels),
                                                         mDataByteSize: UInt32(maxPacketBytes), mData: output))
        let status = AudioConverterFillComplexBuffer(converter, Self.supply, Unmanaged.passUnretained(feed).toOpaque(),
                                                     &packets, &list, &description)
        guard status == noErr || status == Self.noMoreInput, packets == 1, list.mBuffers.mDataByteSize > 0 else { return }
        body(UnsafeRawBufferPointer(start: output, count: Int(list.mBuffers.mDataByteSize)))
    }

    /// The input proc's answer once this packet's frames are given: no more for now.
    private static let noMoreInput: OSStatus = 0x6E6F_6D6F   // 'nomo'

    private final class Feed {
        var samples: UnsafeRawPointer?
        var frames = 0
    }

    private static let supply: AudioConverterComplexInputDataProc = { _, count, data, _, context in
        let feed = Unmanaged<Feed>.fromOpaque(context!).takeUnretainedValue()
        guard let samples = feed.samples, feed.frames > 0 else {
            count.pointee = 0
            return SoundEncoder.noMoreInput
        }
        let frames = min(Int(count.pointee), feed.frames)
        let bytes = frames * SoundEncoder.channels * MemoryLayout<Float>.size
        count.pointee = UInt32(frames)
        data.pointee.mNumberBuffers = 1
        data.pointee.mBuffers.mNumberChannels = UInt32(SoundEncoder.channels)
        data.pointee.mBuffers.mDataByteSize = UInt32(bytes)
        data.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: samples)
        feed.samples = samples.advanced(by: bytes)
        feed.frames -= frames
        return noErr
    }
}
