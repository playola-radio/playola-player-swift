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
    try! await PlayolaStationPlayer.shared.play(stationId: "f3864734-de35-414f-b0b3-e6909b0b77bd")
  }
}

struct ContentView: View {
  let player = PlayolaStationPlayer.shared

    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
          Button("Play") {
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
