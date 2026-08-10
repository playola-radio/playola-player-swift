//
//  Phase5SpikeView.swift
//  PlayolaPlayerExample
//
//  PHASE 5 SLICE-0 HARDWARE DE-RISK SPIKE — THROWAWAY.
//
//  Purpose (PHASE_5_PLAN.md §7 "Slice 0"): prove on a real device that ONE AVSampleBufferAudioRenderer
//  + AVSampleBufferRenderSynchronizer routes as AirPlay-2 LONG-FORM to a HomePod / Apple TV (no -50)
//  with the host session at .playback/.longFormAudio, measure presentation latency, and prove the
//  AVAudioEngine manual-render path can feed the same renderer. Result picks the mixer (custom
//  TimelineMixer vs engine-manual-render). Deleted after the decision — NOT production code.
//
//  ROUTE-CHANGE / AUTO-FLUSH HANDLING (why AirPlay was silent in v1):
//  Per AVSampleBufferAudioRenderer docs, switching the output route (e.g. to AirPlay) triggers an
//  automatic flush (AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification). The synchronizer
//  timebase keeps running, so any buffers we had queued ahead are discarded and we MUST re-enqueue
//  starting at the timebase's CURRENT time, or the new audio sits in the future = silence. This spike
//  now observes that notification and re-anchors (the exact §4.1 / outside-voice C2 mechanism the real
//  renderer needs). The status line logs each re-anchor so you can see it happen on the route switch.
//
//  HOW TO RUN (real device):
//   1. Tap the blue "Phase 5 AirPlay Spike" button → this sheet.
//   2. "Start (sample-buffer)". Hear a 440 Hz tone locally.
//   3. Control Center → AirPlay → HomePod/Apple TV. Audio should keep playing (you may hear a ~½s mute
//      as it re-anchors — that is expected and logged). Watch Renderer status / Route / Live.
//   4. Note Output latency local vs AirPlay. Stop, repeat with "Start (engine-manual)".
//
//  REPORT: did each variant keep playing on AirPlay (any -50/.failed)? local vs AirPlay latency?
//  did you see "auto-flush → re-anchored" when switching? did engine-manual sound as clean?

import AVFoundation
import SwiftUI

// MARK: - Shared audio helpers

private enum SpikeAudio {
  static let sampleRate: Double = 48_000
  static let channels: Int = 2
  static let chunkFrames: Int = 4_096
  static let toneHz: Double = 440

  static func interleavedFloat32ASBD() -> AudioStreamBasicDescription {
    let bytesPerFrame = UInt32(MemoryLayout<Float>.size * channels)
    return AudioStreamBasicDescription(
      mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
      mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
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

// MARK: - Shared feeder: renderer + synchronizer + request loop + auto-flush re-anchor

/// Owns ONE AVSampleBufferAudioRenderer + synchronizer and drives requestMediaDataWhenReady. The PCM
/// source is injected (`produce`) so the two variants differ ONLY in how a chunk is generated. On the
/// route-change auto-flush it re-anchors the PTS clock to the timebase's current time (keeps the
/// timeline moving — a brief mute), which is what makes AirPlay resume instead of going silent.
private final class RendererFeeder: @unchecked Sendable {
  let synchronizer = AVSampleBufferRenderSynchronizer()
  let renderer = AVSampleBufferAudioRenderer()
  private let queue = DispatchQueue(label: "fm.playola.phase5spike.feeder")
  private let produce: @Sendable (_ frames: Int, _ startFrame: Int64) -> [Float]?
  private let onStatus: @Sendable (String) -> Void
  private var nextFrame: Int64 = 0
  private var enqueued: Int64 = 0
  private var observers: [NSObjectProtocol] = []
  private var stopped = false

  init(
    produce: @escaping @Sendable (_ frames: Int, _ startFrame: Int64) -> [Float]?,
    onStatus: @escaping @Sendable (String) -> Void
  ) {
    self.produce = produce
    self.onStatus = onStatus
  }

  func start() {
    synchronizer.addRenderer(renderer)
    let nc = NotificationCenter.default
    observers.append(
      nc.addObserver(
        forName: .AVSampleBufferAudioRendererWasFlushedAutomatically,
        object: renderer, queue: nil
      ) { [weak self] note in self?.reanchor(reason: "auto-flush", note: note) })
    observers.append(
      nc.addObserver(
        forName: .AVSampleBufferAudioRendererOutputConfigurationDidChange,
        object: renderer, queue: nil
      ) { [weak self] _ in self?.onStatus("output-config changed (route change)") })

    renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
      guard let self, !self.stopped else { return }
      while self.renderer.isReadyForMoreMediaData {
        guard let samples = self.produce(SpikeAudio.chunkFrames, self.nextFrame) else { break }
        let pts = CMTime(value: self.nextFrame, timescale: CMTimeScale(SpikeAudio.sampleRate))
        guard
          let sb = SpikeAudio.makeSampleBuffer(
            interleaved: samples, frames: SpikeAudio.chunkFrames, pts: pts)
        else {
          self.onStatus("makeSampleBuffer FAILED")
          break
        }
        self.renderer.enqueue(sb)
        self.nextFrame += Int64(SpikeAudio.chunkFrames)
        self.enqueued += 1
        // Cap absurd race-ahead on AirPlay (which buffers deeply): keep at most ~5s queued.
        let aheadS =
          Double(self.nextFrame) / SpikeAudio.sampleRate
          - CMTimeGetSeconds(self.synchronizer.currentTime())
        if aheadS > 5 { break }
      }
      if self.renderer.status == .failed {
        self.onStatus("renderer .failed: \(self.renderer.error?.localizedDescription ?? "unknown")")
      }
    }
    synchronizer.setRate(1.0, time: .zero)
    onStatus("started (rate=1)")
  }

  /// Route-change recovery: keep the timebase running, re-enqueue from its current time.
  private func reanchor(reason: String, note: Notification?) {
    queue.async { [weak self] in
      guard let self else { return }
      let now = max(0, CMTimeGetSeconds(self.synchronizer.currentTime()))
      self.nextFrame = Int64(now * SpikeAudio.sampleRate)
      self.onStatus("\(reason) → re-anchored @\(String(format: "%.2f", now))s")
    }
  }

  func debugLine() -> String {
    let t = CMTimeGetSeconds(synchronizer.currentTime())
    let ahead = Double(nextFrame) / SpikeAudio.sampleRate - t
    return String(format: "t=%.1fs ahead=%.2fs enq=%d", t, ahead, enqueued)
  }

  func stop() {
    stopped = true
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers.removeAll()
    synchronizer.setRate(0, time: synchronizer.currentTime())
    renderer.stopRequestingMediaData()
    renderer.flush()
    synchronizer.removeRenderer(renderer, at: .zero) { _ in }
    onStatus("stopped")
  }
}

// MARK: - Variant A: generated tone

/// Stateless tone: phase derived from absolute frame index, so re-anchoring never clicks.
private func toneChunk(frames: Int, startFrame: Int64) -> [Float] {
  var out = [Float](repeating: 0, count: frames * SpikeAudio.channels)
  let twoPiF = 2.0 * Double.pi * SpikeAudio.toneHz
  for f in 0..<frames {
    let t = Double(startFrame + Int64(f)) / SpikeAudio.sampleRate
    let v = Float(sin(twoPiF * t) * 0.2)
    out[f * 2] = v
    out[f * 2 + 1] = v
  }
  return out
}

// MARK: - Variant B: AVAudioEngine manual-render source

/// AVAudioEngine in .offline manual-rendering mode produces mixed PCM (a looping tone on a player node),
/// pulled on demand and handed to the same RendererFeeder. Proves "reuse the engine graph, swap only
/// the output" for AirPlay long-form.
private final class EngineManualSource: @unchecked Sendable {
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private var fmt: AVAudioFormat!
  private var renderBuffer: AVAudioPCMBuffer!
  private var ready = false
  private let onStatus: @Sendable (String) -> Void

  init(onStatus: @escaping @Sendable (String) -> Void) { self.onStatus = onStatus }

  func setup() {
    guard
      let interleaved = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: SpikeAudio.sampleRate,
        channels: AVAudioChannelCount(SpikeAudio.channels), interleaved: true)
    else {
      onStatus("engine-manual: bad format")
      return
    }
    fmt = interleaved
    renderBuffer = AVAudioPCMBuffer(
      pcmFormat: interleaved, frameCapacity: AVAudioFrameCount(SpikeAudio.chunkFrames))
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: nil)
    do {
      try engine.enableManualRenderingMode(
        .offline, format: interleaved, maximumFrameCount: AVAudioFrameCount(SpikeAudio.chunkFrames))
      try engine.start()
    } catch {
      onStatus("engine-manual: start FAILED \(error.localizedDescription)")
      return
    }
    if let tone = makeToneBuffer() {
      player.scheduleBuffer(tone, at: nil, options: .loops, completionHandler: nil)
      player.play()
    }
    ready = true
  }

  private func makeToneBuffer() -> AVAudioPCMBuffer? {
    let frames = AVAudioFrameCount(SpikeAudio.sampleRate)
    guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return nil }
    buf.frameLength = frames
    let twoPiF = 2.0 * Double.pi * SpikeAudio.toneHz
    if let ch = buf.floatChannelData {
      let p = ch[0]
      for f in 0..<Int(frames) {
        let v = Float(sin(twoPiF * Double(f) / SpikeAudio.sampleRate) * 0.2)
        p[f * SpikeAudio.channels] = v
        p[f * SpikeAudio.channels + 1] = v
      }
    }
    return buf
  }

  /// Pull `frames` of mixed PCM from the engine as interleaved float32.
  func produce(frames: Int, startFrame: Int64) -> [Float]? {
    guard ready else { return nil }
    do {
      let status = try engine.renderOffline(AVAudioFrameCount(frames), to: renderBuffer)
      guard status == .success else {
        onStatus("engine render \(status.rawValue)")
        return nil
      }
    } catch {
      onStatus("engine renderOffline FAILED \(error.localizedDescription)")
      return nil
    }
    let n = Int(renderBuffer.frameLength)
    guard n > 0, let ch = renderBuffer.floatChannelData else { return nil }
    return Array(UnsafeBufferPointer(start: ch[0], count: n * SpikeAudio.channels))
  }

  func teardown() {
    ready = false
    player.stop()
    engine.stop()
    engine.disableManualRenderingMode()
  }
}

// MARK: - Model

@MainActor
final class Phase5SpikeModel: ObservableObject {
  @Published var status: String = "idle"
  @Published var route: String = "—"
  @Published var outputLatencyMs: String = "—"
  @Published var live: String = "—"
  @Published var running: String? = nil

  private var feeder: RendererFeeder?
  private var engineSource: EngineManualSource?
  private var timer: Timer?

  func configureSessionLongForm() {
    #if os(iOS) || os(tvOS)
      let session = AVAudioSession.sharedInstance()
      do {
        try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try session.setActive(true)
        status = "session: .playback/.longFormAudio active"
      } catch {
        status = "SESSION FAILED: \(error.localizedDescription)"
      }
      refreshRoute()
    #else
      status = "n/a — needs iOS/tvOS"
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
    let f = RendererFeeder(
      produce: { frames, start in toneChunk(frames: frames, startFrame: start) },
      onStatus: { [weak self] s in Task { @MainActor in self?.status = s } })
    feeder = f
    f.start()
    running = "sample-buffer"
    startTicker()
  }

  func startEngineManual() {
    stopAll()
    configureSessionLongForm()
    let src = EngineManualSource(onStatus: { [weak self] s in
      Task { @MainActor in self?.status = s }
    })
    src.setup()
    engineSource = src
    let f = RendererFeeder(
      produce: { frames, start in src.produce(frames: frames, startFrame: start) },
      onStatus: { [weak self] s in Task { @MainActor in self?.status = s } })
    feeder = f
    f.start()
    running = "engine-manual"
    startTicker()
  }

  private func startTicker() {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.refreshRoute()
        self.live = self.feeder?.debugLine() ?? "—"
      }
    }
  }

  func stopAll() {
    timer?.invalidate()
    timer = nil
    feeder?.stop()
    feeder = nil
    engineSource?.teardown()
    engineSource = nil
    running = nil
    live = "—"
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
          Text("Phase 5 Slice-0 spike").font(.title2).bold()
          Text(
            "Prove AirPlay-2 long-form routing + measure latency; compare the two mixer sources. Real device only. AirPlay to a HomePod/Apple TV from Control Center. A brief mute on the route switch is expected (re-anchor)."
          )
          .font(.footnote).foregroundColor(.secondary)

          Group {
            row("Running", model.running ?? "—")
            row("Renderer status", model.status)
            row("Route", model.route)
            row("Output latency", model.outputLatencyMs)
            row("Live", model.live)
          }
          .padding(12).background(Color.gray.opacity(0.12)).cornerRadius(10)

          VStack(spacing: 12) {
            Button("Start (sample-buffer / generated PCM)") { model.startSampleBuffer() }
              .buttonStyle(.borderedProminent)
            Button("Start (engine-manual → renderer)") { model.startEngineManual() }
              .buttonStyle(.borderedProminent)
            Button("Stop") { model.stopAll() }.buttonStyle(.bordered)
            Button("Refresh route/latency") { model.refreshRoute() }.buttonStyle(.bordered)
          }
          .frame(maxWidth: .infinity)

          Text(
            "Report: did each variant keep playing when moved to a HomePod/Apple TV (any -50 / .failed)? Did you see 'auto-flush → re-anchored' on the switch? Local vs AirPlay latency? Did engine-manual sound as clean?"
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
