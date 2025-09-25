//
//  ContentView.swift
//  PlayolaPlayerExample
//
//  Created by Brian D Keane on 12/29/24.
//

import PlayolaPlayer
import SwiftUI

// Main thread responsiveness monitor
class MainThreadMonitor: ObservableObject {
  @Published var isResponsive = true
  @Published var fps: Double = 60
  private var displayLink: CADisplayLink?
  private var lastUpdate: CFTimeInterval = 0
  private var frameCount = 0

  init() {
    startMonitoring()
  }

  deinit {
    displayLink?.invalidate()
  }

  private func startMonitoring() {
    displayLink = CADisplayLink(target: self, selector: #selector(update))
    displayLink?.add(to: .main, forMode: .common)
  }

  @objc private func update(displayLink: CADisplayLink) {
    frameCount += 1

    let elapsed = displayLink.timestamp - lastUpdate
    if elapsed >= 1.0 {
      fps = Double(frameCount) / elapsed
      isResponsive = fps > 30  // Consider unresponsive if below 30 FPS
      frameCount = 0
      lastUpdate = displayLink.timestamp
    }
  }
}

struct ContentView: View {
  @ObservedObject var player = PlayolaStationPlayer.shared
  @StateObject private var threadMonitor = MainThreadMonitor()
  @State private var showingStationPicker = false
  @State private var showingScheduleViewer = false
  @State private var selectedStationId: String = "9d79fd38-1940-4312-8fe8-3b9b50d49c6c"

  var body: some View {
    ZStack {
      // Background gradient
      LinearGradient(
        gradient: Gradient(colors: [Color.black, Color.gray.opacity(0.3)]),
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()

      VStack(spacing: 30) {
        // Header with thread monitor
        HStack {
          VStack(alignment: .leading, spacing: 5) {
            Text("Main Thread Monitor")
              .font(.headline)
              .foregroundColor(.white)
            Text("Watch this during loading")
              .font(.caption)
              .foregroundColor(.white.opacity(0.6))
          }
          Spacer()
          ThreadResponsivenessIndicator(monitor: threadMonitor)
        }
        .padding()

        Spacer()

        // Main content
        VStack(spacing: 25) {
          // Album art placeholder with animation
          ZStack {
            RoundedRectangle(cornerRadius: 20)
              .fill(Color.white.opacity(0.1))
              .frame(width: 250, height: 250)

            if player.isPlaying {
              Image(systemName: "music.note")
                .font(.system(size: 80))
                .foregroundColor(.white.opacity(0.7))
                .rotationEffect(.degrees(player.isPlaying ? 360 : 0))
                .animation(
                  player.isPlaying
                    ? Animation.linear(duration: 3).repeatForever(autoreverses: false) : .default,
                  value: player.isPlaying
                )
            } else {
              Image(systemName: "radio")
                .font(.system(size: 80))
                .foregroundColor(.white.opacity(0.5))
            }
          }

          // Now playing info
          VStack(spacing: 10) {
            if case let .playing(spin) = player.state {
              Text(spin.audioBlock.title)
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .lineLimit(1)

              Text(spin.audioBlock.artist)
                .font(.headline)
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)
            } else if case let .loading(progress) = player.state {
              VStack(spacing: 15) {
                Text("Loading Station...")
                  .font(.headline)
                  .foregroundColor(.white.opacity(0.8))

                ProgressView(value: progress)
                  .progressViewStyle(LinearProgressViewStyle(tint: .white))
                  .frame(width: 200)

                Text("\(Int(progress * 100))%")
                  .font(.caption)
                  .foregroundColor(.white.opacity(0.6))
              }
            } else {
              Text("Ready to Play")
                .font(.title3)
                .foregroundColor(.white.opacity(0.6))
            }
          }
          .frame(height: 80)

          // Offset playback controls
          VStack(spacing: 20) {
            // Time offset buttons
            Text("Play from different times:")
              .font(.caption)
              .foregroundColor(.white.opacity(0.6))

            HStack(spacing: 15) {
              Button("5min ago") {
                playWithOffset(-300)  // 5 minutes ago
              }
              .buttonStyle(OffsetButtonStyle())

              Button("1min ago") {
                playWithOffset(-60)  // 1 minute ago
              }
              .buttonStyle(OffsetButtonStyle())

              Button("10sec ago") {
                playWithOffset(-10)  // 10 seconds ago
              }
              .buttonStyle(OffsetButtonStyle())
            }

            HStack(spacing: 15) {
              Button("10sec future") {
                playWithOffset(10)  // 10 seconds from now
              }
              .buttonStyle(OffsetButtonStyle())

              Button("1min future") {
                playWithOffset(60)  // 1 minute from now
              }
              .buttonStyle(OffsetButtonStyle())

              Button("5min future") {
                playWithOffset(300)  // 5 minutes from now
              }
              .buttonStyle(OffsetButtonStyle())
            }
          }

          // Main playback controls
          HStack(spacing: 40) {
            // Station picker
            Button(
              action: { showingStationPicker.toggle() },
              label: {
                Image(systemName: "list.bullet")
                  .font(.title2)
                  .foregroundColor(.white.opacity(0.8))
              }
            )

            // Play/Stop button (current time)
            Button(
              action: { playOrPause() },
              label: {
                ZStack {
                  Circle()
                    .fill(buttonColor(for: player.state))
                    .frame(width: 80, height: 80)

                  Image(systemName: buttonIcon(for: player.state))
                    .font(.title)
                    .foregroundColor(.white)
                    .offset(x: shouldOffsetIcon(for: player.state) ? 3 : 0)  // Center play icon
                }
              }
            )

            // Schedule viewer
            Button(
              action: { showingScheduleViewer.toggle() },
              label: {
                Image(systemName: "calendar")
                  .font(.title2)
                  .foregroundColor(.white.opacity(0.8))
              }
            )
          }
        }

        Spacer()
      }
    }
    .sheet(isPresented: $showingStationPicker) {
      StationPickerView(selectedStationId: $selectedStationId)
    }
    .sheet(isPresented: $showingScheduleViewer) {
      ScheduleViewer(selectedStationId: selectedStationId)
    }
  }

  func playOrPause() {
    Task {
      switch await player.state {
      case .loading:
        // Cancel loading
        await player.stop()
      case .playing:
        // Stop playing
        await player.stop()
      case .idle:
        // Start playing
        do {
          try await player.play(stationId: selectedStationId)
        } catch {
          // Handle errors gracefully (including cancellation during loading)
          print("Failed to start playback: \(error)")
        }
      }
    }
  }

  func playWithOffset(_ offsetSeconds: TimeInterval) {
    Task {
      // Always stop current playback first
      await player.stop()

      // Calculate the target date
      let atDate = Date().addingTimeInterval(offsetSeconds)

      do {
        try await player.play(
          stationId: selectedStationId,
          atDate: atDate
        )
        print("Started playback with offset: \(offsetSeconds) seconds (at: \(atDate))")
      } catch {
        print("Failed to start offset playback: \(error)")
      }
    }
  }
}

// Thread responsiveness indicator
struct ThreadResponsivenessIndicator: View {
  @ObservedObject var monitor: MainThreadMonitor
  @State private var rotation: Double = 0

  var body: some View {
    VStack(spacing: 8) {
      // Visual spinner that shows thread responsiveness
      ZStack {
        Circle()
          .stroke(Color.white.opacity(0.2), lineWidth: 3)
          .frame(width: 40, height: 40)

        Circle()
          .trim(from: 0, to: 0.7)
          .stroke(
            monitor.isResponsive ? Color.green : Color.red,
            style: StrokeStyle(lineWidth: 3, lineCap: .round)
          )
          .frame(width: 40, height: 40)
          .rotationEffect(.degrees(rotation))
          .animation(
            monitor.isResponsive
              ? Animation.linear(duration: 1).repeatForever(autoreverses: false)
              : Animation.easeInOut(duration: 2).repeatForever(autoreverses: false),
            value: rotation
          )

        Text("\(Int(monitor.fps))")
          .font(.caption2)
          .fontWeight(.bold)
          .foregroundColor(.white)
      }

      VStack(spacing: 2) {
        Text("\(Int(monitor.fps)) FPS")
          .font(.caption)
          .fontWeight(.semibold)
          .foregroundColor(monitor.isResponsive ? .green : .red)

        Text(monitor.isResponsive ? "Responsive" : "BLOCKED")
          .font(.caption2)
          .foregroundColor(monitor.isResponsive ? .white.opacity(0.6) : .red)
          .fontWeight(monitor.isResponsive ? .regular : .bold)
      }
    }
    .padding()
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(Color.black.opacity(0.5))
        .overlay(
          RoundedRectangle(cornerRadius: 12)
            .stroke(
              monitor.isResponsive ? Color.green.opacity(0.3) : Color.red.opacity(0.5), lineWidth: 1
            )
        )
    )
    .scaleEffect(monitor.isResponsive ? 1.0 : 1.1)
    .animation(.easeInOut(duration: 0.3), value: monitor.isResponsive)
    .onAppear {
      rotation = 360
    }
  }
}

// API Models
struct StationListsResponse: Codable {
  let stationLists: [StationList]
}

struct StationList: Codable {
  let id: String
  let title: String
  let hidden: Bool?
  let stations: [StationInfo]
}

struct StationInfo: Codable, Identifiable {
  let id: String
  let name: String
  let playolaID: String?
  let imageURL: String?
  let desc: String?
  let longDesc: String?
  let type: String
}

// Station picker sheet
struct StationPickerView: View {
  @Environment(\.dismiss) var dismiss
  @Binding var selectedStationId: String
  @State private var stations: [StationInfo] = []
  @State private var isLoading = true
  @State private var errorMessage: String?

  var body: some View {
    NavigationView {
      ZStack {
        if isLoading {
          ProgressView("Loading stations...")
            .padding()
        } else if let error = errorMessage {
          VStack(spacing: 16) {
            Text("Failed to load stations")
              .font(.headline)
            Text(error)
              .font(.caption)
              .foregroundColor(.secondary)
            Button("Retry") {
              Task { await loadStations() }
            }
          }
          .padding()
        } else {
          List(stations) { station in
            Button(
              action: {
                Task {
                  do {
                    // Use playolaID for playola stations
                    let stationId = station.playolaID ?? station.id
                    selectedStationId = stationId
                    try await PlayolaStationPlayer.shared.play(stationId: stationId)
                  } catch {
                    print("Failed to start playback: \(error)")
                  }
                }
                dismiss()
              },
              label: {
                HStack {
                  // Show image if available
                  if let imageURL = station.imageURL, let url = URL(string: imageURL) {
                    AsyncImage(url: url) { image in
                      image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                    } placeholder: {
                      Image(systemName: "radio")
                        .foregroundColor(.blue)
                    }
                    .frame(width: 40, height: 40)
                    .cornerRadius(8)
                  } else {
                    Image(systemName: "radio")
                      .foregroundColor(.blue)
                      .frame(width: 40, height: 40)
                  }

                  VStack(alignment: .leading, spacing: 4) {
                    Text(station.name)
                      .font(.headline)
                    if let desc = station.desc {
                      Text(desc)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                  }

                  Spacer()
                }
                .padding(.vertical, 4)
              }
            )
          }
        }
      }
      .navigationTitle("Select Station")
      .navigationBarItems(trailing: Button("Done") { dismiss() })
      .task {
        await loadStations()
      }
    }
  }

  private func loadStations() async {
    isLoading = true
    errorMessage = nil

    do {
      let url = URL(string: "https://admin-api.playola.fm/v1/developer/station-lists")!
      let (data, _) = try await URLSession.shared.data(from: url)

      let response = try JSONDecoder().decode(StationListsResponse.self, from: data)

      // Get stations from in_development_list and artist_list
      var allStations: [StationInfo] = []

      for list in response.stationLists {
        if list.id == "in_development_list" || list.id == "artist_list" {
          // Filter to only include playola type stations
          let playolaStations = list.stations.filter { $0.type == "playola" }
          allStations.append(contentsOf: playolaStations)
        }
      }

      await MainActor.run {
        self.stations = allStations
        self.isLoading = false
      }
    } catch {
      await MainActor.run {
        self.errorMessage = error.localizedDescription
        self.isLoading = false
      }
    }
  }
}

func isLoading(_ state: PlayolaStationPlayer.State) -> Bool {
  if case .loading = state {
    return true
  }
  return false
}

func buttonColor(for state: PlayolaStationPlayer.State) -> Color {
  switch state {
  case .loading:
    return Color.orange
  case .playing:
    return Color.red
  case .idle:
    return Color.green
  }
}

func buttonIcon(for state: PlayolaStationPlayer.State) -> String {
  switch state {
  case .loading:
    return "stop.fill"
  case .playing:
    return "stop.fill"
  case .idle:
    return "play.fill"
  }
}

func shouldOffsetIcon(for state: PlayolaStationPlayer.State) -> Bool {
  if case .idle = state {
    return true
  }
  return false
}

// Custom button style for offset buttons
struct OffsetButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.caption)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(
        RoundedRectangle(cornerRadius: 16)
          .fill(Color.white.opacity(configuration.isPressed ? 0.3 : 0.2))
      )
      .foregroundColor(.white)
      .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
      .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
  }
}

#Preview {
  ContentView()
}
