//
//  ContentView.swift
//  PlayolaPlayerExample
//
//  Created by Brian D Keane on 12/29/24.
//

import SwiftUI
import PlayolaPlayer

func playOrPause() {
  Task {
    try! await PlayolaPlayer.shared.play(stationId: "f3864734-de35-414f-b0b3-e6909b0b77bd")
  }
}

struct ContentView: View {
    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
          Button("Play") {
            playOrPause()
          }
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
