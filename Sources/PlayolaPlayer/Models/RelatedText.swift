//
//  RelatedText.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 7/8/25.
//

public struct RelatedText: Codable, Sendable {
  public let title: String
  public let body: String

  public init(title: String, body: String) {
    self.title = title
    self.body = body
  }
}

extension RelatedText: Equatable, Hashable {
  public func hash(into hasher: inout Hasher) {
    hasher.combine(title)
    hasher.combine(body)
  }

  public static func == (lhs: RelatedText, rhs: RelatedText) -> Bool {
    return lhs.title == rhs.title && lhs.body == rhs.body
  }
}

extension RelatedText {
  public static var mock: RelatedText {
    return RelatedText(
      title: "Why I chose this song",
      body:
        "So John Mayer was, I forget which CD it was, it was, you know, John Mayer's gone through a bunch of different "
        + "phases, and he went through this phase, I can picture the front of the record. It's got something like "
        + "Olivia "
        + "on it. Something like Olivia. Born and Raised, I think is the record it was on. He's gone through so many "
        + "different phases in his career. He's bopped in and out of every musical genre you can be in. He's done it "
        + "all. He's obviously one of the top five guitar players of all time, and I think he's a better songwriter "
        + "than he is a guitar player. And it's like, you know, it's, he's just this person who transcends what we "
        + "call music. He's just so far on his own level that it is nearly inhuman, you know. It's like just "
        + "something totally different that, that we're just kind of lucky to be existing at the same time. So this "
        + "is a song by John Mayer."
    )
  }

  public static var mocks: [RelatedText] {
    var texts = [RelatedText]()
    for i in 1..<6 {
      texts.append(
        RelatedText(
          title: "\(i) - \(RelatedText.mock.title)", body: "\(i) - \(RelatedText.mock.body)"
        ))
    }
    return texts
  }
}
