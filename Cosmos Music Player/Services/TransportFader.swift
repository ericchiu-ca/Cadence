//
//  TransportFader.swift
//  Cosmos Music Player
//
//  Click-free pause and resume for the native engine: a gain stage whose
//  fades run in the render thread, sample by sample.
//

import AVFoundation
import AudioToolbox
import Synchronization

/// Fades the native engine's output around pause and resume, the way
/// foobar2000 and other desktop players do: the gain is ramped on the samples
/// themselves, and the player only stops once the ramp has reached silence.
///
/// The fades used to be twelve volume steps on the main mixer, posted from the
/// main actor. The mixer smooths each step, but it also stops rendering - and
/// freezes that smoothing - as soon as its input goes silent, and the player
/// node was paused in the same render cycle as the last step. The mixer froze
/// at about 8% gain, so every resume started with a jump from silence to 8% of
/// full scale: the crackle. The steps also stalled whenever the tap's own
/// animation held the main thread.
///
/// Sits between the player node and the EQ: player -> fader -> EQ -> mixer.
@MainActor
final class TransportFader {
    let node: AVAudioUnitEffect
    private let control: TransportFadeControl
    private var sequence: UInt16 = 0

    /// Nil if the audio unit cannot be created; the player is then wired
    /// straight to the EQ and transport changes are not faded.
    static func make() -> TransportFader? {
        _ = TransportFadeUnit.registration
        let node = AVAudioUnitEffect(audioComponentDescription: TransportFadeUnit.componentDescription)
        guard let unit = node.auAudioUnit as? TransportFadeUnit else {
            print("⚠️ Transport fader unavailable - pause and resume will not be faded")
            return nil
        }
        return TransportFader(node: node, control: unit.control)
    }

    private init(node: AVAudioUnitEffect, control: TransportFadeControl) {
        self.node = node
        self.control = control
    }

    /// Jumps to `gain` at the next render. Only while nothing is sounding:
    /// with audio playing, a jump is a click.
    func set(_ gain: Float) {
        send(gain, over: 0)
    }

    /// Ramps from wherever the gain is to `gain`, starting at the next render.
    /// A ramp up waits for the input to carry sound, so a fade-in starts with
    /// the music rather than running out over silence first.
    func ramp(to gain: Float, over duration: TimeInterval) {
        send(gain, over: duration)
    }

    /// Ramps to `gain` and returns once the render thread has got there - or
    /// after a timeout, if the engine stopped rendering in the meantime.
    /// Returns early, without waiting, when the calling task is cancelled.
    func fade(to gain: Float, over duration: TimeInterval) async {
        let command = send(gain, over: duration)
        let deadline = ContinuousClock.now + .seconds(duration) + .milliseconds(400)
        try? await Task.sleep(for: .seconds(duration))
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if control.appliedCommand.load(ordering: .acquiring) == command,
               Float(bitPattern: control.renderedGain.load(ordering: .relaxed)) == gain {
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @discardableResult
    private func send(_ gain: Float, over duration: TimeInterval) -> UInt64 {
        sequence &+= 1
        let milliseconds = UInt64(min(max(duration * 1000, 0), Double(UInt16.max)).rounded())
        let command = UInt64(sequence) << 48 | milliseconds << 32 | UInt64(gain.bitPattern)
        control.command.store(command, ordering: .releasing)
        return command
    }
}

/// What the main actor and the render thread share: the latest command in, and
/// how far the render thread has got out. One word each, so neither side ever
/// waits for the other.
final class TransportFadeControl: Sendable {
    /// Sequence (16 bits) | ramp length in ms (16 bits) | target gain (Float bits).
    let command = Atomic<UInt64>(0)
    /// The last command the render thread has picked up.
    let appliedCommand = Atomic<UInt64>(0)
    /// The gain at the end of the last render, as Float bits.
    let renderedGain = Atomic<UInt32>(Float(1).bitPattern)
}

/// The audio unit behind `TransportFader`. Its render block pulls the
/// player's audio into the output buffers and scales it in place.
final class TransportFadeUnit: AUAudioUnit, @unchecked Sendable {
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x6661_6465, // 'fade'
        componentManufacturer: 0x4364_6E63, // 'Cdnc'
        componentFlags: 0,
        componentFlagsMask: 0
    )

    static let registration: Void = {
        AUAudioUnit.registerSubclass(
            TransportFadeUnit.self,
            as: componentDescription,
            name: "Cadence: Transport Fade",
            version: 1
        )
    }()

    let control: TransportFadeControl
    private let kernel: TransportFadeKernel
    private let inputBus: AUAudioUnitBus
    private let outputBus: AUAudioUnitBus
    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!

    override init(
        componentDescription: AudioComponentDescription,
        options: AudioComponentInstantiationOptions = []
    ) throws {
        let control = TransportFadeControl()
        self.control = control
        kernel = TransportFadeKernel(control: control)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        inputBus = try AUAudioUnitBus(format: format)
        outputBus = try AUAudioUnitBus(format: format)
        try super.init(componentDescription: componentDescription, options: options)
        inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        maximumFramesToRender = 4096
    }

    override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { outputBusArray }
    override var canProcessInPlace: Bool { true }

    /// AVAudioEngine connects with its standard format - deinterleaved
    /// Float32 - which is the only layout the kernel scales.
    override func shouldChange(to format: AVAudioFormat, for bus: AUAudioUnitBus) -> Bool {
        format.commonFormat == .pcmFormatFloat32 && !format.isInterleaved
    }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        guard inputBus.format.channelCount == outputBus.format.channelCount else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        kernel.prepare(format: outputBus.format, maximumFrames: maximumFramesToRender)
    }

    override func deallocateRenderResources() {
        kernel.release()
        super.deallocateRenderResources()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let kernel = kernel
        return { actionFlags, timestamp, frameCount, _, outputData, _, pullInputBlock in
            kernel.render(
                actionFlags: actionFlags,
                timestamp: timestamp,
                frameCount: frameCount,
                outputData: outputData,
                pullInputBlock: pullInputBlock
            )
        }
    }
}

/// Render-thread state. Only `prepare` and `release` run elsewhere, and only
/// while the unit is not rendering.
private final class TransportFadeKernel: @unchecked Sendable {
    private let control: TransportFadeControl
    private var sampleRate: Double = 44_100
    private var maximumFrames: AUAudioFrameCount = 0
    /// Where the input is pulled when the downstream node passes no buffers.
    private var scratch: AVAudioPCMBuffer?

    private var gain: Float = 1
    private var target: Float = 1
    private var step: Float = 0
    private var remaining = 0
    private var lastCommand: UInt64 = 0

    init(control: TransportFadeControl) {
        self.control = control
    }

    func prepare(format: AVAudioFormat, maximumFrames: AUAudioFrameCount) {
        sampleRate = format.sampleRate
        self.maximumFrames = maximumFrames
        scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maximumFrames)
    }

    func release() {
        scratch = nil
    }

    func render(
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: AUAudioFrameCount,
        outputData: UnsafeMutablePointer<AudioBufferList>,
        pullInputBlock: AURenderPullInputBlock?
    ) -> AUAudioUnitStatus {
        guard let pullInputBlock else { return kAudioUnitErr_NoConnection }
        guard frameCount <= maximumFrames else { return kAudioUnitErr_TooManyFramesToProcess }

        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        if buffers.count > 0, buffers[0].mData == nil, let scratch {
            let own = UnsafeMutableAudioBufferListPointer(scratch.mutableAudioBufferList)
            for index in 0..<min(buffers.count, own.count) {
                buffers[index].mData = own[index].mData
            }
        }
        let byteSize = frameCount * UInt32(MemoryLayout<Float>.size)
        for index in 0..<buffers.count {
            buffers[index].mDataByteSize = byteSize
        }

        var pullFlags = AudioUnitRenderActionFlags()
        let status = pullInputBlock(&pullFlags, timestamp, frameCount, 0, outputData)
        guard status == noErr else { return status }

        applyLatestCommand()
        let frames = Int(frameCount)

        if pullFlags.contains(.unitRenderAction_OutputIsSilence) {
            actionFlags.pointee.insert(.unitRenderAction_OutputIsSilence)
            // A fade-out may finish over silence; a fade-in waits for sound.
            if remaining > 0, step < 0 {
                advance(by: frames)
            }
        } else if remaining > 0 {
            scaleWithRamp(buffers, frames: frames)
        } else if gain == 0 {
            for index in 0..<buffers.count {
                if let data = buffers[index].mData {
                    memset(data, 0, Int(byteSize))
                }
            }
            actionFlags.pointee.insert(.unitRenderAction_OutputIsSilence)
        } else if gain != 1 {
            for index in 0..<buffers.count {
                guard let samples = buffers[index].mData?.assumingMemoryBound(to: Float.self) else { continue }
                for frame in 0..<frames {
                    samples[frame] *= gain
                }
            }
        }

        control.renderedGain.store(gain.bitPattern, ordering: .relaxed)
        control.appliedCommand.store(lastCommand, ordering: .releasing)
        return noErr
    }

    private func applyLatestCommand() {
        let command = control.command.load(ordering: .acquiring)
        guard command != lastCommand else { return }
        lastCommand = command
        target = Float(bitPattern: UInt32(truncatingIfNeeded: command))
        let milliseconds = Double((command >> 32) & 0xFFFF)
        let frames = Int((milliseconds / 1000 * sampleRate).rounded())
        if frames <= 0 || gain == target {
            gain = target
            remaining = 0
        } else {
            remaining = frames
            step = (target - gain) / Float(frames)
        }
    }

    private func advance(by frames: Int) {
        let count = min(frames, remaining)
        gain += step * Float(count)
        remaining -= count
        if remaining == 0 { gain = target }
    }

    /// Every channel gets the same ramp, starting from the same gain.
    private func scaleWithRamp(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        let startGain = gain
        let startRemaining = remaining
        var endGain = startGain
        var endRemaining = startRemaining
        for index in 0..<buffers.count {
            guard let samples = buffers[index].mData?.assumingMemoryBound(to: Float.self) else { continue }
            var current = startGain
            var left = startRemaining
            for frame in 0..<frames {
                if left > 0 {
                    current += step
                    left -= 1
                    if left == 0 { current = target }
                }
                samples[frame] *= current
            }
            endGain = current
            endRemaining = left
        }
        if endRemaining == startRemaining {
            // No channel had data to scale; keep time moving anyway.
            advance(by: frames)
        } else {
            gain = endGain
            remaining = endRemaining
        }
    }
}
