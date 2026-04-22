# Streaming Player Approach (0.15.0)

This documents the AVPlayer-based streaming approach that was introduced in 0.15.0 and subsequently reverted. The code for this approach lives in the `0.15.0` git tag.

## Overview

The streaming approach replaces the download-first model with AVPlayer's native HTTP streaming. Instead of downloading an entire audio file before playback begins, it starts playback as soon as AVPlayer buffers enough data — typically under 1 second.

## Architecture

### Key Classes

#### StreamingStationPlayer (Orchestrator)
`Sources/PlayolaPlayer/Player/Streaming/StreamingStationPlayer.swift`

- Top-level controller for streaming a Playola station
- Fetches the schedule via `ScheduleService.getSchedule()`
- Manages a dictionary of `StreamingSpinPlayer` instances keyed by spin ID
- Polls the schedule every 20 seconds, loading spins within a 10-minute lookahead window
- Handles audio interruptions (headphone disconnect, phone calls) on iOS/tvOS
- Publishes state: `.idle`, `.loading`, `.playing(Spin)`

#### StreamingSpinPlayer (Per-Spin Playback)
`Sources/PlayolaPlayer/Player/Streaming/StreamingSpinPlayer.swift`

- Manages playback of a single spin using AVPlayer
- State machine: `available → loading → loaded → playing → finished`
- Two playback modes:
  - `playNow(from offsetSeconds:)` — for the currently-airing spin, seeks to the right position and plays immediately
  - `schedulePlay(at date:)` — for upcoming spins, sets a timer to begin playback at the exact airtime
- Runs a fade timer at ~33ms intervals to apply volume automation

#### AVPlayerProviding (Protocol)
`Sources/PlayolaPlayer/Player/Streaming/AVPlayerProviding.swift`

- Protocol wrapping AVPlayer for testability
- `AVPlayerWrapper` implementation creates an AVPlayer with `automaticallyWaitsToMinimizeStalling = true`
- Wraps AVPlayer's callback-based APIs with async/await using `withCheckedThrowingContinuation`

#### FadeScheduleBuilder (Volume Automation)
`Sources/PlayolaPlayer/Player/Streaming/FadeScheduleBuilder.swift`

- Generates discrete volume interpolation steps from a spin's fade array
- Each fade is expanded into 48 steps over 1500ms (linear interpolation)
- Produces a `[FadeStep]` array sorted by time
- Helper methods: `volumeAtMS(_:in:startingVolume:)` for initial volume calculation, `firstUnprocessedIndex(in:afterMS:)` for resuming mid-fade

#### ScheduleService
`Sources/PlayolaPlayer/Player/ScheduleService.swift`

- Fetches and parses station schedules from the Playola API (`/v1/stations/{id}/schedule`)
- Shared between streaming and download players

## How It Works

### Playback Flow

1. `play(stationId:)` is called on `StreamingStationPlayer`
2. Schedule is fetched; the currently-airing spin is identified
3. A `StreamingSpinPlayer` is created for that spin
4. `player.load(spin)` creates an AVPlayerItem from the spin's download URL and waits for `.readyToPlay`
5. The fade schedule is pre-built during loading
6. Based on timing:
   - **Currently playing**: `playNow(from: elapsedSeconds)` seeks to the right offset and starts immediately
   - **Future spin**: `schedulePlay(at: airtime)` defers playback via timer
7. A polling loop runs every 20 seconds, loading upcoming spins within a 10-minute window

### Fade/Volume Handling

- Fades are pre-calculated into discrete steps during the load phase
- A 33ms timer continuously reads the current playback position and applies the appropriate volume
- When starting mid-spin, `volumeAtMS()` determines the correct initial volume
- Each spin manages its own fade schedule independently (no true crossfading between spins)

### Spin Lifecycle

- Spin loads → buffers → plays → cleanup timer fires at `endtime + 1s` → removed from player dictionary

## Comparison: Streaming vs Download

| Aspect | Streaming (0.15.0) | Download (0.14.0) |
|--------|-------------------|-------------------|
| Startup latency | ~1 second | Full file download time |
| Audio engine | AVPlayer | AVAudioEngine |
| State feedback | `.loading` (no progress) | `.loading(Float)` with download % |
| File storage | Streaming buffer only | Full file cached to disk |
| Network handling | AVPlayer manages buffering/reconnects | Manual download with retry |
| Fade application | Timer-based volume on AVPlayer | Integrated in audio engine mixing |
| Spin pre-loading | Parallel within 10-min window | Sequential |

## Why It Was Reverted

The streaming approach was a port that introduced issues. The 0.14.0 download-based approach remains the stable working version.

## Retrieving the Code

```bash
# View the streaming code
git show 0.15.0:Sources/PlayolaPlayer/Player/Streaming/StreamingStationPlayer.swift

# Check out the full 0.15.0 state
git checkout 0.15.0

# Or diff to see what was added
git diff 0.14.0 0.15.0
```
