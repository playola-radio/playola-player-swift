//
//  ContentView.swift
//  PlayolaPlayerExample
//
//  Created by Brian D Keane on 12/29/24.
//

import SwiftUI
import PlayolaPlayer

func playOrPause() {
  let spin = PPSpin(
    key: "testKey",
    audioFileURL: URL(string: "https://test.com")!,
    startTime: Date(),
    beginFadeOutTime: Date(),
    spinInfo: [:])
  print(spin)
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
