//
//  SpinTests.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 1/8/25.
//
// swiftlint:disable file_length

import Foundation
import Testing

@testable import PlayolaPlayer

struct SpinTests {
    var spin: Spin = .mock
    let dateProviderMock = DateProviderMock()

    // Static JSON fixture for testing spin decoding with related texts
    // swiftlint:disable line_length
    private static let spinWithRelatedTextsJSON = """
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
                "body": "When I was in middle school I found this song and I was absolutely mesmerized by it so here it is. This is take me to church by Hozier"
            },
            {
                "title": "Why I chose this song",
                "body": "Hozier is an absolute undeniable talent and I think that you need to hear it. So here is a Hozier song"
            }
        ]
    }
    """
    // swiftlint:enable line_length

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
            durationMS: 10000, // 10 second duration
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
            durationMS: 10000, // 10 second duration
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
            durationMS: 10000, // 10 second duration
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
            durationMS: 15000, // 15 second duration
            endOfMessageMS: 15000
        )

        // Set up the current time
        let now = Date()
        dateProviderMock.setMockDate(now)

        // Test with the current time before the spin's airtime
        let futureSpin = Spin.mockWith(
            airtime: now.addingTimeInterval(5), // Starts in 5 seconds
            audioBlock: audioBlock,
            dateProvider: dateProviderMock
        )
        #expect(futureSpin.isPlaying == false)

        // Test with the current time during the spin's play interval
        let playingSpin = Spin.mockWith(
            airtime: now.addingTimeInterval(-5), // Started 5 seconds ago
            audioBlock: audioBlock,
            dateProvider: dateProviderMock
        )
        #expect(playingSpin.isPlaying == true)

        // Test with the current time after the spin's play interval
        let finishedSpin = Spin.mockWith(
            airtime: now.addingTimeInterval(-20), // Started 20 seconds ago
            audioBlock: audioBlock,
            dateProvider: dateProviderMock
        )
        #expect(finishedSpin.isPlaying == false)
    }

    @Test("Manual time range checking")
    func testManualTimeRangeChecking() throws {
        // Create an audio block with a specific duration
        let audioBlock = AudioBlock.mockWith(
            durationMS: 20000, // 20 second duration
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
            durationMS: 10000, // 10 second duration
            endOfMessageMS: 10000
        )

        // 1. Test a spin that's currently playing
        let playingSpin = Spin.mockWith(
            airtime: now.addingTimeInterval(-2), // Started 2 seconds ago
            audioBlock: customAudioBlock,
            dateProvider: dateProviderMock
        )

        #expect(playingSpin.isPlaying)

        // 2. Test a spin that hasn't started yet
        let upcomingSpin = Spin.mockWith(
            airtime: now.addingTimeInterval(30), // Starts in 30 seconds
            audioBlock: customAudioBlock,
            dateProvider: dateProviderMock
        )

        #expect(!upcomingSpin.isPlaying)

        // 3. Test a spin that has already finished
        let finishedSpin = Spin.mockWith(
            airtime: now.addingTimeInterval(-15), // Started 15 seconds ago with 10 second duration
            audioBlock: customAudioBlock,
            dateProvider: dateProviderMock
        )

        #expect(!finishedSpin.isPlaying)
    }

    @Test("Spin decodes relatedTexts from JSON correctly")
    func testSpinDecodesRelatedTexts() throws {
        let jsonString = createSpinWithRelatedTextsJSON()
        let decoder = createJSONDecoderWithDateFormatting()
        let spin = try decoder.decode(Spin.self, from: jsonString.data(using: .utf8)!)

        verifyBasicSpinProperties(spin)
        verifyAudioBlockProperties(spin)
        verifyFadeProperties(spin)
        verifyRelatedTextProperties(spin)
    }

    private func createSpinWithRelatedTextsJSON() -> String {
        return Self.spinWithRelatedTextsJSON
    }

    private func createJSONDecoderWithDateFormatting() -> JSONDecoder {
        let decoder = JSONDecoder()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        dateFormatter.timeZone = TimeZone(abbreviation: "UTC")
        decoder.dateDecodingStrategy = .formatted(dateFormatter)
        return decoder
    }

    private func verifyBasicSpinProperties(_ spin: Spin) {
        #expect(spin.id == "948fb1e9-6f86-473b-ab04-725b4de63dc4")
        #expect(spin.stationId == "9d79fd38-1940-4312-8fe8-3b9b50d49c6c")
        #expect(spin.startingVolume == 1.0)
    }

    private func verifyAudioBlockProperties(_ spin: Spin) {
        #expect(spin.audioBlock.id == "b55a086b-7b31-47c0-bf3f-b355c8a23a4f")
        #expect(spin.audioBlock.title == "Take Me to Church")
        #expect(spin.audioBlock.artist == "Hozier")
    }

    private func verifyFadeProperties(_ spin: Spin) {
        #expect(spin.fades.count == 3)
        // Fades are sorted by atMS in the initializer
        #expect(spin.fades[0].atMS == 1000)
        #expect(spin.fades[0].toVolume == 1.0)
        #expect(spin.fades[1].atMS == 229_365)
        #expect(spin.fades[1].toVolume == 0.3)
        #expect(spin.fades[2].atMS == 238_324)
        #expect(spin.fades[2].toVolume == 0.0)
    }

    private func verifyRelatedTextProperties(_ spin: Spin) {
        #expect(spin.relatedTexts?.count == 2)

        let firstText = spin.relatedTexts?[0]
        #expect(firstText?.title == "Why I chose this song")
        let expectedFirstBody =
            "When I was in middle school I found this song and I was absolutely mesmerized by it so here it is. "
                + "This is take me to church by Hozier"
        #expect(firstText?.body == expectedFirstBody)

        let secondText = spin.relatedTexts?[1]
        #expect(secondText?.title == "Why I chose this song")
        let expectedSecondBody =
            "Hozier is an absolute undeniable talent and I think that you need to hear it. "
                + "So here is a Hozier song"
        #expect(secondText?.body == expectedSecondBody)
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

    // MARK: - withOffset Tests

    @Test("withOffset creates new spin with positive offset")
    func testWithOffset_positiveOffset() throws {
        let originalAirtime = Date()
        let offset: TimeInterval = 300 // 5 minutes forward

        let originalSpin = Spin.mockWith(
            airtime: originalAirtime,
            dateProvider: dateProviderMock
        )

        let offsetSpin = originalSpin.withOffset(offset)

        // Verify new spin has adjusted airtime
        #expect(offsetSpin.airtime == originalAirtime.addingTimeInterval(offset))

        // Verify all other properties remain unchanged
        #expect(offsetSpin.id == originalSpin.id)
        #expect(offsetSpin.stationId == originalSpin.stationId)
        #expect(offsetSpin.startingVolume == originalSpin.startingVolume)
        #expect(offsetSpin.createdAt == originalSpin.createdAt)
        #expect(offsetSpin.updatedAt == originalSpin.updatedAt)
        #expect(offsetSpin.audioBlock == originalSpin.audioBlock)
        #expect(offsetSpin.fades == originalSpin.fades)
        #expect(offsetSpin.relatedTexts == originalSpin.relatedTexts)

        // Verify original spin is unchanged (immutability)
        #expect(originalSpin.airtime == originalAirtime)
    }

    @Test("withOffset creates new spin with negative offset")
    func testWithOffset_negativeOffset() throws {
        let originalAirtime = Date()
        let offset: TimeInterval = -600 // 10 minutes backward

        let originalSpin = Spin.mockWith(
            airtime: originalAirtime,
            dateProvider: dateProviderMock
        )

        let offsetSpin = originalSpin.withOffset(offset)

        // Verify new spin has adjusted airtime
        #expect(offsetSpin.airtime == originalAirtime.addingTimeInterval(offset))

        // Verify endtime is also adjusted correctly
        let expectedEndtime =
            offsetSpin.airtime + TimeInterval(Double(offsetSpin.audioBlock.endOfMessageMS) / 1000.0)
        #expect(offsetSpin.endtime == expectedEndtime)
    }

    @Test("withOffset with zero offset returns identical spin")
    func testWithOffset_zeroOffset() throws {
        let originalSpin = Spin.mockWith(dateProvider: dateProviderMock)

        let offsetSpin = originalSpin.withOffset(0)

        // All properties should be identical
        #expect(offsetSpin.airtime == originalSpin.airtime)
        #expect(offsetSpin.id == originalSpin.id)
        #expect(offsetSpin.stationId == originalSpin.stationId)
        #expect(offsetSpin.startingVolume == originalSpin.startingVolume)
        #expect(offsetSpin.createdAt == originalSpin.createdAt)
        #expect(offsetSpin.updatedAt == originalSpin.updatedAt)
        #expect(offsetSpin.audioBlock == originalSpin.audioBlock)
        #expect(offsetSpin.fades == originalSpin.fades)
        #expect(offsetSpin.relatedTexts == originalSpin.relatedTexts)
    }

    @Test("withOffset preserves dateProvider")
    func testWithOffset_preservesDateProvider() throws {
        let testDate = Date()
        let customDateProvider = DateProviderMock(mockDate: testDate)
        let originalSpin = Spin.mockWith(dateProvider: customDateProvider)

        let offsetSpin = originalSpin.withOffset(300)

        // Verify dateProvider is preserved by checking it returns the same mock date
        #expect(offsetSpin.dateProvider.now() == testDate)

        // Update the mock date to verify it's the same instance
        let newTestDate = testDate.addingTimeInterval(1000)
        customDateProvider.setMockDate(newTestDate)
        #expect(offsetSpin.dateProvider.now() == newTestDate)
    }

    @Test("withOffset affects isPlaying calculation correctly")
    func testWithOffset_affectsIsPlaying() throws {
        let now = Date()
        dateProviderMock.setMockDate(now)

        // Create a spin that is currently playing
        let playingSpin = Spin.mockWith(
            airtime: now.addingTimeInterval(-5), // Started 5 seconds ago
            dateProvider: dateProviderMock
        )

        #expect(playingSpin.isPlaying == true)

        // Offset it to the future (should no longer be playing)
        let futureOffsetSpin = playingSpin.withOffset(60) // Move 60 seconds forward
        #expect(futureOffsetSpin.isPlaying == false)

        // Offset it to the past (should have already finished)
        let audioBlock = AudioBlock.mockWith(durationMS: 10000) // 10 second duration
        let shortSpin = Spin.mockWith(
            airtime: now.addingTimeInterval(-5),
            audioBlock: audioBlock,
            dateProvider: dateProviderMock
        )

        let pastOffsetSpin = shortSpin.withOffset(-60) // Move 60 seconds backward
        #expect(pastOffsetSpin.isPlaying == false)
    }

    @Test("withOffset with very large offsets")
    func testWithOffset_largeOffsets() throws {
        let originalAirtime = Date()
        let originalSpin = Spin.mockWith(
            airtime: originalAirtime,
            dateProvider: dateProviderMock
        )

        // Test with large positive offset (1 year forward)
        let yearForward: TimeInterval = 365 * 24 * 60 * 60
        let yearForwardSpin = originalSpin.withOffset(yearForward)
        #expect(yearForwardSpin.airtime == originalAirtime.addingTimeInterval(yearForward))

        // Test with large negative offset (1 month backward)
        let monthBackward: TimeInterval = -30 * 24 * 60 * 60
        let monthBackwardSpin = originalSpin.withOffset(monthBackward)
        #expect(monthBackwardSpin.airtime == originalAirtime.addingTimeInterval(monthBackward))
    }

    @Test("withOffset preserves complex fades array")
    func testWithOffset_preservesFades() throws {
        let complexFades = [
            Fade(atMS: 1000, toVolume: 0.8),
            Fade(atMS: 5000, toVolume: 0.5),
            Fade(atMS: 10000, toVolume: 0.2),
            Fade(atMS: 15000, toVolume: 0.0),
        ]

        let originalSpin = Spin.mockWith(
            fades: complexFades,
            dateProvider: dateProviderMock
        )

        let offsetSpin = originalSpin.withOffset(300)

        // Verify fades array is preserved exactly
        #expect(offsetSpin.fades.count == complexFades.count)
        for (index, fade) in offsetSpin.fades.enumerated() {
            #expect(fade.atMS == complexFades[index].atMS)
            #expect(fade.toVolume == complexFades[index].toVolume)
        }
    }

    @Test("withOffset preserves relatedTexts")
    func testWithOffset_preservesRelatedTexts() throws {
        let relatedTexts = [
            RelatedText(title: "Story 1", body: "This is the first story"),
            RelatedText(title: "Story 2", body: "This is the second story"),
        ]

        let originalSpin = Spin.mockWith(
            relatedTexts: relatedTexts,
            dateProvider: dateProviderMock
        )

        let offsetSpin = originalSpin.withOffset(-3600) // 1 hour backward

        // Verify relatedTexts are preserved
        #expect(offsetSpin.relatedTexts?.count == relatedTexts.count)
        #expect(offsetSpin.relatedTexts?[0].title == "Story 1")
        #expect(offsetSpin.relatedTexts?[0].body == "This is the first story")
        #expect(offsetSpin.relatedTexts?[1].title == "Story 2")
        #expect(offsetSpin.relatedTexts?[1].body == "This is the second story")
    }

    @Test("withOffset chain multiple offsets")
    func testWithOffset_chainMultipleOffsets() throws {
        let originalAirtime = Date()
        let originalSpin = Spin.mockWith(
            airtime: originalAirtime,
            dateProvider: dateProviderMock
        )

        // Chain multiple offsets
        let finalSpin =
            originalSpin
                .withOffset(300) // +5 minutes
                .withOffset(-100) // -100 seconds
                .withOffset(50) // +50 seconds

        let totalOffset: TimeInterval = 300 - 100 + 50
        #expect(finalSpin.airtime == originalAirtime.addingTimeInterval(totalOffset))
    }

    // MARK: - volumeAtMS Tests

    // MARK: - volumeAt (3s look‑ahead) Tests

    @Test("volumeAt returns next fade volume when it is within 3s")
    func testVolumeAt_lookahead_hitsNextFade() throws {
        let fades = [
            Fade(atMS: 5000, toVolume: 1.0),
            Fade(atMS: 10000, toVolume: 0.2),
        ]
        let spin = Spin.mockWith(startingVolume: 0.3, fades: fades)

        // At 7.5s, current is 1.0 (from 5s fade), next fade is at 10s (within 3s)
        // Expect to return the next fade's target (0.2)
        #expect(spin.volumeAt(7500) == 0.2)

        // Just before first fade: at 3.2s, next fade at 5s (within 1.8s)
        #expect(spin.volumeAt(3200) == 1.0)
    }

    @Test("volumeAt returns current volume when next fade is beyond 3s")
    func testVolumeAt_lookahead_tooFar() throws {
        let fades = [
            Fade(atMS: 5000, toVolume: 0.7),
            Fade(atMS: 12000, toVolume: 0.4),
        ]
        let spin = Spin.mockWith(startingVolume: 0.3, fades: fades)

        // At 1s, current is 0.3; next is at 5s (delta 4s) -> return current (0.3)
        #expect(spin.volumeAt(1000) == 0.3)

        // At 8s, current is 0.7 (from 5s); next at 12s (delta 4s) -> return 0.7
        #expect(spin.volumeAt(8000) == 0.7)
    }

    @Test("volumeAt treats 3s boundary as inclusive")
    func testVolumeAt_boundaryInclusive() throws {
        let fades = [
            Fade(atMS: 5000, toVolume: 0.8),
        ]
        let spin = Spin.mockWith(startingVolume: 0.2, fades: fades)

        // At 2s, next fade at 5s -> delta 3000ms (exact). Should return next fade's target (0.8)
        #expect(spin.volumeAt(2000) == 0.8)
    }

    @Test("volumeAt handles negative ms by clamping to 0")
    func testVolumeAt_negativeClampsToZero() throws {
        let fades = [Fade(atMS: 1000, toVolume: 0.6)]
        let spin = Spin.mockWith(startingVolume: 0.4, fades: fades)

        #expect(spin.volumeAt(-500) == 0.6) // next fade at 1s is within 3s, so return 0.6
    }

    @Test("volumeAtMS returns starting volume when no fades")
    func testVolumeAtMS_noFades() throws {
        let spin = Spin.mockWith(
            startingVolume: 0.7,
            fades: []
        )

        #expect(spin.volumeAtMS(0) == 0.7)
        #expect(spin.volumeAtMS(1000) == 0.7)
        #expect(spin.volumeAtMS(10000) == 0.7)
    }

    @Test("volumeAtMS returns starting volume before first fade")
    func testVolumeAtMS_beforeFirstFade() throws {
        let fades = [
            Fade(atMS: 5000, toVolume: 0.5),
            Fade(atMS: 10000, toVolume: 0.2),
        ]

        let spin = Spin.mockWith(
            startingVolume: 1.0,
            fades: fades
        )

        #expect(spin.volumeAtMS(0) == 1.0)
        #expect(spin.volumeAtMS(2500) == 1.0)
        #expect(spin.volumeAtMS(4999) == 1.0)
    }

    @Test("volumeAtMS returns fade volume at exact fade time")
    func testVolumeAtMS_atExactFadeTime() throws {
        let fades = [
            Fade(atMS: 5000, toVolume: 0.5),
            Fade(atMS: 10000, toVolume: 0.2),
        ]

        let spin = Spin.mockWith(
            startingVolume: 1.0,
            fades: fades
        )

        #expect(spin.volumeAtMS(5000) == 0.5)
        #expect(spin.volumeAtMS(10000) == 0.2)
    }

    @Test("volumeAtMS returns last fade volume after all fades")
    func testVolumeAtMS_afterAllFades() throws {
        let fades = [
            Fade(atMS: 5000, toVolume: 0.5),
            Fade(atMS: 10000, toVolume: 0.2),
            Fade(atMS: 15000, toVolume: 0.0),
        ]

        let spin = Spin.mockWith(
            startingVolume: 1.0,
            fades: fades
        )

        #expect(spin.volumeAtMS(20000) == 0.0)
        #expect(spin.volumeAtMS(100_000) == 0.0)
    }

    @Test("volumeAtMS handles multiple fades correctly")
    func testVolumeAtMS_multipleFades() throws {
        let fades = [
            Fade(atMS: 1000, toVolume: 0.8),
            Fade(atMS: 5000, toVolume: 0.5),
            Fade(atMS: 10000, toVolume: 0.2),
            Fade(atMS: 15000, toVolume: 0.0),
        ]

        let spin = Spin.mockWith(
            startingVolume: 1.0,
            fades: fades
        )

        // Before any fades
        #expect(spin.volumeAtMS(500) == 1.0)

        // After first fade
        #expect(spin.volumeAtMS(1000) == 0.8)
        #expect(spin.volumeAtMS(3000) == 0.8)

        // After second fade
        #expect(spin.volumeAtMS(5000) == 0.5)
        #expect(spin.volumeAtMS(7500) == 0.5)

        // After third fade
        #expect(spin.volumeAtMS(10000) == 0.2)
        #expect(spin.volumeAtMS(12500) == 0.2)

        // After final fade
        #expect(spin.volumeAtMS(15000) == 0.0)
        #expect(spin.volumeAtMS(20000) == 0.0)
    }

    @Test("volumeAtMS handles unsorted fades correctly")
    func testVolumeAtMS_unsortedFades() throws {
        // Create fades in unsorted order
        let unsortedFades = [
            Fade(atMS: 10000, toVolume: 0.2),
            Fade(atMS: 1000, toVolume: 0.8),
            Fade(atMS: 15000, toVolume: 0.0),
            Fade(atMS: 5000, toVolume: 0.5),
        ]

        let spin = Spin.mockWith(
            startingVolume: 1.0,
            fades: unsortedFades
        )

        // The Spin initializer should sort these, so results should be correct
        #expect(spin.volumeAtMS(500) == 1.0)
        #expect(spin.volumeAtMS(1500) == 0.8)
        #expect(spin.volumeAtMS(6000) == 0.5)
        #expect(spin.volumeAtMS(11000) == 0.2)
        #expect(spin.volumeAtMS(16000) == 0.0)
    }

    // MARK: - volumeAtDate Tests

    @Test("volumeAtDate returns starting volume before spin airtime")
    func testVolumeAtDate_beforeAirtime() throws {
        let airtime = Date()
        let spin = Spin.mockWith(
            airtime: airtime,
            startingVolume: 0.3,
            fades: [Fade(atMS: 5000, toVolume: 1.0)]
        )

        let beforeAirtime = airtime.addingTimeInterval(-10)
        #expect(spin.volumeAtDate(beforeAirtime) == 0.3)
    }

    @Test("volumeAtDate returns correct volume at exact airtime")
    func testVolumeAtDate_atAirtime() throws {
        let airtime = Date()
        let spin = Spin.mockWith(
            airtime: airtime,
            startingVolume: 0.3,
            fades: [Fade(atMS: 5000, toVolume: 1.0)]
        )

        #expect(spin.volumeAtDate(airtime) == 0.3)
    }

    @Test("volumeAtDate returns correct volume during spin")
    func testVolumeAtDate_duringSpin() throws {
        let airtime = Date()
        let fades = [
            Fade(atMS: 5000, toVolume: 0.5),
            Fade(atMS: 10000, toVolume: 1.0),
        ]

        let spin = Spin.mockWith(
            airtime: airtime,
            startingVolume: 0.3,
            fades: fades
        )

        // 3 seconds after airtime (before first fade)
        let during1 = airtime.addingTimeInterval(3)
        #expect(spin.volumeAtDate(during1) == 0.3)

        // 5 seconds after airtime (at first fade)
        let during2 = airtime.addingTimeInterval(5)
        #expect(spin.volumeAtDate(during2) == 0.5)

        // 7.5 seconds after airtime (between fades)
        let during3 = airtime.addingTimeInterval(7.5)
        #expect(spin.volumeAtDate(during3) == 0.5)

        // 10 seconds after airtime (at second fade)
        let during4 = airtime.addingTimeInterval(10)
        #expect(spin.volumeAtDate(during4) == 1.0)

        // 15 seconds after airtime (after all fades)
        let during5 = airtime.addingTimeInterval(15)
        #expect(spin.volumeAtDate(during5) == 1.0)
    }

    @Test("volumeAtDate handles fractional seconds correctly")
    func testVolumeAtDate_fractionalSeconds() throws {
        let airtime = Date()
        let fades = [
            Fade(atMS: 1500, toVolume: 0.7), // 1.5 seconds
            Fade(atMS: 3750, toVolume: 0.4), // 3.75 seconds
        ]

        let spin = Spin.mockWith(
            airtime: airtime,
            startingVolume: 1.0,
            fades: fades
        )

        // 1.4 seconds after airtime (just before first fade)
        let time1 = airtime.addingTimeInterval(1.4)
        #expect(spin.volumeAtDate(time1) == 1.0)

        // 1.5 seconds after airtime (exactly at first fade)
        let time2 = airtime.addingTimeInterval(1.5)
        #expect(spin.volumeAtDate(time2) == 0.7)

        // 3.8 seconds after airtime (just after second fade)
        let time3 = airtime.addingTimeInterval(3.8)
        #expect(spin.volumeAtDate(time3) == 0.4)
    }

    @Test("volumeAtDate consistent with volumeAtMS")
    func testVolumeAtDate_consistentWithVolumeAtMS() throws {
        let airtime = Date()
        let fades = [
            Fade(atMS: 2000, toVolume: 0.8),
            Fade(atMS: 5000, toVolume: 0.3),
            Fade(atMS: 8000, toVolume: 0.0),
        ]

        let spin = Spin.mockWith(
            airtime: airtime,
            startingVolume: 1.0,
            fades: fades
        )

        // Test various time points
        let testPoints: [(TimeInterval, Int)] = [
            (0, 0),
            (1, 1000),
            (2, 2000),
            (3.5, 3500),
            (5, 5000),
            (7, 7000),
            (8, 8000),
            (10, 10000),
        ]

        for (seconds, milliseconds) in testPoints {
            let date = airtime.addingTimeInterval(seconds)
            let volumeFromDate = spin.volumeAtDate(date)
            let volumeFromMS = spin.volumeAtMS(milliseconds)
            #expect(volumeFromDate == volumeFromMS)
        }
    }

    @Test("volumeAtDate works with real-world fade scenario")
    func testVolumeAtDate_realWorldScenario() throws {
        let airtime = Date()

        // Simulate a typical song with intro fade-in and outro fade-out
        let fades = [
            Fade(atMS: 3700, toVolume: 1.0), // Fade in from 0.3 to 1.0 at 3.7 seconds
            Fade(atMS: 180_500, toVolume: 0.0), // Fade out to 0.0 at 180.5 seconds (3 minutes)
        ]

        let spin = Spin.mockWith(
            airtime: airtime,
            startingVolume: 0.3,
            fades: fades
        )

        // Test volume at various points
        let startTime = airtime
        #expect(spin.volumeAtDate(startTime) == 0.3)

        let afterFadeIn = airtime.addingTimeInterval(4.0)
        #expect(spin.volumeAtDate(afterFadeIn) == 1.0)

        let midSong = airtime.addingTimeInterval(90.0) // 1.5 minutes
        #expect(spin.volumeAtDate(midSong) == 1.0)

        let afterFadeOut = airtime.addingTimeInterval(181.0)
        #expect(spin.volumeAtDate(afterFadeOut) == 0.0)
    }

    // MARK: - PlaybackTiming Tests

    @Test("playbackTiming returns future when before airtime")
    func testPlaybackTiming_future() throws {
        let now = Date()
        let dateProviderMock = DateProviderMock(mockDate: now)

        let futureSpin = Spin.mockWith(
            airtime: now.addingTimeInterval(30), // 30 seconds in future
            dateProvider: dateProviderMock
        )

        #expect(futureSpin.playbackTiming == .future)
    }

    @Test("playbackTiming returns playing when during spin with enough time left")
    func testPlaybackTiming_playing() throws {
        let now = Date()
        let dateProviderMock = DateProviderMock(mockDate: now)

        // Create audio block with 60 second duration
        let audioBlock = AudioBlock.mockWith(
            durationMS: 60000,
            endOfMessageMS: 60000
        )

        let playingSpin = Spin.mockWith(
            airtime: now.addingTimeInterval(-10), // Started 10 seconds ago
            audioBlock: audioBlock,
            dateProvider: dateProviderMock
        )

        #expect(playingSpin.playbackTiming == .playing)
    }

    @Test("playbackTiming returns past when spin has finished")
    func testPlaybackTiming_pastFinished() throws {
        let now = Date()
        let dateProviderMock = DateProviderMock(mockDate: now)

        // Create audio block with 30 second duration
        let audioBlock = AudioBlock.mockWith(
            durationMS: 30000,
            endOfMessageMS: 30000
        )

        let finishedSpin = Spin.mockWith(
            airtime: now.addingTimeInterval(-60), // Started 60 seconds ago, finished 30 seconds ago
            audioBlock: audioBlock,
            dateProvider: dateProviderMock
        )

        #expect(finishedSpin.playbackTiming == .past)
    }

    @Test("playbackTiming returns past when less than 2 seconds remaining")
    func testPlaybackTiming_pastTooLate() throws {
        let now = Date()
        let dateProviderMock = DateProviderMock(mockDate: now)

        // Create audio block with 10 second duration
        let audioBlock = AudioBlock.mockWith(
            durationMS: 10000,
            endOfMessageMS: 10000
        )

        // Spin started 8.5 seconds ago, only 1.5 seconds left (less than 2 second minimum)
        let almostFinishedSpin = Spin.mockWith(
            airtime: now.addingTimeInterval(-8.5),
            audioBlock: audioBlock,
            dateProvider: dateProviderMock
        )

        #expect(almostFinishedSpin.playbackTiming == .past)
    }

    @Test("playbackTiming returns playing when exactly 2 seconds remaining")
    func testPlaybackTiming_playingAtBoundary() throws {
        let now = Date()
        let dateProviderMock = DateProviderMock(mockDate: now)

        // Create audio block with 10 second duration
        let audioBlock = AudioBlock.mockWith(
            durationMS: 10000,
            endOfMessageMS: 10000
        )

        // Spin started 8 seconds ago, exactly 2 seconds left (at the boundary)
        let boundarySpin = Spin.mockWith(
            airtime: now.addingTimeInterval(-8.0),
            audioBlock: audioBlock,
            dateProvider: dateProviderMock
        )

        #expect(boundarySpin.playbackTiming == .playing)
    }

    @Test("playbackTiming handles edge case at exact airtime")
    func testPlaybackTiming_atExactAirtime() throws {
        let now = Date()
        let dateProviderMock = DateProviderMock(mockDate: now)

        let exactTimeSpin = Spin.mockWith(
            airtime: now,
            dateProvider: dateProviderMock
        )

        #expect(exactTimeSpin.playbackTiming == .playing)
    }

    @Test("playbackTiming handles edge case at exact endtime")
    func testPlaybackTiming_atExactEndtime() throws {
        let now = Date()
        let dateProviderMock = DateProviderMock(mockDate: now)

        // Create audio block with 10 second duration
        let audioBlock = AudioBlock.mockWith(
            durationMS: 10000,
            endOfMessageMS: 10000
        )

        // Spin started exactly 10 seconds ago (at endtime)
        let endTimeSpin = Spin.mockWith(
            airtime: now.addingTimeInterval(-10.0),
            audioBlock: audioBlock,
            dateProvider: dateProviderMock
        )

        #expect(endTimeSpin.playbackTiming == .past)
    }
}
