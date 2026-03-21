# TODOs

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
