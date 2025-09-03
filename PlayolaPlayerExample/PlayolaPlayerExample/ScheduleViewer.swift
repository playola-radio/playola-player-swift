//
//  ScheduleViewer.swift
//  PlayolaPlayerExample
//
//  Created by Brian D Keane on 9/2/25.
//

import PlayolaPlayer
import SwiftUI

#if os(iOS)
  import UIKit
#endif

// Preference key to track scroll position
struct ScrollOffsetPreferenceKey: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = nextValue()
  }
}

// Triangle shape for the position indicator
struct Triangle: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.midX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
    path.closeSubpath()
    return path
  }
}

// Info for spins too small to display labels inline
struct DetailSpinInfo: Identifiable {
  let id: String
  let spin: Spin
  let originalXPosition: CGFloat
  let originalWidth: CGFloat
  let color: Color
}

struct ScheduleViewer: View {
  @ObservedObject var player = PlayolaStationPlayer.shared
  @Environment(\.dismiss) var dismiss
  let selectedStationId: String
  @State private var schedule: Schedule?
  @State private var isLoading = true
  @State private var selectedSpin: Spin?
  @State private var scrollPosition: CGFloat = 0
  @State private var scheduleTimeAtIndicator = Date()
  @State private var zoomScale: CGFloat = 3.0
  @State private var lastZoomScale: CGFloat = 1.0
  @State private var detailSpinInfo: [DetailSpinInfo] = []
  @State private var playbackPosition: Date?
  @State private var playbackTimer: Timer?

  var body: some View {
    NavigationView {
      ZStack {
        // Background
        Color.black.ignoresSafeArea()

        if isLoading {
          ProgressView("Loading schedule...")
            .foregroundColor(.white)
        } else if let schedule = schedule {
          VStack(spacing: 0) {
            // Schedule area
            ZStack(alignment: .top) {
              // Schedule scroll view
              ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: true) {
                  VStack(spacing: 8) {
                    // Main timeline
                    HStack(spacing: 0) {
                      ForEach(schedule.spins) { spin in
                        SpinVisualization(
                          spin: spin,
                          isSelected: selectedSpin?.id == spin.id,
                          zoomScale: zoomScale,
                          onTap: {
                            selectedSpin = spin
                          },
                          onDetailInfo: { info in
                            // Update detail info when spin is too narrow
                            if let index = detailSpinInfo.firstIndex(where: { $0.id == info.id }) {
                              detailSpinInfo[index] = info
                            } else {
                              detailSpinInfo.append(info)
                            }
                          }
                        )
                        .id(spin.id)
                        .overlay(
                          GeometryReader { spinGeo in
                            Color.clear
                              .onAppear {
                                checkIfSpinAtCenter(spin: spin, geometry: spinGeo)
                              }
                              .onChange(of: scrollPosition) { _ in
                                checkIfSpinAtCenter(spin: spin, geometry: spinGeo)
                              }
                          }
                        )
                      }
                    }
                    .padding(.horizontal)

                    // Detail track for narrow spins
                    if !detailSpinInfo.isEmpty {
                      HStack(spacing: 4) {
                        ForEach(detailSpinInfo.sorted(by: { $0.spin.airtime < $1.spin.airtime })) {
                          info in
                          DetailSpinVisualization(
                            detailInfo: info,
                            isSelected: selectedSpin?.id == info.id,
                            onTap: {
                              selectedSpin = info.spin
                            }
                          )
                        }
                        Spacer()
                      }
                      .padding(.horizontal)
                    }
                  }
                  .background(
                    GeometryReader { geometry in
                      let offset = geometry.frame(in: .named("scrollView")).minX
                      Color.clear
                        .preference(key: ScrollOffsetPreferenceKey.self, value: offset)
                        .onChange(of: offset) { newOffset in
                          scrollPosition = newOffset
                        }
                    }
                  )
                }
                .coordinateSpace(name: "scrollView")
                .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                  scrollPosition = value
                  updateScheduleTimeAtIndicator()
                }
                .onAppear {
                  // Scroll to current time on appear
                  if let nowPlayingSpin = schedule.nowPlaying() {
                    proxy.scrollTo(nowPlayingSpin.id, anchor: .center)
                  }
                }
                .gesture(
                  MagnificationGesture()
                    .onChanged { value in
                      let delta = value / lastZoomScale
                      lastZoomScale = value
                      let newScale = zoomScale * delta

                      // Limit zoom range - allow much higher zoom for detail
                      zoomScale = min(max(newScale, 0.1), 20.0)

                      // Clear detail spin info when zoom changes - it will be repopulated
                      detailSpinInfo.removeAll()
                    }
                    .onEnded { _ in
                      lastZoomScale = 1.0
                    }
                )
              }

              // Time indicator and zoom controls overlay
              VStack {
                HStack {
                  // Zoom controls
                  HStack(spacing: 12) {
                    Button(
                      action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                          // Use variable zoom steps - smaller steps at higher zoom
                          let step = zoomScale > 5.0 ? 1.0 : (zoomScale > 2.0 ? 0.5 : 0.25)
                          zoomScale = max(zoomScale - step, 0.1)
                          // Clear detail info when zoom changes
                          detailSpinInfo.removeAll()
                        }
                      },
                      label: {
                        Image(systemName: "minus.circle.fill")
                          .font(.title2)
                          .foregroundColor(.white)
                      })

                    Text(formatZoomPercentage(zoomScale))
                      .font(.system(size: 14, weight: .medium))
                      .foregroundColor(.white)
                      .frame(width: 60)

                    Button(
                      action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                          // Use variable zoom steps - smaller steps at higher zoom
                          let step = zoomScale > 5.0 ? 1.0 : (zoomScale > 2.0 ? 0.5 : 0.25)
                          zoomScale = min(zoomScale + step, 20.0)
                          // Clear detail info when zoom changes
                          detailSpinInfo.removeAll()
                        }
                      },
                      label: {
                        Image(systemName: "plus.circle.fill")
                          .font(.title2)
                          .foregroundColor(.white)
                      })
                  }
                  .padding(.horizontal, 12)
                  .padding(.vertical, 6)
                  .background(
                    Capsule()
                      .fill(Color.black.opacity(0.8))
                  )
                  .padding(.leading)

                  Spacer()

                  // Time indicator
                  Text(formatTimeForPosition())
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                      Capsule()
                        .fill(Color.black.opacity(0.8))
                    )
                    .padding(.trailing)
                }
                Spacer()
              }
              .padding(.top, 8)

              // Center line indicator (actual visual center)
              Rectangle()
                .fill(Color.red.opacity(0.8))
                .frame(width: 2)
                .overlay(
                  VStack {
                    Triangle()
                      .fill(Color.red.opacity(0.8))
                      .frame(width: 12, height: 8)
                      .rotationEffect(.degrees(180))
                    Spacer()
                  }
                )
                .background(
                  GeometryReader { _ in
                    Color.clear
                      .onAppear {
                        updateTimeBasedOnVisibleSpins()
                      }
                      .onChange(of: scrollPosition) { _ in
                        updateTimeBasedOnVisibleSpins()
                      }
                  }
                )

              // Playback position indicator (blue line)
              if let playbackPos = playbackPosition {
                let playbackX = calculateXPosition(for: playbackPos, in: schedule)
                let screenCenter = UIScreen.main.bounds.width / 2
                // Convert from timeline position to screen position
                let playbackScreenX = playbackX + scrollPosition

                // Only show if visible on screen
                if playbackScreenX >= -50 && playbackScreenX <= UIScreen.main.bounds.width + 50 {
                  Rectangle()
                    .fill(Color.blue.opacity(0.9))
                    .frame(width: 3)
                    .offset(x: playbackScreenX - screenCenter)
                    .overlay(
                      VStack {
                        Triangle()
                          .fill(Color.blue.opacity(0.9))
                          .frame(width: 14, height: 10)
                          .rotationEffect(.degrees(180))
                        Spacer()
                      }
                      .offset(x: playbackScreenX - screenCenter)
                    )
                }
              }

            }

            // Selected spin info and controls
            if let selected = selectedSpin {
              VStack {
                Spacer()

                HStack {
                  VStack(alignment: .leading, spacing: 4) {
                    Text(selected.audioBlock.title)
                      .font(.headline)
                      .foregroundColor(.white)
                    Text(selected.audioBlock.artist)
                      .font(.subheadline)
                      .foregroundColor(.gray)
                    Text(formatTime(selected.airtime))
                      .font(.caption)
                      .foregroundColor(.gray)

                    // Volume and fade information
                    VStack(alignment: .leading, spacing: 2) {
                      Text("Start volume: \(selected.startingVolume, specifier: "%.1f")")
                        .font(.caption)
                        .foregroundColor(.gray)

                      if !selected.fades.isEmpty {
                        Text("Fades:")
                          .font(.caption)
                          .foregroundColor(.gray)

                        ForEach(Array(selected.fades.enumerated()), id: \.offset) { _, fade in
                          Text(
                            "  • to \(fade.toVolume, specifier: "%.1f") at \(formatFadeTime(fade.atMS))"
                          )
                          .font(.caption)
                          .foregroundColor(.gray)
                        }
                      }
                    }
                    .padding(.top, 4)
                  }

                  Spacer()

                  Button("Copy JSON") {
                    copyScheduleSnippet(for: selected)
                  }
                  .padding(.horizontal, 12)
                  .padding(.vertical, 8)
                  .background(Color.blue.opacity(0.8))
                  .foregroundColor(.white)
                  .cornerRadius(8)

                  Button("×") {
                    selectedSpin = nil
                  }
                  .padding(.horizontal, 12)
                  .padding(.vertical, 8)
                  .background(Color.gray.opacity(0.3))
                  .foregroundColor(.white)
                  .cornerRadius(8)
                }
                .padding()
                .background(
                  RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.8))
                )
                .padding(.horizontal)
                .padding(.bottom)
              }
            }
          }
        } else {
          Text("No schedule available")
            .foregroundColor(.white)
        }
      }
      .navigationTitle("")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .principal) {
          VStack(spacing: 2) {
            Text(
              player.stationId == selectedStationId ? "Schedule" : "Schedule (Different Station)"
            )
            .font(.headline)
            .foregroundColor(.white)

            if case .playing(let nowPlaying) = player.state {
              Text("♪ \(nowPlaying.audioBlock.title)")
                .font(.caption)
                .foregroundColor(.green)
                .lineLimit(1)
            } else if player.isPlaying {
              Text("♪ Playing...")
                .font(.caption)
                .foregroundColor(.green)
            }
          }
        }

        ToolbarItem(placement: .navigationBarLeading) {
          if player.isPlaying {
            Button(
              action: {
                Task {
                  await player.stop()
                }
              },
              label: {
                HStack {
                  Image(systemName: "stop.fill")
                  Text("Stop")
                }
              }
            )
            .foregroundColor(.red)
          } else {
            Button("Close") {
              dismiss()
            }
            .foregroundColor(.white)
          }
        }

        ToolbarItem(placement: .navigationBarTrailing) {
          Button(action: playFromIndicator) {
            HStack {
              Image(systemName: "play.fill")
              Text("Play From Here")
            }
          }
          .foregroundColor(.green)
          .disabled(schedule == nil)
        }
      }
      .onAppear {
        loadSchedule()
        startPlaybackTracking()
      }
      .onDisappear {
        stopPlaybackTracking()
      }
    }
  }

  private func loadSchedule() {
    Task {
      do {
        // Use the selected station ID
        let stationId = selectedStationId

        print("Loading schedule for station: \(stationId)")

        // Fetch schedule from API
        let url = URL(
          string:
            "https://admin-api.playola.fm/v1/stations/\(stationId)/schedule?includeRelatedTexts=true"
        )!
        let (data, response) = try await URLSession.shared.data(from: url)

        print("API Response: \(response)")
        print("Data size: \(data.count) bytes")

        // Use the custom decoder that handles the API's date format
        let decoder = JSONDecoderWithIsoFull()

        // API returns an array of spins, not a Schedule object
        let spins = try decoder.decode([Spin].self, from: data)
        let fetchedSchedule = Schedule(stationId: stationId, spins: spins)

        await MainActor.run {
          self.schedule = fetchedSchedule
          self.isLoading = false

          // Initialize the schedule time indicator to the first spin's start time
          if let firstSpin = fetchedSchedule.spins.first {
            self.scheduleTimeAtIndicator = firstSpin.airtime
          }

          // Update the time indicator for the initial scroll position
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.updateScheduleTimeAtIndicator()
          }
        }
      } catch {
        print("Error loading schedule: \(error)")
        print("Error type: \(type(of: error))")
        if let decodingError = error as? DecodingError {
          switch decodingError {
          case .dataCorrupted(let context):
            print("Data corrupted: \(context)")
          case .keyNotFound(let key, let context):
            print("Key not found: \(key), \(context)")
          case .typeMismatch(let type, let context):
            print("Type mismatch: \(type), \(context)")
          case .valueNotFound(let type, let context):
            print("Value not found: \(type), \(context)")
          @unknown default:
            print("Unknown decoding error")
          }
        }
        await MainActor.run {
          self.isLoading = false
        }
      }
    }
  }

  private func updateScheduleTimeAtIndicator() {
    guard let schedule = schedule, !schedule.spins.isEmpty else { return }

    // The scrollPosition is the minX of the HStack in the scrollView coordinate space
    // It starts at 0 and becomes negative as we scroll right
    // The visual center of the screen is always at screenWidth/2
    // So the position in our content that's at the center is: -scrollPosition + screenWidth/2
    let screenWidth = UIScreen.main.bounds.width
    let centerX = -scrollPosition + screenWidth / 2

    // Find which spin is at the center of the screen
    var accumulatedWidth: CGFloat = 16  // Initial padding to match visual layout

    for spin in schedule.spins {
      let spinWidth = calculateSpinWidth(spin: spin)
      let spinStartX = accumulatedWidth
      let spinEndX = accumulatedWidth + spinWidth

      if centerX >= spinStartX && centerX < spinEndX {
        // This spin is at the center - interpolate the time within it
        let positionInSpin = (centerX - spinStartX) / spinWidth

        // The visual width is based on endOfMessageMS, which is when the next item can start
        // But the actual audio might be longer (durationMS)
        // We should use the same duration for time calculation as we use for visual width
        let visualDurationSeconds = Double(spin.audioBlock.endOfMessageMS) / 1000.0
        let timeInSpin = visualDurationSeconds * Double(positionInSpin)
        let newTime = spin.airtime.addingTimeInterval(timeInSpin)

        scheduleTimeAtIndicator = newTime
        return
      }

      accumulatedWidth += spinWidth
    }

    // If we're before the first spin
    if centerX < 16, let firstSpin = schedule.spins.first {
      scheduleTimeAtIndicator = firstSpin.airtime
      return
    }

    // If we're past all spins, show the last spin's end time
    if let lastSpin = schedule.spins.last {
      scheduleTimeAtIndicator = lastSpin.endtime
    }
  }

  private func calculateSpinWidth(spin: Spin) -> CGFloat {
    let durationInSeconds = Double(spin.audioBlock.endOfMessageMS) / 1000.0
    let durationInMinutes = durationInSeconds / 60.0
    return CGFloat(durationInMinutes * 60 * zoomScale)
  }

  private func formatTimeForPosition() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm:ss.SS a"
    formatter.timeZone = TimeZone.current
    return formatter.string(from: scheduleTimeAtIndicator)
  }

  private func formatZoomPercentage(_ scale: CGFloat) -> String {
    let percentage = scale * 100
    if percentage < 100 {
      return String(format: "%.0f%%", percentage)
    } else if percentage < 1000 {
      return String(format: "%.0f%%", percentage)
    } else {
      return String(format: "%.1fk%%", percentage / 1000)
    }
  }

  private func formatTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    formatter.timeZone = TimeZone.current
    return formatter.string(from: date)
  }

  private func formatDuration(_ milliseconds: Int) -> String {
    let seconds = milliseconds / 1000
    let minutes = seconds / 60
    let remainingSeconds = seconds % 60
    return String(format: "%d:%02d", minutes, remainingSeconds)
  }

  private func formatFadeTime(_ milliseconds: Int) -> String {
    return String(format: "%.1f secs", Double(milliseconds) / 1000.0)
  }

  private func updateTimeBasedOnVisibleSpins() {
    guard let schedule = schedule else { return }

    // Simple approach: just update based on the stored spin positions
    // The geometry readers on each spin will handle the actual position checking
  }

  private func checkIfSpinAtCenter(spin: Spin, geometry: GeometryProxy) {
    let spinFrame = geometry.frame(in: .global)
    let screenCenter = UIScreen.main.bounds.width / 2

    // Check if this spin contains the center line
    if spinFrame.minX <= screenCenter && spinFrame.maxX >= screenCenter {
      // Calculate position within the spin (0.0 = start, 1.0 = end)
      let positionInSpin = (screenCenter - spinFrame.minX) / spinFrame.width

      // Calculate time based on position
      let spinDurationSeconds = Double(spin.audioBlock.endOfMessageMS) / 1000.0
      let timeOffsetInSpin = spinDurationSeconds * positionInSpin
      let calculatedTime = spin.airtime.addingTimeInterval(timeOffsetInSpin)

      // Update the time indicator
      DispatchQueue.main.async {
        self.scheduleTimeAtIndicator = calculatedTime
      }
    }
  }

  private func playFromIndicator() {
    // Always use the selectedStationId which is the station for this schedule
    let stationId = selectedStationId

    // Calculate the offset from current time to the indicator time
    let now = Date()
    let targetTime = scheduleTimeAtIndicator
    let offsetSeconds = targetTime.timeIntervalSince(now)

    print("Playing from indicator time: \(formatTimeForPosition())")
    print("Current time: \(now)")
    print("Offset: \(offsetSeconds) seconds")

    // Play from the calculated date/time
    Task {
      do {
        try await player.play(stationId: stationId, atDate: targetTime)
      } catch {
        print("Error starting playback: \(error)")
      }
    }

    // Don't dismiss - stay on this page to show playback status
  }

  private func startPlaybackTracking() {
    playbackTimer?.invalidate()
    playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
      updatePlaybackPosition()
    }
  }

  private func stopPlaybackTracking() {
    playbackTimer?.invalidate()
    playbackTimer = nil
    playbackPosition = nil
  }

  private func updatePlaybackPosition() {
    guard player.isPlaying else {
      playbackPosition = nil
      return
    }

    // Use the current now playing spin and estimate position based on real time
    if case .playing(let nowPlaying) = player.state {
      let now = Date()
      let timeIntoSpin = now.timeIntervalSince(nowPlaying.airtime)

      // Clamp to spin duration
      let spinDuration = Double(nowPlaying.audioBlock.endOfMessageMS) / 1000.0
      let clampedTimeIntoSpin = max(0, min(timeIntoSpin, spinDuration))

      playbackPosition = nowPlaying.airtime.addingTimeInterval(clampedTimeIntoSpin)

      // Debug logging
      let formatter = DateFormatter()
      formatter.dateFormat = "h:mm:ss a"
    } else {
      // If no specific now playing, just use current time
      playbackPosition = Date()
    }
  }

  private func calculateXPosition(for time: Date, in schedule: Schedule) -> CGFloat {
    var accumulatedWidth: CGFloat = 16  // Initial padding

    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm:ss a"

    for spin in schedule.spins {
      let spinWidth = calculateSpinWidth(spin: spin)

      // Check if time falls within this spin
      if time >= spin.airtime && time < spin.endtime {
        let timeIntoSpin = time.timeIntervalSince(spin.airtime)
        let spinDuration = Double(spin.audioBlock.endOfMessageMS) / 1000.0
        let positionInSpin = timeIntoSpin / spinDuration
        let xPosition = accumulatedWidth + (spinWidth * CGFloat(positionInSpin))
        return xPosition
      }

      accumulatedWidth += spinWidth
    }

    // If time is before first spin, return start position
    if let firstSpin = schedule.spins.first, time < firstSpin.airtime {
      return 16
    }
    // If time is after all spins, return end position
    return accumulatedWidth
  }

  private func copyScheduleSnippet(for selectedSpin: Spin) {
    guard let schedule = schedule else { return }

    // Find the index of the selected spin
    guard let selectedIndex = schedule.spins.firstIndex(where: { $0.id == selectedSpin.id }) else {
      return
    }

    // Get the spin before, selected spin, and spin after
    var spinsToExport: [Spin] = []
    if selectedIndex > 0 { spinsToExport.append(schedule.spins[selectedIndex - 1]) }
    spinsToExport.append(selectedSpin)
    if selectedIndex < schedule.spins.count - 1 {
      spinsToExport.append(schedule.spins[selectedIndex + 1])
    }

    // Create encoder with iso8601Full date format
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .formatted(.iso8601Full)
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    do {
      let jsonData = try encoder.encode(spinsToExport)
      if let jsonString = String(data: jsonData, encoding: .utf8) {
        #if os(iOS)
          UIPasteboard.general.string = jsonString
          print("Copied \(spinsToExport.count) spins to clipboard")
        #else
          print("Clipboard not available on this platform")
          print(jsonString)
        #endif
      }
    } catch {
      print("Error encoding spins: \(error)")
    }
  }
}

struct SpinVisualization: View {
  let spin: Spin
  let isSelected: Bool
  let zoomScale: CGFloat
  let onTap: () -> Void
  let onDetailInfo: ((DetailSpinInfo) -> Void)?

  // Calculate width based on duration (1 minute = 60 points * zoom scale)
  private var spinWidth: CGFloat {
    let durationInSeconds = Double(spin.audioBlock.endOfMessageMS) / 1000.0
    let durationInMinutes = durationInSeconds / 60.0
    return CGFloat(durationInMinutes * 60 * zoomScale)
  }

  // Calculate relative positions for fades
  private func fadePosition(fade: Fade) -> CGFloat {
    let totalDuration = Double(spin.audioBlock.endOfMessageMS)
    let fadeTime = Double(fade.atMS)
    return spinWidth * (fadeTime / totalDuration)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      // Time label - only show if there's enough space
      if spinWidth > 40 {
        Text(formatTime(spin.airtime))
          .font(.caption2)
          .foregroundColor(.gray)
      }

      // Spin visualization
      ZStack(alignment: .leading) {
        // Background rectangle
        RoundedRectangle(cornerRadius: 8)
          .fill(backgroundGradient)
          .frame(width: spinWidth, height: 80)
          .overlay(
            RoundedRectangle(cornerRadius: 8)
              .stroke(
                isSelected ? Color.blue : Color.gray.opacity(0.3), lineWidth: isSelected ? 2 : 1)
          )

        // Fade markers
        ForEach(Array(spin.fades.enumerated()), id: \.offset) { _, fade in
          Rectangle()
            .fill(Color.yellow.opacity(0.8))
            .frame(width: 2, height: 80)
            .offset(x: fadePosition(fade: fade))
            .overlay(
              Text("\(fade.toVolume, specifier: "%.1f")")
                .font(.system(size: 8))
                .foregroundColor(.yellow)
                .offset(x: fadePosition(fade: fade), y: -45)
            )
        }

        // Content info - only show if there's enough space
        if spinWidth > 40 {
          VStack(alignment: .leading, spacing: 1) {
            // Only show title if we have reasonable space
            if spinWidth > 80 {
              Text(spin.audioBlock.title)
                .font(.system(size: min(10, spinWidth / 8)))
                .fontWeight(.medium)
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            }

            // Only show artist if we have even more space
            if spinWidth > 120 {
              Text(spin.audioBlock.artist)
                .font(.system(size: min(8, spinWidth / 12)))
                .foregroundColor(.gray)
                .lineLimit(1)
                .truncationMode(.tail)
            }

            // Always show duration if we have basic space
            Text(formatDuration(spin.audioBlock.endOfMessageMS))
              .font(.system(size: min(8, spinWidth / 10)))
              .foregroundColor(.gray.opacity(0.8))
              .lineLimit(1)
          }
          .padding(.horizontal, min(8, spinWidth / 10))
          .padding(.vertical, 2)
          .frame(maxWidth: spinWidth - 4)
        }
      }
      .onTapGesture {
        onTap()
      }
      .background(
        GeometryReader { geometry in
          Color.clear
            .onAppear {
              checkIfShouldShowInDetailTrack(geometry: geometry)
            }
            .onChange(of: spinWidth) { _ in
              checkIfShouldShowInDetailTrack(geometry: geometry)
            }
        }
      )
    }
  }

  private var backgroundGradient: LinearGradient {
    let baseColor = colorForType(spin.audioBlock.type)
    return LinearGradient(
      gradient: Gradient(colors: [
        baseColor.opacity(0.3),
        baseColor.opacity(0.2),
      ]),
      startPoint: .leading,
      endPoint: .trailing
    )
  }

  private func colorForType(_ type: String) -> Color {
    switch type.lowercased() {
    case "song":
      return .blue
    case "commercialblock":
      return .orange
    case "audioimage":
      return .purple
    case "voicetrack":
      return .green
    default:
      return .gray
    }
  }

  private func formatTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    formatter.timeZone = TimeZone.current
    return formatter.string(from: date)
  }

  private func formatDuration(_ milliseconds: Int) -> String {
    let seconds = milliseconds / 1000
    let minutes = seconds / 60
    let remainingSeconds = seconds % 60
    return String(format: "%d:%02d", minutes, remainingSeconds)
  }

  private func checkIfShouldShowInDetailTrack(geometry: GeometryProxy) {
    // If spin is too narrow to show full info, add it to the detail track
    if spinWidth <= 80, let callback = onDetailInfo {
      let frame = geometry.frame(in: .named("scrollView"))
      let detailInfo = DetailSpinInfo(
        id: spin.id,
        spin: spin,
        originalXPosition: frame.minX,
        originalWidth: spinWidth,
        color: colorForType(spin.audioBlock.type)
      )
      callback(detailInfo)
    }
  }
}

struct DetailSpinVisualization: View {
  let detailInfo: DetailSpinInfo
  let isSelected: Bool
  let onTap: () -> Void

  // Fixed width for detail spins - big enough to show info
  private let detailWidth: CGFloat = 120
  private let detailHeight: CGFloat = 60

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      // Time label
      Text(formatTime(detailInfo.spin.airtime))
        .font(.caption2)
        .foregroundColor(.gray)

      // Spin visualization
      ZStack(alignment: .leading) {
        // Background rectangle
        RoundedRectangle(cornerRadius: 6)
          .fill(backgroundGradient)
          .frame(width: detailWidth, height: detailHeight)
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .stroke(
                isSelected ? Color.blue : Color.gray.opacity(0.3), lineWidth: isSelected ? 2 : 1)
          )

        // Content info
        VStack(alignment: .leading, spacing: 1) {
          Text(detailInfo.spin.audioBlock.title)
            .font(.system(size: 10))
            .fontWeight(.medium)
            .foregroundColor(.white)
            .lineLimit(2)
            .truncationMode(.tail)

          if !detailInfo.spin.audioBlock.artist.isEmpty {
            Text(detailInfo.spin.audioBlock.artist)
              .font(.system(size: 8))
              .foregroundColor(.gray)
              .lineLimit(1)
              .truncationMode(.tail)
          }

          Text(formatDuration(detailInfo.spin.audioBlock.endOfMessageMS))
            .font(.system(size: 8))
            .foregroundColor(.gray.opacity(0.8))
            .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: detailWidth - 4)

        // Connection line indicator
        Rectangle()
          .fill(detailInfo.color.opacity(0.6))
          .frame(width: 2, height: detailHeight)
          .offset(x: -1)
      }
    }
    .onTapGesture {
      onTap()
    }
  }

  private var backgroundGradient: LinearGradient {
    return LinearGradient(
      gradient: Gradient(colors: [
        detailInfo.color.opacity(0.3),
        detailInfo.color.opacity(0.2),
      ]),
      startPoint: .leading,
      endPoint: .trailing
    )
  }

  private func formatTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    formatter.timeZone = TimeZone.current
    return formatter.string(from: date)
  }

  private func formatDuration(_ milliseconds: Int) -> String {
    let seconds = milliseconds / 1000
    let minutes = seconds / 60
    let remainingSeconds = seconds % 60
    return String(format: "%d:%02d", minutes, remainingSeconds)
  }
}

#Preview {
  ScheduleViewer(selectedStationId: "9d79fd38-1940-4312-8fe8-3b9b50d49c6c")
}
