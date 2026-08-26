# AirPlay 2 migration — remaining work IN THIS REPO (playola-player-swift)

Scope: only the SDK repo. The app-side server-flag integration lives in
`playola-radio-ios` and is explicitly OUT of this plan. "Done" here = the sample-buffer
render path is device-proven, tagged as a pinnable pre-release, and correct enough for
the app to flip on for Sonos / AirPlay-2 long-form.

Context already true (do not redo):
- PR #106 is MERGED into `develop`. The sample-buffer path ships DORMANT (`.legacyEngine`
  default, locks at first `play()`), so merging changed nothing for listeners.
- `CHANGELOG.md` already documents `0.21.0-beta.2`. There is NO in-code version constant —
  SPM consumers pin to git tags, so "version bump" = cut the tag.
- No `beta` tag exists yet (latest tags are 0.20.x).
- The example app (in this repo) has a debug legacy/sample-buffer toggle and is the QA vehicle.
- CI: CircleCI runs `swiftlint_check` + `test` on PRs (verified green on PR #107), so PR
  branches ARE covered. The GitHub Actions workflow (`.github/workflows/ci.yml`) only
  triggers on `main` and nothing runs on tags — so Stage 3/4 must still verify
  `swift test` + `swiftlint --strict` locally at the exact SHA being tagged.
- The new SampleBuffer files already have meaningful unit coverage; the coverage gaps are
  the specific ones named per-stage below, not "add SampleBuffer tests" generically.

---

## Stage 0: Fix the `pruneCache` exclusion bug (SDK, activation blocker) — do FIRST
**Goal**: Make `pruneCache(maxSize:excludeFilepaths:)` actually honor `excludeFilepaths`,
with honest async/throws semantics.
**Why (Codex, upgraded from "nicety" to blocker)**: the implementation at
`FileDownloadManagerAsync.swift:508` ignores `excludeFilepaths` entirely — it fire-and-forgets
`pruneCacheInternal(maxSize:)` inside a `Task {}`, so the `throws` contract is also fake
(errors are silently lost) and completion is racy (caller thinks pruning finished; it hasn't
started). Under cache pressure on a long session it can delete a file that's actively being
decoded → dropout/corruption. **Both backends are affected**: the sample-buffer poll loop
(`PlayolaStationPlayer.swift:925`) and the legacy path (`PlayolaStationPlayer.swift:1209`)
both pass active paths that are ignored.
**Fix shape (Codex consult, 2026-08-20)**:
1. Change `FileDownloadManaging.pruneCache(maxSize:excludeFilepaths:)` to `async throws`.
   Both SDK call sites are already inside async tasks, so this is the smallest honest fix —
   no fire-and-forget, errors propagate to the existing `errorReporter` catch blocks.
2. Implement the exclusion inside the prune loop (skip excluded paths when deleting;
   excluded files' sizes still count toward the total so pressure accounting stays truthful).
   Compare paths in normalized form (`URL(fileURLWithPath:).standardizedFileURL.path`) so
   `/private/var` vs `/var` style mismatches can't silently defeat the exclusion.
3. Await it at both call sites; update `MockFileDownloadManager` to the new signature.
   `FileDownloadManagerAsync` is `@MainActor`, so awaiting also serializes prune against the
   other cache mutations — no new overlapping-prune race is introduced.
**Tests** (all in `swift test`):
- Excluded active file survives a prune under pressure.
- Non-excluded files are still deleted oldest-first and the size target is met (exclusion
  doesn't break the pruning itself).
- Exclusion works when the caller's path form differs from the cache's (normalization).
- A deletion failure propagates as a thrown error to the awaiting caller (no silent loss).
**Success**: Excluded files never pruned; errors reach callers; tests prove all four bullets;
`swift test` + lint green.
**Status**: Complete — PR #107 MERGED into `develop` 2026-08-20 (`e7f74d8`). Tests green
(112+66), lint clean, Codex review pass, CircleCI green, all bot review comments
(Greptile 4/5 + CodeRabbit) fixed/replied/resolved. Bonus fix from review: legacy prune
now runs at spin start (before the scheduling loop) instead of via the cancelled task's
continuation.

## Stage 1: Device QA matrix (T-DEV) — the blocking gate
**Goal**: Prove the sample-buffer backend on real hardware via the example app.
**Why**: Everything unverifiable off-device funnels here; AirPlay-2 was only ever spiked,
never matrix-tested. Nothing downstream (tag, activation) is safe until this passes.
**Steps**:
1. Confirm the example app builds against the SDK-under-test. Verify the pbxproj SPM ref
   and that the uncommitted worktree-local package-path tweak (`..`) is NOT committed;
   a normal checkout must use `../../PlayolaPlayer`.
2. Build to hardware, flip the debug toggle to `.sampleBuffer` (set-before-play, locks on play).
3. Run the matrix. **Split into two correctness classes (Codex)** — fixed-route can pass
   while live route-change (FU-2) still fails, so they are separate rows. Each row below
   now carries objective acceptance criteria (Codex: no "sounds fine to me" rows):

   **Class A — fixed route from launch (gates beta.2):**
   - **Long-form routing**: routes as AirPlay-2 long-form to HomePod, Apple TV, Sonos.
     Evidence = no `-50` session error in logs AND multi-device group selection works from
     the route picker (long-form is what enables grouped targets); capture console logs per
     device as the artifact, not just "audio plays."
   - **Latency parity vs legacy**: defined comparison = same device, same fixed route,
     toggle legacy vs sample-buffer, measure play-tap → first-audio and steady-state
     schedule offset (spin boundary vs wall clock). Parity = within ~250ms of legacy on the
     local route; on AirPlay routes legacy isn't long-form so compare sample-buffer against
     wall-clock schedule truth instead.
   - **Gapless spin boundaries**: use a station/schedule with known boundary times; listen
     for click/gap at ≥3 real boundaries per route AND check the boundary logs
     (`endOfMessageMS` vs acoustic boundary) — acceptance: no audible click/gap, logged
     boundary error within one buffer (~50ms).
   - **Interruption recovery**: host owns the session, so the test is app-driven:
     trigger a real interruption (phone call / Siri / timer alarm) on device; the example
     app's session handling + SDK pause/refill/resume must recover audio within ~2s of the
     interruption ending, state machine back to `.playing`. (A failure here must be triaged
     as app-harness vs SDK before it counts as an SDK defect.)
   - **Memory bounded**: ≥2-hour session on the oldest supported device class available,
     one local + one AirPlay run; acceptance = resident memory plateaus (no monotonic climb
     across the session), no jetsam, and on-disk cache stays ≤ its 50MB cap with active
     files intact (validates Stage 0).

   **Class B — live route switch mid-session (gates beta.3 / FU-2):**
   - Switch local → AirPlay/Sonos mid-song while paired against a second device; measure
     drift (expected ≈ new route's output latency, ~2s) and capture the numbers. Expected
     to FAIL until Stage 4 lands (documented, not a surprise). These measurements are the
     design input for Stage 4.
**Success**: All Class A rows green with their evidence artifacts (or failures captured
with repro for Stage 2). Class B measured and its failure quantified to drive Stage 4.
**Status**: In Progress — agent prep Complete, hardware matrix PENDING (human).
PR #108 MERGED into `develop` 2026-08-20 (`929c2b4`), example-app only:
- QA readout under the toggle: active backend (pending/locked) + current route +
  `outputLatency` in ms, refreshing on `routeChangeNotification` — makes A-latency and
  B1 drift measurable off each device's screen.
- Real pre-existing bug fixed (Greptile P1): station-picker and schedule-viewer play paths
  skipped `setRenderBackend`, silently locking legacy on first play. All four `play()`
  call sites now go through one `prepareForPlay(useSampleBufferRenderer:)` helper.
- `swift test`: 178 green; SwiftLint clean; device-arch build verified.
Runbook for the human session: `.context/stage1-device-qa.md`. B1 DONE (drift ≈ 1983 ms,
iPhone local→AirPlay, matches route-latency delta — Stage 4's design input). One open
low-severity finding: brief one-time stutter as an AirPlay route first engages (triage vs
legacy baseline in Class A). **Target scoping decision (2026-08-20): only Apple TV
available — Class A runs on Apple TV only; beta.2 ships as "device-verified on Apple TV,
HomePod/Sonos expected-compatible but unverified"; Sonos hardware verification moves to
the Stage 4 multi-room session. Stage 3 changelog must carry this scoping.**
**COMPLETE (2026-08-20): A1–A5 all PASS on Apple TV** (latency comp engaged, no `-50`,
survived lock/background, boundaries gapless, interruption recovered, memory bounded).
B1 drift ≈ 1983 ms banked for Stage 4. QA'd SDK SHA: `929c2b4`. Gate 1 device requirement
satisfied under Apple TV scoping. **Evidence caveats (PR #110 review, carried to Stage 4 /
pre-GA):** A5 ran at 30-min scale, not this stage's original ≥2 h dual-route soak — owed
before GA; A2 was a perceptual pass without captured detail — re-run measurably with
Stage 4's FU-2 instrumentation. See `PHASE_5_QA_MATRIX.md`.
Signing note: CLI signing unavailable — run from Xcode GUI (Settings ▸ Accounts), phone
unlocked; ignore the editor-only "No such module 'PlayolaPlayer'" diagnostic.

## Stage 2: Fix whatever the matrix surfaces (SDK)
**Goal**: Close any device-only defects Stage 1 finds.
**Why**: These codepaths (codec priming, session options, latency sign/magnitude,
interruption) are designed but device-unverified; real hardware is the first true test.
**Steps**: Reproduce via the example app, fix in `Sources/PlayolaPlayer/Player/SampleBuffer/`,
keep `swift build` + `swift test` green, re-run the affected matrix rows.
**Regression rule (Codex)**: any fix touching public API, scheduler semantics, the cache,
or renderer lifecycle gets a unit/regression test before beta.2 — "fixed on device" alone
doesn't close a row.
**Known candidate (Codex review, 2026-08-20, pre-existing PR #106 behavior)**: a current
spin with a nil `audioBlock.downloadUrl` is silently dropped in
`SampleBufferPlaybackController` (~line 214); if it's the only current spin, `play()`
publishes `.playing` with silence instead of failing like the legacy path's validation.
Triage during Stage 1/2 — decide fail-fast vs. skip-and-report.
**Success**: Matrix fully green.
**Status**: Skipped — Stage 1 matrix was clean (2026-08-20). Two review-surfaced items
carried forward, NOT device-blocking: (1) nil-`downloadUrl` current spin silently drops
instead of failing like legacy validation (pre-existing #106 behavior; triage fail-fast vs
skip-and-report in beta.3 alongside Stage 4 so the beta.2 tag stays on the QA'd SHA);
(2) one-time route-engage stutter (low severity, settles; re-check during Stage 4 device work).

## Stage 3: Cut the `0.21.0-beta.2` pre-release tag (integration artifact)
**Goal**: Publish a pinnable pre-release at the exact QA-verified commit.
**Why**: The app can only pin a tag; this unblocks the (separate-repo) integration PR.
**Frame beta.2 as an app-integration / fixed-route beta, NOT a marketed multi-room beta (Codex).**
**Steps**:
1. **Fix the changelog wording before tagging (Codex).** The current `0.21.0-beta.2` copy
   advertises "Sonos multi-room" and "cross-device simultaneity" in the same breath as
   long-form, but live route-change sync (FU-2) is knowingly missing. Reword to
   "fixed-route AirPlay-2 long-form / multi-room routing; live route-change simultaneity
   deferred to beta.3."
2. **README/API docs (Codex, was missing from the plan).** Document the host contract for
   `outputLatencyCompensation`: host feeds it (SDK never reads `AVAudioSession`), it is
   read at `play()` for beta.2, and mid-session route-change re-sync is a beta.3 item.
   State the fixed-route limitation wherever the sample-buffer backend is described.
3. Confirm the `0.21.0-beta.2` section matches what actually shipped/was fixed (incl. Stage 0).
4. **Tag the tested SHA, not "develop tip" (Codex).** `develop` can move between QA and
   tagging; the tag goes on the exact commit the Stage 1 matrix ran against (plus the
   changelog/docs commits, which must be re-verified as docs-only). Run `swift test` +
   lint locally at that SHA (CI doesn't cover develop/tags). Push the tag.
**Success**: `0.21.0-beta.2` visible on origin; SwiftPM resolves it; changelog and README
do not overpromise; tagged SHA == QA-verified SHA (+ docs-only commits).
**Status**: Complete (2026-08-20). PR #109 (docs-only: changelog verification-status block
+ pruneCache entry + README render-backends/host-contract section) merged as `2fc4268` —
verified docs-only vs QA'd `929c2b4`. Greptile 5/5; CodeRabbit's one finding (read-at-play()
wording overstated timing) fixed + 👍'd. `swift test` (178) + `swiftlint --strict` (0) run
locally at `2fc4268`. Annotated tag `0.21.0-beta.2` pushed at `2fc4268`. **Gate 1 is DONE —
the app can pin the tag and open its integration PR.**

## Stage 4: FU-2 — route-change latency re-compensation (SDK, multi-room correctness)
**Goal**: Re-apply the new route's output latency on a mid-session route switch so devices
stay in sync when the route changes live (local → AirPlay, ~18ms → ~2000ms).
**Why**: Start-time compensation covers two fixed-route devices, but a device that switches
route mid-song drifts until the next `play()`. This is the real remaining Sonos multi-room gap.
**Scope honesty (Codex consult, 2026-08-20 — this is bigger than one hook):**
- The "re-read outputLatency on `recoverAfterAutoFlush`" framing assumed a seam that
  doesn't exist: `outputLatencyCompensation` is only read when the controller is
  constructed (baked into `latencyFrames`/renderer `startFrame`), and the auto-flush path
  (`LiveSampleBufferSink.onAutoFlush` → `recoverAfterAutoFlush`) never touches the host's
  latency value.
- Latency is baked into multiple invariants: mapper math, renderer write cursor /
  timebase lead, boundary-observer times, already-scheduled source windows. A live delta
  needs a coherent (generation-style) update or a controlled pipeline re-anchor — not a
  point patch — or we fix sync while breaking spin-boundary callbacks.
- **Public API decision needed**: the SDK never observes `AVAudioSession`, so the host
  must be able to deliver the NEW route's latency at recovery time. Options: a
  `updateOutputLatencyCompensation(_:)` that re-anchors, or a host-provided
  `currentOutputLatencyProvider` closure consulted during recovery. Relying on the host
  having mutated a property before the flush callback fires is an unstated race — don't.
**Steps**: Run a dedicated Codex consult on the seam design when this stage starts (inputs:
Stage 1 Class B drift measurements). Implement, then verify with two devices + a live
switch on hardware. Ship as `0.21.0-beta.5` (same tag discipline as Stage 3; see tag note below).
**Success**: Two devices stay in sync across a live route switch on hardware; re-anchor
discontinuity measured and acceptable; boundary callbacks still fire correctly.
**Status**: Not Started
**Sequencing note**: NOT a blocker for beta.2 — beta.2 ships first (strictly labeled
fixed-route) so the app integrates in parallel; beta.3 is where "Sonos multi-room" becomes
a truthful marketed claim.

**Tag note (2026-08-24)**: the `.sampleBuffer` backend's missing `.loading(progress)`
reporting during initial download (unrelated to FU-2 — a small seam fix on
`SampleBufferPlaybackController`/`PlayolaStationPlayer`, not a route-latency change) shipped
ahead of this stage as `0.21.0-beta.3`. A second unrelated seam fix — the startup deadline
incorrectly publishing `.playing` during its silent pre-decode hole, also on
`SampleBufferPlaybackController` — shipped next as `0.21.0-beta.4`. FU-2's own tag is
therefore `0.21.0-beta.5` — keep the tag discipline above.

## Stage 5 (post-activation, in-repo, non-blocking): optimizations
**Goal**: Round out the render path once it's live behind the flag. Neither gates AirPlay-2 correctness.
- **FU-1** — streaming download / time-to-first-audio (first-spin latency only; own task:
  streaming decoder + range fetch, keep legacy download path intact). *Not a blocker unless
  first-spin full-download latency fails product QA (Codex).*
- **FU-3** — reschedule surgery for changed already-enqueued windows. *Blocker-or-not depends
  on a server-side fact, not hope (Codex): confirm production schedules do NOT mutate spins
  inside the ~1s enqueue horizon. **This verification lives outside this repo** (playola API) —
  record the answer (query/date/result) here as an explicit input; the in-repo decision
  (defer vs. fix) is blocked until that artifact exists. If schedules CAN mutate inside the
  horizon, FU-3 becomes a correctness blocker before GA activation.*
**Success**: Tracked; FU-3's deferral explicitly justified by the recorded server-side check.
**Status**: Not Started

---

## Definition of done — TWO gates (Codex)
- **Gate 1 — App-integration ready:** Stage 0 fixed (with tests), Class A (fixed-route)
  matrix green with evidence, changelog + README reworded to fixed-route, `0.21.0-beta.2`
  tagged on the QA-verified SHA. The app can pin and flip the flag for fixed-route long-form.
- **Gate 2 — SDK migration done:** Stage 4 (FU-2) landed with its host-latency seam,
  Class B (live route-switch) matrix green, `0.21.0-beta.3` tagged. Only now is
  "Sonos multi-room" a truthful claim.

The app-side flag rollout and graduation from `beta` to a real `0.21.0` happen outside this
repo / after production soak. FU-3's server-side verification is the one external input this
plan depends on (Stage 5).
