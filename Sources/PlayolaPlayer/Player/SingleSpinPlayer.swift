import AVFoundation
import Foundation
import os.log

@MainActor
public final class SingleSpinPlayer {
  private static let logger = OSLog(subsystem: "fm.playola.playolaCore", category: "SingleSpin")

  // debugging things to try
  private let debugUseKeyPathBus0 = true

  // Deps (mirroring SpinPlayer)
  private let playolaMainMixer: PlayolaMainMixer = .shared
  private let engine: AVAudioEngine = PlayolaMainMixer.shared.engine
  private let playerNode = AVAudioPlayerNode()
  private let trackMixer = AVAudioMixerNode()
  /// Cached rampable volume parameter for fades/automation
  private var volumeParam: AUParameter?
  private var paramObserverToken: AUParameterObserverToken?
  private let fileDownloadManager: FileDownloadManaging
  private let errorReporter = PlayolaErrorReporter.shared

  public private(set) var spin: Spin
  private var fileURL: URL?
  private var scheduledStartSample: AUEventSampleTime?
  /// Captured hostTime when mixer actually starts (from tap)
  private var startHostTime: UInt64?
  private var activeDownloadId: UUID?
  private var startTapInstalled = false
  private var didCaptureStart = false
  private var scheduledPlayHostTime: UInt64?
  private var paramMonitorTimer: Timer?

  public init(spin: Spin, fileDownloadManager: FileDownloadManaging? = nil) {
    self.spin = spin
    self.fileDownloadManager = fileDownloadManager ?? FileDownloadManagerAsync.shared

    // Configure audio session exactly like SpinPlayer
    playolaMainMixer.configureAudioSession()

    // Connect like SpinPlayer does (into the shared main mixer)
    engine.attach(playerNode)
    engine.attach(trackMixer)
    if debugUseKeyPathBus0 {
      engine.connect(
        playerNode, to: trackMixer, fromBus: 0, toBus: 0, format: TapProperties.default.format)
    } else {
      engine.connect(playerNode, to: trackMixer, format: TapProperties.default.format)
    }

    engine.connect(
      trackMixer,
      to: playolaMainMixer.mixerNode,
      format: TapProperties.default.format
    )
    trackMixer.outputVolume = 1.0

    // Prepare engine once
    engine.prepare()

    // Kick off download
    Task { @MainActor in
      await startDownloadAndSchedule()
    }
  }

  private func findMixerVolumeParam() -> AUParameter? {
    guard let tree = trackMixer.auAudioUnit.parameterTree else { return nil }
    return tree.allParameters.first(where: {
      $0.identifier.lowercased() == "volume" && $0.flags.contains(.flag_CanRamp)
    }) ?? tree.allParameters.first(where: {
      $0.identifier == "0" && $0.flags.contains(.flag_CanRamp)
    })
      ?? tree.allParameters.first(where: {
        $0.flags.contains(.flag_CanRamp)
      })
  }

  /// Resolve and cache the exact rampable volume parameter we'll use for automation.
  private func installParamObserver() {
    guard paramObserverToken == nil,
      let tree = trackMixer.auAudioUnit.parameterTree
    else { return }

    paramObserverToken = tree.token(byAddingParameterObserver: { [weak self] addr, value in
      // This callback runs on the audio thread when the AU applies a parameter change.
      let ht = mach_absolute_time()
      os_log(
        "🎯 PARAM OBS: addr=%llu -> %.3f atHostTime=%llu",
        log: SingleSpinPlayer.logger, type: .info, addr, value, ht)
    })
  }
  /// Heuristic: prefer the *exact* input bus 0 volume of the trackMixer (this is the one that muted during the sweep),
  /// then explicit "volume", then a rampable "0" whose current value is closest to the node's outputVolume,
  /// then any rampable param with value > 0.5, then fallback to first rampable.
  private func resolveVolumeParam() -> AUParameter? {
    guard let tree = trackMixer.auAudioUnit.parameterTree else { return nil }
    let params = tree.allParameters.filter { $0.flags.contains(.flag_CanRamp) }

    // Prefer the mixer output bus volume
    if let byOutput = params.first(where: { $0.keyPath.lowercased().contains("output.0") }) {
      os_log(
        "🎚️ VOLUME PARAM: chose OUTPUT by keyPath '%{public}@' addr=%llu",
        log: SingleSpinPlayer.logger, type: .info, byOutput.keyPath, byOutput.address)
      self.volumeParam = byOutput
      return byOutput
    }

    // 0) Prefer the *exact* input bus 0 volume of the trackMixer (this is the one that muted during the sweep)
    if let byKeyPathBus0 = params.first(where: { $0.keyPath.lowercased().contains("input.0.0") }) {
      os_log(
        "🎚️ VOLUME PARAM: chose by keyPath '%{public}@' addr=%llu", log: SingleSpinPlayer.logger,
        type: .info, byKeyPathBus0.keyPath, byKeyPathBus0.address)
      self.volumeParam = byKeyPathBus0
      return byKeyPathBus0
    }

    // 1) Prefer explicit "volume"
    if let byName = params.first(where: { $0.identifier.lowercased() == "volume" }) {
      os_log(
        "🎚️ VOLUME PARAM: chose '%{public}@' addr=%llu (by name)", log: SingleSpinPlayer.logger,
        type: .info, byName.identifier, byName.address)
      self.volumeParam = byName
      return byName
    }

    // 2) Prefer '0' whose current value ~ outputVolume
    let target = trackMixer.outputVolume
    if let byZeroNearOut =
      params
      .filter({ $0.identifier == "0" })
      .min(by: { abs(Double($0.value - target)) < abs(Double($1.value - target)) })
    {
      os_log(
        "🎚️ VOLUME PARAM: chose '0' addr=%llu (closest to outputVolume=%.3f, cur=%.3f)",
        log: SingleSpinPlayer.logger, type: .info, byZeroNearOut.address, target,
        byZeroNearOut.value)
      self.volumeParam = byZeroNearOut
      return byZeroNearOut
    }

    // 3) Any rampable with value > 0.5
    if let byValue = params.first(where: { $0.value > 0.5 }) {
      os_log(
        "🎚️ VOLUME PARAM: chose '%{public}@' addr=%llu (value-based cur=%.3f)",
        log: SingleSpinPlayer.logger, type: .info, byValue.identifier, byValue.address,
        byValue.value)
      self.volumeParam = byValue
      return byValue
    }

    // 4) Fallback: first rampable
    if let any = params.first {
      os_log(
        "🎚️ VOLUME PARAM: chose '%{public}@' addr=%llu (fallback)",
        log: SingleSpinPlayer.logger, type: .info, any.identifier, any.address)
      self.volumeParam = any
      return any
    }

    os_log(
      "⚠️ VOLUME PARAM: no rampable parameter found", log: SingleSpinPlayer.logger, type: .error)
    return nil
  }

  public func stop() {
    os_log("🛑 SingleSpinPlayer.stop()", log: SingleSpinPlayer.logger, type: .info)

    if let id = activeDownloadId {
      _ = fileDownloadManager.cancelDownload(id: id)
      activeDownloadId = nil
    }

    if engine.isRunning {
      playerNode.stop()
      playerNode.reset()
    }

    paramMonitorTimer?.invalidate()
    paramMonitorTimer = nil

    // keep engine/mixer graph alive for reuse; no teardown needed
  }

  private func dumpMixerParams(_ whereTag: StaticString) {
    guard let tree = trackMixer.auAudioUnit.parameterTree else {
      os_log("🎚️ PARAMS: no parameter tree", log: SingleSpinPlayer.logger, type: .info)
      return
    }
    os_log(
      "🎚️ PARAMS[%{public}@]: count=%d", log: SingleSpinPlayer.logger, type: .info,
      String(describing: whereTag), tree.allParameters.count)
    for (i, p) in tree.allParameters.enumerated() {
      os_log(
        "  #%d id='%{public}@' addr=%llu canRamp=%{public}@ min=%.2f max=%.2f cur=%.3f",
        log: SingleSpinPlayer.logger, type: .info,
        i, p.identifier, p.address, p.flags.contains(.flag_CanRamp) ? "YES" : "NO", p.minValue,
        p.maxValue, p.value)
    }
  }

  // MARK: - Internals

  private func startDownloadAndSchedule() async {
    guard let remote = spin.audioBlock.downloadUrl else {
      await errorReporter.reportError(
        NSError(
          domain: "SingleSpinPlayer", code: 400,
          userInfo: [NSLocalizedDescriptionKey: "Spin has no download URL"]),
        context: "Missing download URL", level: .error)
      return
    }

    os_log(
      "⬇️ Downloading: %{public}@", log: SingleSpinPlayer.logger, type: .info, remote.absoluteString)

    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      self.activeDownloadId = self.fileDownloadManager.downloadFile(
        remoteUrl: remote,
        progressHandler: { _ in },
        completion: { [weak self] result in
          guard let self else {
            cont.resume()
            return
          }
          switch result {
          case .success(let url):
            self.fileURL = url
            os_log(
              "✅ Downloaded file: %{public}@", log: SingleSpinPlayer.logger, type: .info,
              url.lastPathComponent)
            Task { @MainActor in
              self.scheduleStartInTwoSeconds()
              cont.resume()
            }
          case .failure(let err):
            Task { @MainActor in
              await self.errorReporter.reportError(
                err, context: "SingleSpin download failed", level: .error)
            }
            cont.resume()
          }
        }
      )
    }
  }

  private func scheduleStartInTwoSeconds() {
    guard let url = fileURL else { return }

    do {
      // Ensure engine is running
      if !engine.isRunning {
        playolaMainMixer.configureAudioSession()
        try engine.start()
      }

      let file = try AVAudioFile(forReading: url)

      // Scheme A: schedule at nil, then play(at:)
      playerNode.stop()
      playerNode.scheduleFile(file, at: nil)

      // Host-time 2s from *now*
      let hostNow = engine.outputNode.lastRenderTime?.hostTime ?? mach_absolute_time()
      let delta = AVAudioTime.hostTime(forSeconds: 2.0)
      let when = AVAudioTime(hostTime: hostNow + delta)
      self.scheduledPlayHostTime = when.hostTime

      // Install a render-thread parameter observer once (diagnostics)
      installParamObserver()

      // Debug: dump parameters before play
      dumpMixerParams("pre-play")

      // Install a one-shot tap to capture the *actual* render start on the mixer
      if !startTapInstalled {
        startTapInstalled = true
        didCaptureStart = false
        trackMixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, time in
          guard let self = self else { return }
          // Ensure we only handle the first *valid* callback (after actual start)
          if self.didCaptureStart { return }

          // Only accept callbacks at/after the scheduled play host time
          guard let playHost = self.scheduledPlayHostTime else { return }
          if time.hostTime < playHost {
            // Not started yet; ignore early render callbacks (likely silence preroll)
            return
          }

          // Sanity: require some signal energy to avoid capturing silence
          var hasEnergy = false
          if let ch0 = buffer.floatChannelData?.pointee {
            let n = Int(buffer.frameLength)
            var acc: Float = 0
            if n > 0 {
              for i in 0..<n {
                let s = ch0[i]
                acc += s * s
              }
              let rms = sqrt(acc / Float(n))
              if rms > 1e-6 { hasEnergy = true }
            }
          }
          if !hasEnergy {
            // Still silence; wait for next callback
            return
          }

          self.didCaptureStart = true

          // `time` here is in the mixer's sample domain – capture as start
          let startSample = AUEventSampleTime(time.sampleTime)
          self.scheduledStartSample = startSample
          let sr = self.trackMixer.auAudioUnit.outputBusses[0].format.sampleRate
          os_log(
            "🎯 Captured REAL mixer start sample via tap: %lld (sr=%.0f)",
            log: SingleSpinPlayer.logger, type: .info, startSample, sr)
          // Also capture the hostTime at which playback actually started
          self.startHostTime = time.hostTime

          // Remove tap immediately (one-shot)
          self.trackMixer.removeTap(onBus: 0)
          self.startTapInstalled = false

          // Establish a known baseline at the exact captured host time
          if let volParam = self.volumeParam ?? self.resolveVolumeParam() {
            self.volumeParam = volParam
            volParam.setValue(1.0, originator: nil, atHostTime: time.hostTime)
            os_log(
              "🔧 Set baseline mixer volume=1.0 (addr=%llu) at hostTime=%llu",
              log: SingleSpinPlayer.logger, type: .info, volParam.address, time.hostTime)
          } else {
            os_log(
              "⚠️ No rampable volume param found to set baseline", log: SingleSpinPlayer.logger,
              type: .error)
          }

          // Schedule smooth ramps using sample-time automation (AU scheduleParameterBlock) relative to the captured start sample.
          Task { @MainActor in
            // Smooth ramps (sample-time) relative to captured mixer start sample
            // After we capture start + set baseline:
            self.scheduleStepFade(at: 2.0, duration: 2.0, from: 1.0, to: 0.0, steps: 48)  // down over 2s
            self.scheduleStepFade(at: 4.0, duration: 2.0, from: 0.0, to: 1.0, steps: 48)  // up over 2s
            // After we capture start + set baseline:
            self.scheduleStepFade(at: 6.0, duration: 2.0, from: 1.0, to: 0.0, steps: 48)  // down over 2s
            self.scheduleStepFade(at: 8.0, duration: 2.0, from: 0.0, to: 1.0, steps: 48)  // up over 2s
            self.startParamMonitor()
          }
        }
      }

      os_log(
        "⏱️ Scheduling spin to start in 2.0s (host=%llu)", log: SingleSpinPlayer.logger, type: .info,
        when.hostTime)

      // Resolve & cache the exact parameter instance we'll automate and monitor
      if let p = resolveVolumeParam() {
        os_log(
          "🔎 Will play; USING param '%{public}@' addr=%llu cur=%.3f",
          log: SingleSpinPlayer.logger, type: .info, p.identifier, p.address, p.value)
      } else {
        os_log(
          "⚠️ No rampable param found before play()", log: SingleSpinPlayer.logger, type: .error)
      }

      playerNode.play(at: when)

      // (Removed: scheduleSanityFade to avoid overlapping ramps during the test)
    } catch {
      Task { @MainActor in
        await errorReporter.reportError(
          error, context: "Failed to schedule SingleSpin start", level: .error)
      }
    }
  }

  // Stepwise fade using sample-time scheduling to avoid AU's slow internal ramp.
  private func scheduleFade(
    at offsetSeconds: Double,
    to targetVolume: Float,
    duration: Double = 0.75,
    steps: Int = 24
  ) {
    guard let start = scheduledStartSample,
      let param = volumeParam ?? resolveVolumeParam()
    else {
      os_log(
        "⚠️ scheduleFade skipped — missing start/param", log: SingleSpinPlayer.logger, type: .error)
      return
    }

    let schedule = trackMixer.auAudioUnit.scheduleParameterBlock
    let sr = trackMixer.auAudioUnit.outputBusses[0].format.sampleRate

    // Where the fade should *start* (from song start)
    var startSamples = start + AUEventSampleTime(offsetSeconds * sr)

    // Clamp to a hair in the future if somehow behind
    if let rt = trackMixer.lastRenderTime {
      let nowSample = AUEventSampleTime(rt.sampleTime)
      let guardFrames = AUEventSampleTime(sr * 0.010)  // 10 ms
      if startSamples <= nowSample + guardFrames {
        startSamples = nowSample + guardFrames
        os_log("⏱️ FADE clamped to now+10ms", log: SingleSpinPlayer.logger, type: .info)
      }
    }

    let totalFrames = AUEventSampleTime(duration * sr)
    let stepFrames = max<AUEventSampleTime>(1, totalFrames / AUEventSampleTime(steps))
    let v0 = param.value
    let v1 = AUValue(targetVolume)

    for i in 0...steps {
      // linear steps; switch to log curve if you prefer
      let t = AUEventSampleTime(i) * stepFrames
      let lerp = v0 + (v1 - v0) * AUValue(Double(i) / Double(steps))
      let when = startSamples + t
      // rampFrames = 0 => instantaneous step at exact sample time
      schedule(when, 0, param.address, lerp)
    }

    os_log(
      "🔉 Queued STEP FADE: startSample=%lld → %lld, v=%.3f→%.3f (%d steps)",
      log: SingleSpinPlayer.logger, type: .info,
      startSamples, startSamples + totalFrames, v0, v1, steps)
  }

  private func startParamMonitor() {
    paramMonitorTimer?.invalidate()
    guard let p0 = volumeParam ?? resolveVolumeParam() else {
      os_log("👀 Param monitor: no rampable volume param", log: SingleSpinPlayer.logger, type: .info)
      return
    }
    var last = p0.value
    os_log(
      "👀 Param monitor: watching addr=%llu ('%{public}@'), start=%.3f",
      log: SingleSpinPlayer.logger, type: .info, p0.address, p0.identifier, last)
    paramMonitorTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
      [weak self] _ in
      guard let self = self, let p = self.volumeParam ?? self.resolveVolumeParam() else { return }
      let v = p.value
      if abs(v - last) >= 0.005 {
        os_log(
          "📈 PARAM monitor: %.3f → %.3f (addr=%llu)", log: SingleSpinPlayer.logger, type: .info,
          last, v, p.address)
        last = v
      }
    }
  }

  private func scheduleSanityFade(after secondsFromNow: Double = 3.0) {
    guard engine.isRunning,
      let rt = trackMixer.lastRenderTime,
      let param = volumeParam ?? resolveVolumeParam()
    else {
      os_log(
        "⚠️ Sanity fade skipped — engine/rt/param missing",
        log: SingleSpinPlayer.logger, type: .error)
      return
    }

    let schedule = trackMixer.auAudioUnit.scheduleParameterBlock
    let sr = trackMixer.auAudioUnit.outputBusses[0].format.sampleRate
    let nowSamples = AUEventSampleTime(rt.sampleTime)

    // Down over 0.5s starting (now + secondsFromNow + 0.5)
    let downStart = nowSamples + AUEventSampleTime((secondsFromNow + 0.5) * sr)
    // Up over 0.5s starting (now + secondsFromNow + 1.5)
    let upStart = nowSamples + AUEventSampleTime((secondsFromNow + 1.5) * sr)
    let rampFrames = AUAudioFrameCount(0.5 * sr)

    os_log(
      "🧪 SANITY fade: down@%.1fs, up@%.1fs → samples down=%lld up=%lld",
      log: SingleSpinPlayer.logger, type: .info,
      secondsFromNow + 0.5, secondsFromNow + 1.5, downStart, upStart)

    schedule(downStart, rampFrames, param.address, 0.0)
    schedule(upStart, rampFrames, param.address, 1.0)
  }
  // (Fallback jump helpers removed)

  private func hardCutPropertyToggle() {
    // Control: if this isn’t audible, your mixer isn’t in the signal path.
    trackMixer.outputVolume = 0.0
    os_log(
      "🔨 Property cut: trackMixer.outputVolume = 0.0", log: SingleSpinPlayer.logger, type: .info)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
      self.trackMixer.outputVolume = 1.0
      os_log(
        "🔨 Property cut: trackMixer.outputVolume = 1.0", log: SingleSpinPlayer.logger, type: .info)
    }
  }

  private func bruteForceParamSweep() {
    guard let tree = trackMixer.auAudioUnit.parameterTree else {
      os_log("🧪 Sweep: no parameter tree", log: SingleSpinPlayer.logger, type: .info)
      return
    }
    // Try every candidate that *might* be volume.
    let candidates = tree.allParameters.filter { p in
      let id = p.identifier.lowercased()
      let kp = p.keyPath.lowercased()
      return p.flags.contains(.flag_CanRamp)
        && (id == "0" || id.contains("volume") || kp.contains("/volume"))
    }
    if candidates.isEmpty {
      os_log("🧪 Sweep: no candidate params", log: SingleSpinPlayer.logger, type: .info)
      return
    }
    os_log(
      "🧪 Sweep: testing %d params sequentially", log: SingleSpinPlayer.logger, type: .info,
      candidates.count)

    var delay: Double = 0.5
    for p in candidates {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        let ht = mach_absolute_time()
        os_log(
          "🧪 Sweep: CUT addr=%llu id='%{public}@' keyPath='%{public}@'",
          log: SingleSpinPlayer.logger, type: .info, p.address, p.identifier, p.keyPath)
        p.setValue(0.0, originator: nil, atHostTime: ht)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
          p.setValue(1.0, originator: nil, atHostTime: mach_absolute_time())
          os_log("🧪 Sweep: RESTORE addr=%llu", log: SingleSpinPlayer.logger, type: .info, p.address)
        }
      }
      delay += 0.6
    }
  }
  /// Staggered param punches for known candidates (input.0.0, input.0.1, output.0).
  private func punchKnownCandidatesOnce() {
    guard let tree = trackMixer.auAudioUnit.parameterTree else {
      os_log("🥊 PARAM PUNCH: no parameter tree", log: SingleSpinPlayer.logger, type: .info)
      return
    }

    // Stagger punches so you can clearly hear each one.
    // input.0.0 at +1s, input.0.1 at +4s, output.0 at +7s (each holds 0.6s)
    let params = tree.allParameters
    let cInputL = params.first { $0.keyPath.lowercased().contains("input.0.0") }
    let cInputR = params.first { $0.keyPath.lowercased().contains("input.0.1") }
    let cOutput = params.first { $0.keyPath.lowercased().contains("output.0") }

    if let p = cInputL {
      scheduleParamPunch(p, label: "input.0.0", delaySeconds: 1.0, holdSeconds: 0.6)
    } else {
      os_log("🥊 PARAM PUNCH: missing input.0.0", log: SingleSpinPlayer.logger, type: .info)
    }

    if let p = cInputR {
      scheduleParamPunch(p, label: "input.0.1", delaySeconds: 4.0, holdSeconds: 0.6)
    } else {
      os_log("🥊 PARAM PUNCH: missing input.0.1", log: SingleSpinPlayer.logger, type: .info)
    }

    if let p = cOutput {
      scheduleParamPunch(p, label: "output.0", delaySeconds: 7.0, holdSeconds: 0.6)
    } else {
      os_log("🥊 PARAM PUNCH: missing output.0", log: SingleSpinPlayer.logger, type: .info)
    }
  }

  /// Drop to 0 NOW and restore to 1.0 in 0.5s using host-time scheduling.
  private func immediateParamPunch(_ param: AUParameter, label: String) {
    let nowHT = mach_absolute_time()
    os_log(
      "🥊 PARAM PUNCH NOW: %{public}@ addr=%llu ↓0 now, ↑1 @+0.5s",
      log: SingleSpinPlayer.logger, type: .info, label, param.address)
    param.setValue(0.0, originator: nil, atHostTime: nowHT)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      param.setValue(1.0, originator: nil, atHostTime: mach_absolute_time())
      os_log(
        "🥊 PARAM PUNCH RESTORE: %{public}@ addr=%llu",
        log: SingleSpinPlayer.logger, type: .info, label, param.address)
    }
  }

  /// Schedule a drop to 0 at a future host time and restore after `holdSeconds`.
  /// Uses host-time scheduling (no RunLoop timers) so audio thread executes precisely.
  private func scheduleParamPunch(
    _ param: AUParameter, label: String, delaySeconds: Double, holdSeconds: Double
  ) {
    let nowHT = mach_absolute_time()
    let startHT = nowHT + AVAudioTime.hostTime(forSeconds: delaySeconds)
    let endHT = startHT + AVAudioTime.hostTime(forSeconds: holdSeconds)

    os_log(
      "✳️ PARAM PUNCH SCHEDULE: %{public}@ addr=%llu start@+%.1fs restore@+%.1fs (startHT=%llu, endHT=%llu)",
      log: SingleSpinPlayer.logger, type: .info, label, param.address, delaySeconds,
      delaySeconds + holdSeconds, startHT, endHT)

    // Schedule directly on the parameter at precise host times (no GCD delays needed)
    param.setValue(0.0, originator: nil, atHostTime: startHT)
    param.setValue(1.0, originator: nil, atHostTime: endHT)
  }
  /// Schedule a jump (no ramp) of the chosen volume parameter at a host-time offset from song start.
  private func scheduleHostTimeJump(at offsetSeconds: Double, to targetVolume: Float) {
    guard let startHT = startHostTime else {
      os_log(
        "⚠️ hostTime jump skipped — no startHostTime yet", log: SingleSpinPlayer.logger, type: .error
      )
      return
    }
    guard let p = volumeParam ?? resolveVolumeParam() else {
      os_log(
        "⚠️ hostTime jump skipped — no rampable volume param", log: SingleSpinPlayer.logger,
        type: .error)
      return
    }
    let ht = startHT + AVAudioTime.hostTime(forSeconds: offsetSeconds)
    os_log(
      "⏩ HOST jump → t=%.3fs hostTime=%llu target=%.3f (addr=%llu)",
      log: SingleSpinPlayer.logger, type: .info, offsetSeconds, ht, targetVolume, p.address)
    p.setValue(AUValue(targetVolume), originator: nil, atHostTime: ht)
  }

  private func scheduleHardJump(at offsetSeconds: Double, to targetVolume: Float) {
    guard let start = scheduledStartSample,
      let param = volumeParam ?? resolveVolumeParam()
    else {
      os_log(
        "⚠️ scheduleHardJump skipped — missing start/param",
        log: SingleSpinPlayer.logger, type: .error)
      return
    }
    let schedule = trackMixer.auAudioUnit.scheduleParameterBlock
    let sr = trackMixer.auAudioUnit.outputBusses[0].format.sampleRate
    var whenSamples = start + AUEventSampleTime(offsetSeconds * sr)
    let rampFrames: AUAudioFrameCount = 0

    if let rt = trackMixer.lastRenderTime {
      let nowSample = AUEventSampleTime(rt.sampleTime)
      let guardFrames = AUEventSampleTime(sr * 0.010)
      if whenSamples <= nowSample + guardFrames {
        whenSamples = nowSample + guardFrames
        os_log("⏱️ JUMP clamped to now+10ms", log: SingleSpinPlayer.logger, type: .info)
      }
    }
    os_log(
      "🔉 Queue JUMP → t=%.3fs startSample=%lld target=%.3f (no ramp)",
      log: SingleSpinPlayer.logger, type: .info, offsetSeconds, whenSamples, targetVolume)
    os_log("🔗 Param keyPath='%{public}@'", log: SingleSpinPlayer.logger, type: .info, param.keyPath)
    schedule(whenSamples, rampFrames, param.address, AUValue(targetVolume))
  }

  private func scheduleStepFade(
    at offsetSeconds: Double,
    duration: Double,
    from startValue: Float,
    to endValue: Float,
    steps: Int = 48
  ) {
    guard let start = scheduledStartSample,
      let param = volumeParam ?? resolveVolumeParam()
    else {
      os_log("⚠️ step fade skipped — missing start/param", log: Self.logger, type: .error)
      return
    }

    let sr = trackMixer.auAudioUnit.outputBusses[0].format.sampleRate
    let schedule = trackMixer.auAudioUnit.scheduleParameterBlock

    // step spacing (linear in time; ~every 2s/48 ≈ 41.7ms by default)
    let totalFrames = AUEventSampleTime(duration * sr)
    let framesPerStep = max<AUEventSampleTime>(1, totalFrames / AUEventSampleTime(steps))

    var when = start + AUEventSampleTime(offsetSeconds * sr)

    // safety clamp: don’t schedule in the past
    if let rt = trackMixer.lastRenderTime {
      let nowSample = AUEventSampleTime(rt.sampleTime)
      let guardFrames = AUEventSampleTime(sr * 0.010)
      if when <= nowSample + guardFrames { when = nowSample + guardFrames }
    }

    // queue the steps
    for i in 0...steps {
      // linear curve; swap for equal-power if you prefer:
      // let t = 0.5 * (1 - cos(Double(i)/Double(steps) * .pi))
      let t = Double(i) / Double(steps)
      let v = AUValue(startValue + Float(t) * (endValue - startValue))
      schedule(when + AUEventSampleTime(i) * framesPerStep, 0, param.address, v)
    }

    os_log(
      "🔉 Queued STEP FADE: startSample=%lld → %lld, v=%.3f→%.3f (%d steps)",
      log: Self.logger, type: .info,
      when, when + AUEventSampleTime(steps) * framesPerStep, startValue, endValue, steps)
  }

}
