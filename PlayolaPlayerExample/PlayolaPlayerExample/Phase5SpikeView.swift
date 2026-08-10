//
//  Phase5SpikeView.swift
//  PlayolaPlayerExample
//
//  PHASE 5 SLICE-0 HARDWARE DE-RISK SPIKE — THROWAWAY.
//
//  Purpose (from PHASE_5_PLAN.md §7 "Slice 0"): before building the real pipeline,
//  prove on a real device that ONE AVSampleBufferAudioRenderer + AVSampleBufferRenderSynchronizer
//  routes as AirPlay-2 LONG-FORM to a HomePod / Apple TV (no OSStatus -50) with the host session at
//  .playback/.longFormAudio, measure end-to-end presentation latency, AND prove the alternative
//  AVAudioEngine manual-rendering path can produce PCM that feeds the same renderer. The result PICKS
//  the mixer architecture (custom TimelineMixer vs engine-manual-render). This file is deleted once
//  that decision is made — it is NOT production code and lives only in the example app.
//
//  HOW TO RUN
//   1. Build/run PlayolaPlayerExample on a REAL DEVICE (AirPlay long-form cannot be tested in the sim).
//   2. Tap the airplayaudio button on the main screen.
//   3. Tap "Start (sample-buffer)". You should hear a 440 Hz tone. Confirm audio.
//   4. Open Control Center → AirPlay → pick a HomePod / Apple TV. Audio should move there and KEEP
//      playing (this is the long-form route-share test). Watch the "Route" + "Renderer status" lines.
//      If status goes .failed or you see error -50, long-form routing failed → record it.
//   5. Note "Output latency" locally vs on AirPlay (it jumps up on AirPlay — that's the anchor offset
//      the real renderer must compensate for, plan §4.1 A1).
//   6. Stop, then "Start (engine-manual)" and repeat the AirPlay move to confirm the reuse path routes
//      the same way and sounds clean.
//
//  WHAT TO REPORT BACK (this is the go/no-go):
//   - Did each variant route long-form to a HomePod/Apple TV and keep playing? (any -50 / .failed?)
//   - Local vs AirPlay output latency (seconds) for each variant.
//   - Did engine-manual-render sound as clean as the sample-buffer variant?
//   → Picks custom TimelineMixer vs engine-manual-render for the real build.

import AVFoundation
import SwiftUI

// MARK: - Shared audio helpers

private enum SpikeAudio {
  static let sampleRate: Double = 48_000
  static let channels: Int = 2
  static let chunkFrames: Int = 4_096
  static let toneHz: Double = 440

  /// Interleaved stereo float32 ASBD matching the mix format the real path will use.
  static func interleavedFloat32ASBD() -> AudioStreamBasicDescription {
    let bytesPerFrame = UInt32(MemoryLayout<Float>.size * channels)
    return AudioStreamBasicDescription(
      mSampleRate: sampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: bytesPerFrame,
      mFramesPerPacket: 1,
      mBytesPerFrame: bytesPerFrame,
      mChannelsPerFrame: UInt32(channels),
      mBitsPerChannel: 32,
      mReserved: 0)
  }

  /// Wrap interleaved float32 samples into a ready-to-render LPCM CMSampleBuffer with an absolute PTS.
  static func makeSampleBuffer(interleaved samples: [Float], frames: Int, pts: CMTime)
    -> CMSampleBuffer?
  {
    var asbd = interleavedFloat32ASBD()
    var formatDesc: CMAudioFormatDescription?
    guard
      CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil,
        formatDescriptionOut: &formatDesc) == noErr, let fmt = formatDesc
    else { return nil }

    let dataByteSize = frames * Int(asbd.mBytesPerFrame)
    var blockBuffer: CMBlockBuffer?
    guard
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: dataByteSize,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
        dataLength: dataByteSize, flags: 0, blockBufferOut: &blockBuffer) == noErr,
      let bb = blockBuffer
    else { return nil }
    guard CMBlockBufferAssureBlockMemory(bb) == noErr else { return nil }
    let copyStatus = samples.withUnsafeBytes { raw -> OSStatus in
      guard let base = raw.baseAddress else { return -1 }
      return CMBlockBufferReplaceDataBytes(
        with: base, blockBuffer: bb, offsetIntoDestination: 0, dataLength: dataByteSize)
    }
    guard copyStatus == noErr else { return nil }

    var sampleBuffer: CMSampleBuffer?
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
      presentationTimeStamp: pts, decodeTimeStamp: .invalid)
    var sampleSize = Int(asbd.mBytesPerFrame)
    guard
      CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: fmt,
        sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
        sampleBufferOut: &sampleBuffer) == noErr
    else { return nil }
    return sampleBuffer
  }
}

// MARK: - Variant A: generated-PCM straight into the sample-buffer renderer

/// Feeds a 440 Hz interleaved-float32 tone to one AVSampleBufferAudioRenderer via requestMediaDataWhenReady.
/// This is the exact sink the real custom-mixer path uses; only the PCM source is fake.
private final class SampleBufferToneDriver: @unchecked Sendable {
  private let synchronizer = AVSampleBufferRenderSynchronizer()
  private let renderer = AVSampleBufferAudioRenderer()
  private let queue = DispatchQueue(label: "fm.playola.phase5spike.samplebuffer")
  private var frameIndex: Int64 = 0
  private var phase: Double = 0
  private let onStatus: @Sendable (String) -> Void

  init(onStatus: @escaping @Sendable (String) -> Void) { self.onStatus = onStatus }

  func start() {
    synchronizer.addRenderer(renderer)
    renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
      guard let self else { return }
      while self.renderer.isReadyForMoreMediaData {
        self.enqueueNextChunk()
        if self.frameIndex > Int64(SpikeAudio.sampleRate) * 3_600 { break }  // 1h safety cap
      }
      if self.renderer.status == .failed {
        let err = self.renderer.error?.localizedDescription ?? "unknown"
        self.onStatus("renderer .failed: \(err)")
      }
    }
    synchronizer.setRate(1.0, time: .zero)
    onStatus("sample-buffer: started (rate=1)")
  }

  func stop() {
    synchronizer.setRate(0, time: synchronizer.currentTime())
    renderer.stopRequestingMediaData()
    renderer.flush()
    synchronizer.removeRenderer(renderer, at: .zero) { _ in }
    onStatus("sample-buffer: stopped")
  }

  private func enqueueNextChunk() {
    let frames = SpikeAudio.chunkFrames
    var samples = [Float](repeating: 0, count: frames * SpikeAudio.channels)
    let inc = 2.0 * Double.pi * SpikeAudio.toneHz / SpikeAudio.sampleRate
    for f in 0..<frames {
      let v = Float(sin(phase) * 0.2)
      samples[f * 2] = v
      samples[f * 2 + 1] = v
      phase += inc
      if phase > 2 * Double.pi { phase -= 2 * Double.pi }
    }
    let pts = CMTime(value: frameIndex, timescale: CMTimeScale(SpikeAudio.sampleRate))
    if let sb = SpikeAudio.makeSampleBuffer(interleaved: samples, frames: frames, pts: pts) {
      renderer.enqueue(sb)
      frameIndex += Int64(frames)
    } else {
      onStatus("sample-buffer: makeSampleBuffer FAILED")
    }
  }
}

// MARK: - Variant B: AVAudioEngine manual-rendering → same sample-buffer renderer

/// Proves the "reuse the existing engine graph, replace only the output" path: an AVAudioEngine in
/// manual-rendering mode produces mixed PCM (here just a looping tone on a player node), which we wrap
/// into CMSampleBuffers and feed to the SAME AVSampleBufferAudioRenderer for AirPlay long-form.
private final class EngineManualRenderDriver: @unchecked Sendable {
  private let synchronizer = AVSampleBufferRenderSynchronizer()
  private let renderer = AVSampleBufferAudioRenderer()
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let queue = DispatchQueue(label: "fm.playola.phase5spike.enginemanual")
  private var frameIndex: Int64 = 0
  private let onStatus: @Sendable (String) -> Void
  private var manualFormat: AVAudioFormat!
  private var renderBuffer: AVAudioPCMBuffer!

  init(onStatus: @escaping @Sendable (String) -> Void) { self.onStatus = onStatus }

  func start() {
    guard
      let interleaved = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: SpikeAudio.sampleRate,
        channels: AVAudioChannelCount(SpikeAudio.channels), interleaved: true)
    else {
      onStatus("engine-manual: bad format")
      return
    }
    manualFormat = interleaved
    renderBuffer = AVAudioPCMBuffer(
      pcmFormat: interleaved, frameCapacity: AVAudioFrameCount(SpikeAudio.chunkFrames))

    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: nil)
    do {
      // .offline mode: the renderer's requestMediaDataWhenReady pull IS our clock, so we render exactly
      // the frames requested each time (not a real-time thread). This is the correct manual-render fit.
      try engine.enableManualRenderingMode(
        .offline, format: interleaved, maximumFrameCount: AVAudioFrameCount(SpikeAudio.chunkFrames))
      try engine.start()
    } catch {
      onStatus("engine-manual: engine start FAILED \(error.localizedDescription)")
      return
    }
    if let tone = makeToneBuffer() {
      player.scheduleBuffer(tone, at: nil, options: .loops, completionHandler: nil)
      player.play()
    }

    synchronizer.addRenderer(renderer)
    renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
      guard let self else { return }
      while self.renderer.isReadyForMoreMediaData {
        self.pullAndEnqueue()
        if self.frameIndex > Int64(SpikeAudio.sampleRate) * 3_600 { break }
      }
      if self.renderer.status == .failed {
        self.onStatus(
          "engine-manual renderer .failed: \(self.renderer.error?.localizedDescription ?? "unknown")"
        )
      }
    }
    synchronizer.setRate(1.0, time: .zero)
    onStatus("engine-manual: started (manual .realtime → renderer)")
  }

  func stop() {
    synchronizer.setRate(0, time: synchronizer.currentTime())
    renderer.stopRequestingMediaData()
    renderer.flush()
    player.stop()
    engine.stop()
    engine.disableManualRenderingMode()
    synchronizer.removeRenderer(renderer, at: .zero) { _ in }
    onStatus("engine-manual: stopped")
  }

  /// One second of 440 Hz interleaved tone to loop through the player node → engine mixer.
  private func makeToneBuffer() -> AVAudioPCMBuffer? {
    let frames = AVAudioFrameCount(SpikeAudio.sampleRate)
    guard let buf = AVAudioPCMBuffer(pcmFormat: manualFormat, frameCapacity: frames) else {
      return nil
    }
    buf.frameLength = frames
    let inc = 2.0 * Double.pi * SpikeAudio.toneHz / SpikeAudio.sampleRate
    var ph = 0.0
    if let ch = buf.floatChannelData {
      // interleaved: single buffer, stride = channels
      let ptr = ch[0]
      for f in 0..<Int(frames) {
        let v = Float(sin(ph) * 0.2)
        ptr[f * SpikeAudio.channels] = v
        ptr[f * SpikeAudio.channels + 1] = v
        ph += inc
        if ph > 2 * Double.pi { ph -= 2 * Double.pi }
      }
    }
    return buf
  }

  private func pullAndEnqueue() {
    let frames = AVAudioFrameCount(SpikeAudio.chunkFrames)
    do {
      let status = try engine.renderOffline(frames, to: renderBuffer)
      guard status == .success else {
        onStatus("engine-manual: render status \(status.rawValue)")
        return
      }
    } catch {
      onStatus("engine-manual: renderOffline FAILED \(error.localizedDescription)")
      return
    }
    let frameCount = Int(renderBuffer.frameLength)
    guard frameCount > 0, let ch = renderBuffer.floatChannelData else { return }
    let interleaved = Array(
      UnsafeBufferPointer(start: ch[0], count: frameCount * SpikeAudio.channels))
    let pts = CMTime(value: frameIndex, timescale: CMTimeScale(SpikeAudio.sampleRate))
    if let sb = SpikeAudio.makeSampleBuffer(interleaved: interleaved, frames: frameCount, pts: pts)
    {
      renderer.enqueue(sb)
      frameIndex += Int64(frameCount)
    }
  }
}

// MARK: - Model

@MainActor
final class Phase5SpikeModel: ObservableObject {
  @Published var status: String = "idle"
  @Published var route: String = "—"
  @Published var outputLatencyMs: String = "—"
  @Published var running: String? = nil  // "sample-buffer" | "engine-manual" | nil

  private var sbDriver: SampleBufferToneDriver?
  private var engDriver: EngineManualRenderDriver?
  private var routeTimer: Timer?

  func configureSessionLongForm() {
    #if os(iOS) || os(tvOS)
      let session = AVAudioSession.sharedInstance()
      do {
        try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try session.setActive(true)
        status = "session: .playback/.longFormAudio active"
      } catch {
        status = "SESSION FAILED: \(error.localizedDescription) — long-form category rejected?"
      }
      refreshRoute()
      routeTimer?.invalidate()
      routeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.refreshRoute() }
      }
    #else
      status = "n/a — spike requires iOS/tvOS (AVAudioSession)"
    #endif
  }

  func refreshRoute() {
    #if os(iOS) || os(tvOS)
      let session = AVAudioSession.sharedInstance()
      let outs = session.currentRoute.outputs.map { "\($0.portName) [\($0.portType.rawValue)]" }
      route = outs.isEmpty ? "(none)" : outs.joined(separator: ", ")
      outputLatencyMs = String(format: "%.1f ms", session.outputLatency * 1000)
    #endif
  }

  func startSampleBuffer() {
    stopAll()
    configureSessionLongForm()
    let d = SampleBufferToneDriver(onStatus: { [weak self] s in
      Task { @MainActor in self?.status = s }
    })
    sbDriver = d
    d.start()
    running = "sample-buffer"
  }

  func startEngineManual() {
    stopAll()
    configureSessionLongForm()
    let d = EngineManualRenderDriver(onStatus: { [weak self] s in
      Task { @MainActor in self?.status = s }
    })
    engDriver = d
    d.start()
    running = "engine-manual"
  }

  func stopAll() {
    sbDriver?.stop()
    sbDriver = nil
    engDriver?.stop()
    engDriver = nil
    running = nil
  }
}

// MARK: - View

struct Phase5SpikeView: View {
  @StateObject private var model = Phase5SpikeModel()
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationView {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text("Phase 5 Slice-0 spike")
            .font(.title2).bold()
          Text(
            "Prove AirPlay-2 long-form routing + measure latency, and compare the two mixer sources. Run on a REAL DEVICE, then AirPlay to a HomePod/Apple TV from Control Center."
          )
          .font(.footnote).foregroundColor(.secondary)

          Group {
            row("Running", model.running ?? "—")
            row("Renderer status", model.status)
            row("Route", model.route)
            row("Output latency", model.outputLatencyMs)
          }
          .padding(12)
          .background(Color.gray.opacity(0.12))
          .cornerRadius(10)

          VStack(spacing: 12) {
            Button("Start (sample-buffer / generated PCM)") { model.startSampleBuffer() }
              .buttonStyle(.borderedProminent)
            Button("Start (engine-manual → renderer)") { model.startEngineManual() }
              .buttonStyle(.borderedProminent)
            Button("Stop") { model.stopAll() }
              .buttonStyle(.bordered)
            Button("Refresh route/latency") { model.refreshRoute() }
              .buttonStyle(.bordered)
          }
          .frame(maxWidth: .infinity)

          Text(
            "Report: did each variant keep playing when moved to a HomePod/Apple TV (no -50 / .failed)? Local vs AirPlay latency? Did engine-manual sound as clean? → picks the real mixer."
          )
          .font(.caption2).foregroundColor(.secondary)
        }
        .padding()
      }
      .navigationTitle("Slice-0 Spike")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") {
            model.stopAll()
            dismiss()
          }
        }
      }
      .onAppear { model.configureSessionLongForm() }
      .onDisappear { model.stopAll() }
    }
  }

  private func row(_ label: String, _ value: String) -> some View {
    HStack(alignment: .top) {
      Text(label).font(.caption).foregroundColor(.secondary).frame(width: 120, alignment: .leading)
      Text(value).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
