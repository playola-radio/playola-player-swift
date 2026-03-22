//
//  ContentView.swift
//  PlayolaPlayerExample
//
//  Created by Brian D Keane on 12/29/24.
//

import PlayolaPlayer
import SwiftUI

enum PlayerMode: String, CaseIterable {
  case streaming = "Streaming"
  case download = "Download"
}

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
      isResponsive = fps > 30
      frameCount = 0
      lastUpdate = displayLink.timestamp
    }
  }
}

struct ContentView: View {
  @ObservedObject var downloadPlayer = PlayolaStationPlayer.shared
  @StateObject var streamingPlayer = StreamingStationPlayer()
  @StateObject private var threadMonitor = MainThreadMonitor()
  @State private var showingStationPicker = false
  @State private var showingScheduleViewer = false
  @State private var selectedStationId: String = "9d79fd38-1940-4312-8fe8-3b9b50d49c6c"
  @State private var playerMode: PlayerMode = .streaming

  private var isPlaying: Bool {
    switch playerMode {
    case .streaming: return streamingPlayer.isPlaying
    case .download: return downloadPlayer.isPlaying
    }
  }

  private var nowPlayingSpin: Spin? {
    switch playerMode {
    case .streaming:
      if case .playing(let spin) = streamingPlayer.state { return spin }
    case .download:
      if case .playing(let spin) = downloadPlayer.state { return spin }
    }
    return nil
  }

  private var isLoading: Bool {
    switch playerMode {
    case .streaming:
      if case .loading = streamingPlayer.state { return true }
    case .download:
      if case .loading = downloadPlayer.state { return true }
    }
    return false
  }

  private var isIdle: Bool {
    switch playerMode {
    case .streaming:
      if case .idle = streamingPlayer.state { return true }
    case .download:
      if case .idle = downloadPlayer.state { return true }
    }
    return false
  }

  private var loadingProgress: Float? {
    switch playerMode {
    case .streaming:
      return nil
    case .download:
      if case .loading(let progress) = downloadPlayer.state {
        return progress
      }
    }
    return nil
  }

  var body: some View {
    ZStack {
      LinearGradient(
        gradient: Gradient(colors: [Color.black, Color.gray.opacity(0.3)]),
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()

      VStack(spacing: 30) {
        // Header with thread monitor and player toggle
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

        // Player mode toggle
        VStack(spacing: 8) {
          Picker("Player Mode", selection: $playerMode) {
            ForEach(PlayerMode.allCases, id: \.self) { mode in
              Text(mode.rawValue).tag(mode)
            }
          }
          .pickerStyle(.segmented)
          .padding(.horizontal)
          .onChange(of: playerMode) { _, _ in
            Task { await stopCurrentPlayer() }
          }

          Text(
            playerMode == .streaming
              ? "AVPlayer streaming (fast startup)"
              : "AVAudioEngine download (full file)"
          )
          .font(.caption2)
          .foregroundColor(.white.opacity(0.5))
        }

        Spacer()

        VStack(spacing: 25) {
          // Album art placeholder
          ZStack {
            RoundedRectangle(cornerRadius: 20)
              .fill(Color.white.opacity(0.1))
              .frame(width: 250, height: 250)

            if isPlaying {
              Image(systemName: "music.note")
                .font(.system(size: 80))
                .foregroundColor(.white.opacity(0.7))
                .rotationEffect(.degrees(isPlaying ? 360 : 0))
                .animation(
                  isPlaying
                    ? Animation.linear(duration: 3).repeatForever(autoreverses: false) : .default,
                  value: isPlaying
                )
            } else {
              Image(systemName: "radio")
                .font(.system(size: 80))
                .foregroundColor(.white.opacity(0.5))
            }
          }

          // Now playing info
          VStack(spacing: 10) {
            if let spin = nowPlayingSpin {
              Text(spin.audioBlock.title)
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .lineLimit(1)

              Text(spin.audioBlock.artist)
                .font(.headline)
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)
            } else if isLoading {
              VStack(spacing: 15) {
                Text("Loading Station...")
                  .font(.headline)
                  .foregroundColor(.white.opacity(0.8))

                if let progress = loadingProgress {
                  ProgressView(value: progress)
                    .progressViewStyle(LinearProgressViewStyle(tint: .white))
                    .frame(width: 200)

                  Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
                } else {
                  ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                }
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
            Text("Play from different times:")
              .font(.caption)
              .foregroundColor(.white.opacity(0.6))

            HStack(spacing: 15) {
              Button("5min ago") { playWithOffset(-300) }
                .buttonStyle(OffsetButtonStyle())
              Button("1min ago") { playWithOffset(-60) }
                .buttonStyle(OffsetButtonStyle())
              Button("10sec ago") { playWithOffset(-10) }
                .buttonStyle(OffsetButtonStyle())
            }

            HStack(spacing: 15) {
              Button("10sec future") { playWithOffset(10) }
                .buttonStyle(OffsetButtonStyle())
              Button("1min future") { playWithOffset(60) }
                .buttonStyle(OffsetButtonStyle())
              Button("5min future") { playWithOffset(300) }
                .buttonStyle(OffsetButtonStyle())
            }
          }

          // Main playback controls
          HStack(spacing: 40) {
            Button(
              action: { showingStationPicker.toggle() },
              label: {
                Image(systemName: "list.bullet")
                  .font(.title2)
                  .foregroundColor(.white.opacity(0.8))
              })

            Button(
              action: { playOrPause() },
              label: {
                ZStack {
                  Circle()
                    .fill(currentButtonColor)
                    .frame(width: 80, height: 80)

                  Image(systemName: currentButtonIcon)
                    .font(.title)
                    .foregroundColor(.white)
                    .offset(x: isIdle ? 3 : 0)
                }
              })

            Button(
              action: { showingScheduleViewer.toggle() },
              label: {
                Image(systemName: "calendar")
                  .font(.title2)
                  .foregroundColor(.white.opacity(0.8))
              })
          }
        }

        Spacer()
      }
    }
    .sheet(isPresented: $showingStationPicker) {
      StationPickerView(
        selectedStationId: $selectedStationId,
        playerMode: playerMode,
        streamingPlayer: streamingPlayer
      )
    }
    .sheet(isPresented: $showingScheduleViewer) {
      ScheduleViewer(selectedStationId: selectedStationId)
    }
  }

  private var currentButtonColor: Color {
    if isPlaying { return .red }
    if isLoading { return .orange }
    return .green
  }

  private var currentButtonIcon: String {
    if isIdle { return "play.fill" }
    return "stop.fill"
  }

  func stopCurrentPlayer() async {
    await downloadPlayer.stop()
    streamingPlayer.stop()
  }

  func playOrPause() {
    Task {
      if isPlaying || isLoading {
        await stopCurrentPlayer()
      } else {
        do {
          switch playerMode {
          case .streaming:
            try await streamingPlayer.play(stationId: selectedStationId)
          case .download:
            try await downloadPlayer.play(stationId: selectedStationId)
          }
        } catch {
          print("Failed to start playback: \(error)")
        }
      }
    }
  }

  func playWithOffset(_ offsetSeconds: TimeInterval) {
    Task {
      await stopCurrentPlayer()
      let atDate = Date().addingTimeInterval(offsetSeconds)
      do {
        switch playerMode {
        case .streaming:
          try await streamingPlayer.play(stationId: selectedStationId, atDate: atDate)
        case .download:
          try await downloadPlayer.play(stationId: selectedStationId, atDate: atDate)
        }
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
  var playerMode: PlayerMode
  var streamingPlayer: StreamingStationPlayer
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
                    let stationId = station.playolaID ?? station.id
                    selectedStationId = stationId
                    switch playerMode {
                    case .streaming:
                      streamingPlayer.stop()
                      try await streamingPlayer.play(stationId: stationId)
                    case .download:
                      await PlayolaStationPlayer.shared.stop()
                      try await PlayolaStationPlayer.shared.play(stationId: stationId)
                    }
                  } catch {
                    print("Failed to start playback: \(error)")
                  }
                }
                dismiss()
              },
              label: {
                HStack {
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
              })
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

      var allStations: [StationInfo] = []

      for list in response.stationLists {
        if list.id == "in_development_list" || list.id == "artist_list" {
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
