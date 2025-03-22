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

### Basic Playback

To start playing a Playola station:

```swift
import PlayolaPlayer
import SwiftUI

struct ContentView: View {
    @ObservedObject var player = PlayolaStationPlayer.shared

    var body: some View {
        VStack {
            Button(player.isPlaying ? "Stop" : "Play") {
                if player.isPlaying {
                    player.stop()
                } else {
                    Task {
                        try await player.play(stationId: "your-station-id")
                    }
                }
            }
            .padding()
            
            // Display the current playback state
            Text("Now playing: \(getCurrentTrackInfo())")
        }
    }
    
    func getCurrentTrackInfo() -> String {
        switch player.state {
        case .playing(let audioBlock):
            return "\(audioBlock.title) by \(audioBlock.artist)"
        case .loading(let progress):
            return "Loading... \(Int(progress * 100))%"
        case .idle:
            return "Nothing playing"
        }
    }
}
```

### Handling Player States

The player provides an observable state that you can use to update your UI:

```swift
switch player.state {
case .idle:
    // Player is not playing anything
case .loading(let progress):
    // Player is loading content, progress is a Float from 0.0 to 1.0
case .playing(let audioBlock):
    // Player is actively playing this audio block
    // audioBlock contains metadata like title, artist, etc.
}
```

### Implementing a Custom Delegate

You can implement the `PlayolaStationPlayerDelegate` to receive callbacks for state changes:

```swift
class MyPlayerManager: PlayolaStationPlayerDelegate {
    init() {
        PlayolaStationPlayer.shared.delegate = self
    }
    
    func player(_ player: PlayolaStationPlayer, playerStateDidChange state: PlayolaStationPlayer.State) {
        // Handle state changes
        switch state {
        case .playing(let audioBlock):
            print("Now playing: \(audioBlock.title) by \(audioBlock.artist)")
        case .loading(let progress):
            print("Loading: \(progress * 100)%")
        case .idle:
            print("Playback stopped")
        }
    }
}
```

### Error Handling

PlayolaPlayer provides a centralized error reporting system:

```swift
// Configure error reporting
PlayolaErrorReporter.shared.reportingLevel = .error
PlayolaErrorReporter.shared.delegate = self

// Implement the delegate
extension MyClass: PlayolaErrorReporterDelegate {
    func playolaDidEncounterError(_ error: Error,
                                 sourceFile: String,
                                 sourceLine: Int,
                                 function: String,
                                 stackTrace: String) {
        // Log or display the error
        print("Playola error: \(error.localizedDescription)")
        print("In \(sourceFile):\(sourceLine)")
    }
}
```

## Advanced Usage

### Audio Session Configuration

PlayolaPlayer configures the audio session for you, but if you need to customize it:

```swift
// Get access to the main mixer
let mainMixer = PlayolaMainMixer.shared

// Configure the audio session before playing
mainMixer.configureAudioSession()

// Clean up when done
mainMixer.deactivateAudioSession()

// Handle interruptions (add these to your app delegate or scene)
NotificationCenter.default.addObserver(
    mainMixer,
    selector: #selector(PlayolaMainMixer.handleAudioSessionInterruption(_:)),
    name: AVAudioSession.interruptionNotification,
    object: nil
)

NotificationCenter.default.addObserver(
    mainMixer,
    selector: #selector(PlayolaMainMixer.handleAudioRouteChange(_:)),
    name: AVAudioSession.routeChangeNotification,
    object: nil
)
```

### Manual File Management

If you need to manage audio files manually:

```swift
// Access the file download manager
let downloadManager = FileDownloadManager.shared

// Download a file with progress updates
let downloadId = downloadManager.downloadFile(
    remoteUrl: URL(string: "https://example.com/audio.mp3")!,
    progressHandler: { progress in
        print("Download progress: \(progress * 100)%")
    },
    completion: { result in
        switch result {
        case .success(let localUrl):
            print("File downloaded to: \(localUrl)")
        case .failure(let error):
            print("Download failed: \(error)")
        }
    }
)

// Cancel a download if needed
downloadManager.cancelDownload(id: downloadId)

// Clear the cache when needed
try? downloadManager.clearCache()

// Prune the cache to a specific size
try? downloadManager.pruneCache(maxSize: 100_000_000) // 100MB
```

## Contributing to PlayolaPlayer

We welcome contributions to PlayolaPlayer! Here's how you can help:

### Development Setup

1. Clone the repository:
   ```bash
   git clone https://github.com/your-organization/PlayolaPlayer.git
   cd PlayolaPlayer
   ```

2. Open the package in Xcode:
   ```bash
   xed .
   ```

3. The package includes tests that you can run in Xcode using the test navigator.

### Project Structure

- **Sources/PlayolaPlayer**: Contains the main library code
  - **Player**: Core playback components
  - **Models**: Data models for spins, schedules, etc.
  - **Protocols**: Interface definitions
  - **Extensions**: Swift extensions
  - **ErrorHandling**: Error reporting system
  - **MockData**: Test data

- **Tests/PlayolaPlayerTests**: Test suite for the library
  - **Test Utilities**: Helper classes for testing
  - **AudioNormalizationCalculatorTests**: Audio processing tests

### Coding Guidelines

- Follow Swift's API Design Guidelines
- Document all public APIs using standard documentation comments
- Maintain thread safety with proper actor isolation
- Include unit tests for new functionality
- Use Swift Concurrency (async/await) for asynchronous operations
- Properly handle errors and edge cases

### Documentation

All public APIs should be documented with standard documentation comments:

```swift
/// Brief description of what this does
///
/// More detailed explanation if needed
///
/// - Parameters:
///   - paramName: Description of the parameter
/// - Returns: Description of the return value
/// - Throws: Conditions under which this might throw errors
public func myFunction(paramName: ParamType) throws -> ReturnType {
    // Implementation
}
```

### Testing

The library uses the Swift Testing framework. Add tests for any new functionality:

```swift
@Test("Descriptive test name")
func testSomething() throws {
    // Arrange
    let sut = SystemUnderTest()
    
    // Act
    let result = sut.methodToTest()
    
    // Assert
    #expect(result == expectedValue)
}
```

### Error Handling

Use the PlayolaErrorReporter for consistent error reporting:

```swift
Task { @MainActor in
    PlayolaErrorReporter.shared.reportError(
        error,
        context: "Failed to process audio file: \(filename)",
        level: .error
    )
}
```

### Submitting Changes

1. Create a feature branch:
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. Make your changes and commit them:
   ```bash
   git commit -m "Description of your changes"
   ```

3. Push your branch:
   ```bash
   git push origin feature/your-feature-name
   ```

4. Create a pull request on GitHub

### Pull Request Process

1. Update the README.md or documentation if needed
2. Make sure all tests pass
3. Ensure your code follows the project's style
4. Get at least one code review from a maintainer

## License

MIT

## Contact

For questions or support, please contact `brian -at - playola.fm`.
