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
            if case .playing(let spin) = player.state {
              Text(spin.audioBlock.title)
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .lineLimit(1)

              Text(spin.audioBlock.artist)
                .font(.headline)
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)
            } else if case .loading(let progress) = player.state {
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

          // Playback controls
          HStack(spacing: 40) {
            // Station picker
            Button(action: { showingStationPicker.toggle() }) {
              Image(systemName: "list.bullet")
                .font(.title2)
                .foregroundColor(.white.opacity(0.8))
            }

            // Play/Stop button
            Button(action: playOrPause) {
              ZStack {
                Circle()
                  .fill(player.isPlaying ? Color.red : Color.green)
                  .frame(width: 80, height: 80)

                Image(systemName: player.isPlaying ? "stop.fill" : "play.fill")
                  .font(.title)
                  .foregroundColor(.white)
                  .offset(x: player.isPlaying ? 0 : 3)  // Center play icon
              }
            }
            .disabled(isLoading(player.state))

            // Placeholder for future control
            Image(systemName: "speaker.wave.2")
              .font(.title2)
              .foregroundColor(.white.opacity(0.3))
          }
        }

        Spacer()
      }
    }
    .sheet(isPresented: $showingStationPicker) {
      StationPickerView()
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

// Station picker sheet
struct StationPickerView: View {
  @Environment(\.dismiss) var dismiss

  let stations = [
    ("9d79fd38-1940-4312-8fe8-3b9b50d49c6c", "Default Station")
    // Add more stations here
  ]

  var body: some View {
    NavigationView {
      List(stations, id: \.0) { station in
        Button(action: {
          Task {
            try? await PlayolaStationPlayer.shared.play(stationId: station.0)
          }
          dismiss()
        }) {
          HStack {
            Image(systemName: "radio")
              .foregroundColor(.blue)
            Text(station.1)
            Spacer()
          }
        }
      }
      .navigationTitle("Select Station")
      .navigationBarItems(trailing: Button("Done") { dismiss() })
    }
  }
}

func isLoading(_ state: PlayolaStationPlayer.State) -> Bool {
  if case .loading = state {
    return true
  }
  return false
}

func playOrPause() {
  Task {
    if await PlayolaStationPlayer.shared.isPlaying {
      await PlayolaStationPlayer.shared.stop()
    } else {
      try! await PlayolaStationPlayer.shared.play(stationId: "9d79fd38-1940-4312-8fe8-3b9b50d49c6c")
    }
  }
}

#Preview {
  ContentView()
}
