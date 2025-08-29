# PlayolaPlayer

A Swift audio player library for iOS that provides streaming radio capabilities for the Playola platform.

## Overview

PlayolaPlayer is a Swift Package Manager library that handles audio streaming, scheduling, caching, and playback for Playola radio stations. It downloads and plays audio files in the right order with smooth transitions to make them sound like a continuous radio stream.

## Features

- Stream audio from Playola radio stations
- Schedule audio files to play at specific times
- Cache files locally with automatic cleanup
- Normalize audio volume levels
- Smooth transitions and crossfades between audio files
- Error reporting and logging
- Swift Concurrency (async/await)
- Combine publishers for reactive programming
- Delegate pattern support
- Play from any point in time (historical playback)
- Volume fading and mixing

## Requirements

- iOS 17.0+
- Swift 5.10+
- Xcode 16.2+

## Installation

### Swift Package Manager

To integrate PlayolaPlayer into your Xcode project using Swift Package Manager:

1. In Xcode, select **File > Add Package Dependencies...**
2. Enter the repository URL: `https://github.com/your-organization/PlayolaPlayer.git`
3. Specify the version requirements (recommended: exact version or from version)
4. Click **Add Package**

Or add it directly to your `Package.swift` file:

```swift
dependencies: [
    .package(url: "https://github.com/your-organization/PlayolaPlayer.git", from: "1.0.0")
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: ["PlayolaPlayer"]),
]
```

## Usage

### Quick Start

The simplest way to get started with PlayolaPlayer:

```swift
import PlayolaPlayer

// 1. Configure the player (required)
PlayolaStationPlayer.shared.configure(authProvider: myAuthProvider)

// 2. Start playing a station (async function)
Task {
    try await PlayolaStationPlayer.shared.play(stationId: "your-station-id")
}

// 3. Stop playback when done (synchronous function)
PlayolaStationPlayer.shared.stop()
```

### Configuration

Before using PlayolaPlayer, you need to configure it with an authentication provider. You can also optionally specify a custom base URL for development or staging environments:

```swift
import PlayolaPlayer

// Production configuration (default)
PlayolaStationPlayer.shared.configure(authProvider: myAuthProvider)

// Local development configuration
PlayolaStationPlayer.shared.configure(
    authProvider: myAuthProvider,
    baseURL: URL(string: "http://localhost:3000")!
)

// Staging environment configuration
PlayolaStationPlayer.shared.configure(
    authProvider: myAuthProvider,
    baseURL: URL(string: "https://staging-api.playola.fm")!
)
```

### Authentication Setup

To use authenticated features (like listening session reporting), implement the `PlayolaAuthenticationProvider` protocol:

```swift
import PlayolaPlayer

class MyAuthProvider: PlayolaAuthenticationProvider {
    func getCurrentToken() async -> String? {
        // Return the current user's JWT token
        return UserDefaults.standard.string(forKey: "userToken")
    }
    
    func refreshToken() async -> String? {
        // This is called automatically when receiving 401 responses
        return await getNewAuthTokenFromServer() // your refresh logic here
    }
}

// Configure the player with authentication
let authProvider = MyAuthProvider()
PlayolaStationPlayer.shared.configure(authProvider: authProvider)
```

### Basic Playback Control

The main interface for controlling playback:

```swift
import PlayolaPlayer

let player = PlayolaStationPlayer.shared

// Start playing a station
Task {
    do {
        try await player.play(stationId: "your-station-id")
    } catch {
        print("Failed to play station: \(error)")
    }
}

// Play from a specific point in time (historical playback)
Task {
    let oneHourAgo = Date().addingTimeInterval(-3600)
    try await player.play(stationId: "your-station-id", atDate: oneHourAgo)
}

// Stop playback
player.stop()

// Check current status
if player.isPlaying {
    print("Currently playing station: \(player.stationId ?? "unknown")")
}
```

### State Observation with Combine

PlayolaPlayer provides Combine publishers for reactive programming:

```swift
import PlayolaPlayer
import Combine

class PlayerViewModel: ObservableObject {
    @Published var nowPlaying: String = "Nothing playing"
    @Published var isLoading: Bool = false
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        // Subscribe to state changes
        PlayolaStationPlayer.shared.$state
            .sink { [weak self] state in
                switch state {
                case .idle:
                    self?.nowPlaying = "Nothing playing"
                    self?.isLoading = false
                case .loading(let progress):
                    self?.nowPlaying = "Loading... \(Int(progress * 100))%"
                    self?.isLoading = true
                case .playing(let spin):
                    self?.nowPlaying = "\(spin.audioBlock.title) by \(spin.audioBlock.artist)"
                    self?.isLoading = false
                }
            }
            .store(in: &cancellables)
        
        // Subscribe to station changes
        PlayolaStationPlayer.shared.$stationId
            .compactMap { $0 }
            .sink { stationId in
                print("Now playing station: \(stationId)")
            }
            .store(in: &cancellables)
    }
}
```

### SwiftUI Integration

Complete example of PlayolaPlayer in SwiftUI:

```swift
import SwiftUI
import PlayolaPlayer

struct PlayerView: View {
    @StateObject private var player = PlayolaStationPlayer.shared
    @State private var stationId = ""
    
    var body: some View {
        VStack(spacing: 20) {
            // Station input
            TextField("Station ID", text: $stationId)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding(.horizontal)
            
            // Play/Stop button
            Button(action: togglePlayback) {
                Label(
                    player.isPlaying ? "Stop" : "Play",
                    systemImage: player.isPlaying ? "stop.fill" : "play.fill"
                )
                .frame(width: 120)
            }
            .buttonStyle(.borderedProminent)
            .disabled(stationId.isEmpty && !player.isPlaying)
            
            // Current state display
            VStack {
                Text("Status:")
                    .font(.headline)
                
                switch player.state {
                case .idle:
                    Text("Not playing")
                        .foregroundColor(.secondary)
                case .loading(let progress):
                    ProgressView(value: progress)
                        .progressViewStyle(LinearProgressViewStyle())
                    Text("Loading... \(Int(progress * 100))%")
                case .playing(let spin):
                    VStack(spacing: 5) {
                        Text(spin.audioBlock.title)
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text(spin.audioBlock.artist)
                            .foregroundColor(.secondary)
                        if let album = spin.audioBlock.album {
                            Text(album)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(10)
            .padding(.horizontal)
            
            Spacer()
        }
        .padding(.top)
    }
    
    func togglePlayback() {
        if player.isPlaying {
            player.stop()
        } else {
            Task {
                do {
                    try await player.play(stationId: stationId)
                } catch {
                    print("Playback error: \(error)")
                }
            }
        }
    }
}
```

### Delegate Pattern for UIKit

For UIKit applications or when you prefer delegate patterns:

```swift
import UIKit
import PlayolaPlayer

class PlayerViewController: UIViewController {
    private let player = PlayolaStationPlayer.shared
    
    override func viewDidLoad() {
        super.viewDidLoad()
        player.delegate = self
    }
}

extension PlayerViewController: PlayolaStationPlayerDelegate {
    func player(_ player: PlayolaStationPlayer, 
                playerStateDidChange state: PlayolaStationPlayer.State) {
        DispatchQueue.main.async { [weak self] in
            switch state {
            case .idle:
                self?.updateUI(title: "Not Playing", subtitle: nil)
            case .loading(let progress):
                self?.updateUI(title: "Loading...", 
                             subtitle: "\(Int(progress * 100))%")
            case .playing(let spin):
                self?.updateUI(title: spin.audioBlock.title, 
                             subtitle: spin.audioBlock.artist)
                
                // Access additional metadata
                if let duration = spin.audioBlock.durationMS {
                    print("Duration: \(duration / 1000) seconds")
                }
                
                if let imageUrl = spin.audioBlock.imageUrl {
                    self?.loadAlbumArt(from: imageUrl)
                }
            }
        }
    }
    
    private func updateUI(title: String, subtitle: String?) {
        // Update your UI elements
    }
    
    private func loadAlbumArt(from url: URL) {
        // Load and display album artwork
    }
}
```

### Working with Audio Metadata

Access detailed metadata from the currently playing content:

```swift
if case .playing(let spin) = PlayolaStationPlayer.shared.state {
    let audioBlock = spin.audioBlock
    
    // Basic metadata
    print("Title: \(audioBlock.title)")
    print("Artist: \(audioBlock.artist)")
    print("Album: \(audioBlock.album ?? "Unknown")")
    print("Type: \(audioBlock.type)")
    
    // Timing information (in milliseconds)
    print("Duration: \(audioBlock.durationMS / 1000) seconds")
    print("End of message: \(audioBlock.endOfMessageMS / 1000) seconds")
    print("Outro starts: \(audioBlock.beginningOfOutroMS / 1000) seconds")
    print("Intro ends: \(audioBlock.endOfIntroMS / 1000) seconds")
    
    // Additional metadata
    print("Created: \(audioBlock.createdAt)")
    if let spotifyId = audioBlock.spotifyId {
        print("Spotify ID: \(spotifyId)")
    }
    if let transcription = audioBlock.transcription {
        print("Transcription: \(transcription)")
    }
    
    // Spin-specific information
    print("Scheduled airtime: \(spin.airtime)")
    print("Starting volume: \(spin.startingVolume)")
    if let relatedTexts = spin.relatedTexts {
        for text in relatedTexts {
            print("Related: \(text.title) - \(text.body)")
        }
    }
}
```

### Error Handling

PlayolaPlayer provides comprehensive error handling:

```swift
import PlayolaPlayer

class ErrorHandler: PlayolaErrorReporterDelegate {
    init() {
        // Configure error reporting
        PlayolaErrorReporter.shared.delegate = self
        PlayolaErrorReporter.shared.reportingLevel = .error
        PlayolaErrorReporter.shared.logToConsole = true
    }
    
    func playolaDidEncounterError(_ error: Error,
                                 sourceFile: String,
                                 sourceLine: Int,
                                 function: String,
                                 stackTrace: String) {
        switch error {
        case let stationError as StationPlayerError:
            handleStationPlayerError(stationError)
        case let downloadError as FileDownloadError:
            handleDownloadError(downloadError)
        case let sessionError as ListeningSessionError:
            handleSessionError(sessionError)
        default:
            print("Playola Error: \(error.localizedDescription)")
            print("Location: \(sourceFile):\(sourceLine) in \(function)")
        }
    }
    
    private func handleStationPlayerError(_ error: StationPlayerError) {
        switch error {
        case .networkError(let message):
            showAlert(title: "Network Error", message: message)
        case .scheduleError(let message):
            showAlert(title: "Schedule Error", message: message)
        case .playbackError(let message):
            showAlert(title: "Playback Error", message: message)
        case .invalidStationId(let id):
            showAlert(title: "Invalid Station", message: "Station ID '\(id)' not found")
        case .fileDownloadError(let message):
            showAlert(title: "Download Error", message: message)
        }
    }
    
    private func handleDownloadError(_ error: FileDownloadError) {
        switch error {
        case .downloadCancelled:
            break // User cancelled - no action needed
        case .invalidRemoteURL(let url):
            print("Invalid URL: \(url)")
        case .downloadFailed(let message):
            showAlert(title: "Download Failed", message: message)
        case .directoryCreationFailed:
            showAlert(title: "Storage Error", message: "Could not create cache directory")
        case .fileMoveFailed:
            showAlert(title: "Storage Error", message: "Could not save downloaded file")
        case .fileNotFound:
            showAlert(title: "File Error", message: "Audio file not found")
        case .cachePruneFailed(let message):
            print("Cache pruning failed: \(message)")
        case .unknownError(let message):
            showAlert(title: "Unknown Error", message: message)
        }
    }
    
    private func handleSessionError(_ error: ListeningSessionError) {
        switch error {
        case .missingDeviceId:
            print("Device ID not available")
        case .networkError(let message):
            print("Session network error: \(message)")
        case .invalidResponse(let message):
            print("Invalid session response: \(message)")
        case .encodingError(let message):
            print("Session encoding error: \(message)")
        case .authenticationFailed(let message):
            print("Session auth failed: \(message)")
        }
    }
    
    private func showAlert(title: String, message: String) {
        // Show alert to user
    }
}

// Configure error reporting levels
PlayolaErrorReporter.shared.reportingLevel = .debug // Reports everything

// Available levels:
// .none     - No reporting
// .critical - Only critical errors
// .error    - Errors and critical (default)
// .warning  - Warnings and above
// .debug    - All messages

// Report custom errors
error.playolaReport(context: "Custom operation failed", level: .warning)
```

### Audio Session Management

PlayolaPlayer automatically manages audio sessions, but you can customize the behavior:

```swift
import AVFoundation

// Handle interruptions (phone calls, alarms, etc.)
NotificationCenter.default.addObserver(
    forName: AVAudioSession.interruptionNotification,
    object: nil,
    queue: .main
) { notification in
    PlayolaStationPlayer.shared.handleAudioSessionInterruption(notification)
}

// Handle route changes (headphones plugged/unplugged)
NotificationCenter.default.addObserver(
    forName: AVAudioSession.routeChangeNotification,
    object: nil,
    queue: .main
) { notification in
    PlayolaStationPlayer.shared.handleAudioRouteChange(notification)
}
```

### File Download Management

Work with the file download and caching system:

```swift
let downloadManager = FileDownloadManagerAsync.shared

// Check cache status
let cacheSize = downloadManager.currentCacheSize()
print("Current cache size: \(cacheSize / 1024 / 1024) MB")

// Check if file exists locally
let fileExists = downloadManager.fileExists(for: audioURL)

// Get local URL for remote file
let localURL = downloadManager.localURL(for: audioURL)

// Clear entire cache
try downloadManager.clearCache()

// Prune cache with size limit
try downloadManager.pruneCache(maxSize: 100 * 1024 * 1024, excludeFilepaths: [])

// Check available disk space
if let availableSpace = downloadManager.availableDiskSpace() {
    print("Available disk space: \(availableSpace / 1024 / 1024) MB")
}
```

## How It Works

PlayolaPlayer makes separate audio files sound like a continuous radio stream by coordinating multiple components. Here's how it works:

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    PlayolaStationPlayer                        │
│                   (Main Coordinator)                           │
├─────────────────────────────────────────────────────────────────┤
│ ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────────┐ │
│ │   SpinPlayer    │ │   SpinPlayer    │ │   SpinPlayer        │ │
│ │   (Current)     │ │   (Next)        │ │   (Future)          │ │
│ └─────────────────┘ └─────────────────┘ └─────────────────────┘ │
├─────────────────────────────────────────────────────────────────┤
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │              PlayolaMainMixer                               │ │
│ │            (AVAudioEngine Coordinator)                     │ │
│ └─────────────────────────────────────────────────────────────┘ │
├─────────────────────────────────────────────────────────────────┤
│ ┌───────────────┐ ┌───────────────┐ ┌─────────────────────────┐ │
│ │   Schedule    │ │  Download     │ │   Error Reporter        │ │
│ │   Manager     │ │   Manager     │ │   & Analytics           │ │
│ └───────────────┘ └───────────────┘ └─────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

### Key Components and Their Roles

#### 1. PlayolaStationPlayer - The Main Coordinator
The main coordinator that handles the streaming:
- Fetches station schedules from the Playola API
- Manages multiple SpinPlayer instances that handle individual audio files
- Coordinates timing to ensure smooth transitions between audio files
- Handles state management and provides the API to your app

#### 2. Schedule System - Timeline Management
Each station has a schedule that defines what plays when:
- Spins represent individual audio files with timing information
- AudioBlocks contain the actual audio files plus metadata (title, artist, duration)
- Timing markers like `endOfMessageMS` and `beginningOfOutroMS` enable crossfading
- Historical playback works by adjusting the schedule offset

#### 3. SpinPlayer Pool - Multiple Players Working Together
Multiple SpinPlayer instances work together for continuous playback:
- Current player handles the actively playing audio
- Next players pre-load and prepare upcoming audio files
- Automatic scheduling ensures each audio file starts at the right time
- Volume fading creates smooth transitions between different sources

#### 4. Download System - File Management
File management ensures smooth playback:
- Downloads upcoming audio files before they're needed
- Automatic retry with exponential backoff for failed downloads
- Cache management with size limits and automatic cleanup
- Cancel and restart capability for changing stations

#### 5. Audio Engine - Sound Processing
Built on AVAudioEngine for audio processing:
- Real-time mixing of multiple audio sources
- Volume control and fading between tracks
- Audio normalization for consistent volume levels
- Session management for handling interruptions and route changes

### How Separate Files Become Continuous Radio

The key to making separate audio files sound like continuous radio:

#### 1. **Pre-loading Files**
```swift
// Look ahead in the schedule and download upcoming files
let upcomingSpins = schedule.current().filter { $0.airtime < .now + 600 } // Next 10 minutes
for spin in upcomingSpins {
    if !isScheduled(spin: spin) {
        try await scheduleSpin(spin: spin) // Download and prepare
    }
}
```

#### 2. **Timing Coordination**
Each audio file contains timing markers that enable crossfading:
- `endOfMessageMS`: When the main content ends (start crossfade here)
- `beginningOfOutroMS`: When the outro begins (overlap new content)
- `endOfIntroMS`: When the intro ends (full volume transition complete)

#### 3. **Multiple Players Working Together**
```swift
// Multiple SpinPlayer instances work in coordination
let currentPlayer = getAvailableSpinPlayer() // Playing now
let nextPlayer = getAvailableSpinPlayer()    // Loading next
let futurePlayer = getAvailableSpinPlayer()  // Preparing future

// Each handles a different time slice of the continuous stream
```

#### 4. **Smooth Transitions**
The system creates smooth transitions through:
- Volume fading: Gradual volume changes at transition points
- Precise timing: Audio files start exactly when scheduled
- Buffer management: Pre-loaded content prevents gaps
- Error recovery: Automatic retry and fallback for failed content

#### 5. **Adapting to Conditions**
The system adapts to changing conditions:
- Network issues: Retry downloads with exponential backoff
- Schedule updates: Fetch new content as it becomes available
- Playback position: Track exactly where we are in the stream
- Cache management: Remove old files while preserving upcoming content

### State Management Flow

```
[User calls play()] 
        ↓
[Fetch station schedule]
        ↓
[Find current audio block]
        ↓
[Download and prepare first audio] → [State: .loading(progress)]
        ↓
[Start playback] → [State: .playing(spin)]
        ↓
[Pre-load next audio blocks]
        ↓
[Monitor for transitions]
        ↓
[Seamlessly switch to next block]
        ↓
[Continue cycle...]
```

### Historical Playback

You can play from any point in time:

```swift
// Playing "as if" it were 1 hour ago
let oneHourAgo = Date().addingTimeInterval(-3600)
try await player.play(stationId: "station-id", atDate: oneHourAgo)
```

This works by:
1. Calculate how far back in time to play
2. Shift all air times by the offset amount
3. Find what would have been playing at that time
4. Use the regular playback system with adjusted timing

This lets you listen to the radio as it was broadcasting in the past, with proper timing and transitions.

### Error Recovery

The system handles network issues:

- Progressive retry: Failed downloads are retried with increasing delays
- Alternative content: If content fails to load, continue with available content
- State recovery: Interruptions (calls, notifications) are handled with automatic resume
- Cache validation: Downloaded files are verified before playback
- Resource cleanup: Failed or cancelled downloads are cleaned up properly

This ensures smooth playback even when individual components have issues.

## Complete API Reference

### Main Player Classes

#### PlayolaStationPlayer
The primary interface for radio station playback:

```swift
@MainActor
final public class PlayolaStationPlayer: ObservableObject {
    // Singleton instance
    public static let shared: PlayolaStationPlayer
    
    // Published properties for state observation
    @Published public var stationId: String?
    @Published public var state: State
    
    // Configuration
    public func configure(authProvider: PlayolaAuthenticationProvider, baseURL: URL = default)
    
    // Playback control
    public func play(stationId: String, atDate: Date? = nil) async throws
    public func stop()
    
    // Status checking
    public var isPlaying: Bool { get }
    
    // Delegate support
    public weak var delegate: PlayolaStationPlayerDelegate?
    
    // Audio session handling (iOS only)
    public func handleAudioSessionInterruption(_ notification: Notification)
    public func handleAudioRouteChange(_ notification: Notification)
}

public enum State: Sendable {
    case idle
    case loading(Float)  // Progress 0.0-1.0
    case playing(Spin)
}
```

#### SpinPlayer
Low-level audio player for individual audio blocks:

```swift
@MainActor
public class SpinPlayer {
    public let id: UUID
    public var spin: Spin?
    public weak var delegate: SpinPlayerDelegate?
    public var state: State
    public var isPlaying: Bool { get }
    public var volume: Float
    public var localUrl: URL?
    public var duration: Double { get }
    
    public func stop()
    public func playNow(from startTime: Double, to endTime: Double? = nil)
    public func load(_ spin: Spin, onDownloadProgress: ((Float) -> Void)?) async -> Result<URL, Error>
    public func schedulePlay(at scheduledDate: Date)
    public func scheduleFades(_ spin: Spin)
    public func loadFile(with url: URL) async
}

public enum State {
    case available, loading, loaded, playing
}
```

#### PlayolaMainMixer
Audio engine coordinator for mixing multiple sources:

```swift
open class PlayolaMainMixer {
    public static let shared: PlayolaMainMixer
    
    public let mixerNode: AVAudioMixerNode
    public let engine: AVAudioEngine
    public weak var delegate: PlayolaMainMixerDelegate?
    
    public func configureAudioSession()
    public func deactivateAudioSession()
    public func start() throws
    public func attach(_ node: AVAudioPlayerNode)
    public func connect(_ playerNode: AVAudioPlayerNode, to mixerNode: AVAudioMixerNode, format: AVAudioFormat?)
    public func prepare()
}
```

### Model Types

#### AudioBlock
Represents an audio content item with rich metadata:

```swift
public struct AudioBlock: Codable, Sendable, Equatable, Hashable {
    // Identification
    public let id: String
    public let s3Key: String
    public let s3BucketName: String
    
    // Metadata
    public let title: String
    public let artist: String
    public let album: String?
    public let type: String
    public let popularity: Int?
    public let spotifyId: String?
    public let isrc: String?
    public let youTubeId: Int?
    
    // Timing information (in milliseconds)
    public let durationMS: Int
    public let endOfMessageMS: Int
    public let beginningOfOutroMS: Int
    public let endOfIntroMS: Int
    public let lengthOfOutroMS: Int
    
    // URLs
    public let downloadUrl: URL?
    public let imageUrl: URL?
    
    // Content
    public let transcription: String?
    
    // Timestamps
    public let createdAt: Date
    public let updatedAt: Date
    
    // Mock data support
    public static var mock: AudioBlock { get }
    public static var mocks: [AudioBlock] { get }
    public static func mockWith(...) -> AudioBlock
}
```

#### Spin
Represents a scheduled playback item:

```swift
public struct Spin: Codable, Sendable, Equatable, Hashable {
    // Core properties
    public let id: String
    public let stationId: String
    public let airtime: Date
    public let startingVolume: Float
    public let createdAt: Date
    public let updatedAt: Date
    
    // Content
    public let audioBlock: AudioBlock
    public let fades: [Fade]
    public let relatedTexts: [RelatedText]?
    
    // Testing support
    public var dateProvider: DateProviderProtocol!
    
    // Computed properties
    public var endtime: Date { get }
    public var isPlaying: Bool { get }
    
    // Utility methods
    public func withOffset(_ offset: TimeInterval) -> Spin
    
    // Mock data support
    public static var mock: Spin { get }
    public static func mockWith(...) -> Spin
}
```

#### Fade
Volume transition point:

```swift
public struct Fade: Codable, Sendable, Equatable {
    public let atMS: Int        // Time in milliseconds
    public let toVolume: Float  // Target volume (0.0-1.0)
    
    public init(atMS: Int, toVolume: Float)
}
```

#### Schedule
Station schedule container:

```swift
public struct Schedule: Sendable, Hashable {
    public let id: UUID
    public let stationId: String
    public let spins: [Spin]
    public let dateProvider: DateProviderProtocol
    
    public func current(offsetTimeInterval: TimeInterval? = nil) -> [Spin]
    public func nowPlaying(offsetTimeInterval: TimeInterval? = nil) -> Spin?
    
    // Mock data support
    public static let mock: Schedule
}
```

#### Station
Station information:

```swift
public struct Station: Codable, Sendable, Hashable, Equatable {
    public let id: String
    public let name: String
    public let curatorName: String
    public let imageUrl: URL?
    public let createdAt: Date
    public let updatedAt: Date
}
```

#### RelatedText
Additional text content associated with spins:

```swift
public struct RelatedText: Codable, Sendable, Equatable, Hashable {
    public let title: String
    public let body: String
    
    public static var mock: RelatedText { get }
    public static var mocks: [RelatedText] { get }
}
```

### Authentication

#### PlayolaAuthenticationProvider
Protocol for providing authentication tokens:

```swift
public protocol PlayolaAuthenticationProvider {
    func getCurrentToken() async -> String?
    func refreshToken() async -> String?
}
```

### Error Handling

#### Error Types

```swift
// Station player errors
public enum StationPlayerError: Error, LocalizedError {
    case networkError(String)
    case scheduleError(String)
    case playbackError(String)
    case invalidStationId(String)
    case fileDownloadError(String)
}

// File download errors
public enum FileDownloadError: Error, LocalizedError {
    case directoryCreationFailed
    case fileMoveFailed
    case fileNotFound
    case invalidRemoteURL(URL)
    case downloadFailed(String)
    case cachePruneFailed(String)
    case downloadCancelled
    case unknownError(String)
}

// Listening session errors
public enum ListeningSessionError: Error, LocalizedError {
    case missingDeviceId
    case networkError(String)
    case invalidResponse(String)
    case encodingError(String)
    case authenticationFailed(String)
}
```

#### PlayolaErrorReporter
Centralized error reporting system:

```swift
public actor PlayolaErrorReporter {
    public static let shared: PlayolaErrorReporter
    
    public weak var delegate: PlayolaErrorReporterDelegate?
    public var reportingLevel: PlayolaErrorReportingLevel
    public var logToConsole: Bool
    public var maxStackFrames: Int
    
    public func reportError(_ error: Error, context: String = "", level: PlayolaErrorReportingLevel) async
}

public protocol PlayolaErrorReporterDelegate: AnyObject {
    func playolaDidEncounterError(_ error: Error, sourceFile: String, sourceLine: Int, 
                                 function: String, stackTrace: String)
}

public enum PlayolaErrorReportingLevel: Int, Sendable {
    case none, critical, error, warning, debug
}

// Extension for easy error reporting
extension Error {
    public func playolaReport(context: String = "", level: PlayolaErrorReportingLevel = .error)
}
```

### File Management

#### FileDownloadManagerAsync
Handles downloading and caching of audio files:

```swift
public class FileDownloadManagerAsync: FileDownloadManaging {
    public static let shared: FileDownloadManagerAsync
    public static let MAX_AUDIO_FOLDER_SIZE: Int64
    public static let subfolderName: String
    
    public var activeDownloadIds: Set<String> { get }
    public var activeDownloadsCount: Int { get }
    
    // Main download methods
    public func downloadFileAsync(remoteUrl: URL, progressHandler: ((Float) -> Void)?) async throws -> URL
    public func downloadFile(remoteUrl: URL, progressHandler: @escaping (Float) -> Void, 
                           completion: @escaping (Result<URL, FileDownloadError>) -> Void) -> UUID
    
    // Download management
    public func cancelDownload(id downloadId: UUID) -> Bool
    public func cancelDownload(for remoteUrl: URL) -> Int
    public func cancelAllDownloads()
    
    // File operations
    public func fileExists(for remoteUrl: URL) -> Bool
    public func localURL(for remoteUrl: URL) -> URL
    
    // Cache management
    public func clearCache() throws
    public func pruneCache(maxSize: Int64?, excludeFilepaths: [String]) throws
    public func currentCacheSize() -> Int64
    public func availableDiskSpace() -> Int64?
}
```

### Utility Types

#### Date and Timer Providers
For testable time-dependent behavior:

```swift
public protocol DateProviderProtocol: Sendable {
    func now() -> Date
}

public class DateProvider: Sendable, DateProviderProtocol {
    public static let shared: DateProvider
    public func now() -> Date
}

public protocol TimerProvider: Sendable {
    func schedule(deadline: Date, repeating: TimeInterval, block: @escaping () -> Void) -> Timer
    func schedule(deadline: Date, block: @escaping () -> Void) -> Timer
}
```

#### Device Information
```swift
public struct DeviceInfoProvider {
    public static let deviceName: String
    public static let systemVersion: String
    public static let identifierForVendor: UUID?
}
```

#### JSON Decoding
```swift
public class JSONDecoderWithIsoFull: JSONDecoder {
    // Pre-configured with ISO8601 date decoding strategy
}
```

### Delegate Protocols

```swift
public protocol PlayolaStationPlayerDelegate: AnyObject {
    func player(_ player: PlayolaStationPlayer, playerStateDidChange state: PlayolaStationPlayer.State)
}

public protocol SpinPlayerDelegate: AnyObject, MainActor {
    func player(_ player: SpinPlayer, startedPlaying spin: Spin)
    func player(_ player: SpinPlayer, didPlayFile file: AVAudioFile, atTime time: TimeInterval, 
               withBuffer buffer: AVAudioPCMBuffer)
    func player(_ player: SpinPlayer, didChangeState state: SpinPlayer.State)
}

public protocol PlayolaMainMixerDelegate: AnyObject {
    func player(_ mainMixer: PlayolaMainMixer, didPlayBuffer: AVAudioPCMBuffer)
}
```

## Contributing

Contributions are welcome! Please see our contributing guidelines for details on:

- Development setup
- Coding standards  
- Testing requirements
- Pull request process

### Quick Start for Contributors

```bash
# Clone the repository
git clone https://github.com/playola-radio/PlayolaPlayer.git
cd PlayolaPlayer

# Run tests
swift test

# Build the package
swift build

# Build example app for simulator
cd PlayolaPlayerExample && xcodebuild -project PlayolaPlayerExample.xcodeproj \
  -scheme PlayolaPlayerExample \
  -destination 'platform=iOS Simulator,name=iPhone 15' build

# Generate Xcode project (if needed)
swift package generate-xcodeproj
```

### Development Guidelines

- Follow Swift API Design Guidelines
- Use Swift Concurrency (async/await) for asynchronous operations
- Document all public APIs with standard documentation comments
- Include tests for new functionality
- Maintain proper actor isolation for thread safety
- Use meaningful error contexts with PlayolaErrorReporter

### Testing

```bash
# Run all tests
swift test

# Run specific test suite
swift test --filter AudioNormalizationCalculatorTests

# Run specific test
swift test --filter PlayolaPlayerTests/testSpecificFunction
```

## License

MIT

## Support

For questions or support, please contact `brian -at- playola.fm` or create an issue on GitHub.