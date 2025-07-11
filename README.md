# PlayolaPlayer

A Swift audio player library for iOS that provides streaming radio capabilities for the Playola platform.

## Overview

PlayolaPlayer is a Swift Package Manager library that handles audio streaming, scheduling, caching, and playback for Playola radio stations. It offers intelligent audio scheduling, automatic audio normalization, and seamless transitions between audio blocks.

## Features

- 🎵 Stream audio from Playola radio stations
- 🗓 Intelligent audio scheduling with precise timing control
- 📦 Efficient file caching with automatic cleanup
- 🔊 Audio normalization for consistent volume levels
- 🔄 Smooth transitions and crossfades between audio blocks
- 🔔 Comprehensive error reporting system
- 🧩 Swift Concurrency support (async/await)
- 📡 Combine publishers for reactive programming
- 🎯 Delegate pattern support for state changes

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

### Basic Playback

The simplest way to use PlayolaPlayer is through the singleton instance:

```swift
import PlayolaPlayer

// Configure first (required)
PlayolaStationPlayer.shared.configure(authProvider: myAuthProvider)

// Start playing a station
Task {
    do {
        try await PlayolaStationPlayer.shared.play(stationId: "your-station-id")
    } catch {
        print("Failed to play station: \(error)")
    }
}

// Stop playback
PlayolaStationPlayer.shared.stop()

// Check if playing
if PlayolaStationPlayer.shared.isPlaying {
    print("Currently playing")
}
```

### Using Combine Publishers

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
                case .playing(let audioBlock):
                    self?.nowPlaying = "\(audioBlock.title) by \(audioBlock.artist)"
                    self?.isLoading = false
                }
            }
            .store(in: &cancellables)
        
        // Subscribe to station ID changes
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

Here's a complete SwiftUI example:

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
                case .playing(let audioBlock):
                    VStack(spacing: 5) {
                        Text(audioBlock.title)
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text(audioBlock.artist)
                            .foregroundColor(.secondary)
                        if let album = audioBlock.album {
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

### Using Delegates

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
            case .playing(let audioBlock):
                self?.updateUI(title: audioBlock.title, 
                             subtitle: audioBlock.artist)
                
                // Access additional metadata
                if let duration = audioBlock.durationMS {
                    print("Duration: \(duration / 1000) seconds")
                }
                
                if let imageUrl = audioBlock.imageUrl {
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

### Error Handling

PlayolaPlayer provides comprehensive error handling capabilities:

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
        // Handle errors based on type
        switch error {
        case let stationError as StationPlayerError:
            handleStationPlayerError(stationError)
        case let downloadError as FileDownloadError:
            handleDownloadError(downloadError)
        default:
            // Generic error handling
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
            // User cancelled - no action needed
            break
        case .invalidRemoteURL(let url):
            print("Invalid URL: \(url)")
        case .downloadFailed(let message):
            showAlert(title: "Download Failed", message: message)
        default:
            showAlert(title: "Download Error", 
                     message: error.localizedDescription)
        }
    }
    
    private func showAlert(title: String, message: String) {
        // Show alert to user
    }
}
```

### Advanced Features

#### Custom Base URL Configuration

You can check the current API configuration after configuring the player:

```swift
// Access the configured base URL (read-only)
let currentBaseURL = PlayolaStationPlayer.shared.listeningSessionReporter?.baseURL
print("API Base URL: \(currentBaseURL?.absoluteString ?? "Not configured")")
```

#### Audio Session Handling

PlayolaPlayer automatically handles audio session configuration, but you can customize the behavior:

```swift
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

#### Working with Audio Blocks

Access detailed metadata from the currently playing audio block:

```swift
if case .playing(let audioBlock) = PlayolaStationPlayer.shared.state {
    print("Title: \(audioBlock.title)")
    print("Artist: \(audioBlock.artist)")
    print("Album: \(audioBlock.album ?? "Unknown")")
    
    // Timing information
    if let duration = audioBlock.durationMS {
        print("Duration: \(duration / 1000) seconds")
    }
    
    if let endOfMessage = audioBlock.endOfMessageMS {
        print("End of message: \(endOfMessage / 1000) seconds")
    }
    
    if let outroStart = audioBlock.beginningOfOutroMS {
        print("Outro starts at: \(outroStart / 1000) seconds")
    }
    
    // Additional metadata
    print("Type: \(audioBlock.type)")
    print("Created: \(audioBlock.createdAt)")
    
    if let spotifyId = audioBlock.spotifyId {
        print("Spotify ID: \(spotifyId)")
    }
}
```

#### Schedule Information

Access the current schedule and upcoming spins:

```swift
// Get the current spin player (internal component)
// Note: This is typically handled internally, but available for advanced use cases
import PlayolaPlayer

// The schedule is managed internally, but you can observe state changes
// to know when new content is playing
```

#### Custom Error Reporting Levels

Configure error reporting based on your needs:

```swift
// Set reporting level
PlayolaErrorReporter.shared.reportingLevel = .debug // Reports everything

// Available levels:
// .none     - No reporting
// .critical - Only critical errors
// .error    - Errors and critical
// .warning  - Warnings and above
// .debug    - All messages

// Report custom errors
error.playolaReport(context: "Custom operation failed", level: .warning)
```

## Model Types Reference

### AudioBlock
Represents an audio content item with rich metadata:
- **Identification**: `id`, `s3Key`, `s3BucketName`
- **Metadata**: `title`, `artist`, `album`, `spotifyId`
- **Timing**: `durationMS`, `endOfMessageMS`, `beginningOfOutroMS`, `endOfIntroMS`
- **URLs**: `downloadUrl`, `imageUrl`
- **Additional**: `type`, `popularity`, `createdAt`, `updatedAt`

### Spin
Represents a scheduled playback item:
- **Core**: `id`, `stationId`, `airtime`
- **Content**: `audioBlock` (optional)
- **Playback**: `startingVolume`, `fades` array
- **Computed**: `endtime`, `isPlaying`

### Fade
Volume transition point:
- `atMS`: Time in milliseconds
- `toVolume`: Target volume (0.0-1.0)

### Station
Station information:
- `id`, `name`, `curatorName`
- `imageUrl` (optional)
- `createdAt`, `updatedAt`

### Schedule
Station schedule container:
- `stationId`
- `spins` array
- Computed: `nowPlaying`, `current`

## Contributing

We welcome contributions to PlayolaPlayer! Please see our [Contributing Guidelines](#contributing-to-playolaplayer) section for details on:

- Development setup
- Coding standards
- Testing requirements
- Pull request process

### Quick Start for Contributors

```bash
# Clone the repository
git clone https://github.com/your-organization/PlayolaPlayer.git
cd PlayolaPlayer

# Open in Xcode
xed .

# Run tests
swift test

# Build the package
swift build
```

### Key Guidelines

- Follow Swift API Design Guidelines
- Use Swift Concurrency (async/await) for asynchronous operations
- Document all public APIs
- Include tests for new functionality
- Maintain thread safety with proper actor isolation

## License

MIT

## Contact

For questions or support, please contact `brian -at- playola.fm`.