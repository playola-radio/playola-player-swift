//
//  SpinTests.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 1/8/25.
//

import Foundation
import Testing

@testable import PlayolaPlayer

struct SpinTests {
  var spin: Spin = .mock
  let dateProviderMock = DateProviderMock()

  init() {
    spin.dateProvider = dateProviderMock
  }

  @Test("isPlaying returns false if .now is too early")
  func testIsPlaying_nowIsBeforeSpin() throws {
    // Use mockWith to create a spin with a controlled airtime
    let now = Date()
    dateProviderMock.setMockDate(now)

    // Create a spin that starts 30 seconds in the future
    let futureSpin = Spin.mockWith(
      airtime: now.addingTimeInterval(30),
      dateProvider: dateProviderMock
    )

    #expect(futureSpin.isPlaying == false)
  }

  @Test("isPlaying returns true if .now is between start and endTime")
  func testIsPlaying_nowIsDuringSpin() throws {
    // Use mockWith to create a spin that's currently playing
    let now = Date()
    dateProviderMock.setMockDate(now)

    // Create a spin that started 3 seconds ago
    let playingSpin = Spin.mockWith(
      airtime: now.addingTimeInterval(-3),
      dateProvider: dateProviderMock
    )

    #expect(playingSpin.isPlaying == true)
  }

  @Test("isPlaying returns false if .now is after endtime")
  func testIsPlaying_nowIsAfterSpin() throws {
    // Create an audio block with a specific duration
    let shortAudioBlock = AudioBlock.mockWith(
      durationMS: 10000,  // 10 second duration
      endOfMessageMS: 10000
    )

    // Set up the current time
    let now = Date()
    dateProviderMock.setMockDate(now)

    // Create a spin that started 30 seconds ago with a 10-second duration
    // This means it finished 20 seconds ago
    let finishedSpin = Spin.mockWith(
      airtime: now.addingTimeInterval(-30),
      audioBlock: shortAudioBlock,
      dateProvider: dateProviderMock
    )

    #expect(finishedSpin.isPlaying == false)
  }

  @Test("isPlaying returns true at exactly the airtime")
  func testIsPlaying_exactlyAtAirtime() throws {
    // Set up the current time
    let now = Date()
    dateProviderMock.setMockDate(now)

    // Create a spin that starts exactly now
    let startingSpin = Spin.mockWith(
      airtime: now,
      dateProvider: dateProviderMock
    )

    #expect(startingSpin.isPlaying == true)
  }

  @Test("isPlaying returns true just before endtime")
  func testIsPlaying_justBeforeEndtime() throws {
    // Create an audio block with a specific duration
    let audioBlock = AudioBlock.mockWith(
      durationMS: 10000,  // 10 second duration
      endOfMessageMS: 10000
    )

    // Set up the current time
    let now = Date()
    dateProviderMock.setMockDate(now)

    // Create a spin that started almost 10 seconds ago (just 1 millisecond before endtime)
    let almostFinishedSpin = Spin.mockWith(
      airtime: now.addingTimeInterval(-9.999),
      audioBlock: audioBlock,
      dateProvider: dateProviderMock
    )

    #expect(almostFinishedSpin.isPlaying == true)
  }

  @Test("isPlaying returns true at exactly the endtime")
  func testIsPlaying_exactlyAtEndtime() throws {
    // Create an audio block with a specific duration
    let audioBlock = AudioBlock.mockWith(
      durationMS: 10000,  // 10 second duration
      endOfMessageMS: 10000
    )

    // Set up the current time
    let now = Date()
    dateProviderMock.setMockDate(now)

    // Create a spin that started exactly 10 seconds ago (exactly at endtime)
    let justFinishedSpin = Spin.mockWith(
      airtime: now.addingTimeInterval(-10),
      audioBlock: audioBlock,
      dateProvider: dateProviderMock
    )

    #expect(justFinishedSpin.isPlaying == true)
  }

  @Test("endtime is calculated correctly from airtime and audioBlock duration")
  func testEndtimeCalculation() throws {
    // Verify the endtime is calculated as airtime + audioBlock.endOfMessageMS milliseconds
    let expectedEndtime =
      spin.airtime + TimeInterval(Double(spin.audioBlock.endOfMessageMS) / 1000.0)
    #expect(spin.endtime == expectedEndtime)
  }

  @Test("Spin plays between airtime and endtime")
  func testSpinTimeInterval() throws {
    // Create an audio block with a specific duration
    let audioBlock = AudioBlock.mockWith(
      durationMS: 15000,  // 15 second duration
      endOfMessageMS: 15000
    )

    // Set up the current time
    let now = Date()
    dateProviderMock.setMockDate(now)

    // Test with the current time before the spin's airtime
    let futureSpin = Spin.mockWith(
      airtime: now.addingTimeInterval(5),  // Starts in 5 seconds
      audioBlock: audioBlock,
      dateProvider: dateProviderMock
    )
    #expect(futureSpin.isPlaying == false)

    // Test with the current time during the spin's play interval
    let playingSpin = Spin.mockWith(
      airtime: now.addingTimeInterval(-5),  // Started 5 seconds ago
      audioBlock: audioBlock,
      dateProvider: dateProviderMock
    )
    #expect(playingSpin.isPlaying == true)

    // Test with the current time after the spin's play interval
    let finishedSpin = Spin.mockWith(
      airtime: now.addingTimeInterval(-20),  // Started 20 seconds ago
      audioBlock: audioBlock,
      dateProvider: dateProviderMock
    )
    #expect(finishedSpin.isPlaying == false)
  }

  @Test("Manual time range checking")
  func testManualTimeRangeChecking() throws {
    // Create an audio block with a specific duration
    let audioBlock = AudioBlock.mockWith(
      durationMS: 20000,  // 20 second duration
      endOfMessageMS: 20000
    )

    // Set a reference time
    let referenceTime = Date()

    // Create a spin starting at our reference time
    let testSpin = Spin.mockWith(
      airtime: referenceTime,
      audioBlock: audioBlock
    )

    // We can manually check if a time is within a spin's play range

    // Time before the spin starts (5 seconds before reference)
    let beforeTime = referenceTime.addingTimeInterval(-5)
    let isBeforeTimeInRange = beforeTime >= testSpin.airtime && beforeTime < testSpin.endtime
    #expect(isBeforeTimeInRange == false)

    // Time during the spin (10 seconds after reference, which is halfway through)
    let duringTime = referenceTime.addingTimeInterval(10)
    let isDuringTimeInRange = duringTime >= testSpin.airtime && duringTime < testSpin.endtime
    #expect(isDuringTimeInRange == true)

    // Time at exact airtime (should be in range)
    let isAirtimeInRange =
      testSpin.airtime >= testSpin.airtime && testSpin.airtime < testSpin.endtime
    #expect(isAirtimeInRange == true)

    // Time at exact endtime (should not be in range)
    let isEndtimeInRange =
      testSpin.endtime >= testSpin.airtime && testSpin.endtime < testSpin.endtime
    #expect(isEndtimeInRange == false)
  }

  @Test("Testing varying playback scenarios with custom mocks")
  func testPlaybackScenarios() throws {
    let now = Date()
    let dateProviderMock = DateProviderMock(mockDate: now)

    // Create an AudioBlock with custom duration
    let customAudioBlock = AudioBlock.mockWith(
      title: "Custom Test Track",
      artist: "Test Artist",
      durationMS: 10000,  // 10 second duration
      endOfMessageMS: 10000
    )

    // 1. Test a spin that's currently playing
    let playingSpin = Spin.mockWith(
      airtime: now.addingTimeInterval(-2),  // Started 2 seconds ago
      audioBlock: customAudioBlock,
      dateProvider: dateProviderMock
    )

    #expect(playingSpin.isPlaying)

    // 2. Test a spin that hasn't started yet
    let upcomingSpin = Spin.mockWith(
      airtime: now.addingTimeInterval(30),  // Starts in 30 seconds
      audioBlock: customAudioBlock,
      dateProvider: dateProviderMock
    )

    #expect(!upcomingSpin.isPlaying)

    // 3. Test a spin that has already finished
    let finishedSpin = Spin.mockWith(
      airtime: now.addingTimeInterval(-15),  // Started 15 seconds ago with 10 second duration
      audioBlock: customAudioBlock,
      dateProvider: dateProviderMock
    )

    #expect(!finishedSpin.isPlaying)
  }

  @Test("Spin decodes relatedTexts from JSON correctly")
  func testSpinDecodesRelatedTexts() throws {
    let jsonString = """
      {
          "id": "948fb1e9-6f86-473b-ab04-725b4de63dc4",
          "stationId": "9d79fd38-1940-4312-8fe8-3b9b50d49c6c",
          "audioBlockId": "b55a086b-7b31-47c0-bf3f-b355c8a23a4f",
          "airtime": "2025-07-08T18:17:27.867Z",
          "endOfMessageTime": "2025-07-08T14:45:18.269Z",
          "startingVolume": 1,
          "fades": [
              {
                  "atMS": 229365,
                  "toVolume": 0.3
              },
              {
                  "atMS": 238324,
                  "toVolume": 0
              },
              {
                  "atMS": 1000,
                  "toVolume": 1
              }
          ],
          "createdAt": "2025-07-08T14:45:18.255Z",
          "updatedAt": "2025-07-08T14:45:18.255Z",
          "audioBlock": {
              "endOfMessageMS": 237324,
              "s3BucketName": "playola-songs-intake",
              "downloadUrl": "https://playola-songs-intake.s3.amazonaws.com/Hozier%20--%20Take%20Me%20to%20Church.m4a",
              "beginningOfOutroMS": 229365,
              "endOfIntroMS": 1000,
              "lengthOfOutroMS": 7959,
              "earliestNextSpinStartMS": 229365,
              "overlapRole": "background",
              "id": "b55a086b-7b31-47c0-bf3f-b355c8a23a4f",
              "type": "song",
              "title": "Take Me to Church",
              "artist": "Hozier",
              "album": "Hozier (Expanded Edition)",
              "durationMS": 241693,
              "popularity": 83,
              "youTubeId": null,
              "releaseDate": "2014-09-19",
              "s3Key": "Hozier -- Take Me to Church.m4a",
              "isrc": "USSM11307291",
              "appleId": "900672609",
              "spotifyId": "1CS7Sd1u5tWkstBhpssyjP",
              "imageUrl": "https://i.scdn.co/image/ab67616d0000b2734ca68d59a4a29c856a4a39c2",
              "attributes": {},
              "precedesAudioBlocks": {},
              "limitToStations": null,
              "transcription": null,
              "createdAt": "2025-04-01T15:28:32.252Z",
              "updatedAt": "2025-07-04T20:47:35.877Z"
          },
          "relatedTexts": [
              {
                  "title": "Why I chose this song",
                  "body": "When I was in middle school I found this song and I was absolutely mesmerized by it so here it is.  This is take me to church by Hozier"
              },
              {
                  "title": "Why I chose this song",
                  "body": "Hozier is an absolute undeniable talent and I think that you need to hear it. So here is a Hozier song"
              }
          ]
      }
      """

    let jsonData = jsonString.data(using: .utf8)!

    // Set up a date formatter for the specific date format in the JSON
    let decoder = JSONDecoder()
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
    dateFormatter.timeZone = TimeZone(abbreviation: "UTC")
    decoder.dateDecodingStrategy = .formatted(dateFormatter)

    // Decode the Spin
    let spin = try decoder.decode(Spin.self, from: jsonData)

    // Test that basic properties are decoded
    #expect(spin.id == "948fb1e9-6f86-473b-ab04-725b4de63dc4")
    #expect(spin.stationId == "9d79fd38-1940-4312-8fe8-3b9b50d49c6c")
    #expect(spin.startingVolume == 1.0)

    // Test that audioBlock is decoded
    #expect(spin.audioBlock != nil)
    #expect(spin.audioBlock.id == "b55a086b-7b31-47c0-bf3f-b355c8a23a4f")
    #expect(spin.audioBlock.title == "Take Me to Church")
    #expect(spin.audioBlock.artist == "Hozier")

    // Test that fades are decoded
    #expect(spin.fades.count == 3)
    #expect(spin.fades[0].atMS == 229365)
    #expect(spin.fades[0].toVolume == 0.3)

    // Test that relatedTexts are decoded (this is the main test)
    #expect(spin.relatedTexts != nil)
    #expect(spin.relatedTexts?.count == 2)

    let firstRelatedText = spin.relatedTexts?[0]
    #expect(firstRelatedText?.title == "Why I chose this song")
    #expect(
      firstRelatedText?.body
        == "When I was in middle school I found this song and I was absolutely mesmerized by it so here it is.  This is take me to church by Hozier"
    )

    let secondRelatedText = spin.relatedTexts?[1]
    #expect(secondRelatedText?.title == "Why I chose this song")
    #expect(
      secondRelatedText?.body
        == "Hozier is an absolute undeniable talent and I think that you need to hear it. So here is a Hozier song"
    )
  }

  @Test("Spin decodes correctly when relatedTexts is missing")
  func testSpinDecodesWithoutRelatedTexts() throws {
    let jsonString = """
      {
          "id": "948fb1e9-6f86-473b-ab04-725b4de63dc4",
          "stationId": "9d79fd38-1940-4312-8fe8-3b9b50d49c6c",
          "audioBlockId": "b55a086b-7b31-47c0-bf3f-b355c8a23a4f",
          "airtime": "2025-07-08T18:17:27.867Z",
          "endOfMessageTime": "2025-07-08T14:45:18.269Z",
          "startingVolume": 1,
          "fades": [],
          "createdAt": "2025-07-08T14:45:18.255Z",
          "updatedAt": "2025-07-08T14:45:18.255Z",
          "audioBlock": {
              "endOfMessageMS": 237324,
              "s3BucketName": "playola-songs-intake",
              "downloadUrl": "https://playola-songs-intake.s3.amazonaws.com/test.m4a",
              "beginningOfOutroMS": 229365,
              "endOfIntroMS": 1000,
              "lengthOfOutroMS": 7959,
              "id": "b55a086b-7b31-47c0-bf3f-b355c8a23a4f",
              "type": "song",
              "title": "Test Song",
              "artist": "Test Artist",
              "durationMS": 241693,
              "s3Key": "test.m4a",
              "createdAt": "2025-04-01T15:28:32.252Z",
              "updatedAt": "2025-07-04T20:47:35.877Z"
          }
      }
      """

    let jsonData = jsonString.data(using: .utf8)!

    let decoder = JSONDecoder()
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
    dateFormatter.timeZone = TimeZone(abbreviation: "UTC")
    decoder.dateDecodingStrategy = .formatted(dateFormatter)

    // This should decode successfully with relatedTexts as nil
    let spin = try decoder.decode(Spin.self, from: jsonData)

    #expect(spin.id == "948fb1e9-6f86-473b-ab04-725b4de63dc4")
    #expect(spin.relatedTexts == nil)
  }
}
