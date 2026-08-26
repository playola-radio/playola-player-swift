# Phase 5 — deferred follow-ups

Tracked work intentionally left out of the sample-buffer render path slice-1 (see `PHASE_5_PLAN.md` §7
"OUT"). None of these block the current device QA; they are the next optimizations once the AirPlay
matrix passes.

## FU-1 — Stream the download / start on partial bytes (time-to-first-audio)

**What:** Today a spin's audio is fully downloaded before playback: `SampleBufferPlaybackController`
calls `FileDownloadManaging.downloadFileAsync` (which returns a *complete* local file), then
`SpinBufferSource` opens it with `AVAudioFile`. The **decode** side already starts partial — playback
begins after the first ~2s of read-ahead decodes, not the whole file — but the **download** is the
latency floor for the *first* spin.

**Goal:** begin playback as soon as enough bytes have arrived, instead of waiting for the whole file.

**Why it's not trivial (its own task, not a bolt-on):**
- `AVAudioFile` needs a complete, valid file. `.m4a`/AAC commonly stores its `moov` index atom at the
  *end*, so the front can't be decoded until the whole file lands unless it's faststart-encoded.
- `FileDownloadManaging` yields finished files, not a byte stream (also used by the legacy path — don't
  destabilize it).
- Needs a streaming decoder: `AudioFileStream`/`ExtAudioFile`, or `AVAssetReader` over a
  progressively-loading `AVURLAsset` (`AVAssetResourceLoaderDelegate`), plus HTTP range / progressive
  fetch. Format-dependent (MP3 streams from the front; M4A needs faststart or range-to-`moov`).

**Scope:** mainly helps the *first* spin (the rolling ones are already buffered ahead). Design the
streaming decoder + download-layer change independently; keep the legacy download path intact.

## FU-2 — Route-change latency re-compensation (multi-device sync during a live route switch)

**What:** Cross-device simultaneity is handled at **play start** via output-latency compensation (each
device shifts its anchor by its own `AVAudioSession.outputLatency`; host-fed since the SDK can't read
the session). See `PlayolaStationPlayer.outputLatencyCompensation`.

**Gap:** if the route changes *mid-session* (e.g. local speaker → AirPlay), the presentation latency
jumps (~18 ms → ~2000 ms). The auto-flush recovery (`recoverAfterAutoFlush`) rejoins at the playhead but
does **not** re-apply the new route's latency, so a device that switches routes mid-song will be
mis-compensated by the latency delta until the next play().

**Goal:** on the route-change auto-flush, re-read the host's current `outputLatency` and re-anchor with
the updated compensation, so devices stay in sync across a live route switch.

**Why deferred:** correct sign/magnitude and the re-anchor discontinuity are **device-measured**
(needs two devices + a route switch). The start-time compensation already covers the common test
(two devices each on a fixed route from the start).

## FU-3 — Rescheduling surgery for changed already-enqueued windows

Slice-1 dynamic schedule only handles the cheap **append** (a new spin beyond the write cursor). A
change to a spin whose audio is **already enqueued** (inside the ~1s shallow queue) is logged and
ignored (`onLateSpinIgnored`). Full handling = flush-tail + re-anchor + rebuild from the current
playhead under a new internal render generation (`PHASE_5_PLAN.md` §7 OUT, C2). Rare in practice
(changes land minutes out); revisit only if real schedules mutate inside the enqueue horizon.
