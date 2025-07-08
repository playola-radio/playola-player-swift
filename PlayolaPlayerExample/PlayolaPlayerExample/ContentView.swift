//
//  ContentView.swift
//  PlayolaPlayerExample
//
//  Created by Brian D Keane on 12/29/24.
//

import SwiftUI
import PlayolaPlayer

func playerStateTextFromPlayerState(_ state: PlayolaStationPlayer.State) -> String {
  switch state {
  case .idle:
    return "Idle"
  case .playing(let audioBlock):
    return "Playing \(audioBlock.title) by \(audioBlock.artist)"
  case .loading(let progress):
    return "Loading: \(roundf(progress * 100))% complete"
  }
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

struct ContentView: View {
  @ObservedObject var player = PlayolaStationPlayer.shared

    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
          Button(player.isPlaying ? "Stop" : "Play") {
            playOrPause()
          }
          .padding(.bottom, 5)

          Text("Player State: \(playerStateTextFromPlayerState(player.state))")
            .padding(.bottom, 5)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
