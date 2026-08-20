import os

/// Shared log channel for the Phase 5 sample-buffer render path. Filter in Console/Xcode by
/// subsystem `fm.playola.playolaCore` category `SampleBuffer` (or `log stream --predicate
/// 'subsystem == "fm.playola.playolaCore" && category == "SampleBuffer"'`).
let sampleBufferLog = Logger(subsystem: "fm.playola.playolaCore", category: "SampleBuffer")
