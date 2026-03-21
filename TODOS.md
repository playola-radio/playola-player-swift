# TODOs

## P2: Buffering UI indicator
Surface stall/unstall events from StreamingSpinPlayer to StreamingStationPlayer.State
(e.g., add a `.buffering` case) so the UI can show a buffering indicator during network
stalls. The onStall/onUnstall callback infrastructure is built as part of the host-time
sync work — this TODO is about surfacing it to the UI layer.

**Effort**: S (human) → XS (CC)
**Depends on**: Host-time-synced streaming playback (this branch)
**Context**: With automaticallyWaitsToMinimizeStalling=false, AVPlayer won't show its
built-in buffering behavior. Users hear silence with no visual feedback during stalls.

## P3: Server-side audio normalization
Pre-normalize audio files to a target LUFS during upload/ingest on the backend.
Currently, the AVAudioEngine-based player applies client-side normalization via
`AVAudioUnitEQ.globalGain` (±24dB). The new streaming player and web player skip
normalization entirely. Server-side pre-normalization would solve loudness consistency
for all clients permanently.

**Effort**: L (human) → M (CC)
**Depends on**: Backend audio pipeline access
**Context**: Added during streaming player implementation (2026-03-20). The streaming
player (AVPlayer-based) cannot do client-side normalization because AVPlayer doesn't
connect to AVAudioEngine. The web player also doesn't normalize. This is the clean
long-term solution.
